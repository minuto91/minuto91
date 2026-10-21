-- Minuto 91 / 014: season/career statistics and player cards (Doc 02 RN-053..069,
-- RN-077..081, Doc 03 sec. 18-19, Doc 04 sec. 23-24). Formulas validated in
-- docs/simulacao_formulas.xlsx (formula_version 1).
-- Everything here is a projection rebuilt from official results (finalized, never
-- annulled matches), so annulments (020) can recompute it.
-- Card (one per member and season; guests have none):
--  recency weight 2 for the 5 most recent matches played, 1 before;
--  Finalização = min(100, 100 * weighted goals per match / 1);
--  Garçom      = min(100, 100 * weighted assists per match / 0.5);
--  Presença    = 100 * matches played / finalized season matches since joining (no weights);
--  Pé Quente   = 100 * weighted points (win 1, draw 0.5, loss 0);
--  Resenha     = 10 * weighted peer rating V of matches with a valid rating; 50 if none.
--  Overall: position weights (position snapshot of the latest match played).
--  Provisional (< 5 matches): [b*(5-n) + calculated*n]/5, b = 0.7*previous season overall
--  + 0.3*50, or 50 for a debutant. Tier on round(overall): bronze < 60 <= prata < 80 <= ouro.
-- Snapshots of every recomputed card are kept per finalized match (RN-069).
-- Streaks count only matches played: wins (draw/loss break), unbeaten (loss breaks),
-- displayed final rating >= 8.0 (a played match without valid rating breaks).

create table public.player_season_stats (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 season_id uuid not null,
 membership_id uuid not null,
 matches_played integer not null default 0,
 wins integer not null default 0,
 draws integer not null default 0,
 losses integer not null default 0,
 goals integer not null default 0,
 assists integer not null default 0,
 red_cards integer not null default 0,
 valid_ratings integer not null default 0,
 avg_final_rating numeric(8,6),
 high_ratings integer not null default 0,
 best_final_rating numeric(8,6),
 max_goals_in_match integer not null default 0,
 craque_awards integer not null default 0,
 best_win_streak integer not null default 0,
 best_unbeaten_streak integer not null default 0,
 best_high_rating_streak integer not null default 0,
 current_win_streak integer not null default 0,
 current_unbeaten_streak integer not null default 0,
 current_high_rating_streak integer not null default 0,
 updated_at timestamptz not null default now(),
 foreign key (season_id, pelada_id) references public.seasons(id, pelada_id),
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 unique (season_id, membership_id)
);

-- Same counters over the whole career in the pelada (Premium view in 019).
create table public.player_career_stats (like public.player_season_stats including defaults including constraints);
alter table public.player_career_stats drop column season_id;
alter table public.player_career_stats add primary key (id),
 add foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 add unique (membership_id);

create table public.player_cards (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 season_id uuid not null,
 membership_id uuid not null,
 position text not null check (position in ('goalkeeper','defender','midfielder','attacker')),
 finishing numeric(9,6) not null check (finishing between 0 and 100),
 assisting numeric(9,6) not null check (assisting between 0 and 100),
 attendance numeric(9,6) not null check (attendance between 0 and 100),
 winning numeric(9,6) not null check (winning between 0 and 100),
 peer_rating numeric(9,6) not null check (peer_rating between 0 and 100),
 overall numeric(9,6) not null check (overall between 0 and 100),
 tier text not null check (tier in ('bronze','prata','ouro')),
 is_provisional boolean not null,
 matches_played integer not null,
 formula_version integer not null,
 updated_at timestamptz not null default now(),
 foreign key (season_id, pelada_id) references public.seasons(id, pelada_id),
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 unique (season_id, membership_id)
);

create table public.card_snapshots (
 id uuid primary key default gen_random_uuid(),
 card_id uuid not null references public.player_cards(id) on delete cascade,
 match_id uuid not null references public.matches(id),
 snapshot_data jsonb not null,
 formula_version integer not null,
 created_at timestamptz not null default now(),
 unique (card_id, match_id)
);
create index idx_card_snapshots_card on public.card_snapshots(card_id, created_at);

