-- Minuto 91 / 031: free trial protection (PRD sec. 7 "1 por pelada e 1 por conta de administrador";
-- evolution V2, part 8). Rules kept from 019: only the active admin starts it, server-side, never
-- during the beta (so the beta never consumes the commercial trial), one per pelada and one per
-- admin account (unique constraints in premium_trial_usage).
-- Fixed here:
--  - Account transfer (024) moved the person to a new auth user while premium_trial_usage stayed on
--    the old id, so the new account could get a second trial. Now the trial belongs to the person:
--    every account in a transfer chain counts (private.account_lineage, filled when a code is
--    redeemed, back-filled for past transfers).
--  - Concurrent calls: serialized per account (advisory lock) besides the pelada row lock; a unique
--    violation that still slips through answers TRIAL_ALREADY_USED, never a raw error.
--  - Audit: every grant is recorded in private.premium_trial_grants with signals for MANUAL review
--    (no automatic blocking, no new personal data; product decision 22/10/2026):
--     * member_overlap: >= 50% of the pelada's active players (at least 3) are or were members of
--       another pelada that got a trial in the last 180 days (peladas recreated to chain trials);
--     * fresh_admin_and_pelada: admin account and pelada both created less than 7 days before.
--    Support reviews with private.trial_review (SQL Editor, service role).
-- Not abuse and still allowed: a new admin (succession) cannot restart the trial of the same pelada,
-- but keeps their own one trial for another pelada they administer.

create table private.account_lineage (
 user_id uuid not null,          -- current account
 ancestor_user_id uuid not null, -- an account whose history was transferred into it (any depth)
 linked_at timestamptz not null default now(),
 primary key (user_id, ancestor_user_id)
);
revoke all on private.account_lineage from public, anon, authenticated;

create function private.on_transfer_code_redeemed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 insert into private.account_lineage(user_id, ancestor_user_id)
 select new.redeemed_by, new.user_id
 union select new.redeemed_by, l.ancestor_user_id from private.account_lineage l where l.user_id = new.user_id
 on conflict do nothing;
 return new;
end $$;
create trigger transfer_code_redeemed after update of redeemed_by on private.account_transfer_codes
for each row when (old.redeemed_by is null and new.redeemed_by is not null)
execute function private.on_transfer_code_redeemed();
revoke all on function private.on_transfer_code_redeemed() from public, anon, authenticated;

-- Back-fill past transfers (oldest first, so chains resolve).
do $$
declare c record;
begin
 for c in select user_id, redeemed_by from private.account_transfer_codes where redeemed_by is not null order by redeemed_at loop
  insert into private.account_lineage(user_id, ancestor_user_id)
  select c.redeemed_by, c.user_id
  union select c.redeemed_by, l.ancestor_user_id from private.account_lineage l where l.user_id = c.user_id
  on conflict do nothing;
 end loop;
end $$;

-- The person (this account or any account transferred into it) already used a trial.
create function private.trial_used_by_person(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.premium_trial_usage u where u.admin_user_id = p_user
   or u.admin_user_id in (select l.ancestor_user_id from private.account_lineage l where l.user_id = p_user));
$$;
revoke all on function private.trial_used_by_person(uuid) from public, anon, authenticated;

create table private.premium_trial_grants (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 admin_user_id uuid not null,
 granted_at timestamptz not null default now(),
 active_players integer not null,
 overlapping_players integer not null,
 suspicious boolean not null,
 signals jsonb not null default '[]'::jsonb,
 reviewed_at timestamptz,
 review_note text
);
create index trial_grants_review on private.premium_trial_grants(granted_at) where suspicious and reviewed_at is null;
revoke all on private.premium_trial_grants from public, anon, authenticated;

create view private.trial_review as
 select g.*, p.name pelada_name, p.created_at pelada_created_at
 from private.premium_trial_grants g join public.peladas p on p.id = g.pelada_id
 where g.suspicious and g.reviewed_at is null order by g.granted_at;
revoke all on private.trial_review from public, anon, authenticated;

create or replace function public.start_premium_trial(p_pelada uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ends timestamptz := now() + interval '30 days'; v_active integer; v_overlap integer;
 v_signals jsonb := '[]'::jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform 1 from public.peladas where id=p_pelada for update;
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if coalesce((select (value)::boolean from private.app_config where key='premium_beta_open'), false) then
  raise exception 'PREMIUM_BETA_ACTIVE'; end if;
 if exists(select 1 from public.pelada_entitlements where pelada_id=p_pelada and premium_until > now()) then
  raise exception 'ALREADY_PREMIUM'; end if;
 -- One trial per person at a time, even from two peladas at once.
 perform pg_advisory_xact_lock(hashtextextended('premium_trial:' || auth.uid()::text, 0));
 if exists(select 1 from public.premium_trial_usage where pelada_id=p_pelada) or private.trial_used_by_person(auth.uid()) then
  raise exception 'TRIAL_ALREADY_USED'; end if;
 begin
  insert into public.premium_trial_usage(pelada_id,admin_user_id) values(p_pelada,auth.uid());
 exception when unique_violation then
  raise exception 'TRIAL_ALREADY_USED';
 end;
 insert into public.pelada_entitlements(pelada_id,plan,status,trial_started_at,trial_ends_at,source)
 values(p_pelada,'premium','trial',now(),v_ends,'trial')
 on conflict (pelada_id) do update set plan='premium', status='trial', trial_started_at=now(),
  trial_ends_at=v_ends, source='trial';

 -- Review signals (record only).
 select count(*) into v_active from public.pelada_memberships
 where pelada_id=p_pelada and status='active' and user_id is not null;
 select count(distinct m.user_id) into v_overlap from public.pelada_memberships m
 where m.pelada_id=p_pelada and m.status='active' and m.user_id is not null and exists(
  select 1 from public.pelada_memberships o join public.premium_trial_usage u on u.pelada_id=o.pelada_id
  where o.user_id=m.user_id and o.pelada_id<>p_pelada and u.granted_at > now() - interval '180 days');
 if v_overlap >= 3 and v_overlap * 2 >= v_active then
  v_signals := v_signals || jsonb_build_array('member_overlap'); end if;
 if exists(select 1 from public.peladas where id=p_pelada and created_at > now() - interval '7 days')
  and exists(select 1 from auth.users where id=auth.uid() and created_at > now() - interval '7 days') then
  v_signals := v_signals || jsonb_build_array('fresh_admin_and_pelada'); end if;
 insert into private.premium_trial_grants(pelada_id,admin_user_id,active_players,overlapping_players,suspicious,signals)
 values(p_pelada,auth.uid(),v_active,v_overlap,jsonb_array_length(v_signals)>0,v_signals);

 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'premium_trial_started',jsonb_build_object('trial_ends_at',v_ends,'signals',v_signals));
 return jsonb_build_object('trial_ends_at',v_ends);
end $$;

-- Same as 019, with the per-person rule in trial_available.
create or replace function public.get_pelada_entitlement(p_pelada uuid) returns jsonb
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
   and not exists(select 1 from public.premium_trial_usage where pelada_id=p_pelada)
   and not private.trial_used_by_person(auth.uid()),
  'has_open_subscription', exists(select 1 from public.subscription_purchasers
   where pelada_id=p_pelada and status in ('pending','active')));
end $$;
