-- Minuto 91 / 032: block hides the profile row in BOTH directions (fix of 029; audit V3, 22/10/2026).
-- Problem: profiles_read_peers (023, kept by 029) only checked "the reader blocked the owner". Whoever
-- WAS blocked could still read the blocker's profile row (display_name, avatar_path) straight from
-- the table and, through avatars_read (027, which follows profiles RLS), get a signed URL to the
-- blocker's photo. 029 already promised "both directions" for the global area (blocked_either_way).
-- Fix: the peer branch uses private.blocked_either_way too.
-- Legitimate access inside the pelada is kept: the member nickname (pelada_memberships.player_name),
-- statistics, sheets, rankings and cards do not depend on this row; the app already falls back to the
-- nickname and the initials when the profile row is not readable (same as the blocker side since 023).
-- Old app versions: they read only id, display_name and avatar_path (029); a hidden row is the same case
-- they already handle for the blocker. Rollback: recreate the 029 policy (not recommended).

drop policy profiles_read_peers on public.profiles;
create policy profiles_read_peers on public.profiles for select to authenticated
 using (((select private.shares_pelada(id)) and not (select private.blocked_either_way(id)))
  or (profile_visibility = 'public' and (select private.can_view_global(id, 'public'))));
