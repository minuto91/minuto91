-- Minuto 91 / 028: pelada crest (PRD "escudo, imagem" of the pelada, Doc 03 peladas.crest_path,
-- Doc 04 sec. 30.6; evolution V2, part 3). The column crest_path exists since 003; this adds the
-- storage and the only way to change it.
-- Crest:
--  - Private bucket "crests": PNG or JPEG, up to 1 MB. Object name "<pelada id>/<random uuid>.png|.jpg".
--  - Only the ACTIVE ADMIN uploads to the pelada's folder (Storage API), then calls set_pelada_crest.
--  - Who reads a crest: the admin (own uploads), and whoever can read the pelada row pointing to that
--    exact object (peladas RLS: active members). Moderation (023) clears crest_path, so it stops at once.
--  - The app shows crests only through short-lived signed URLs; without a crest it draws the initials.
--  - Orphans (replaced, removed, moderated, failed uploads) are deleted by storage-cleanup.
-- update_pelada_profile (004) no longer accepts a free crest/image path.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('crests', 'crests', false, 1048576, array['image/png','image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
 allowed_mime_types = excluded.allowed_mime_types;

-- Text in, so a malformed folder name never reaches a uuid cast inside a policy.
create function private.is_active_admin_folder(p_folder text) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.pelada_memberships m
  where m.pelada_id::text = p_folder and m.user_id = (select auth.uid())
   and m.status = 'active' and m.role = 'admin');
$$;
revoke all on function private.is_active_admin_folder(text) from public, anon;
grant execute on function private.is_active_admin_folder(text) to authenticated;

create policy crests_insert_admin on storage.objects for insert to authenticated
 with check (bucket_id = 'crests'
  and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(png|jpg)$'
  and (select private.is_active_admin_folder((storage.foldername(name))[1])));
create policy crests_delete_admin on storage.objects for delete to authenticated
 using (bucket_id = 'crests' and (select private.is_active_admin_folder((storage.foldername(name))[1])));
create policy crests_read on storage.objects for select to authenticated
 using (bucket_id = 'crests' and ((select private.is_active_admin_folder((storage.foldername(name))[1]))
  or exists(select 1 from public.peladas p where p.crest_path = storage.objects.name)));
-- No UPDATE policy: a new crest is always a new object.

create index peladas_by_crest on public.peladas(crest_path) where crest_path is not null;

-- Points the pelada to a crest already uploaded to its folder. Returns the previous path (or null)
-- so the app can delete the old file.
create function public.set_pelada_crest(p_pelada uuid, p_path text) returns text
language plpgsql security definer set search_path = '' as $$
declare v_old text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform 1 from public.peladas where id = p_pelada for update;
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if p_path is null or p_path !~ ('^' || p_pelada::text
   || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(png|jpg)$') then
  raise exception 'INVALID_CREST_PATH'; end if;
 select crest_path into v_old from public.peladas where id = p_pelada;
 update public.peladas set crest_path = p_path where id = p_pelada;
 insert into private.audit_events(pelada_id,actor_user_id,event_type) values(p_pelada,auth.uid(),'pelada_crest_set');
 return v_old;
end $$;

-- Removes the crest. Returns the previous path (or null).
create function public.clear_pelada_crest(p_pelada uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare v_old text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform 1 from public.peladas where id = p_pelada for update;
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 select crest_path into v_old from public.peladas where id = p_pelada;
 update public.peladas set crest_path = null where id = p_pelada;
 if v_old is not null then
  insert into private.audit_events(pelada_id,actor_user_id,event_type) values(p_pelada,auth.uid(),'pelada_crest_cleared');
 end if;
 return v_old;
end $$;

-- Same signature as 004 (no app uses it today), but crest and image can no longer be set to an
-- arbitrary path here: they must stay as they are (crest changes only through the RPCs above).
create or replace function public.update_pelada_profile(p_pelada uuid, p_name text, p_description text,
 p_crest_path text, p_image_path text, p_weekday smallint, p_time time)
returns void language plpgsql security definer set search_path = '' as $$
declare v_name text := btrim(p_name); v_cur public.peladas;
begin
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if v_name is null or length(v_name) not between 2 and 100 then raise exception 'INVALID_NAME'; end if;
 select * into v_cur from public.peladas where id = p_pelada for update;
 if p_crest_path is distinct from v_cur.crest_path then raise exception 'INVALID_CREST_PATH'; end if;
 if p_image_path is distinct from v_cur.image_path then raise exception 'INVALID_IMAGE_PATH'; end if;
 update public.peladas set name=v_name, description=p_description,
  recurring_weekday=p_weekday, recurring_time=p_time where id=p_pelada;
 insert into private.audit_events(pelada_id,actor_user_id,event_type) values(p_pelada,auth.uid(),'pelada_profile_updated');
end $$;

-- For the storage-cleanup Edge Function (service role): which of these paths are still in use.
create function public.crest_paths_in_use(p_paths text[]) returns setof text
language sql stable security definer set search_path = '' as $$
 select crest_path from public.peladas where crest_path = any(p_paths);
$$;

revoke all on function public.set_pelada_crest(uuid,text), public.clear_pelada_crest(uuid),
 public.crest_paths_in_use(text[]) from public,anon,authenticated;
grant execute on function public.set_pelada_crest(uuid,text), public.clear_pelada_crest(uuid) to authenticated;
grant execute on function public.crest_paths_in_use(text[]) to service_role;
