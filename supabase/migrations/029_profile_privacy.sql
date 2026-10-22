-- Minuto 91 / 029: profile and career visibility (evolution V2, part 6; Política v1.2 sec. 7
-- "configurações de visibilidade"). PRODUCT DECISIONS (22/10/2026):
--  - Two independent settings: profile_visibility and career_visibility, each
--    'private' (only the owner), 'peladas' (authenticated users who share an ACTIVE pelada with
--    the owner) or 'public' (any authenticated user). Default 'peladas' for everyone, which is
--    exactly what peers could already see before this migration (no wider exposure).
--  - Inside a pelada nothing changes: name, photo, card, stats and rankings stay visible to the
--    pelada's members whatever the settings (the ritual and the official records need them).
--    The settings protect the GLOBAL area: dominant foot, the list of the owner's peladas,
--    achievements from other peladas and the global career (030).
--  - 'public' also lets any authenticated user read the profile row (name and photo).
--  - Blocks: whoever blocked or was blocked by the owner sees nothing global, in both directions.
--    A deactivated (transferred) account, or one with a pending deletion, shows nothing global.
--  - Photos keep the 027 rules (short signed URLs; a link already issued lasts until it expires,
--    at most 15 min in the app; CDN cache 5 min). Images shared outside the app cannot be recalled.
-- Column access: peers read only id, display_name and avatar_path straight from profiles; the
-- owner reads everything through get_my_profile; others through get_player_profile.

alter table public.profiles
 add column profile_visibility text not null default 'peladas'
  check (profile_visibility in ('private','peladas','public')),
 add column career_visibility text not null default 'peladas'
  check (career_visibility in ('private','peladas','public'));

revoke select on public.profiles from authenticated;
grant select (id, display_name, avatar_path) on public.profiles to authenticated;

-- Account still usable by others: not transferred away, no pending deletion.
create function private.account_is_listed(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.profiles p where p.id = p_user and p.deactivated_at is null)
  and not exists(select 1 from private.account_deletion_requests r where r.user_id = p_user and r.status = 'pending');
$$;

-- Block in either direction between the caller and p_user.
create function private.blocked_either_way(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.user_blocks b
  where (b.blocker_user_id = (select auth.uid()) and b.blocked_user_id = p_user)
     or (b.blocker_user_id = p_user and b.blocked_user_id = (select auth.uid())));
$$;

-- Can the caller see p_user's global data at this visibility level?
create function private.can_view_global(p_user uuid, p_level text) returns boolean
language sql stable security definer set search_path = '' as $$
 select case
  when (select auth.uid()) is null then false
  when p_user = (select auth.uid()) then true
  when p_level = 'private' or p_level is null then false
  when not private.account_is_listed(p_user) or private.blocked_either_way(p_user) then false
  when p_level = 'public' then true
  else private.shares_pelada(p_user) end;
$$;

revoke all on function private.account_is_listed(uuid), private.blocked_either_way(uuid),
 private.can_view_global(uuid,text) from public, anon;
grant execute on function private.account_is_listed(uuid), private.blocked_either_way(uuid),
 private.can_view_global(uuid,text) to authenticated;

-- Peers keep reading name/photo as before (023: hidden from whoever blocked them); a public
-- profile is also readable by any authenticated user not blocked in either direction.
drop policy profiles_read_peers on public.profiles;
create policy profiles_read_peers on public.profiles for select to authenticated
 using (((select private.shares_pelada(id)) and not exists(select 1 from public.user_blocks b
   where b.blocker_user_id=(select auth.uid()) and b.blocked_user_id=profiles.id))
  or (profile_visibility = 'public' and (select private.can_view_global(id, 'public'))));

create function public.get_my_profile() returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('id', p.id, 'display_name', p.display_name, 'avatar_path', p.avatar_path,
  'dominant_foot', p.dominant_foot, 'adult_declared_at', p.adult_declared_at,
  'terms_accepted_at', p.terms_accepted_at, 'profile_visibility', p.profile_visibility,
  'career_visibility', p.career_visibility)
 from public.profiles p where p.id = (select auth.uid());
$$;

create function public.set_my_privacy(p_profile text, p_career text) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_profile is null or p_profile not in ('private','peladas','public')
  or p_career is null or p_career not in ('private','peladas','public') then
  raise exception 'INVALID_VISIBILITY'; end if;
 update public.profiles set profile_visibility = p_profile, career_visibility = p_career where id = auth.uid();
 insert into private.audit_events(actor_user_id,event_type,metadata)
 values(auth.uid(),'privacy_updated',jsonb_build_object('profile',p_profile,'career',p_career));
end $$;

-- Global profile of a player. When the caller may not see it: {"visible": false} only.
-- Peladas listed: active ones and the ones the player left (history kept); never retired records.
create function public.get_player_profile(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p public.profiles;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into p from public.profiles where id = p_user;
 if not found or not private.can_view_global(p_user, p.profile_visibility) then
  return jsonb_build_object('visible', false);
 end if;
 return jsonb_build_object('visible', true, 'id', p.id, 'display_name', p.display_name,
  'avatar_path', p.avatar_path, 'dominant_foot', p.dominant_foot, 'is_me', p.id = auth.uid(),
  'career_visible', private.can_view_global(p_user, p.career_visibility),
  'peladas', coalesce((select jsonb_agg(jsonb_build_object('pelada_id', x.id, 'name', x.name,
     'crest_path', x.crest_path, 'membership_id', m.id, 'position', m.preferred_position,
     'role', m.role, 'status', m.status, 'joined_at', m.joined_at) order by m.status, m.joined_at)
   from public.pelada_memberships m join public.peladas x on x.id = m.pelada_id
   where m.user_id = p_user and m.status in ('active','left')), '[]'::jsonb));
end $$;

revoke all on function public.get_my_profile(), public.set_my_privacy(text,text),
 public.get_player_profile(uuid) from public, anon, authenticated;
grant execute on function public.get_my_profile(), public.set_my_privacy(text,text),
 public.get_player_profile(uuid) to authenticated;
