-- Minuto 91 / 004: settings, pelada creation, invites and joining (v1.1).
-- The minimum of 6 eligible voters is a FIXED constant of open_voting_session
-- (stage 3); it is intentionally NOT a column here.
create table public.pelada_settings (
 pelada_id uuid primary key references public.peladas(id) on delete cascade,
 timezone text not null default 'America/Sao_Paulo' check(length(timezone) between 1 and 100),
 voting_duration_minutes integer not null default 240 check(voting_duration_minutes in (120,240,360)),
 minimum_numeric_ratings integer check(minimum_numeric_ratings is null or minimum_numeric_ratings between 0 and 99),
 -- ON by default; only effective while the pelada has Premium (active, trial or beta).
 bola_murcha_enabled boolean not null default true,
 team_names_customized boolean not null default false,
 updated_at timestamptz not null default now()
);
create trigger settings_touch before update on public.pelada_settings
for each row execute function private.touch_updated_at();
alter table public.pelada_settings enable row level security;
revoke all on public.pelada_settings from anon,authenticated;
grant select on public.pelada_settings to authenticated;
create policy settings_read_members on public.pelada_settings for select to authenticated
 using ((select private.is_active_member(pelada_id)));
-- Settings changes will be introduced by a dedicated, Premium-aware RPC.

create function private.valid_position(p text) returns boolean language sql immutable
set search_path = '' as $$ select p in ('goalkeeper','defender','midfielder','attacker') $$;
revoke all on function private.valid_position(text) from public,anon;
grant execute on function private.valid_position(text) to authenticated;

