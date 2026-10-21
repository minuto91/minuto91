-- Minuto 91 / 015: rankings, monthly awards, highlights and records (Doc 02 RN-070..085,
-- RN-118, Doc 03 sec. 20, Doc 04 sec. 25.2).
-- Highlights (craque, garcom_round, bola_murcha) belong to the last finalized match of
-- the pelada; the previous ones expire when a new match is finalized. Garçom da
-- rodada = most assists in the match (min. 1), ties shared.
-- Monthly awards (month in the pelada timezone), recomputed whenever a match of that
-- month is finalized after the month ended (late matches included); a month closes
-- only when none of its matches is still being voted:
--  monthly_king  (Rei do Mês): best average of valid final ratings, min. 3 valid
--                 matches; tie -> more Craque titles in the month; still tied -> shared;
--  top_scorer / top_assist: most goals / assists (min. 1), ties shared;
--  most_improved: biggest overall gain in the month (published snapshots), min. 3
--                 matches played; players whose position changed in the month do not
--                 compete (product decision); gain must be > 0; ties shared.
-- Rankings use competition ranking (1, 1, 3) over official values.
-- Records: current and previous season free; older seasons Premium (RN-083).
-- No public ranking of red cards (RN-085).

create table public.highlights (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null,
 membership_id uuid not null,
 highlight_type text not null check (highlight_type in ('craque','garcom_round','bola_murcha')),
 created_at timestamptz not null default now(),
 expires_at timestamptz,
 foreign key (match_id, pelada_id) references public.matches(id, pelada_id),
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 unique (match_id, membership_id, highlight_type)
);
create index idx_highlights_active on public.highlights(pelada_id) where expires_at is null;

create table public.monthly_closures (
 pelada_id uuid not null references public.peladas(id),
 period_month date not null check (extract(day from period_month)=1),
 closed_at timestamptz not null default now(),
 primary key (pelada_id, period_month)
);

alter table public.highlights enable row level security;
alter table public.monthly_closures enable row level security;
revoke all on public.highlights, public.monthly_closures from anon,authenticated;
grant select on public.highlights, public.monthly_closures to authenticated;
create policy highlights_read on public.highlights for select to authenticated
 using ((select private.is_active_member(pelada_id)));
create policy closures_read on public.monthly_closures for select to authenticated
 using ((select private.is_active_member(pelada_id)));
-- No client writes.

