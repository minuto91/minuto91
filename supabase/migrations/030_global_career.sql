-- Minuto 91 / 030: global career of a player (evolution V2, parts 4-5). Read-only: everything comes
-- from the official projections (014 stats and cards, 013/015 awards, 016 round selection), which
-- already exclude non-finalized and annulled matches. Nothing is recomputed here.
-- PRODUCT DECISIONS (22/10/2026):
--  - Visibility: career_visibility of the owner (029). Not visible -> {"visible": false} only.
--  - Premium (PRD sec. 7, RN-083 "histórico completo e carreira"): per pelada, a Premium pelada (or
--    the beta) shows every season; a free pelada shows only the current and the previous season
--    (same rule as check_season_access, 015). "hidden_seasons" tells how many were left out.
--    The overall totals add up exactly the seasons shown, so they never mix in hidden data.
--  - Peladas: the ones the player is in and the ones they left (history kept). Retired records
--    ("Aposentado") belong to no navigable profile and are never included. A transferred account
--    brings its memberships, so its career follows (024).
--  - Counters are summed (each match belongs to one pelada and one season: no double counting).
--    Averages and streaks are not summed: they are shown per season only.
--  - Achievements: official awards (Craque da Partida, Rei do Mês, Artilheiro, Garçom do mês,
--    Maior Evolução) and Seleção da Rodada. Bola Murcha is not an achievement and is left out.
--    No overall is invented: cards (with the 5 official attributes) are shown per pelada and season.

create function private.career_seasons(p_pelada uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
 select s.id from public.seasons s
 where s.pelada_id = p_pelada and (private.pelada_has_premium(p_pelada) or s.id in (
  select x.id from public.seasons x where x.pelada_id = p_pelada
   and x.starts_on <= private.pelada_today(p_pelada) order by x.starts_on desc limit 2));
$$;
revoke all on function private.career_seasons(uuid) from public, anon;
grant execute on function private.career_seasons(uuid) to authenticated;

create function public.get_player_career(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_level text; v_peladas jsonb; v_achievements jsonb; v_totals jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select career_visibility into v_level from public.profiles where id = p_user;
 if not found or not private.can_view_global(p_user, v_level) then
  return jsonb_build_object('visible', false);
 end if;

 with mem as (
  select m.id, m.pelada_id, m.status, m.preferred_position, m.joined_at, p.name, p.crest_path,
   private.pelada_has_premium(m.pelada_id) full_history
  from public.pelada_memberships m join public.peladas p on p.id = m.pelada_id
  where m.user_id = p_user and m.status in ('active','left')),
 st as (
  select mem.id membership_id, s.id season_id, s.name, s.starts_on, s.ends_on, s.status season_status,
   x.matches_played, x.wins, x.draws, x.losses, x.goals, x.assists, x.red_cards, x.craque_awards,
   x.valid_ratings, x.avg_final_rating, c.overall, c.tier, c.is_provisional, c.position card_position,
   c.finishing, c.assisting, c.attendance, c.winning, c.peer_rating, c.matches_played card_matches,
   s.id in (select private.career_seasons(mem.pelada_id)) shown
  from mem join public.player_season_stats x on x.membership_id = mem.id
  join public.seasons s on s.id = x.season_id
  left join public.player_cards c on c.membership_id = mem.id and c.season_id = s.id
  where x.matches_played > 0)
 select coalesce(jsonb_agg(jsonb_build_object(
   'pelada_id', mem.pelada_id, 'name', mem.name, 'crest_path', mem.crest_path, 'membership_id', mem.id,
   'status', mem.status, 'position', mem.preferred_position, 'joined_at', mem.joined_at,
   'full_history', mem.full_history,
   'hidden_seasons', (select count(*) from st where st.membership_id = mem.id and not st.shown),
   'totals', (select jsonb_build_object('matches_played', coalesce(sum(matches_played),0), 'wins', coalesce(sum(wins),0),
      'draws', coalesce(sum(draws),0), 'losses', coalesce(sum(losses),0), 'goals', coalesce(sum(goals),0),
      'assists', coalesce(sum(assists),0), 'red_cards', coalesce(sum(red_cards),0),
      'craque_awards', coalesce(sum(craque_awards),0))
     from st where st.membership_id = mem.id and st.shown),
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

 with mem as (
  select m.id, m.pelada_id, p.name from public.pelada_memberships m join public.peladas p on p.id = m.pelada_id
  where m.user_id = p_user and m.status in ('active','left')),
 ach as (
  select a.award_type kind, mem.pelada_id, mem.name pelada_name, s.name season_name, a.period_month,
   mt.played_at, a.is_shared, coalesce(mt.played_at, a.period_month::timestamptz, a.created_at) sort_at
  from mem join public.awards a on a.membership_id = mem.id
  join public.seasons s on s.id = a.season_id
  left join public.matches mt on mt.id = a.match_id
  where a.status = 'active' and a.award_type <> 'bola_murcha'
   and a.season_id in (select private.career_seasons(mem.pelada_id))
  union all
  select 'round_selection', mem.pelada_id, mem.name, s.name, null, mt.played_at, false, mt.played_at
  from mem join public.round_selection_players rp on rp.membership_id = mem.id
  join public.round_selections r on r.id = rp.selection_id and r.status = 'published'
  join public.matches mt on mt.id = r.match_id and mt.status = 'finalized'
  join public.seasons s on s.id = mt.season_id
  where mt.season_id in (select private.career_seasons(mem.pelada_id)))
 select coalesce(jsonb_agg(jsonb_build_object('type', kind, 'pelada_id', pelada_id, 'pelada_name', pelada_name,
   'season_name', season_name, 'period_month', period_month, 'played_at', played_at, 'is_shared', is_shared)
   order by sort_at desc), '[]'::jsonb)
 into v_achievements from ach;

 select jsonb_build_object(
  'matches_played', coalesce(sum((e->'totals'->>'matches_played')::int),0),
  'wins', coalesce(sum((e->'totals'->>'wins')::int),0), 'draws', coalesce(sum((e->'totals'->>'draws')::int),0),
  'losses', coalesce(sum((e->'totals'->>'losses')::int),0), 'goals', coalesce(sum((e->'totals'->>'goals')::int),0),
  'assists', coalesce(sum((e->'totals'->>'assists')::int),0),
  'red_cards', coalesce(sum((e->'totals'->>'red_cards')::int),0),
  'craque_awards', coalesce(sum((e->'totals'->>'craque_awards')::int),0))
 into v_totals from jsonb_array_elements(v_peladas) e;

 return jsonb_build_object('visible', true, 'is_me', p_user = auth.uid(), 'totals', v_totals,
  'peladas', v_peladas, 'achievements', v_achievements);
end $$;

revoke all on function public.get_player_career(uuid) from public, anon, authenticated;
grant execute on function public.get_player_career(uuid) to authenticated;
