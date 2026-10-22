-- Minuto 91 / 033: evolution of a player's Card in a season (V4.1, profile and evolution).
-- Source: public.card_snapshots (014), written for every card of the season each time a match is
-- finalized, with the five attributes, overall, tier, position and provisional flag. No new storage:
-- the history is the official one and nothing earlier is invented.
-- Rules:
--  * only snapshots of matches still 'finalized' (an annulled match drops out; 020 recomputes the Card
--    without a snapshot, so 'current' carries the official value after an annulment);
--  * same access as rankings and records: active member of the pelada, and seasons older than the
--    previous one need the pelada's Premium (private.check_season_access, RN-083);
--  * the membership must belong to the season's pelada (no cross-pelada reads);
--  * 'played' tells whether the player was in that match (Presença changes for everyone each match);
--  * also returns the season's official Craque count and the months of Rei do Mês (active awards).
-- Formulas are untouched (formula_version stays 1).

create function public.get_player_evolution(p_membership uuid, p_season uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_pelada uuid; v_points jsonb; v_current jsonb; v_kings jsonb; v_craque integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 v_pelada := private.check_season_access(p_season);
 if not exists(select 1 from public.pelada_memberships where id=p_membership and pelada_id=v_pelada) then
  raise exception 'MEMBER_NOT_FOUND'; end if;

 select coalesce(jsonb_agg(jsonb_build_object(
   'match_id', m.id, 'played_at', m.played_at,
   'played', exists(select 1 from public.match_player_results r where r.match_id=m.id and r.membership_id=p_membership),
   'overall', (s.snapshot_data->>'overall')::numeric, 'finishing', (s.snapshot_data->>'finishing')::numeric,
   'assisting', (s.snapshot_data->>'assisting')::numeric, 'attendance', (s.snapshot_data->>'attendance')::numeric,
   'winning', (s.snapshot_data->>'winning')::numeric, 'peer_rating', (s.snapshot_data->>'peer_rating')::numeric,
   'tier', s.snapshot_data->>'tier', 'position', s.snapshot_data->>'position',
   'is_provisional', (s.snapshot_data->>'is_provisional')::boolean)
   order by m.played_at, m.id), '[]'::jsonb)
 into v_points
 from public.player_cards c
 join public.card_snapshots s on s.card_id=c.id
 join public.matches m on m.id=s.match_id and m.status='finalized'
 where c.membership_id=p_membership and c.season_id=p_season;

 select jsonb_build_object('overall', c.overall, 'finishing', c.finishing, 'assisting', c.assisting,
   'attendance', c.attendance, 'winning', c.winning, 'peer_rating', c.peer_rating, 'tier', c.tier,
   'position', c.position, 'is_provisional', c.is_provisional, 'updated_at', c.updated_at)
 into v_current from public.player_cards c where c.membership_id=p_membership and c.season_id=p_season;

 select coalesce(jsonb_agg(a.period_month order by a.period_month), '[]'::jsonb) into v_kings
 from public.awards a where a.membership_id=p_membership and a.season_id=p_season
  and a.award_type='monthly_king' and a.status='active';
 select count(*) into v_craque from public.awards a where a.membership_id=p_membership and a.season_id=p_season
  and a.award_type='match_craque' and a.status='active';

 return jsonb_build_object('points', v_points, 'current', v_current, 'monthly_king', v_kings, 'craque', v_craque);
end $$;

revoke all on function public.get_player_evolution(uuid,uuid) from public, anon;
grant execute on function public.get_player_evolution(uuid,uuid) to authenticated;
