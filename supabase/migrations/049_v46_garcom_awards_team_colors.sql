-- Minuto 91 / 049: V4.6 — prêmios Garçom da Partida e Garçom do Mês; cor dos times na súmula.
--
-- Decisions approved by the founder on 23/10/2026 (V4.6):
--  * Garçom da Partida (match_garcom): official award with history. At least 1 assist; only players of the official
--    (finalized) match; most assists wins; ties: every leader receives it; no assist, no award. Granted after the
--    match is finalized (same moment as the cards); independent per pelada. It does not depend on the voting being
--    valid (it is an objective statistic, like goals). The old "Garçom da rodada" highlight (015) stays as it is.
--  * Garçom do Mês (monthly_garcom): replaces top_assist (015), which is no longer granted. Old top_assist rows stay
--    in the table (history kept, not shown by the V4.6 app). Rule: at least 2 assists and at least 1 official match
--    in the calendar month (match date in the pelada timezone, not the date the stats were entered). Tiebreak:
--    1) total assists; 2) assists per match played; 3) matches with at least one assist; 4) still tied: all receive.
--    The average is compared exactly: among players with the same total, the higher average is the one with fewer
--    matches (a/n1 > a/n2 <=> n1 < n2), so there is no rounding. Team victory is not required.
--  * Both are idempotent (rerunning with the same data changes nothing and sends no new notification), are
--    reprocessed when a match is finalized late or annulled (020 revokes the awards of the match and recomputes its
--    month) and never cross peladas. Retired members get no new award (RN-106), as in 021.
--  * Closed months and finalized matches are backfilled once here, WITHOUT notifications (history only).
--  * Team colors: optional, from a fixed palette, chosen by the admin/assistant on the match sheet
--    (set_match_team_colors). Used by the Seleção da Rodada (border of each player = color of the team the player was
--    on in that match). No color is invented: without a color the app draws a neutral border.
-- Overall formulas, the Seleção algorithm and the sticker criteria are unchanged.

---------------------------------------------------------------------------------------------------
-- Award types
---------------------------------------------------------------------------------------------------

do $$
declare v_name text;
begin
 select c.conname into v_name from pg_constraint c
 where c.conrelid = 'public.awards'::regclass and c.contype = 'c' and pg_get_constraintdef(c.oid) like '%award_type%';
 execute format('alter table public.awards drop constraint %I', v_name);
end $$;
alter table public.awards add constraint awards_award_type_check check (award_type in
 ('match_craque','bola_murcha','monthly_king','top_scorer','top_assist','most_improved','match_garcom','monthly_garcom'));

---------------------------------------------------------------------------------------------------
-- Garçom da Partida
---------------------------------------------------------------------------------------------------