create function private.refresh_highlights(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid;
begin
 select pelada_id into v_pelada from public.matches where id=p_match;
 update public.highlights set expires_at=now() where pelada_id=v_pelada and expires_at is null and match_id<>p_match;
 delete from public.highlights where match_id=p_match;
 insert into public.highlights(pelada_id,match_id,membership_id,highlight_type)
 select v_pelada, p_match, membership_id, case award_type when 'match_craque' then 'craque' else 'bola_murcha' end
 from public.awards where match_id=p_match and status='active' and award_type in ('match_craque','bola_murcha');
 insert into public.highlights(pelada_id,match_id,membership_id,highlight_type)
 select v_pelada, p_match, membership_id, 'garcom_round' from public.match_player_results
 where match_id=p_match and assists >= 1
  and assists=(select max(assists) from public.match_player_results where match_id=p_match);
end $$;

-- Grants the awards of p_award_type to the rows of p_winners (membership, votes/value).
create function private.grant_month_award(p_pelada uuid, p_season uuid, p_month date, p_type text,
 p_winners uuid[]) returns void
language sql security definer set search_path = '' as $$
 insert into public.awards(pelada_id,season_id,membership_id,award_type,period_month,is_shared)
 select p_pelada, p_season, w, p_type, p_month, cardinality(p_winners) > 1 from unnest(p_winners) w;
$$;

-- Official results of the matches played in [p_start, p_end) (pelada timezone).
create function private.month_results(p_pelada uuid, p_start date, p_end date)
returns table(membership_id uuid, match_id uuid, final_rating numeric, has_valid_rating boolean,
 goals integer, assists integer, season_id uuid, played_at timestamptz)
language sql stable security definer set search_path = '' as $$
 select r.membership_id, r.match_id, r.final_rating, r.has_valid_rating, r.goals, r.assists, m.season_id, m.played_at
 from public.match_player_results r join public.matches m on m.id=r.match_id
 where m.pelada_id=p_pelada and m.status='finalized'
  and private.pelada_local_date(p_pelada, m.played_at) >= p_start
  and private.pelada_local_date(p_pelada, m.played_at) < p_end;
$$;

-- (Re)computes the monthly awards of an ended month. Idempotent.
create function private.close_month(p_pelada uuid, p_month date) returns void
language plpgsql security definer set search_path = '' as $$
declare v_start date := date_trunc('month', p_month)::date; v_end date; v_season uuid; v_w uuid[];
begin
 v_end := (v_start + interval '1 month')::date;
 if private.pelada_today(p_pelada) < v_end then return; end if; -- month not over
 if exists(select 1 from public.matches where pelada_id=p_pelada and status in ('voting_open','finalizing')
   and private.pelada_local_date(pelada_id, played_at) >= v_start
   and private.pelada_local_date(pelada_id, played_at) < v_end) then return; end if;

 update public.awards set status='revoked', revoked_at=now()
 where pelada_id=p_pelada and period_month=v_start and status='active';
 insert into public.monthly_closures(pelada_id,period_month) values(p_pelada,v_start)
 on conflict (pelada_id, period_month) do update set closed_at=now();
 select r.season_id into v_season from private.month_results(p_pelada,v_start,v_end) r
 order by r.played_at desc limit 1;
 if v_season is null then return; end if; -- no finalized match in the month

 -- Rei do Mês: average of valid ratings (min. 3), then Craque titles in the month.
 with mr as (select * from private.month_results(p_pelada,v_start,v_end)),
 k as (
  select r.membership_id, avg(r.final_rating) a,
   (select count(*) from public.awards aw where aw.membership_id=r.membership_id and aw.status='active'
    and aw.award_type='match_craque' and aw.match_id in (select match_id from mr)) c
  from mr r where r.has_valid_rating group by r.membership_id having count(*) >= 3),
 top as (select * from k where a=(select max(a) from k))
 select array_agg(membership_id) into v_w from top where c=(select max(c) from top);
 if v_w is not null then perform private.grant_month_award(p_pelada,v_season,v_start,'monthly_king',v_w); end if;

 with t as (select membership_id, sum(goals) g from private.month_results(p_pelada,v_start,v_end) group by 1)
 select array_agg(membership_id) into v_w from t where g >= 1 and g=(select max(g) from t);
 if v_w is not null then perform private.grant_month_award(p_pelada,v_season,v_start,'top_scorer',v_w); end if;

 with t as (select membership_id, sum(assists) a from private.month_results(p_pelada,v_start,v_end) group by 1)
 select array_agg(membership_id) into v_w from t where a >= 1 and a=(select max(a) from t);
 if v_w is not null then perform private.grant_month_award(p_pelada,v_season,v_start,'top_assist',v_w); end if;

 -- Maior evolução: last published overall before the month (or the first one in it)
 -- vs the last one in the month; any position change in the period excludes the player.
 with snaps as (
  select c.membership_id, (s.snapshot_data->>'overall')::numeric ov, s.snapshot_data->>'position' pos,
   private.pelada_local_date(p_pelada, m.played_at) d, m.played_at, m.id mid
  from public.card_snapshots s join public.player_cards c on c.id=s.card_id
  join public.matches m on m.id=s.match_id
  where c.pelada_id=p_pelada and m.status='finalized' and private.pelada_local_date(p_pelada, m.played_at) < v_end),
 cand as (select membership_id from private.month_results(p_pelada,v_start,v_end) group by 1 having count(*) >= 3),
 g as (
  select c.membership_id, b.ov ov0, b.pos pos0, f.ov ov_first, l.ov ov1,
   (select count(distinct pos) from snaps x where x.membership_id=c.membership_id and x.d >= v_start) npos,
   (select min(pos) from snaps x where x.membership_id=c.membership_id and x.d >= v_start) mpos
  from cand c
  left join lateral (select ov, pos from snaps x where x.membership_id=c.membership_id and x.d < v_start
   order by x.played_at desc, x.mid desc limit 1) b on true
  left join lateral (select ov from snaps x where x.membership_id=c.membership_id and x.d >= v_start
   order by x.played_at, x.mid limit 1) f on true
  left join lateral (select ov from snaps x where x.membership_id=c.membership_id and x.d >= v_start
   order by x.played_at desc, x.mid desc limit 1) l on true),
 e as (select membership_id, ov1 - coalesce(ov0, ov_first) gain from g
  where npos = 1 and (pos0 is null or pos0 = mpos))
 select array_agg(membership_id) into v_w from e where gain > 0 and gain=(select max(gain) from e);
 if v_w is not null then perform private.grant_month_award(p_pelada,v_season,v_start,'most_improved',v_w); end if;
end $$;

-- Closes every ended month of the pelada that has finalized matches and is not
-- closed yet, plus the month of p_match (late matches recompute their month).
create function private.close_pending_months(p_pelada uuid, p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_month date;
begin
 for v_month in
  select distinct date_trunc('month', private.pelada_local_date(p_pelada, m.played_at))::date mo
  from public.matches m where m.pelada_id=p_pelada and m.status='finalized'
   and (m.id=p_match or not exists(select 1 from public.monthly_closures c where c.pelada_id=p_pelada
    and c.period_month=date_trunc('month', private.pelada_local_date(p_pelada, m.played_at))::date))
  order by 1 loop
  perform private.close_month(p_pelada, v_month);
 end loop;
end $$;

-- Hook for 016 (Seleção da Rodada). Replaced there.
create function private.after_rankings_updated(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 null;
end $$;

-- Replaces the 014 hook.
create or replace function private.after_cards_updated(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid;
begin
 select pelada_id into v_pelada from public.matches where id=p_match;
 perform private.refresh_highlights(p_match);
 perform private.close_pending_months(v_pelada, p_match);
 perform private.after_rankings_updated(p_match);
end $$;

-- Free: current and previous season; older seasons need Premium (RN-083).
create function private.check_season_access(p_season uuid) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_s public.seasons; v_cur public.seasons;
begin
 select * into v_s from public.seasons where id=p_season;
 if not found or not private.is_active_member(v_s.pelada_id) then raise exception 'SEASON_NOT_FOUND'; end if;
 select * into v_cur from public.seasons where pelada_id=v_s.pelada_id
  and starts_on <= private.pelada_today(v_s.pelada_id) order by starts_on desc limit 1;
 if v_s.id <> v_cur.id and not private.pelada_has_premium(v_s.pelada_id) and v_s.id is distinct from
   (select id from public.seasons where pelada_id=v_s.pelada_id and starts_on < v_cur.starts_on
    order by starts_on desc limit 1) then
  raise exception 'PREMIUM_REQUIRED'; end if;
 return v_s.pelada_id;
end $$;

-- Season ranking with competition positions (1, 1, 3).
-- p_metric: overall | goals | assists | avg_rating | matches | wins.
-- avg_rating lists only players with at least one valid rating.
create function public.get_season_ranking(p_season uuid, p_metric text)
returns table(rank_position bigint, membership_id uuid, metric_value numeric)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
 perform private.check_season_access(p_season);
 if p_metric is null or p_metric not in ('overall','goals','assists','avg_rating','matches','wins') then
  raise exception 'INVALID_METRIC'; end if;
 return query
 select rank() over (order by t.v desc), t.mem, t.v from (
  select c.membership_id mem, c.overall v from public.player_cards c where p_metric='overall' and c.season_id=p_season
  union all
  select s.membership_id, case p_metric when 'goals' then s.goals when 'assists' then s.assists
   when 'matches' then s.matches_played when 'wins' then s.wins else s.avg_final_rating end
  from public.player_season_stats s where p_metric<>'overall' and s.season_id=p_season
   and (p_metric<>'avg_rating' or s.avg_final_rating is not null)) t
 order by 1, 2;
end $$;

-- Season records (RN-077), each with all holders in case of a tie (RN-084).
create function public.get_season_records(p_season uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 perform private.check_season_access(p_season);
 return jsonb_build_object(
  'biggest_win', (select jsonb_agg(jsonb_build_object('match_id',id,'team_a_score',team_a_score,'team_b_score',team_b_score))
    from public.matches where season_id=p_season and status='finalized' and team_a_score<>team_b_score
    and abs(team_a_score-team_b_score)=(select max(abs(team_a_score-team_b_score)) from public.matches
     where season_id=p_season and status='finalized')),
  'most_goals_in_match', private.record_holders(p_season, 'max_goals_in_match'),
  'best_final_rating', private.record_holders(p_season, 'best_final_rating'),
  'best_win_streak', private.record_holders(p_season, 'best_win_streak'),
  'best_unbeaten_streak', private.record_holders(p_season, 'best_unbeaten_streak'),
  'best_high_rating_streak', private.record_holders(p_season, 'best_high_rating_streak'));
end $$;

create function private.record_holders(p_season uuid, p_col text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
 execute format($q$
  select jsonb_build_object('value', max(%1$I), 'membership_ids',
   (select jsonb_agg(membership_id) from public.player_season_stats where season_id=$1
    and %1$I=(select max(%1$I) from public.player_season_stats where season_id=$1) and %1$I > 0))
  from public.player_season_stats where season_id=$1 $q$, p_col) into v using p_season;
 return v;
end $$;

revoke all on function private.refresh_highlights(uuid), private.grant_month_award(uuid,uuid,date,text,uuid[]),
 private.month_results(uuid,date,date),
 private.close_month(uuid,date), private.close_pending_months(uuid,uuid), private.after_rankings_updated(uuid),
 private.check_season_access(uuid), private.record_holders(uuid,text) from public,anon,authenticated;
revoke all on function public.get_season_ranking(uuid,text), public.get_season_records(uuid) from public,anon;
grant execute on function public.get_season_ranking(uuid,text), public.get_season_records(uuid) to authenticated;
