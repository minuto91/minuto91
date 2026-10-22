-- Minuto 91 / 027: profile photo, dominant foot and profile editing (audit 21/10/2026, Fase 2;
-- PRD RF-001 "a foto é opcional", Doc 02 RN-002, Doc 04 sec. 30.6, Política v1.2 sec. 7).
-- Photo:
--  - Private bucket "avatars": JPEG only, up to 2 MB. Object name "<user id>/<random uuid>.jpg".
--  - The app uploads to the user's own folder (Storage API), then calls set_my_avatar.
--  - Who reads a photo: the owner, and whoever can read the owner's profile row pointing to that
--    exact object (profiles RLS: shares an active pelada and was not blocked by the reader). So an
--    Aposentado, a purged account or a moderated photo stops being visible at once.
--  - The app shows photos only through short-lived signed URLs (no public URLs).
--  - Orphan files (replaced, removed, moderated, purged, failed uploads) are deleted by the Edge
--    Function storage-cleanup through the Storage API (Supabase does not allow deleting
--    storage.objects with SQL). The app also deletes the previous file right after a change.
-- Dominant foot: belongs to the person (same in every pelada), optional, never used by any
--  formula (card, rating, selection).
-- Display name: edited through update_my_profile, which also renames the user's ACTIVE
--  memberships (player_name is what each pelada shows). Retired records keep "Aposentado".
-- The client can no longer UPDATE profiles directly; only through the RPCs below.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 2097152, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
 allowed_mime_types = excluded.allowed_mime_types;

create policy avatars_insert_own on storage.objects for insert to authenticated
 with check (bucket_id = 'avatars'
  and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
  and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_delete_own on storage.objects for delete to authenticated
 using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_read on storage.objects for select to authenticated
 using (bucket_id = 'avatars' and ((storage.foldername(name))[1] = (select auth.uid())::text
  or exists(select 1 from public.profiles p where p.avatar_path = storage.objects.name)));
-- No UPDATE policy: a new photo is always a new object.

create index profiles_by_avatar on public.profiles(avatar_path) where avatar_path is not null;

alter table public.profiles add column dominant_foot text
 check (dominant_foot is null or dominant_foot in ('right','left','both'));

revoke update on public.profiles from authenticated;
drop policy profiles_update_self on public.profiles;

create function public.update_my_profile(p_display_name text, p_dominant_foot text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_name text := nullif(btrim(p_display_name), '');
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform private.require_onboarded();
 if v_name is null or length(v_name) > 80 then raise exception 'INVALID_NAME'; end if;
 if p_dominant_foot is not null and p_dominant_foot not in ('right','left','both') then
  raise exception 'INVALID_DOMINANT_FOOT'; end if;
 update public.profiles set display_name = v_name, dominant_foot = p_dominant_foot where id = auth.uid();
 update public.pelada_memberships set player_name = v_name
 where user_id = auth.uid() and status = 'active' and player_name is distinct from v_name;
end $$;

-- Points the profile to a photo already uploaded to the user's folder. Returns the previous
-- path (or null) so the app can delete the old file.
create function public.set_my_avatar(p_path text) returns text
language plpgsql security definer set search_path = '' as $$
declare v_old text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform private.require_onboarded();
 if p_path is null or p_path !~ ('^' || auth.uid()::text
   || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$') then
  raise exception 'INVALID_AVATAR_PATH'; end if;
 select avatar_path into v_old from public.profiles where id = auth.uid() for update;
 update public.profiles set avatar_path = p_path where id = auth.uid();
 return v_old;
end $$;

-- Removes the photo from the profile. Returns the previous path (or null).
create function public.clear_my_avatar() returns text
language plpgsql security definer set search_path = '' as $$
declare v_old text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select avatar_path into v_old from public.profiles where id = auth.uid() for update;
 update public.profiles set avatar_path = null where id = auth.uid();
 return v_old;
end $$;

-- For the storage-cleanup Edge Function (service role): which of these paths are still in use.
create function public.avatar_paths_in_use(p_paths text[]) returns setof text
language sql stable security definer set search_path = '' as $$
 select avatar_path from public.profiles where avatar_path = any(p_paths);
$$;

revoke all on function public.update_my_profile(text,text), public.set_my_avatar(text),
 public.clear_my_avatar(), public.avatar_paths_in_use(text[]) from public,anon,authenticated;
grant execute on function public.update_my_profile(text,text), public.set_my_avatar(text),
 public.clear_my_avatar() to authenticated;
grant execute on function public.avatar_paths_in_use(text[]) to service_role;
