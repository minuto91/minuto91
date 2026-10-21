-- Minuto 91 / 019: Premium per pelada, free trial and store events (Doc 02 RN-090..096,
-- Doc 03 sec. 24, Doc 04 sec. 28).
-- The pelada is Premium when: premium_beta_open is true (beta, no billing), OR its
-- 30-day trial is running, OR a paid period is running (premium_until).
-- Trial: started by the admin (product decision), once per pelada and once per admin
-- account, never while the beta flag is on. admin_user_id has no cascading FK, so
-- deleting the account does not allow a new trial (legal validation PT-05).
-- Purchase: only the admin; start_premium_purchase registers the buyer for the pelada
-- before the store purchase (one active subscription per buyer at launch; one per pelada).
-- Store events (RevenueCat) arrive through an Edge Function holding the webhook secret,
-- which calls apply_subscription_event with the service role (never the app). Events are
-- idempotent by event id and never shorten a paid period. Admin changes do not touch
-- the subscription.
-- After expiry: Premium features stop for new uses; data is kept; open votings keep their
-- frozen settings; only the oldest assistant keeps privileges (RN-096, enforced lazily
-- by is_active_staff); career statistics become Premium-only to read.

create table public.pelada_entitlements (
 pelada_id uuid primary key references public.peladas(id),
 plan text not null default 'free' check (plan in ('free','premium')),
 status text not null default 'none' check (status in ('none','trial','active','cancelled','expired')),
 trial_started_at timestamptz,
 trial_ends_at timestamptz,
 premium_until timestamptz,
 source text check (source in ('trial','store')),
 updated_at timestamptz not null default now(),
 constraint trial_period check ((trial_started_at is null) = (trial_ends_at is null))
);
create trigger entitlements_touch before update on public.pelada_entitlements
for each row execute function private.touch_updated_at();

create table public.premium_trial_usage (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 admin_user_id uuid not null,
 granted_at timestamptz not null default now(),
 unique (pelada_id),
 unique (admin_user_id)
);

create table public.subscription_purchasers (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 buyer_user_id uuid not null,
 store_account_ref text,
 product_id text,
 status text not null default 'pending' check (status in ('pending','active','cancelled','expired')),
 started_at timestamptz,
 ended_at timestamptz,
 created_at timestamptz not null default now()
);
create unique index one_active_subscription_per_buyer on public.subscription_purchasers(buyer_user_id)
 where status = 'active';
create unique index one_open_subscription_per_pelada on public.subscription_purchasers(pelada_id)
 where status in ('pending','active');

create table private.subscription_events (
 id uuid primary key default gen_random_uuid(),
 event_id text not null unique,
 event_type text not null,
 app_user_id text,
 product_id text,
 payload jsonb not null,
 result text not null,
 received_at timestamptz not null default now()
);
revoke all on private.subscription_events from public,anon,authenticated;

alter table public.pelada_entitlements enable row level security;
alter table public.premium_trial_usage enable row level security;
alter table public.subscription_purchasers enable row level security;
revoke all on public.pelada_entitlements, public.premium_trial_usage, public.subscription_purchasers from anon,authenticated;
-- The app reads the entitlement through get_pelada_entitlement; buyers see their own purchase rows.
grant select on public.subscription_purchasers to authenticated;
create policy purchasers_read_own on public.subscription_purchasers for select to authenticated
 using (buyer_user_id = (select auth.uid()));