alter table public.player_season_stats enable row level security;
alter table public.player_career_stats enable row level security;
alter table public.player_cards enable row level security;
alter table public.card_snapshots enable row level security;
revoke all on public.player_season_stats, public.player_career_stats, public.player_cards,
 public.card_snapshots from anon,authenticated;
grant select on public.player_season_stats, public.player_career_stats, public.player_cards,
 public.card_snapshots to authenticated;
create policy season_stats_read on public.player_season_stats for select to authenticated
 using ((select private.is_active_member(pelada_id)));
create policy career_stats_read on public.player_career_stats for select to authenticated
 using ((select private.is_active_member(pelada_id)));
create policy cards_read on public.player_cards for select to authenticated
 using ((select private.is_active_member(pelada_id)));
create policy card_snapshots_read on public.card_snapshots for select to authenticated
 using (exists(select 1 from public.player_cards c where c.id=card_id));
-- No client writes.

-- Official results of a member, oldest first (p_season null = whole career).
create function private.official_results(p_membership uuid, p_season uuid)
returns table(match_id uuid, played_at timestamptz, match_result text, goals integer, assists integer,
 has_valid_rating boolean, final_rating numeric, peer_rating numeric, position_snapshot text)
language sql stable security definer set search_path = '' as $$
 select r.match_id, m.played_at, r.match_result, r.goals, r.assists, r.has_valid_rating, r.final_rating,
  r.peer_rating, r.position_snapshot
 from public.match_player_results r join public.matches m on m.id=r.match_id
 where r.membership_id=p_membership and m.status='finalized'
  and (p_season is null or m.season_id=p_season)
 order by m.played_at, m.id;
$$;

create function private.streaks(p_membership uuid, p_season uuid,
 out best_win integer, out best_unbeaten integer, out best_high integer,
 out cur_win integer, out cur_unbeaten integer, out cur_high integer)
language plpgsql stable security definer set search_path = '' as $$
declare r record;
begin
 best_win:=0; best_unbeaten:=0; best_high:=0; cur_win:=0; cur_unbeaten:=0; cur_high:=0;
 for r in select * from private.official_results(p_membership, p_season) loop
  cur_win := case when r.match_result='win' then cur_win+1 else 0 end;
  cur_unbeaten := case when r.match_result<>'loss' then cur_unbeaten+1 else 0 end;
  cur_high := case when r.has_valid_rating and round(r.final_rating,1) >= 8 then cur_high+1 else 0 end;
  best_win := greatest(best_win,cur_win);
  best_unbeaten := greatest(best_unbeaten,cur_unbeaten);
  best_high := greatest(best_high,cur_high);
 end loop;
end $$;

-- Aggregated counters of one member (season or career) as a row of player_season_stats.
create function private.compute_stats(p_pelada uuid, p_membership uuid, p_season uuid)
returns public.player_season_stats
language plpgsql stable security definer set search_path = '' as $$
declare s public.player_season_stats; k record;
begin
 select count(*), count(*) filter (where match_result='win'), count(*) filter (where match_result='draw'),
  count(*) filter (where match_result='loss'), coalesce(sum(r.goals),0), coalesce(sum(r.assists),0),
  coalesce(sum(r.red_cards),0), count(*) filter (where r.has_valid_rating),
  round(avg(r.final_rating) filter (where r.has_valid_rating),6),
  count(*) filter (where r.has_valid_rating and round(r.final_rating,1) >= 8),
  max(r.final_rating), coalesce(max(r.goals),0)
 into s.matches_played, s.wins, s.draws, s.losses, s.goals, s.assists, s.red_cards, s.valid_ratings,
  s.avg_final_rating, s.high_ratings, s.best_final_rating, s.max_goals_in_match
 from public.match_player_results r join public.matches m on m.id=r.match_id
 where r.membership_id=p_membership and m.status='finalized' and (p_season is null or m.season_id=p_season);
 select count(*) into s.craque_awards from public.awards a
 where a.membership_id=p_membership and a.award_type='match_craque' and a.status='active'
  and (p_season is null or a.season_id=p_season);
 select * into k from private.streaks(p_membership, p_season);
 s.best_win_streak:=k.best_win; s.best_unbeaten_streak:=k.best_unbeaten; s.best_high_rating_streak:=k.best_high;
 s.current_win_streak:=k.cur_win; s.current_unbeaten_streak:=k.cur_unbeaten; s.current_high_rating_streak:=k.cur_high;
 s.pelada_id:=p_pelada; s.season_id:=p_season; s.membership_id:=p_membership;
 return s;