-- (Re)computes the Garçom da Partida of one match. Idempotent: only the difference is written.
create function private.grant_match_garcom(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_w uuid[] := '{}';
begin
 select * into v_m from public.matches where id = p_match;
 if not found then return; end if;
 if v_m.status = 'finalized' then
  with r as (
   select r.membership_id, r.assists from public.match_player_results r
   join public.pelada_memberships pm on pm.id = r.membership_id and pm.pelada_id = v_m.pelada_id and pm.status <> 'retired'
   where r.match_id = p_match and r.pelada_id = v_m.pelada_id and r.assists >= 1)
  select coalesce(array_agg(r.membership_id order by r.membership_id), '{}') into v_w
  from r where r.assists = (select max(assists) from r);
 end if;

 update public.awards set status = 'revoked', revoked_at = now()
 where match_id = p_match and award_type = 'match_garcom' and status = 'active' and not (membership_id = any(v_w));
 update public.awards set is_shared = cardinality(v_w) > 1
 where match_id = p_match and award_type = 'match_garcom' and status = 'active' and is_shared <> (cardinality(v_w) > 1);
 insert into public.awards(pelada_id, match_id, season_id, membership_id, award_type, is_shared)
 select v_m.pelada_id, p_match, v_m.season_id, w, 'match_garcom', cardinality(v_w) > 1 from unnest(v_w) w
 where not exists(select 1 from public.awards a where a.match_id = p_match and a.award_type = 'match_garcom'
  and a.status = 'active' and a.membership_id = w);
end $$;

---------------------------------------------------------------------------------------------------
-- Garçom do Mês
---------------------------------------------------------------------------------------------------

-- (Re)computes the Garçom do Mês of an ended month. Idempotent: only the difference is written. Months that are not
-- over are left untouched (close_month also waits for votings of the month to end before calling this).
create function private.grant_monthly_garcom(p_pelada uuid, p_month date) returns void
language plpgsql security definer set search_path = '' as $$
declare v_start date := date_trunc('month', p_month)::date; v_end date; v_season uuid; v_w uuid[] := '{}';
begin
 v_end := (v_start + interval '1 month')::date;
 if private.pelada_today(p_pelada) < v_end then return; end if;
 select r.season_id into v_season from private.month_results(p_pelada, v_start, v_end) r order by r.played_at desc limit 1;
 if v_season is not null then
  with t as (
   select r.membership_id, sum(r.assists)::int a, count(*)::int n, (count(*) filter (where r.assists >= 1))::int k
   from private.month_results(p_pelada, v_start, v_end) r
   join public.pelada_memberships pm on pm.id = r.membership_id and pm.pelada_id = p_pelada and pm.status <> 'retired'
   group by r.membership_id),
  e as (select * from t where a >= 2 and n >= 1),
  s1 as (select * from e where a = (select max(a) from e)),
  s2 as (select * from s1 where n = (select min(n) from s1)), -- same total: best average = fewest matches (exact)
  s3 as (select * from s2 where k = (select max(k) from s2))
  select coalesce(array_agg(membership_id order by membership_id), '{}') into v_w from s3;
 end if;

 update public.awards set status = 'revoked', revoked_at = now()
 where pelada_id = p_pelada and period_month = v_start and award_type = 'monthly_garcom' and status = 'active'
  and not (membership_id = any(v_w));
 update public.awards set is_shared = cardinality(v_w) > 1
 where pelada_id = p_pelada and period_month = v_start and award_type = 'monthly_garcom' and status = 'active'
  and is_shared <> (cardinality(v_w) > 1);
 insert into public.awards(pelada_id, season_id, membership_id, award_type, period_month, is_shared)
 select p_pelada, v_season, w, 'monthly_garcom', v_start, cardinality(v_w) > 1 from unnest(v_w) w
 where not exists(select 1 from public.awards a where a.pelada_id = p_pelada and a.period_month = v_start
  and a.award_type = 'monthly_garcom' and a.status = 'active' and a.membership_id = w);
end $$;

-- (Re)computes the monthly awards of an ended month. Idempotent.
create or replace function private.close_month(p_pelada uuid, p_month date) returns void
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

 -- V4.6: Garçom do Mês (monthly_garcom) no lugar do antigo top_assist, que não é mais concedido.
 perform private.grant_monthly_garcom(p_pelada, v_start);

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

-- Replaces 015: the Garçom da Partida is granted with the cards, before the highlights and the months.
create or replace function private.after_cards_updated(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid;
begin
 select pelada_id into v_pelada from public.matches where id=p_match;
 perform private.grant_match_garcom(p_match);
 perform private.refresh_highlights(p_match);
 perform private.close_pending_months(v_pelada, p_match);
 perform private.after_rankings_updated(p_match);
end $$;

revoke all on function private.grant_match_garcom(uuid), private.grant_monthly_garcom(uuid,date) from public, anon, authenticated;

---------------------------------------------------------------------------------------------------
-- Sala de Troféus: five official awards
---------------------------------------------------------------------------------------------------

create or replace function public.get_player_career_summary(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_level text; v_peladas jsonb; v_trophies jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select career_visibility into v_level from public.profiles where id = p_user;
 if not found or not private.can_view_global(p_user, v_level) then return jsonb_build_object('visible', false); end if;

 with mem as (
  select m.id, m.pelada_id, m.status, m.preferred_position, m.position_code, m.joined_at, p.name, p.crest_path,
   private.pelada_has_premium(m.pelada_id) full_history,
   array(select private.career_seasons(m.pelada_id)) shown_seasons
  from public.pelada_memberships m join public.peladas p on p.id = m.pelada_id
  where m.user_id = p_user and m.status in ('active','left')),
 st as (
  select mem.id membership_id, s.id season_id, s.name, s.starts_on, s.ends_on, s.status season_status,
   x.matches_played, x.wins, x.draws, x.losses, x.goals, x.assists, x.red_cards, x.craque_awards,
   x.valid_ratings, x.avg_final_rating, c.overall, c.tier, c.is_provisional, c.position card_position,
   c.finishing, c.assisting, c.attendance, c.winning, c.peer_rating, c.matches_played card_matches,
   s.id = any(mem.shown_seasons) shown
  from mem join public.player_season_stats x on x.membership_id = mem.id
  join public.seasons s on s.id = x.season_id
  left join public.player_cards c on c.membership_id = mem.id and c.season_id = s.id
  where x.matches_played > 0),
 tr as (
  select a.membership_id, a.award_type, count(*) n
  from mem join public.awards a on a.membership_id = mem.id
  where a.status = 'active' and a.award_type in ('match_craque','monthly_king','bola_murcha','match_garcom','monthly_garcom')
   and a.season_id = any(mem.shown_seasons)
  group by a.membership_id, a.award_type)
 select coalesce(jsonb_agg(jsonb_build_object(
   'pelada_id', mem.pelada_id, 'name', mem.name, 'crest_path', mem.crest_path, 'membership_id', mem.id,
   'status', mem.status, 'position', mem.preferred_position, 'position_code', mem.position_code,
   'joined_at', mem.joined_at, 'full_history', mem.full_history,
   'hidden_seasons', (select count(*) from st where st.membership_id = mem.id and not st.shown),
   'totals', (select jsonb_build_object('matches_played', coalesce(sum(matches_played),0), 'wins', coalesce(sum(wins),0),
      'draws', coalesce(sum(draws),0), 'losses', coalesce(sum(losses),0), 'goals', coalesce(sum(goals),0),
      'assists', coalesce(sum(assists),0), 'red_cards', coalesce(sum(red_cards),0),
      'craque_awards', coalesce(sum(craque_awards),0))
     from st where st.membership_id = mem.id and st.shown),
   'trophies', jsonb_build_object(
      'match_craque', coalesce((select n from tr where tr.membership_id = mem.id and tr.award_type = 'match_craque'), 0),
      'monthly_king', coalesce((select n from tr where tr.membership_id = mem.id and tr.award_type = 'monthly_king'), 0),
      'bola_murcha', coalesce((select n from tr where tr.membership_id = mem.id and tr.award_type = 'bola_murcha'), 0),
      'match_garcom', coalesce((select n from tr where tr.membership_id = mem.id and tr.award_type = 'match_garcom'), 0),
      'monthly_garcom', coalesce((select n from tr where tr.membership_id = mem.id and tr.award_type = 'monthly_garcom'), 0)),
   'seasons', coalesce((select jsonb_agg(jsonb_build_object('season_id', season_id, 'name', name,
      'starts_on', starts_on, 'ends_on', ends_on, 'status', season_status, 'matches_played', matches_played,
      'wins', wins, 'draws', draws, 'losses', losses, 'goals', goals, 'assists', assists, 'red_cards', red_cards,
      'craque_awards', craque_awards, 'valid_ratings', valid_ratings, 'avg_final_rating', avg_final_rating,
      'card', case when overall is null then null else jsonb_build_object('overall', overall, 'tier', tier,
       'is_provisional', is_provisional, 'position', card_position, 'finishing', finishing, 'assisting', assisting,
       'attendance', attendance, 'winning', winning, 'peer_rating', peer_rating, 'matches_played', card_matches) end)
      order by starts_on desc)
     from st where st.membership_id = mem.id and st.shown), '[]'::jsonb))
  order by mem.status, mem.joined_at), '[]'::jsonb)
 into v_peladas from mem;

 select jsonb_build_object(
  'match_craque', coalesce(sum((e->'trophies'->>'match_craque')::int), 0),
  'monthly_king', coalesce(sum((e->'trophies'->>'monthly_king')::int), 0),
  'bola_murcha', coalesce(sum((e->'trophies'->>'bola_murcha')::int), 0),
  'match_garcom', coalesce(sum((e->'trophies'->>'match_garcom')::int), 0),
  'monthly_garcom', coalesce(sum((e->'trophies'->>'monthly_garcom')::int), 0))
 into v_trophies from jsonb_array_elements(v_peladas) e;

 return jsonb_build_object('visible', true, 'is_me', p_user = auth.uid(),
  'totals', (select jsonb_build_object(
    'matches_played', coalesce(sum((e->'totals'->>'matches_played')::int),0),
    'wins', coalesce(sum((e->'totals'->>'wins')::int),0), 'draws', coalesce(sum((e->'totals'->>'draws')::int),0),
    'losses', coalesce(sum((e->'totals'->>'losses')::int),0), 'goals', coalesce(sum((e->'totals'->>'goals')::int),0),
    'assists', coalesce(sum((e->'totals'->>'assists')::int),0),
    'red_cards', coalesce(sum((e->'totals'->>'red_cards')::int),0),
    'craque_awards', coalesce(sum((e->'totals'->>'craque_awards')::int),0))
   from jsonb_array_elements(v_peladas) e),
  'partial', exists(select 1 from jsonb_array_elements(v_peladas) e where (e->>'hidden_seasons')::int > 0),
  'trophies', v_trophies, 'peladas', v_peladas);
end $$;

create or replace function public.get_trophy_history(p_user uuid, p_type text, p_after jsonb default null, p_limit integer default 20)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_level text; v_lim integer := private.page_limit(p_limit, 20, 50); a_at timestamptz; a_id uuid; v_items jsonb;
 v_next jsonb; v_n integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_type is null or p_type not in ('match_craque','monthly_king','bola_murcha','match_garcom','monthly_garcom') then raise exception 'INVALID_TROPHY'; end if;
 select career_visibility into v_level from public.profiles where id = p_user;
 if not found or not private.can_view_global(p_user, v_level) then return jsonb_build_object('visible', false); end if;
 if p_after is not null then
  begin a_at := (p_after->>'at')::timestamptz; a_id := (p_after->>'id')::uuid;
  exception when others then raise exception 'INVALID_CURSOR'; end;
  if a_at is null or a_id is null then raise exception 'INVALID_CURSOR'; end if;
 end if;

 with mem as (
  select m.id, m.pelada_id, p.name, p.crest_path, array(select private.career_seasons(m.pelada_id)) shown
  from public.pelada_memberships m join public.peladas p on p.id = m.pelada_id
  where m.user_id = p_user and m.status in ('active','left')),
 t as (
  select a.id, a.match_id, a.period_month, a.is_shared, mem.pelada_id, mem.name pelada_name, mem.crest_path,
   s.name season_name, mt.played_at, mt.team_a_name, mt.team_b_name, mt.team_a_score, mt.team_b_score,
   coalesce(mt.played_at, (a.period_month::timestamp at time zone 'UTC'), a.created_at) sort_at
  from mem join public.awards a on a.membership_id = mem.id
  join public.seasons s on s.id = a.season_id
  left join public.matches mt on mt.id = a.match_id
  where a.status = 'active' and a.award_type = p_type and a.season_id = any(mem.shown)),
 page as (select * from t where a_id is null or (t.sort_at, t.id) < (a_at, a_id) order by t.sort_at desc, t.id desc limit v_lim + 1)
 -- Placar e nomes dos times só para o próprio jogador e para quem joga naquela pelada (perfil público mostra o
 -- troféu, a pelada e a data, como get_player_career).
 select coalesce(jsonb_agg(jsonb_build_object('id', id, 'match_id', case when inside then match_id end, 'period_month', period_month,
   'is_shared', is_shared, 'pelada_id', pelada_id, 'pelada_name', pelada_name, 'crest_path', case when inside then crest_path end,
   'season_name', season_name, 'played_at', played_at,
   'team_a_name', case when inside then team_a_name end, 'team_b_name', case when inside then team_b_name end,
   'team_a_score', case when inside then team_a_score end, 'team_b_score', case when inside then team_b_score end, 'at', sort_at)
   order by sort_at desc, id desc), '[]'::jsonb), count(*)
 into v_items, v_n
 from (select page.*, p_user = auth.uid() or private.is_active_member(page.pelada_id) inside from page) page;

 if v_n > v_lim then
  v_items := (select jsonb_agg(x order by o) from jsonb_array_elements(v_items) with ordinality q(x, o) where o <= v_lim);
  v_next := jsonb_build_object('at', v_items->(v_lim-1)->'at', 'id', v_items->(v_lim-1)->'id');
 end if;
 return jsonb_build_object('visible', true, 'items', v_items, 'next', v_next);
end $$;

---------------------------------------------------------------------------------------------------
-- Team colors
---------------------------------------------------------------------------------------------------

alter table public.matches add column team_a_color text, add column team_b_color text;
alter table public.matches add constraint match_team_colors_check check (
 (team_a_color is null or team_a_color in ('azul','branco','preto','vermelho','amarelo','laranja','roxo','rosa'))
 and (team_b_color is null or team_b_color in ('azul','branco','preto','vermelho','amarelo','laranja','roxo','rosa'))
 and (team_a_color is null or team_b_color is null or team_a_color <> team_b_color));

-- Admin or assistant; any match of the pelada except an annulled one. null clears the color.
create function public.set_match_team_colors(p_match uuid, p_team_a_color text, p_team_b_color text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_a text := nullif(btrim(p_team_a_color), ''); v_b text := nullif(btrim(p_team_b_color), '');
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id = p_match for update;
 if not found or not private.is_active_member(v_m.pelada_id) then raise exception 'MATCH_NOT_FOUND'; end if;
 if not private.is_active_staff(v_m.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 if v_m.status = 'annulled' then raise exception 'MATCH_ANNULLED'; end if;
 if (v_a is not null and v_a not in ('azul','branco','preto','vermelho','amarelo','laranja','roxo','rosa'))
  or (v_b is not null and v_b not in ('azul','branco','preto','vermelho','amarelo','laranja','roxo','rosa')) then
  raise exception 'INVALID_TEAM_COLOR'; end if;
 if v_a is not null and v_a = v_b then raise exception 'TEAM_COLORS_EQUAL'; end if;
 update public.matches set team_a_color = v_a, team_b_color = v_b where id = p_match
  and (team_a_color is distinct from v_a or team_b_color is distinct from v_b);
end $$;
revoke all on function public.set_match_team_colors(uuid,text,text) from public, anon;
grant execute on function public.set_match_team_colors(uuid,text,text) to authenticated;

---------------------------------------------------------------------------------------------------
-- Backfill (history only, no notifications)
---------------------------------------------------------------------------------------------------

alter table public.awards disable trigger award_notifications;
do $$
declare r record;
begin
 for r in select id from public.matches where status = 'finalized' order by played_at, id loop
  perform private.grant_match_garcom(r.id);
 end loop;
 for r in select pelada_id, period_month from public.monthly_closures order by pelada_id, period_month loop
  perform private.grant_monthly_garcom(r.pelada_id, r.period_month);
 end loop;
end $$;
alter table public.awards enable trigger award_notifications;