create function public.create_pelada(p_name text, p_position text, p_description text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_pelada uuid; v_name text;
begin
 if v_user is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform private.require_onboarded();
 if not private.valid_position(p_position) then raise exception 'INVALID_POSITION'; end if;
 v_name := btrim(p_name);
 if v_name is null or length(v_name) not between 2 and 100 then raise exception 'INVALID_NAME'; end if;
 insert into public.peladas(name,description,created_by) values(v_name,p_description,v_user) returning id into v_pelada;
 insert into public.pelada_memberships(pelada_id,user_id,player_name,role,preferred_position)
 select v_pelada,v_user,display_name,'admin',p_position from public.profiles where id=v_user;
 insert into public.pelada_settings(pelada_id) values(v_pelada);
 insert into private.audit_events(pelada_id,actor_user_id,event_type)
 values(v_pelada,v_user,'pelada_created');
 return v_pelada;
end $$;

-- Admin edits the pelada profile (crest, image, recurring day/time).
create function public.update_pelada_profile(p_pelada uuid, p_name text, p_description text,
 p_crest_path text, p_image_path text, p_weekday smallint, p_time time)
returns void language plpgsql security definer set search_path = '' as $$
declare v_name text := btrim(p_name);
begin
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if v_name is null or length(v_name) not between 2 and 100 then raise exception 'INVALID_NAME'; end if;
 update public.peladas set name=v_name, description=p_description, crest_path=p_crest_path,
  image_path=p_image_path, recurring_weekday=p_weekday, recurring_time=p_time where id=p_pelada;
 insert into private.audit_events(pelada_id,actor_user_id,event_type) values(p_pelada,auth.uid(),'pelada_profile_updated');
end $$;

-- The token is returned ONCE; only its SHA-256 digest is persisted.
create function public.create_pelada_invite(p_pelada uuid,p_valid_hours integer default 168,p_max_uses integer default 100)
returns text language plpgsql security definer set search_path = '' as $$
declare v_token text;
begin
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if p_valid_hours not between 1 and 720 or p_max_uses not between 1 and 1000 then raise exception 'INVALID_INVITE_LIMITS'; end if;
 if not exists(select 1 from public.peladas where id=p_pelada and status='active') then raise exception 'PELADA_NOT_ACTIVE'; end if;
 v_token := encode(extensions.gen_random_bytes(32),'hex');
 insert into private.pelada_invites(pelada_id,token_hash,created_by,expires_at,max_uses)
 values(p_pelada,encode(extensions.digest(v_token,'sha256'),'hex'),auth.uid(),now()+make_interval(hours=>p_valid_hours),p_max_uses);
 insert into private.audit_events(pelada_id,actor_user_id,event_type) values(p_pelada,auth.uid(),'invite_created');
 return v_token;
end $$;

-- "Regenerate link": revokes every active invite of the pelada.
create function public.revoke_pelada_invites(p_pelada uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 update private.pelada_invites set revoked_at=now() where pelada_id=p_pelada and revoked_at is null;
 get diagnostics v_n = row_count;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'invites_revoked',jsonb_build_object('count',v_n));
 return v_n;
end $$;

-- A new member must choose a position. A returning member keeps the existing
-- record (history, card, stickers); the position is updated only if provided.
create function public.join_pelada(p_invite_token text, p_position text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_inv private.pelada_invites%rowtype; v_membership uuid; v_name text;
 v_existing public.pelada_memberships%rowtype; v_count integer;
begin
 if v_user is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform private.require_onboarded();
 if p_invite_token is null or p_invite_token !~ '^[0-9a-f]{64}$' then
  raise exception 'INVALID_INVITE'; end if;
 if p_position is not null and not private.valid_position(p_position) then raise exception 'INVALID_POSITION'; end if;
 select * into v_inv from private.pelada_invites
 where token_hash=encode(extensions.digest(p_invite_token,'sha256'),'hex') for update;
 if not found or v_inv.revoked_at is not null or v_inv.expires_at<=now() or v_inv.uses>=v_inv.max_uses then
  raise exception 'INVALID_OR_EXPIRED_INVITE'; end if;
 -- Lock pelada to serialize capacity checks and administrator departure.
 perform 1 from public.peladas where id=v_inv.pelada_id and status='active' for update;
 if not found then raise exception 'PELADA_NOT_ACTIVE'; end if;
 select display_name into v_name from public.profiles where id=v_user;
 if v_name is null then raise exception 'PROFILE_REQUIRED'; end if;
 select * into v_existing from public.pelada_memberships
 where pelada_id=v_inv.pelada_id and user_id=v_user for update;
 if found and v_existing.status='active' then return v_existing.id; end if;
 if found and v_existing.status in ('suspended','retired') then raise exception 'MEMBERSHIP_NOT_REJOINABLE'; end if;
 select count(*) into v_count from public.pelada_memberships
 where pelada_id=v_inv.pelada_id and status='active';
 if v_count>=100 then raise exception 'PELADA_FULL'; end if;
 if v_existing.id is not null then
  -- Reactivate the SAME record. joined_at is preserved (identity continuity).
  update public.pelada_memberships set status='active', role='player', assistant_since=null,
   player_name=v_name, preferred_position=coalesce(p_position, preferred_position)
  where id=v_existing.id returning id into v_membership;
 else
  if p_position is null then raise exception 'POSITION_REQUIRED'; end if;
  insert into public.pelada_memberships(pelada_id,user_id,player_name,preferred_position)
  values(v_inv.pelada_id,v_user,v_name,p_position) returning id into v_membership;
 end if;
 update private.pelada_invites set uses=uses+1 where id=v_inv.id;
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type)
 values(v_inv.pelada_id,v_user,v_membership,case when v_existing.id is not null then 'member_rejoined' else 'member_joined' end);
 return v_membership;
end $$;

-- Position change takes effect from the next match played (each match stores
-- its own snapshot, so past matches are never altered).
create function public.set_my_position(p_pelada uuid, p_position text) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.valid_position(p_position) then raise exception 'INVALID_POSITION'; end if;
 update public.pelada_memberships set preferred_position=p_position
 where pelada_id=p_pelada and user_id=auth.uid() and status='active';
 if not found then raise exception 'ACTIVE_MEMBERSHIP_REQUIRED'; end if;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'position_changed',jsonb_build_object('position',p_position));
end $$;

revoke all on function public.create_pelada(text,text,text),
 public.update_pelada_profile(uuid,text,text,text,text,smallint,time),
 public.create_pelada_invite(uuid,integer,integer), public.revoke_pelada_invites(uuid),
 public.join_pelada(text,text), public.set_my_position(uuid,text) from public,anon;
grant execute on function public.create_pelada(text,text,text),
 public.update_pelada_profile(uuid,text,text,text,text,smallint,time),
 public.create_pelada_invite(uuid,integer,integer), public.revoke_pelada_invites(uuid),
 public.join_pelada(text,text), public.set_my_position(uuid,text) to authenticated;
