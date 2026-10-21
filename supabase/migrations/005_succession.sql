-- Minuto 91 / 005: assistants, designated successor and automatic succession (v1.1).
-- Succession order: 1) successor designated by the admin; 2) oldest assistant
-- (by assistant_since); 3) oldest active player (by joined_at). Ties: id.

-- Server-side switches. premium_beta_open = true while the beta runs (all
-- peladas get Premium, no billing). Entitlements arrive in migration 019.
create table private.app_config (key text primary key, value jsonb not null);
revoke all on private.app_config from public,anon,authenticated;
insert into private.app_config values ('premium_beta_open','true'::jsonb);

create function private.pelada_has_premium(p_pelada uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select coalesce((select (value)::boolean from private.app_config where key='premium_beta_open'), false);
 -- TODO(019): OR active entitlement / trial for p_pelada.
$$;
create function private.assistant_limit(p_pelada uuid) returns integer
language sql stable security definer set search_path = '' as $$
 select case when private.pelada_has_premium(p_pelada) then 3 else 1 end;
$$;
revoke all on function private.pelada_has_premium(uuid), private.assistant_limit(uuid) from public,anon,authenticated;

-- Direct changes to the administrator are only possible inside the RPCs below.
create function private.ensure_admin_successor() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if (old.status='active' and old.role='admin' and (new.status <> 'active' or new.role <> 'admin'))
 or (new.role='admin' and old.role is distinct from 'admin') then
  if current_setting('minuto91.admin_transition',true) is distinct from 'authorized' then
   raise exception 'ADMIN_TRANSITION_REQUIRES_RPC' using errcode='42501';
  end if;
 end if;
 return new;
end $$;
create trigger admin_transition_guard before update on public.pelada_memberships
for each row execute function private.ensure_admin_successor();
revoke all on function private.ensure_admin_successor() from public,anon,authenticated;

-- Admin designates (or clears, with NULL) the successor in advance.
create function public.set_successor(p_pelada uuid, p_membership uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if p_membership is not null and not exists(select 1 from public.pelada_memberships
   where id=p_membership and pelada_id=p_pelada and status='active' and user_id is not null and role<>'admin') then
  raise exception 'INVALID_SUCCESSOR'; end if;
 update public.peladas set successor_membership_id=p_membership where id=p_pelada;
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type)
 values(p_pelada,auth.uid(),p_membership,'successor_designated');
end $$;

-- Admin designates or removes an assistant. Limit: 1 (free) / 3 (Premium or beta).
create function public.set_assistant(p_pelada uuid, p_membership uuid, p_is_assistant boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.pelada_memberships%rowtype;
begin
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 perform 1 from public.peladas where id=p_pelada for update;
 select * into v_m from public.pelada_memberships where id=p_membership and pelada_id=p_pelada and status='active' for update;
 if not found or v_m.role='admin' then raise exception 'INVALID_MEMBER'; end if;
 if p_is_assistant then
  if v_m.user_id is null then raise exception 'ASSISTANT_REQUIRES_ACCOUNT'; end if;
  if v_m.role='assistant' then return; end if;
  if (select count(*) from public.pelada_memberships where pelada_id=p_pelada and status='active' and role='assistant')
     >= private.assistant_limit(p_pelada) then raise exception 'ASSISTANT_LIMIT_REACHED'; end if;
  update public.pelada_memberships set role='assistant', assistant_since=now() where id=v_m.id;
 else
  update public.pelada_memberships set role='player', assistant_since=null where id=v_m.id and role='assistant';
 end if;
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
 values(p_pelada,auth.uid(),v_m.id,'assistant_changed',jsonb_build_object('is_assistant',p_is_assistant));
end $$;

-- All departures must use this RPC.
create function public.leave_pelada(p_pelada uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_actor uuid:=auth.uid(); v_self public.pelada_memberships%rowtype;
 v_successor uuid; v_source text;
begin
 if v_actor is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 -- Per-pelada serialization is mandatory for succession and membership writes.
 perform 1 from public.peladas where id=p_pelada for update;
 if not found then raise exception 'PELADA_NOT_FOUND'; end if;
 select * into v_self from public.pelada_memberships
 where pelada_id=p_pelada and user_id=v_actor and status='active' for update;
 if not found then raise exception 'ACTIVE_MEMBERSHIP_REQUIRED'; end if;
 if v_self.role='admin' then
  select m.id, case when m.id=p.successor_membership_id then 'designated'
                    when m.role='assistant' then 'assistant' else 'player' end
  into v_successor, v_source
  from public.pelada_memberships m join public.peladas p on p.id=m.pelada_id
  where m.pelada_id=p_pelada and m.id<>v_self.id and m.status='active' and m.user_id is not null
  order by case when m.id=p.successor_membership_id then 0 when m.role='assistant' then 1 else 2 end,
           m.assistant_since asc nulls last, m.joined_at asc, m.id asc
  limit 1 for update of m;
  perform set_config('minuto91.admin_transition','authorized',true);
  update public.pelada_memberships set role='player',status='left',assistant_since=null where id=v_self.id;
  if v_successor is not null then
   update public.pelada_memberships set role='admin',assistant_since=null where id=v_successor;
   update public.peladas set status='active', successor_membership_id=null where id=p_pelada;
   insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
   values(p_pelada,v_actor,v_successor,'admin_succeeded',jsonb_build_object('previous_admin',v_self.id,'source',v_source));
  else
   update public.peladas set status='restricted', successor_membership_id=null where id=p_pelada;
   insert into private.audit_events(pelada_id,actor_user_id,event_type)
   values(p_pelada,v_actor,'pelada_without_eligible_admin');
  end if;
  perform set_config('minuto91.admin_transition','',true);
 else
  update public.pelada_memberships set status='left',role='player',assistant_since=null where id=v_self.id;
  update public.peladas set successor_membership_id=null where id=p_pelada and successor_membership_id=v_self.id;
 end if;
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type)
 values(p_pelada,v_actor,v_self.id,'member_left');
 return jsonb_build_object('left_membership_id',v_self.id,'new_admin_membership_id',v_successor,
 'succession_source',v_source,'pelada_restricted',v_self.role='admin' and v_successor is null);
end $$;

revoke all on function public.set_successor(uuid,uuid), public.set_assistant(uuid,uuid,boolean),
 public.leave_pelada(uuid) from public,anon;
grant execute on function public.set_successor(uuid,uuid), public.set_assistant(uuid,uuid,boolean),
 public.leave_pelada(uuid) to authenticated;

-- Future account-deletion worker must reuse an equivalent privileged succession
-- path BEFORE deleting auth.users. Do not delete auth.users directly for admins.
-- Premium entitlements remain attached to pelada_id and are never modified here.