create or replace function private.pelada_has_premium(p_pelada uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select coalesce((select (value)::boolean from private.app_config where key='premium_beta_open'), false)
  or exists(select 1 from public.pelada_entitlements e where e.pelada_id=p_pelada
   and (e.trial_ends_at > now() or e.premium_until > now()));
$$;

-- RN-096: beyond the plan limit, only the oldest assistants keep their privileges.
create or replace function private.is_active_staff(p_pelada uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.pelada_memberships m
  where m.pelada_id=p_pelada and m.user_id=(select auth.uid()) and m.status='active'
   and (m.role='admin' or (m.role='assistant' and (
    select count(*) from public.pelada_memberships o where o.pelada_id=p_pelada and o.status='active'
     and o.role='assistant' and (o.assistant_since, o.id) < (m.assistant_since, m.id))
    < private.assistant_limit(p_pelada))));
$$;

-- Career statistics ("histórico completo e carreira") are Premium.
drop policy career_stats_read on public.player_career_stats;
create policy career_stats_read on public.player_career_stats for select to authenticated
 using ((select private.is_active_member(pelada_id)) and (select private.pelada_has_premium(pelada_id)));

-- What the app needs to show the Premium state of a pelada (members only).
create function public.get_pelada_entitlement(p_pelada uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_beta boolean; e public.pelada_entitlements;
begin
 if not private.is_active_member(p_pelada) then raise exception 'PELADA_NOT_FOUND'; end if;
 v_beta := coalesce((select (value)::boolean from private.app_config where key='premium_beta_open'), false);
 select * into e from public.pelada_entitlements where pelada_id=p_pelada;
 return jsonb_build_object(
  'is_premium', private.pelada_has_premium(p_pelada),
  'source', case when v_beta then 'beta' when e.premium_until > now() then 'subscription'
                 when e.trial_ends_at > now() then 'trial' end,
  'status', coalesce(e.status,'none'), 'trial_ends_at', e.trial_ends_at, 'premium_until', e.premium_until,
  'is_admin', private.is_active_admin(p_pelada),
  'trial_available', not v_beta and private.is_active_admin(p_pelada)
   and not exists(select 1 from public.premium_trial_usage where pelada_id=p_pelada or admin_user_id=auth.uid()),
  'has_open_subscription', exists(select 1 from public.subscription_purchasers
   where pelada_id=p_pelada and status in ('pending','active')));
end $$;

create function public.start_premium_trial(p_pelada uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ends timestamptz := now() + interval '30 days';
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform 1 from public.peladas where id=p_pelada for update;
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if coalesce((select (value)::boolean from private.app_config where key='premium_beta_open'), false) then
  raise exception 'PREMIUM_BETA_ACTIVE'; end if;
 if exists(select 1 from public.pelada_entitlements where pelada_id=p_pelada and premium_until > now()) then
  raise exception 'ALREADY_PREMIUM'; end if;
 if exists(select 1 from public.premium_trial_usage where pelada_id=p_pelada or admin_user_id=auth.uid()) then
  raise exception 'TRIAL_ALREADY_USED'; end if;
 insert into public.premium_trial_usage(pelada_id,admin_user_id) values(p_pelada,auth.uid());
 insert into public.pelada_entitlements(pelada_id,plan,status,trial_started_at,trial_ends_at,source)
 values(p_pelada,'premium','trial',now(),v_ends,'trial')
 on conflict (pelada_id) do update set plan='premium', status='trial', trial_started_at=now(),
  trial_ends_at=v_ends, source='trial';
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'premium_trial_started',jsonb_build_object('trial_ends_at',v_ends));
 return jsonb_build_object('trial_ends_at',v_ends);
end $$;

-- Registers the admin as buyer before the store purchase (the app then buys with
-- appUserID = the admin's user id). Returns the purchaser id.
create function public.start_premium_purchase(p_pelada uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform 1 from public.peladas where id=p_pelada for update;
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if coalesce((select (value)::boolean from private.app_config where key='premium_beta_open'), false) then
  raise exception 'PREMIUM_BETA_ACTIVE'; end if;
 if exists(select 1 from public.subscription_purchasers where pelada_id=p_pelada and status='active') then
  raise exception 'ALREADY_SUBSCRIBED'; end if;
 if exists(select 1 from public.subscription_purchasers where buyer_user_id=auth.uid() and status='active') then
  raise exception 'BUYER_ALREADY_SUBSCRIBED'; end if;
 select id into v_id from public.subscription_purchasers where pelada_id=p_pelada and status='pending';
 if found then
  update public.subscription_purchasers set buyer_user_id=auth.uid() where id=v_id;
 else
  insert into public.subscription_purchasers(pelada_id,buyer_user_id) values(p_pelada,auth.uid()) returning id into v_id;
 end if;
 return v_id;
end $$;

-- Called ONLY by the RevenueCat webhook Edge Function (service role), with the event
-- object of the webhook body: {id, type, app_user_id, product_id, expiration_at_ms,
-- original_transaction_id}. Returns what was done.
create function public.apply_subscription_event(p_event jsonb) returns text
language plpgsql security definer set search_path = '' as $$
declare v_event_id text := p_event->>'id'; v_type text := p_event->>'type'; v_buyer uuid;
 v_p public.subscription_purchasers; v_exp timestamptz; v_result text;
begin
 if v_event_id is null or v_type is null then raise exception 'INVALID_EVENT'; end if;
 if exists(select 1 from private.subscription_events where event_id=v_event_id) then
  return 'duplicate'; end if;
 begin v_buyer := (p_event->>'app_user_id')::uuid; exception when invalid_text_representation then v_buyer := null; end;
 v_exp := to_timestamp((p_event->>'expiration_at_ms')::numeric / 1000);

 select * into v_p from public.subscription_purchasers where buyer_user_id=v_buyer
  and status in ('pending','active','cancelled') order by (status='active') desc, created_at desc limit 1;
 if not found then
  v_result := 'unmatched';
 else
  -- Same lock order as start_premium_purchase: pelada first, then the purchaser row.
  perform 1 from public.peladas where id=v_p.pelada_id for update;
  perform 1 from public.subscription_purchasers where id=v_p.id for update;
  if v_type in ('INITIAL_PURCHASE','RENEWAL','UNCANCELLATION','PRODUCT_CHANGE') then
   update public.subscription_purchasers set status='active', started_at=coalesce(started_at,now()),
    store_account_ref=coalesce(p_event->>'original_transaction_id',store_account_ref),
    product_id=coalesce(p_event->>'product_id',product_id), ended_at=null where id=v_p.id;
   insert into public.pelada_entitlements(pelada_id,plan,status,premium_until,source)
   values(v_p.pelada_id,'premium','active',v_exp,'store')
   on conflict (pelada_id) do update set plan='premium', status='active', source='store',
    premium_until=greatest(public.pelada_entitlements.premium_until, excluded.premium_until);
   v_result := 'activated';
  elsif v_type = 'CANCELLATION' then
   -- Renewal turned off: the paid period stays.
   update public.subscription_purchasers set status='cancelled' where id=v_p.id;
   update public.pelada_entitlements set status='cancelled' where pelada_id=v_p.pelada_id;
   v_result := 'cancelled';
  elsif v_type = 'EXPIRATION' then
   update public.subscription_purchasers set status='expired', ended_at=now() where id=v_p.id;
   update public.pelada_entitlements set status='expired', plan='free' where pelada_id=v_p.pelada_id;
   v_result := 'expired';
  else
   v_result := 'ignored';
  end if;
  insert into private.audit_events(pelada_id,event_type,metadata)
  values(v_p.pelada_id,'subscription_event',jsonb_build_object('event_id',v_event_id,'type',v_type,'result',v_result));
 end if;
 insert into private.subscription_events(event_id,event_type,app_user_id,product_id,payload,result)
 values(v_event_id,v_type,p_event->>'app_user_id',p_event->>'product_id',p_event,v_result);
 return v_result;
end $$;

revoke all on function public.get_pelada_entitlement(uuid), public.start_premium_trial(uuid),
 public.start_premium_purchase(uuid), public.apply_subscription_event(jsonb) from public,anon,authenticated;
grant execute on function public.get_pelada_entitlement(uuid), public.start_premium_trial(uuid),
 public.start_premium_purchase(uuid) to authenticated;
grant execute on function public.apply_subscription_event(jsonb) to service_role;
