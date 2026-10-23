-- Minuto 91 / 046: V4.4 fase 2, RLS das listas grandes sem custo por linha.
--
-- Measured (docs/evidencias_v44, Postgres 17): reading the squad of a pelada (Elenco: cards of the season + members)
-- took 33 ms with 20 players, 243 ms with 100 and 540 ms with 500. Cause: the policies call a function per row
-- (private.is_active_member(pelada_id) and private.season_readable(season_id) depend on the row, so the
-- "(select ...)" wrapper cannot cache them); each call runs its own queries.
--
-- Same rules, evaluated once per query: the caller's active peladas and readable seasons are computed by two
-- functions with no row argument, and the policies test membership in those sets (hashed once).
--   private.my_active_peladas()    = the peladas where private.is_active_member(...) is true for the caller
--   private.my_readable_seasons()  = the seasons where private.season_readable(...) is true for the caller
--                                    (active member and Pelada Premium, or one of the two latest started seasons)
-- Only the four tables read in long lists change: pelada_memberships, player_cards, player_season_stats, awards.
-- The helper functions of 003/037 stay (other policies and functions use them).

create function private.my_active_peladas() returns setof uuid
language sql stable security definer set search_path = '' as $$
 select m.pelada_id from public.pelada_memberships m where m.user_id = (select auth.uid()) and m.status = 'active';
$$;

create function private.my_readable_seasons() returns setof uuid
language sql stable security definer set search_path = '' as $$
 select s.id from public.seasons s
 where s.pelada_id in (select private.my_active_peladas())
  and (private.pelada_has_premium(s.pelada_id) or s.id in (
   select x.id from public.seasons x where x.pelada_id = s.pelada_id and x.starts_on <= private.pelada_today(s.pelada_id)
   order by x.starts_on desc limit 2));
$$;

revoke all on function private.my_active_peladas(), private.my_readable_seasons() from public, anon;
grant execute on function private.my_active_peladas(), private.my_readable_seasons() to authenticated; -- used by policies

drop policy memberships_read_peers on public.pelada_memberships;
create policy memberships_read_peers on public.pelada_memberships for select to authenticated
 using (pelada_id in (select private.my_active_peladas()));

drop policy cards_read on public.player_cards;
create policy cards_read on public.player_cards for select to authenticated
 using (pelada_id in (select private.my_active_peladas()) and season_id in (select private.my_readable_seasons())
  and exists(select 1 from public.pelada_memberships m where m.id = membership_id and m.status <> 'retired'));

drop policy season_stats_read on public.player_season_stats;
create policy season_stats_read on public.player_season_stats for select to authenticated
 using (pelada_id in (select private.my_active_peladas()) and season_id in (select private.my_readable_seasons()));

drop policy awards_read_members on public.awards;
create policy awards_read_members on public.awards for select to authenticated
 using (pelada_id in (select private.my_active_peladas()) and season_id in (select private.my_readable_seasons()));