end $$;

create function private.recompute_stats(p_pelada uuid, p_season uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_mem uuid; s public.player_season_stats;
begin
 delete from public.player_season_stats where season_id=p_season;
 delete from public.player_career_stats where pelada_id=p_pelada;
 for v_mem in select distinct r.membership_id from public.match_player_results r
   join public.matches m on m.id=r.match_id where m.pelada_id=p_pelada and m.status='finalized' loop
  s := private.compute_stats(p_pelada, v_mem, null);
  insert into public.player_career_stats(pelada_id,membership_id,matches_played,wins,draws,losses,goals,assists,
   red_cards,valid_ratings,avg_final_rating,high_ratings,best_final_rating,max_goals_in_match,craque_awards,
   best_win_streak,best_unbeaten_streak,best_high_rating_streak,current_win_streak,current_unbeaten_streak,
   current_high_rating_streak)
  values(p_pelada,v_mem,s.matches_played,s.wins,s.draws,s.losses,s.goals,s.assists,s.red_cards,s.valid_ratings,
   s.avg_final_rating,s.high_ratings,s.best_final_rating,s.max_goals_in_match,s.craque_awards,s.best_win_streak,
   s.best_unbeaten_streak,s.best_high_rating_streak,s.current_win_streak,s.current_unbeaten_streak,
   s.current_high_rating_streak);
  s := private.compute_stats(p_pelada, v_mem, p_season);
  if s.matches_played > 0 then
   s.id := gen_random_uuid(); s.updated_at := now();
   insert into public.player_season_stats values (s.*);
  end if;
 end loop;
end $$;

create function private.recompute_card(p_season uuid, p_membership uuid, p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_s public.seasons; v_played integer; v_sw numeric; v_g numeric; v_a numeric; v_pts numeric;
 v_swr numeric; v_vr numeric; v_first timestamptz; v_pos text; v_realized integer; v_joined timestamptz;
 fin numeric; gar numeric; pres numeric; pq numeric; res numeric; w numeric[]; v_calc numeric;
 v_prev numeric; v_b numeric; v_overall numeric; v_tier text; v_card uuid;
begin
 select * into v_s from public.seasons where id=p_season;
 with o as (select r.*, row_number() over (order by r.played_at desc, r.match_id desc) rn
            from private.official_results(p_membership, p_season) r),
  x as (select o.*, case when rn<=5 then 2 else 1 end wt from o)
 select count(*), sum(wt), sum(wt*goals), sum(wt*assists),
  sum(wt*case match_result when 'win' then 1 when 'draw' then 0.5 else 0 end),
  coalesce(sum(wt) filter (where has_valid_rating),0), sum(wt*peer_rating) filter (where has_valid_rating),
  min(played_at), (array_agg(position_snapshot order by rn))[1]
 into v_played, v_sw, v_g, v_a, v_pts, v_swr, v_vr, v_first, v_pos from x;

 if v_played = 0 then
  delete from public.player_cards where season_id=p_season and membership_id=p_membership;
  return;
 end if;

 select joined_at into v_joined from public.pelada_memberships where id=p_membership;
 select count(*) into v_realized from public.matches
 where season_id=p_season and status='finalized' and played_at >= least(v_joined, v_first);

 fin := least(100, 100*v_g/v_sw/1.0);
 gar := least(100, 100*v_a/v_sw/0.5);
 pres := 100.0*v_played/greatest(v_realized, v_played);
 pq := 100*v_pts/v_sw;
 res := case when v_swr=0 then 50 else 10*v_vr/v_swr end;
 -- Finalização, Garçom, Presença, Pé Quente, Resenha (Doc 03 sec. 19).
 w := case v_pos when 'attacker' then array[0.35,0.15,0.15,0.15,0.20]
                 when 'midfielder' then array[0.15,0.30,0.15,0.15,0.25]
                 when 'defender' then array[0.05,0.10,0.20,0.25,0.40]
                 else array[0.00,0.05,0.20,0.25,0.50] end;
 v_calc := fin*w[1] + gar*w[2] + pres*w[3] + pq*w[4] + res*w[5];

 select c.overall into v_prev from public.player_cards c join public.seasons s on s.id=c.season_id
 where c.membership_id=p_membership and s.pelada_id=v_s.pelada_id and s.ends_on < v_s.starts_on
 order by s.ends_on desc limit 1;
 v_b := case when v_prev is null then 50 else 0.7*v_prev + 0.3*50 end;
 v_overall := case when v_played < 5 then (v_b*(5-v_played) + v_calc*v_played)/5 else v_calc end;
 v_tier := case when round(v_overall,0) < 60 then 'bronze' when round(v_overall,0) < 80 then 'prata' else 'ouro' end;

 insert into public.player_cards(pelada_id,season_id,membership_id,position,finishing,assisting,attendance,
  winning,peer_rating,overall,tier,is_provisional,matches_played,formula_version)
 values(v_s.pelada_id,p_season,p_membership,v_pos,round(fin,6),round(gar,6),round(pres,6),round(pq,6),
  round(res,6),round(v_overall,6),v_tier,v_played<5,v_played,1)
 on conflict (season_id, membership_id) do update set position=excluded.position, finishing=excluded.finishing,
  assisting=excluded.assisting, attendance=excluded.attendance, winning=excluded.winning,
  peer_rating=excluded.peer_rating, overall=excluded.overall, tier=excluded.tier,
  is_provisional=excluded.is_provisional, matches_played=excluded.matches_played,
  formula_version=excluded.formula_version, updated_at=now()
 returning id into v_card;

 if p_match is not null then
  insert into public.card_snapshots(card_id,match_id,snapshot_data,formula_version)
  select c.id, p_match, jsonb_build_object('position',c.position,'finishing',c.finishing,'assisting',c.assisting,
   'attendance',c.attendance,'winning',c.winning,'peer_rating',c.peer_rating,'overall',c.overall,'tier',c.tier,
   'is_provisional',c.is_provisional,'matches_played',c.matches_played), 1
  from public.player_cards c where c.id=v_card
  on conflict (card_id, match_id) do update set snapshot_data=excluded.snapshot_data, created_at=now();
 end if;
end $$;

-- Recomputes every card of the season (Presença changes for everyone at each match).
create function private.recompute_cards(p_season uuid, p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_mem uuid;
begin
 for v_mem in select membership_id from public.player_cards where season_id=p_season
   union select r.membership_id from public.match_player_results r join public.matches m on m.id=r.match_id
   where m.season_id=p_season and m.status='finalized' loop
  perform private.recompute_card(p_season, v_mem, p_match);
 end loop;
end $$;

-- Hook for 015 (rankings, awards, highlights). Replaced there.
create function private.after_cards_updated(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 null;
end $$;

-- Replaces the 013 hook.
create or replace function private.after_match_finalized(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches;
begin
 select * into v_m from public.matches where id=p_match;
 perform private.recompute_stats(v_m.pelada_id, v_m.season_id);
 perform private.recompute_cards(v_m.season_id, p_match);
 perform private.after_cards_updated(p_match);
end $$;

revoke all on function private.official_results(uuid,uuid), private.streaks(uuid,uuid),
 private.compute_stats(uuid,uuid,uuid), private.recompute_stats(uuid,uuid),
 private.recompute_card(uuid,uuid,uuid), private.recompute_cards(uuid,uuid),
 private.after_cards_updated(uuid) from public,anon,authenticated;
