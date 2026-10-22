-- Minuto 91 / 043: V4.3 phase 5, Financeiro da Pelada Premium (digital cash book).
--
-- The app never moves money: no Pix, card, boleto or gateway. Admins record what happened.
--
-- Access (9.2): the pelada admin, and assistants the admin explicitly enabled (finance_access) while they are
-- staff. Pelada Premium is required to read or write; when it expires every record is kept (nothing is
-- deleted) and access comes back when the plan is active again. Common players never see collective finance.
--
-- Money: integer cents (no float). Every value > 0; a payment never exceeds what is still owed.
--
-- Model:
--   finance_payers   people without an account who pay (avulsos externos): name and note only.
--   finance_members  mensalistas: member or external payer, monthly amount, due day (1-28), start, status.
--                    Changing the amount affects only charges generated afterwards (never retroactive).
--   finance_charges  what someone owes: 'monthly' (one per mensalista and month, unique), 'single' (avulso,
--                    optionally linked to a match) or 'extra' (contribuição extraordinária). Status is derived
--                    from the payments: pending / partial / paid, or cancelled (only without payments).
--   finance_payments payments received for a charge (amount, date, informative method). Idempotent by
--                    request_id; a second payment of the same amount on the same charge within 10 minutes is
--                    refused as a possible duplicate unless confirmed. Never deleted: reversal (estorno) keeps
--                    the row with who/when/why.
--   finance_entries  other income (contribuições, patrocínio...) and expenses (campo, arbitragem, água...), with
--                    free categories; pending or settled; cancellation instead of deletion.
--   finance_events   audit: author, time, record, values before and after.
--
-- Balance (9.10): realized = payments not reversed + settled income - settled expenses. Pending values are
-- never counted as available money: receivable, pending expenses and the projection are separate numbers.
-- Dates are calendar dates of the pelada (its time zone, private.pelada_today).
-- Concurrency: every write locks the pelada's finance (advisory) and the affected row.

---------------------------------------------------------------------------------------------------
-- Tables
---------------------------------------------------------------------------------------------------

create table public.finance_access (
 pelada_id uuid not null references public.peladas(id),
 membership_id uuid not null references public.pelada_memberships(id),
 granted_by uuid references public.profiles(id) on delete set null,
 granted_at timestamptz not null default now(),
 primary key (pelada_id, membership_id)
);

create table public.finance_payers (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 display_name text not null check (length(btrim(display_name)) between 2 and 60),
 notes text check (notes is null or length(notes) <= 200),
 archived_at timestamptz,
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now()
);
create unique index finance_payers_unique_name on public.finance_payers(pelada_id, lower(btrim(display_name))) where archived_at is null;

create table public.finance_members (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 membership_id uuid references public.pelada_memberships(id),
 payer_id uuid references public.finance_payers(id),
 amount_cents integer not null check (amount_cents between 1 and 100000000),
 due_day smallint not null check (due_day between 1 and 28),
 starts_on date not null,
 ends_on date,
 status text not null default 'active' check (status in ('active','suspended','ended')),
 notes text check (notes is null or length(notes) <= 200),
 version integer not null default 1,
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check ((membership_id is null) <> (payer_id is null))
);
create unique index finance_members_one_open_member on public.finance_members(pelada_id, membership_id) where status <> 'ended' and membership_id is not null;
create unique index finance_members_one_open_payer on public.finance_members(pelada_id, payer_id) where status <> 'ended' and payer_id is not null;

create table public.finance_charges (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 kind text not null check (kind in ('monthly','single','extra')),
 finance_member_id uuid references public.finance_members(id),
 membership_id uuid references public.pelada_memberships(id),
 payer_id uuid references public.finance_payers(id),
 match_id uuid references public.matches(id),
 reference_month date check (reference_month is null or extract(day from reference_month) = 1),
 description text not null check (length(btrim(description)) between 1 and 120),
 amount_due_cents integer not null check (amount_due_cents between 1 and 100000000),
 amount_paid_cents integer not null default 0 check (amount_paid_cents >= 0 and amount_paid_cents <= amount_due_cents),
 due_date date not null,
 status text not null default 'pending' check (status in ('pending','partial','paid','cancelled')),
 request_id uuid,
 version integer not null default 1,
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 cancelled_at timestamptz,
 cancelled_by uuid references public.profiles(id) on delete set null,
 cancel_reason text check (cancel_reason is null or length(cancel_reason) <= 200),
 check ((membership_id is null) <> (payer_id is null)),
 check ((kind = 'monthly') = (finance_member_id is not null and reference_month is not null)),
 check (status <> 'cancelled' or amount_paid_cents = 0),
 unique (finance_member_id, reference_month),
 unique (pelada_id, request_id)
);
create index finance_charges_open on public.finance_charges(pelada_id, due_date) where status in ('pending','partial');
create index finance_charges_by_month on public.finance_charges(pelada_id, due_date);

create table public.finance_payments (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 charge_id uuid not null references public.finance_charges(id),
 amount_cents integer not null check (amount_cents between 1 and 100000000),
 received_on date not null,
 method text check (method in ('pix','dinheiro','cartao','transferencia','outro')),
 notes text check (notes is null or length(notes) <= 200),
 request_id uuid not null,
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 reversed_at timestamptz,
 reversed_by uuid references public.profiles(id) on delete set null,
 reverse_reason text check (reverse_reason is null or length(reverse_reason) <= 200),
 unique (pelada_id, request_id)
);
create index finance_payments_by_date on public.finance_payments(pelada_id, received_on) where reversed_at is null;
create index finance_payments_by_charge on public.finance_payments(charge_id);

create table public.finance_entries (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 direction text not null check (direction in ('income','expense')),
 category text not null check (length(btrim(category)) between 1 and 40),
 description text not null check (length(btrim(description)) between 1 and 120),
 amount_cents integer not null check (amount_cents between 1 and 100000000),
 entry_date date not null,
 status text not null check (status in ('pending','settled','cancelled')),
 method text check (method in ('pix','dinheiro','cartao','transferencia','outro')),
 notes text check (notes is null or length(notes) <= 200),
 request_id uuid,
 version integer not null default 1,
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 cancelled_at timestamptz,
 cancel_reason text check (cancel_reason is null or length(cancel_reason) <= 200),
 unique (pelada_id, request_id)
);
create index finance_entries_by_date on public.finance_entries(pelada_id, entry_date);

create table public.finance_events (
 id bigint generated always as identity primary key,
 pelada_id uuid not null references public.peladas(id),
 actor_user_id uuid references public.profiles(id) on delete set null,
 event_type text not null,
 entity text not null,
 entity_id uuid,
 before_data jsonb,
 after_data jsonb,
 created_at timestamptz not null default now()
);
create index finance_events_by_pelada on public.finance_events(pelada_id, created_at desc);

---------------------------------------------------------------------------------------------------
-- Access
---------------------------------------------------------------------------------------------------

-- Admin, or assistant (counted as staff by the plan) with the explicit finance permission.
create function private.has_finance_access(p_pelada uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.pelada_memberships m where m.pelada_id=p_pelada and m.user_id=(select auth.uid())
  and m.status='active' and (m.role='admin' or (m.role='assistant' and private.is_active_staff(p_pelada)
   and exists(select 1 from public.finance_access a where a.pelada_id=p_pelada and a.membership_id=m.id))));
$$;

create function private.can_read_finance(p_pelada uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select private.has_finance_access(p_pelada) and private.pelada_has_premium(p_pelada);
$$;

-- Every finance call: authenticated, finance permission, Pelada Premium. Writes also serialize per pelada.
create function private.require_finance(p_pelada uuid, p_write boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_pelada is null or not exists(select 1 from public.peladas where id=p_pelada) then raise exception 'PELADA_NOT_FOUND'; end if;
 if not private.has_finance_access(p_pelada) then raise exception 'FINANCE_FORBIDDEN' using errcode='42501'; end if;
 if not private.pelada_has_premium(p_pelada) then raise exception 'PREMIUM_REQUIRED'; end if;
 if p_write then perform pg_advisory_xact_lock(hashtextextended('finance:' || p_pelada::text, 0)); end if;
end $$;

create function private.finance_log(p_pelada uuid, p_event text, p_entity text, p_id uuid, p_before jsonb, p_after jsonb)
returns void language sql security definer set search_path = '' as $$
 insert into public.finance_events(pelada_id,actor_user_id,event_type,entity,entity_id,before_data,after_data)
 values(p_pelada,auth.uid(),p_event,p_entity,p_id,p_before,p_after);
$$;

create function private.finance_person_name(p_membership uuid, p_payer uuid) returns text
language sql stable security definer set search_path = '' as $$
 select coalesce((select player_name from public.pelada_memberships where id=p_membership),
  (select display_name from public.finance_payers where id=p_payer), '-');
$$;

-- The person must belong to this pelada (any status for history; active required for new records).
create function private.finance_check_person(p_pelada uuid, p_membership uuid, p_payer uuid, p_new boolean) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
 if (p_membership is null) = (p_payer is null) then raise exception 'FINANCE_PERSON_REQUIRED'; end if;
 if p_membership is not null and not exists(select 1 from public.pelada_memberships where id=p_membership and pelada_id=p_pelada
   and (status='active' or not p_new)) then raise exception 'FINANCE_INVALID_PERSON'; end if;
 if p_payer is not null and not exists(select 1 from public.finance_payers where id=p_payer and pelada_id=p_pelada
   and (archived_at is null or not p_new)) then raise exception 'FINANCE_INVALID_PERSON'; end if;
end $$;

create function private.finance_status(p_due integer, p_paid integer) returns text
language sql immutable set search_path = '' as $$
 select case when p_paid = 0 then 'pending' when p_paid < p_due then 'partial' else 'paid' end;
$$;

create function private.charge_json(p_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('id', c.id, 'kind', c.kind, 'finance_member_id', c.finance_member_id,
  'membership_id', c.membership_id, 'payer_id', c.payer_id, 'person_name', private.finance_person_name(c.membership_id, c.payer_id),
  'match_id', c.match_id, 'reference_month', c.reference_month, 'description', c.description,
  'amount_due_cents', c.amount_due_cents, 'amount_paid_cents', c.amount_paid_cents,
  'outstanding_cents', case when c.status='cancelled' then 0 else c.amount_due_cents - c.amount_paid_cents end,
  'due_date', c.due_date, 'status', c.status,
  'overdue', c.status in ('pending','partial') and c.due_date < private.pelada_today(c.pelada_id),
  'version', c.version, 'created_at', c.created_at, 'cancelled_at', c.cancelled_at, 'cancel_reason', c.cancel_reason,
  'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'amount_cents', p.amount_cents, 'received_on', p.received_on,
     'method', p.method, 'notes', p.notes, 'created_at', p.created_at, 'reversed_at', p.reversed_at, 'reverse_reason', p.reverse_reason,
     'created_by_name', (select display_name from public.profiles where id=p.created_by)) order by p.received_on, p.created_at)
   from public.finance_payments p where p.charge_id=c.id), '[]'::jsonb))
 from public.finance_charges c where c.id=p_id;
$$;

-- Who may use the Financeiro (any member may ask; nothing financial is returned to others).
create function public.get_finance_access(p_pelada uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.is_active_member(p_pelada) then raise exception 'PELADA_NOT_FOUND'; end if;
 return jsonb_build_object('can_access', private.has_finance_access(p_pelada),
  'premium', private.pelada_has_premium(p_pelada), 'is_admin', private.is_active_admin(p_pelada),
  'has_records', case when private.has_finance_access(p_pelada) then
    exists(select 1 from public.finance_events where pelada_id=p_pelada) else null end,
  'assistants', case when private.is_active_admin(p_pelada) then coalesce((select jsonb_agg(jsonb_build_object(
     'membership_id', m.id, 'name', m.player_name,
     'enabled', exists(select 1 from public.finance_access a where a.pelada_id=p_pelada and a.membership_id=m.id))
     order by m.player_name)
   from public.pelada_memberships m where m.pelada_id=p_pelada and m.status='active' and m.role='assistant'), '[]'::jsonb) end);
end $$;

-- Admin only: enable/disable the finance permission of an assistant.
create function public.set_finance_access(p_pelada uuid, p_membership uuid, p_enabled boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if not private.pelada_has_premium(p_pelada) then raise exception 'PREMIUM_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended('finance:' || p_pelada::text, 0));
 if coalesce(p_enabled, false) then
  if not exists(select 1 from public.pelada_memberships where id=p_membership and pelada_id=p_pelada and status='active' and role='assistant') then
   raise exception 'FINANCE_ASSISTANT_REQUIRED'; end if;
  insert into public.finance_access(pelada_id,membership_id,granted_by) values(p_pelada,p_membership,auth.uid())
  on conflict do nothing;
  if found then perform private.finance_log(p_pelada,'access_granted','access',p_membership,null,null); end if;
 else
  delete from public.finance_access where pelada_id=p_pelada and membership_id=p_membership;
  if found then perform private.finance_log(p_pelada,'access_revoked','access',p_membership,null,null); end if;
 end if;
end $$;

---------------------------------------------------------------------------------------------------
-- People
---------------------------------------------------------------------------------------------------

create function public.save_finance_payer(p_pelada uuid, p_id uuid, p_name text, p_notes text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_old public.finance_payers; v_id uuid; v_name text := btrim(coalesce(p_name,''));
begin
 perform private.require_finance(p_pelada, true);
 if length(v_name) not between 2 and 60 then raise exception 'FINANCE_INVALID_NAME'; end if;
 if exists(select 1 from public.finance_payers where pelada_id=p_pelada and archived_at is null
   and lower(btrim(display_name))=lower(v_name) and id is distinct from p_id) then raise exception 'FINANCE_DUPLICATE_PAYER'; end if;
 if p_id is null then
  insert into public.finance_payers(pelada_id,display_name,notes,created_by) values(p_pelada,v_name,nullif(btrim(p_notes),''),auth.uid())
  returning id into v_id;
  perform private.finance_log(p_pelada,'payer_created','payer',v_id,null,jsonb_build_object('name',v_name));
 else
  select * into v_old from public.finance_payers where id=p_id and pelada_id=p_pelada and archived_at is null for update;
  if not found then raise exception 'FINANCE_NOT_FOUND'; end if;
  update public.finance_payers set display_name=v_name, notes=nullif(btrim(p_notes),'') where id=p_id returning id into v_id;
  perform private.finance_log(p_pelada,'payer_updated','payer',v_id,jsonb_build_object('name',v_old.display_name),
   jsonb_build_object('name',v_name));
 end if;
 return v_id;
end $$;

---------------------------------------------------------------------------------------------------
-- Mensalistas
---------------------------------------------------------------------------------------------------

create function private.finance_member_json(p_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('id', f.id, 'membership_id', f.membership_id, 'payer_id', f.payer_id,
  'person_name', private.finance_person_name(f.membership_id, f.payer_id),
  'person_active', case when f.membership_id is not null then (select status='active' from public.pelada_memberships where id=f.membership_id)
    else (select archived_at is null from public.finance_payers where id=f.payer_id) end,
  'amount_cents', f.amount_cents, 'due_day', f.due_day, 'starts_on', f.starts_on, 'ends_on', f.ends_on,
  'status', f.status, 'notes', f.notes, 'version', f.version,
  'overdue_cents', coalesce((select sum(c.amount_due_cents - c.amount_paid_cents) from public.finance_charges c
    where c.finance_member_id=f.id and c.status in ('pending','partial') and c.due_date < private.pelada_today(f.pelada_id)), 0),
  'open_cents', coalesce((select sum(c.amount_due_cents - c.amount_paid_cents) from public.finance_charges c
    where c.finance_member_id=f.id and c.status in ('pending','partial')), 0))
 from public.finance_members f where f.id=p_id;
$$;

-- Creates or edits a mensalista. A new amount only applies to charges generated afterwards.
create function public.save_monthly_member(p_pelada uuid, p_id uuid, p_membership uuid, p_payer uuid, p_amount_cents integer,
 p_due_day integer, p_starts_on date, p_notes text default null, p_expected_version integer default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old public.finance_members; v_id uuid;
begin
 perform private.require_finance(p_pelada, true);
 if p_amount_cents is null or p_amount_cents not between 1 and 100000000 then raise exception 'FINANCE_INVALID_AMOUNT'; end if;
 if p_due_day is null or p_due_day not between 1 and 28 then raise exception 'FINANCE_INVALID_DUE_DAY'; end if;
 if p_starts_on is null then raise exception 'FINANCE_INVALID_DATE'; end if;
 if p_id is null then
  perform private.finance_check_person(p_pelada, p_membership, p_payer, true);
  if exists(select 1 from public.finance_members where pelada_id=p_pelada and status<>'ended'
    and (membership_id=p_membership or payer_id=p_payer)) then raise exception 'FINANCE_ALREADY_MONTHLY'; end if;
  insert into public.finance_members(pelada_id,membership_id,payer_id,amount_cents,due_day,starts_on,notes,created_by)
  values(p_pelada,p_membership,p_payer,p_amount_cents,p_due_day,p_starts_on,nullif(btrim(p_notes),''),auth.uid()) returning id into v_id;
  perform private.finance_log(p_pelada,'monthly_created','monthly_member',v_id,null,private.finance_member_json(v_id) - 'overdue_cents' - 'open_cents');
 else
  select * into v_old from public.finance_members where id=p_id and pelada_id=p_pelada for update;
  if not found or v_old.status='ended' then raise exception 'FINANCE_NOT_FOUND'; end if;
  if p_expected_version is not null and p_expected_version <> v_old.version then raise exception 'FINANCE_VERSION_CONFLICT'; end if;
  update public.finance_members set amount_cents=p_amount_cents, due_day=p_due_day, starts_on=p_starts_on,
   notes=nullif(btrim(p_notes),''), version=version+1, updated_at=now() where id=p_id returning id into v_id;
  perform private.finance_log(p_pelada,'monthly_updated','monthly_member',v_id,
   jsonb_build_object('amount_cents',v_old.amount_cents,'due_day',v_old.due_day,'starts_on',v_old.starts_on,'notes',v_old.notes),
   jsonb_build_object('amount_cents',p_amount_cents,'due_day',p_due_day,'starts_on',p_starts_on,'notes',nullif(btrim(p_notes),'')));
 end if;
 return private.finance_member_json(v_id);
end $$;

-- active <-> suspended, or ended (final). Open charges stay owed.
create function public.set_monthly_member_status(p_id uuid, p_status text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old public.finance_members;
begin
 select * into v_old from public.finance_members where id=p_id;
 if not found then raise exception 'FINANCE_NOT_FOUND'; end if;
 perform private.require_finance(v_old.pelada_id, true);
 select * into v_old from public.finance_members where id=p_id for update;
 if p_status is null or p_status not in ('active','suspended','ended') or v_old.status='ended' then raise exception 'FINANCE_INVALID_STATUS'; end if;
 update public.finance_members set status=p_status, version=version+1, updated_at=now(),
  ends_on=case when p_status='ended' then private.pelada_today(pelada_id) else null end where id=p_id;
 perform private.finance_log(v_old.pelada_id,'monthly_status','monthly_member',p_id,jsonb_build_object('status',v_old.status),
  jsonb_build_object('status',p_status,'reason',nullif(btrim(p_reason),'')));
 return private.finance_member_json(p_id);
end $$;

-- One charge per active mensalista and month (idempotent). Month: up to the next one; never before the start.
create function public.generate_monthly_charges(p_pelada uuid, p_month date default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare v_month date; v_end date; v_today date; v_n integer := 0; f public.finance_members; v_id uuid;
begin
 perform private.require_finance(p_pelada, true);
 v_today := private.pelada_today(p_pelada);
 v_month := date_trunc('month', coalesce(p_month, v_today))::date;
 if v_month > (date_trunc('month', v_today) + interval '1 month')::date then raise exception 'FINANCE_INVALID_DATE'; end if;
 v_end := (v_month + interval '1 month - 1 day')::date;
 for f in select * from public.finance_members where pelada_id=p_pelada and status='active' and starts_on <= v_end
   and (membership_id is null or exists(select 1 from public.pelada_memberships m where m.id=membership_id and m.status='active'))
   and (payer_id is null or exists(select 1 from public.finance_payers p where p.id=payer_id and p.archived_at is null))
   order by created_at loop
  insert into public.finance_charges(pelada_id,kind,finance_member_id,membership_id,payer_id,reference_month,description,
   amount_due_cents,due_date,created_by)
  values(p_pelada,'monthly',f.id,f.membership_id,f.payer_id,v_month,'Mensalidade '||to_char(v_month,'MM/YYYY'),
   f.amount_cents, make_date(extract(year from v_month)::int, extract(month from v_month)::int, f.due_day), auth.uid())
  on conflict (finance_member_id, reference_month) do nothing
  returning id into v_id;
  if v_id is not null then
   v_n := v_n + 1;
   perform private.finance_log(p_pelada,'charge_created','charge',v_id,null,
    jsonb_build_object('kind','monthly','amount_due_cents',f.amount_cents,'reference_month',v_month));
   v_id := null;
  end if;
 end loop;
 return v_n;
end $$;

---------------------------------------------------------------------------------------------------
-- Charges and payments
---------------------------------------------------------------------------------------------------

-- Avulso ('single', optionally a match of this pelada) or contribuição extraordinária ('extra').
create function public.create_charge(p_pelada uuid, p_kind text, p_membership uuid, p_payer uuid, p_match uuid,
 p_description text, p_amount_cents integer, p_due_date date, p_request_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
 perform private.require_finance(p_pelada, true);
 if p_request_id is null then raise exception 'FINANCE_REQUEST_ID_REQUIRED'; end if;
 select id into v_id from public.finance_charges where pelada_id=p_pelada and request_id=p_request_id;
 if found then return private.charge_json(v_id); end if; -- same request again: same result
 if p_kind is null or p_kind not in ('single','extra') then raise exception 'FINANCE_INVALID_KIND'; end if;
 if p_amount_cents is null or p_amount_cents not between 1 and 100000000 then raise exception 'FINANCE_INVALID_AMOUNT'; end if;
 if p_due_date is null then raise exception 'FINANCE_INVALID_DATE'; end if;
 perform private.finance_check_person(p_pelada, p_membership, p_payer, true);
 if p_match is not null and not exists(select 1 from public.matches where id=p_match and pelada_id=p_pelada) then
  raise exception 'FINANCE_INVALID_MATCH'; end if;
 insert into public.finance_charges(pelada_id,kind,membership_id,payer_id,match_id,description,amount_due_cents,due_date,request_id,created_by)
 values(p_pelada,p_kind,p_membership,p_payer,p_match,
  coalesce(nullif(btrim(p_description),''), case p_kind when 'single' then 'Avulso' else 'Contribuição extraordinária' end),
  p_amount_cents,p_due_date,p_request_id,auth.uid()) returning id into v_id;
 perform private.finance_log(p_pelada,'charge_created','charge',v_id,null,
  jsonb_build_object('kind',p_kind,'amount_due_cents',p_amount_cents,'due_date',p_due_date));
 return private.charge_json(v_id);
end $$;

-- Change amount, due date or description of an open charge (amount never below what was paid).
create function public.update_charge(p_charge uuid, p_amount_cents integer, p_due_date date, p_description text,
 p_expected_version integer default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old public.finance_charges;
begin
 select * into v_old from public.finance_charges where id=p_charge;
 if not found then raise exception 'FINANCE_NOT_FOUND'; end if;
 perform private.require_finance(v_old.pelada_id, true);
 select * into v_old from public.finance_charges where id=p_charge for update;
 if v_old.status='cancelled' then raise exception 'FINANCE_CHARGE_CANCELLED'; end if;
 if p_expected_version is not null and p_expected_version <> v_old.version then raise exception 'FINANCE_VERSION_CONFLICT'; end if;
 if p_amount_cents is null or p_amount_cents not between 1 and 100000000 then raise exception 'FINANCE_INVALID_AMOUNT'; end if;
 if p_amount_cents < v_old.amount_paid_cents then raise exception 'FINANCE_AMOUNT_BELOW_PAID'; end if;
 if p_due_date is null then raise exception 'FINANCE_INVALID_DATE'; end if;
 update public.finance_charges set amount_due_cents=p_amount_cents, due_date=p_due_date,
  description=coalesce(nullif(btrim(p_description),''), description),
  status=private.finance_status(p_amount_cents, amount_paid_cents), version=version+1, updated_at=now() where id=p_charge;
 perform private.finance_log(v_old.pelada_id,
  case when p_due_date <> v_old.due_date and p_amount_cents = v_old.amount_due_cents then 'charge_due_date_changed' else 'charge_updated' end,
  'charge',p_charge,
  jsonb_build_object('amount_due_cents',v_old.amount_due_cents,'due_date',v_old.due_date,'description',v_old.description),
  jsonb_build_object('amount_due_cents',p_amount_cents,'due_date',p_due_date,'description',coalesce(nullif(btrim(p_description),''), v_old.description)));
 return private.charge_json(p_charge);
end $$;

-- Logical deletion. Only without payments (reverse them first).
create function public.cancel_charge(p_charge uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old public.finance_charges;
begin
 select * into v_old from public.finance_charges where id=p_charge;
 if not found then raise exception 'FINANCE_NOT_FOUND'; end if;
 perform private.require_finance(v_old.pelada_id, true);
 select * into v_old from public.finance_charges where id=p_charge for update;
 if v_old.status='cancelled' then return private.charge_json(p_charge); end if;
 if v_old.amount_paid_cents > 0 then raise exception 'FINANCE_CHARGE_HAS_PAYMENTS'; end if;
 if length(btrim(coalesce(p_reason,''))) < 3 then raise exception 'FINANCE_REASON_REQUIRED'; end if;
 update public.finance_charges set status='cancelled', cancelled_at=now(), cancelled_by=auth.uid(),
  cancel_reason=btrim(p_reason), version=version+1, updated_at=now() where id=p_charge;
 perform private.finance_log(v_old.pelada_id,'charge_cancelled','charge',p_charge,jsonb_build_object('status',v_old.status),
  jsonb_build_object('status','cancelled','reason',btrim(p_reason)));
 return private.charge_json(p_charge);
end $$;

-- Records a payment received (manual). Idempotent by p_request_id; refuses overpayment; a same-amount payment
-- on the same charge in the last 10 minutes needs p_confirm_duplicate (two admins registering the same money).
create function public.register_payment(p_charge uuid, p_amount_cents integer, p_received_on date, p_method text,
 p_notes text, p_request_id uuid, p_confirm_duplicate boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_c public.finance_charges; v_id uuid; v_today date;
begin
 select * into v_c from public.finance_charges where id=p_charge;
 if not found then raise exception 'FINANCE_NOT_FOUND'; end if;
 perform private.require_finance(v_c.pelada_id, true);
 if p_request_id is null then raise exception 'FINANCE_REQUEST_ID_REQUIRED'; end if;
 select id into v_id from public.finance_payments where pelada_id=v_c.pelada_id and request_id=p_request_id;
 if found then return private.charge_json(p_charge); end if;
 select * into v_c from public.finance_charges where id=p_charge for update;
 if v_c.status='cancelled' then raise exception 'FINANCE_CHARGE_CANCELLED'; end if;
 if p_amount_cents is null or p_amount_cents < 1 then raise exception 'FINANCE_INVALID_AMOUNT'; end if;
 if p_amount_cents > v_c.amount_due_cents - v_c.amount_paid_cents then raise exception 'FINANCE_OVERPAYMENT'; end if;
 v_today := private.pelada_today(v_c.pelada_id);
 if p_received_on is null or p_received_on > v_today then raise exception 'FINANCE_INVALID_DATE'; end if;
 if p_method is not null and p_method not in ('pix','dinheiro','cartao','transferencia','outro') then raise exception 'FINANCE_INVALID_METHOD'; end if;
 if not coalesce(p_confirm_duplicate, false) and exists(select 1 from public.finance_payments where charge_id=p_charge
   and reversed_at is null and amount_cents=p_amount_cents and created_at > now() - interval '10 minutes') then
  raise exception 'FINANCE_POSSIBLE_DUPLICATE'; end if;
 insert into public.finance_payments(pelada_id,charge_id,amount_cents,received_on,method,notes,request_id,created_by)
 values(v_c.pelada_id,p_charge,p_amount_cents,p_received_on,p_method,nullif(btrim(p_notes),''),p_request_id,auth.uid()) returning id into v_id;
 update public.finance_charges set amount_paid_cents=amount_paid_cents+p_amount_cents,
  status=private.finance_status(amount_due_cents, amount_paid_cents+p_amount_cents), updated_at=now() where id=p_charge;
 perform private.finance_log(v_c.pelada_id,'payment_registered','payment',v_id,
  jsonb_build_object('charge_id',p_charge,'amount_paid_cents',v_c.amount_paid_cents,'status',v_c.status),
  jsonb_build_object('charge_id',p_charge,'amount_cents',p_amount_cents,'received_on',p_received_on,'method',p_method,
   'amount_paid_cents',v_c.amount_paid_cents+p_amount_cents,'status',private.finance_status(v_c.amount_due_cents, v_c.amount_paid_cents+p_amount_cents)));
 return private.charge_json(p_charge);
end $$;

-- Estorno: the payment stays recorded (reversed), the charge goes back to what is still owed.
create function public.reverse_payment(p_payment uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_p public.finance_payments; v_c public.finance_charges;
begin
 select * into v_p from public.finance_payments where id=p_payment;
 if not found then raise exception 'FINANCE_NOT_FOUND'; end if;
 perform private.require_finance(v_p.pelada_id, true);
 select * into v_c from public.finance_charges where id=v_p.charge_id for update;
 select * into v_p from public.finance_payments where id=p_payment for update;
 if v_p.reversed_at is not null then raise exception 'FINANCE_ALREADY_REVERSED'; end if;
 if length(btrim(coalesce(p_reason,''))) < 3 then raise exception 'FINANCE_REASON_REQUIRED'; end if;
 update public.finance_payments set reversed_at=now(), reversed_by=auth.uid(), reverse_reason=btrim(p_reason) where id=p_payment;
 update public.finance_charges set amount_paid_cents=amount_paid_cents-v_p.amount_cents,
  status=private.finance_status(amount_due_cents, amount_paid_cents-v_p.amount_cents), updated_at=now() where id=v_c.id;
 perform private.finance_log(v_p.pelada_id,'payment_reversed','payment',p_payment,
  jsonb_build_object('amount_cents',v_p.amount_cents,'charge_status',v_c.status,'amount_paid_cents',v_c.amount_paid_cents),
  jsonb_build_object('reason',btrim(p_reason),'amount_paid_cents',v_c.amount_paid_cents-v_p.amount_cents,
   'charge_status',private.finance_status(v_c.amount_due_cents, v_c.amount_paid_cents-v_p.amount_cents)));
 return private.charge_json(v_c.id);
end $$;

---------------------------------------------------------------------------------------------------
-- Other income and expenses
---------------------------------------------------------------------------------------------------

create function public.save_finance_entry(p_pelada uuid, p_id uuid, p_direction text, p_category text, p_description text,
 p_amount_cents integer, p_entry_date date, p_status text, p_method text default null, p_notes text default null,
 p_request_id uuid default null, p_expected_version integer default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old public.finance_entries; v_id uuid;
begin
 perform private.require_finance(p_pelada, true);
 if p_id is null then
  if p_request_id is null then raise exception 'FINANCE_REQUEST_ID_REQUIRED'; end if;
  select id into v_id from public.finance_entries where pelada_id=p_pelada and request_id=p_request_id;
  if found then return (select to_jsonb(e) from public.finance_entries e where e.id=v_id); end if;
 end if;
 if p_direction is null or p_direction not in ('income','expense') then raise exception 'FINANCE_INVALID_KIND'; end if;
 if length(btrim(coalesce(p_category,''))) not between 1 and 40 then raise exception 'FINANCE_INVALID_CATEGORY'; end if;
 if length(btrim(coalesce(p_description,''))) not between 1 and 120 then raise exception 'FINANCE_INVALID_DESCRIPTION'; end if;
 if p_amount_cents is null or p_amount_cents not between 1 and 100000000 then raise exception 'FINANCE_INVALID_AMOUNT'; end if;
 if p_status is null or p_status not in ('pending','settled') then raise exception 'FINANCE_INVALID_STATUS'; end if;
 if p_entry_date is null or (p_status='settled' and p_entry_date > private.pelada_today(p_pelada)) then raise exception 'FINANCE_INVALID_DATE'; end if;
 if p_method is not null and p_method not in ('pix','dinheiro','cartao','transferencia','outro') then raise exception 'FINANCE_INVALID_METHOD'; end if;
 if p_id is null then
  insert into public.finance_entries(pelada_id,direction,category,description,amount_cents,entry_date,status,method,notes,request_id,created_by)
  values(p_pelada,p_direction,btrim(p_category),btrim(p_description),p_amount_cents,p_entry_date,p_status,p_method,
   nullif(btrim(p_notes),''),p_request_id,auth.uid()) returning id into v_id;
  perform private.finance_log(p_pelada,'entry_created','entry',v_id,null,
   (select to_jsonb(e) - 'request_id' from public.finance_entries e where e.id=v_id));
 else
  select * into v_old from public.finance_entries where id=p_id and pelada_id=p_pelada for update;
  if not found or v_old.status='cancelled' then raise exception 'FINANCE_NOT_FOUND'; end if;
  if v_old.direction <> p_direction then raise exception 'FINANCE_INVALID_KIND'; end if;
  if p_expected_version is not null and p_expected_version <> v_old.version then raise exception 'FINANCE_VERSION_CONFLICT'; end if;
  update public.finance_entries set category=btrim(p_category), description=btrim(p_description), amount_cents=p_amount_cents,
   entry_date=p_entry_date, status=p_status, method=p_method, notes=nullif(btrim(p_notes),''), version=version+1, updated_at=now()
  where id=p_id returning id into v_id;
  perform private.finance_log(p_pelada,'entry_updated','entry',v_id,to_jsonb(v_old) - 'request_id',
   (select to_jsonb(e) - 'request_id' from public.finance_entries e where e.id=v_id));
 end if;
 return (select to_jsonb(e) from public.finance_entries e where e.id=v_id);
end $$;

create function public.cancel_finance_entry(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_old public.finance_entries;
begin
 select * into v_old from public.finance_entries where id=p_id;
 if not found then raise exception 'FINANCE_NOT_FOUND'; end if;
 perform private.require_finance(v_old.pelada_id, true);
 select * into v_old from public.finance_entries where id=p_id for update;
 if v_old.status='cancelled' then return; end if;
 if length(btrim(coalesce(p_reason,''))) < 3 then raise exception 'FINANCE_REASON_REQUIRED'; end if;
 update public.finance_entries set status='cancelled', cancelled_at=now(), cancel_reason=btrim(p_reason), version=version+1,
  updated_at=now() where id=p_id;
 perform private.finance_log(v_old.pelada_id,'entry_cancelled','entry',p_id,jsonb_build_object('status',v_old.status),
  jsonb_build_object('status','cancelled','reason',btrim(p_reason)));
end $$;

---------------------------------------------------------------------------------------------------
-- Reads (official numbers computed here)
---------------------------------------------------------------------------------------------------

create function private.finance_totals(p_pelada uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object(
  'income_cents', coalesce((select sum(amount_cents) from public.finance_payments where pelada_id=p_pelada and reversed_at is null
     and received_on between p_from and p_to), 0)
   + coalesce((select sum(amount_cents) from public.finance_entries where pelada_id=p_pelada and direction='income'
     and status='settled' and entry_date between p_from and p_to), 0),
  'expense_cents', coalesce((select sum(amount_cents) from public.finance_entries where pelada_id=p_pelada and direction='expense'
     and status='settled' and entry_date between p_from and p_to), 0));
$$;

-- Dashboard: realized balance (all time), month figures, what is owed, mensalistas, latest movements.
create function public.get_finance_overview(p_pelada uuid, p_month date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_today date; v_from date; v_to date; v_all jsonb; v_m jsonb; v_recv bigint; v_recv_overdue bigint; v_pexp bigint; v_pinc bigint;
begin
 perform private.require_finance(p_pelada, false);
 v_today := private.pelada_today(p_pelada);
 v_from := date_trunc('month', coalesce(p_month, v_today))::date;
 v_to := (v_from + interval '1 month - 1 day')::date;
 v_all := private.finance_totals(p_pelada, '0001-01-01', '9999-12-31');
 v_m := private.finance_totals(p_pelada, v_from, v_to);
 select coalesce(sum(amount_due_cents - amount_paid_cents), 0),
  coalesce(sum(amount_due_cents - amount_paid_cents) filter (where due_date < v_today), 0)
 into v_recv, v_recv_overdue from public.finance_charges where pelada_id=p_pelada and status in ('pending','partial');
 select coalesce(sum(amount_cents) filter (where direction='expense'), 0), coalesce(sum(amount_cents) filter (where direction='income'), 0)
 into v_pexp, v_pinc from public.finance_entries where pelada_id=p_pelada and status='pending';
 return jsonb_build_object('today', v_today, 'month', v_from,
  'balance_cents', (v_all->>'income_cents')::bigint - (v_all->>'expense_cents')::bigint,
  'month_income_cents', (v_m->>'income_cents')::bigint, 'month_expense_cents', (v_m->>'expense_cents')::bigint,
  'receivable_cents', v_recv + v_pinc, 'overdue_cents', v_recv_overdue, 'pending_expense_cents', v_pexp,
  'projected_balance_cents', (v_all->>'income_cents')::bigint - (v_all->>'expense_cents')::bigint + v_recv + v_pinc - v_pexp,
  'monthly_active', (select count(*) from public.finance_members where pelada_id=p_pelada and status='active'),
  'monthly_late', (select count(distinct c.finance_member_id) from public.finance_charges c join public.finance_members f on f.id=c.finance_member_id
     where c.pelada_id=p_pelada and f.status='active' and c.status in ('pending','partial') and c.due_date < v_today),
  'single_count_month', (select count(*) from public.finance_charges where pelada_id=p_pelada and kind='single' and status<>'cancelled'
     and due_date between v_from and v_to),
  'month_charges_missing', (select count(*) from public.finance_members f where f.pelada_id=p_pelada and f.status='active'
     and f.starts_on <= v_to and not exists(select 1 from public.finance_charges c where c.finance_member_id=f.id and c.reference_month=v_from)),
  'latest', public.get_finance_ledger(p_pelada, null, null, null, 8));
end $$;

-- Movements (cash book): payments received (and reversed) and other income/expenses.
create function public.get_finance_ledger(p_pelada uuid, p_month date default null, p_direction text default null,
 p_category text default null, p_limit integer default 200) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_from date; v_to date;
begin
 perform private.require_finance(p_pelada, false);
 if p_month is not null then v_from := date_trunc('month', p_month)::date; v_to := (v_from + interval '1 month - 1 day')::date; end if;
 return coalesce((select jsonb_agg(x order by (x->>'date') desc, (x->>'created_at') desc) from (
  select x from (
   select jsonb_build_object('source','payment','id',p.id,'charge_id',c.id,'direction','income',
    'category', case c.kind when 'monthly' then 'Mensalidade' when 'single' then 'Avulso' else 'Contribuição extraordinária' end,
    'description', c.description || ' · ' || private.finance_person_name(c.membership_id, c.payer_id),
    'amount_cents', p.amount_cents, 'date', p.received_on, 'method', p.method,
    'status', case when p.reversed_at is null then 'settled' else 'reversed' end,
    'author', (select display_name from public.profiles where id=p.created_by), 'created_at', p.created_at) x
   from public.finance_payments p join public.finance_charges c on c.id=p.charge_id
   where p.pelada_id=p_pelada and (v_from is null or p.received_on between v_from and v_to)
   union all
   select jsonb_build_object('source','entry','id',e.id,'direction',e.direction,'category',e.category,'description',e.description,
    'amount_cents', e.amount_cents, 'date', e.entry_date, 'method', e.method, 'status', e.status, 'version', e.version,
    'notes', e.notes, 'cancel_reason', e.cancel_reason,
    'author', (select display_name from public.profiles where id=e.created_by), 'created_at', e.created_at)
   from public.finance_entries e
   where e.pelada_id=p_pelada and (v_from is null or e.entry_date between v_from and v_to)) y
  where (p_direction is null or x->>'direction'=p_direction) and (p_category is null or x->>'category'=p_category)
  order by (x->>'date') desc, (x->>'created_at') desc limit greatest(1, least(coalesce(p_limit,200), 1000))) z), '[]'::jsonb);
end $$;

-- Charges with filters (month by due date, status incl. 'overdue', person, kind).
create function public.get_finance_charges(p_pelada uuid, p_month date default null, p_status text default null,
 p_membership uuid default null, p_payer uuid default null, p_kind text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_from date; v_to date; v_today date;
begin
 perform private.require_finance(p_pelada, false);
 v_today := private.pelada_today(p_pelada);
 if p_month is not null then v_from := date_trunc('month', p_month)::date; v_to := (v_from + interval '1 month - 1 day')::date; end if;
 return coalesce((select jsonb_agg(private.charge_json(c.id) order by c.due_date, c.created_at) from public.finance_charges c
  where c.pelada_id=p_pelada and (v_from is null or c.due_date between v_from and v_to)
   and (p_status is null or c.status=p_status or (p_status='open' and c.status in ('pending','partial'))
        or (p_status='overdue' and c.status in ('pending','partial') and c.due_date < v_today))
   and (p_membership is null or c.membership_id=p_membership) and (p_payer is null or c.payer_id=p_payer)
   and (p_kind is null or c.kind=p_kind)), '[]'::jsonb);
end $$;

-- People: mensalistas, external payers and members (for the pickers).
create function public.get_finance_people(p_pelada uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 perform private.require_finance(p_pelada, false);
 return jsonb_build_object(
  'monthly', coalesce((select jsonb_agg(private.finance_member_json(f.id) order by f.status, private.finance_person_name(f.membership_id, f.payer_id))
    from public.finance_members f where f.pelada_id=p_pelada), '[]'::jsonb),
  'payers', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.display_name, 'notes', p.notes) order by p.display_name)
    from public.finance_payers p where p.pelada_id=p_pelada and p.archived_at is null), '[]'::jsonb),
  'members', coalesce((select jsonb_agg(jsonb_build_object('membership_id', m.id, 'name', m.player_name) order by m.player_name)
    from public.pelada_memberships m where m.pelada_id=p_pelada and m.status='active'), '[]'::jsonb));
end $$;

-- Reports: month summary, by category, by person (owed/paid in the month and open in total).
create function public.get_finance_report(p_pelada uuid, p_month date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_from date; v_to date; v_t jsonb;
begin
 perform private.require_finance(p_pelada, false);
 v_from := date_trunc('month', coalesce(p_month, private.pelada_today(p_pelada)))::date;
 v_to := (v_from + interval '1 month - 1 day')::date;
 v_t := private.finance_totals(p_pelada, v_from, v_to);
 return jsonb_build_object('month', v_from,
  'income_cents', (v_t->>'income_cents')::bigint, 'expense_cents', (v_t->>'expense_cents')::bigint,
  'result_cents', (v_t->>'income_cents')::bigint - (v_t->>'expense_cents')::bigint,
  'open_cents', coalesce((select sum(amount_due_cents - amount_paid_cents) from public.finance_charges where pelada_id=p_pelada
     and status in ('pending','partial') and due_date between v_from and v_to), 0),
  'by_category', coalesce((select jsonb_agg(jsonb_build_object('direction', direction, 'category', category, 'amount_cents', total)
     order by direction, total desc) from (
    select x->>'direction' direction, x->>'category' category, sum((x->>'amount_cents')::bigint) total
    from jsonb_array_elements(public.get_finance_ledger(p_pelada, v_from, null, null, 1000)) x
    where x->>'status'='settled' group by 1, 2) q), '[]'::jsonb),
  'by_person', coalesce((select jsonb_agg(jsonb_build_object('membership_id', membership_id, 'payer_id', payer_id,
     'name', private.finance_person_name(membership_id, payer_id), 'due_cents', due, 'paid_cents', paid, 'open_total_cents', open_total)
     order by private.finance_person_name(membership_id, payer_id)) from (
    select c.membership_id, c.payer_id,
     sum(c.amount_due_cents) filter (where c.due_date between v_from and v_to and c.status<>'cancelled') due,
     coalesce((select sum(p.amount_cents) from public.finance_payments p join public.finance_charges c2 on c2.id=p.charge_id
       where p.reversed_at is null and p.received_on between v_from and v_to
        and c2.membership_id is not distinct from c.membership_id and c2.payer_id is not distinct from c.payer_id and c2.pelada_id=p_pelada), 0) paid,
     sum(c.amount_due_cents - c.amount_paid_cents) filter (where c.status in ('pending','partial')) open_total
    from public.finance_charges c where c.pelada_id=p_pelada group by c.membership_id, c.payer_id) q
    where coalesce(due,0) > 0 or paid > 0 or coalesce(open_total,0) > 0), '[]'::jsonb));
end $$;

-- Audit trail.
create function public.get_finance_history(p_pelada uuid, p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 perform private.require_finance(p_pelada, false);
 return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'event_type', e.event_type, 'entity', e.entity, 'entity_id', e.entity_id,
   'before', e.before_data, 'after', e.after_data, 'created_at', e.created_at,
   'author', (select display_name from public.profiles where id=e.actor_user_id)) order by e.id desc)
  from (select * from public.finance_events where pelada_id=p_pelada order by id desc
        limit greatest(1, least(coalesce(p_limit,100), 500))) e), '[]'::jsonb);
end $$;

---------------------------------------------------------------------------------------------------
-- RLS: reads only by finance users of the pelada (with Premium); writes only through the functions above.
---------------------------------------------------------------------------------------------------

alter table public.finance_access enable row level security;
alter table public.finance_payers enable row level security;
alter table public.finance_members enable row level security;
alter table public.finance_charges enable row level security;
alter table public.finance_payments enable row level security;
alter table public.finance_entries enable row level security;
alter table public.finance_events enable row level security;
revoke all on public.finance_access, public.finance_payers, public.finance_members, public.finance_charges,
 public.finance_payments, public.finance_entries, public.finance_events from anon, authenticated;
grant select on public.finance_access, public.finance_payers, public.finance_members, public.finance_charges,
 public.finance_payments, public.finance_entries, public.finance_events to authenticated;
create policy finance_access_read on public.finance_access for select to authenticated using ((select private.can_read_finance(pelada_id)));
create policy finance_payers_read on public.finance_payers for select to authenticated using ((select private.can_read_finance(pelada_id)));
create policy finance_members_read on public.finance_members for select to authenticated using ((select private.can_read_finance(pelada_id)));
create policy finance_charges_read on public.finance_charges for select to authenticated using ((select private.can_read_finance(pelada_id)));
create policy finance_payments_read on public.finance_payments for select to authenticated using ((select private.can_read_finance(pelada_id)));
create policy finance_entries_read on public.finance_entries for select to authenticated using ((select private.can_read_finance(pelada_id)));
create policy finance_events_read on public.finance_events for select to authenticated using ((select private.can_read_finance(pelada_id)));

revoke all on function private.has_finance_access(uuid), private.can_read_finance(uuid), private.require_finance(uuid,boolean),
 private.finance_log(uuid,text,text,uuid,jsonb,jsonb), private.finance_person_name(uuid,uuid),
 private.finance_check_person(uuid,uuid,uuid,boolean), private.finance_status(integer,integer), private.charge_json(uuid),
 private.finance_member_json(uuid), private.finance_totals(uuid,date,date) from public, anon, authenticated;
grant execute on function private.can_read_finance(uuid) to authenticated; -- used by the policies

revoke all on function public.get_finance_access(uuid), public.set_finance_access(uuid,uuid,boolean),
 public.save_finance_payer(uuid,uuid,text,text),
 public.save_monthly_member(uuid,uuid,uuid,uuid,integer,integer,date,text,integer),
 public.set_monthly_member_status(uuid,text,text), public.generate_monthly_charges(uuid,date),
 public.create_charge(uuid,text,uuid,uuid,uuid,text,integer,date,uuid), public.update_charge(uuid,integer,date,text,integer),
 public.cancel_charge(uuid,text), public.register_payment(uuid,integer,date,text,text,uuid,boolean),
 public.reverse_payment(uuid,text),
 public.save_finance_entry(uuid,uuid,text,text,text,integer,date,text,text,text,uuid,integer),
 public.cancel_finance_entry(uuid,text), public.get_finance_overview(uuid,date),
 public.get_finance_ledger(uuid,date,text,text,integer), public.get_finance_charges(uuid,date,text,uuid,uuid,text),
 public.get_finance_people(uuid), public.get_finance_report(uuid,date), public.get_finance_history(uuid,integer)
 from public, anon;
grant execute on function public.get_finance_access(uuid), public.set_finance_access(uuid,uuid,boolean),
 public.save_finance_payer(uuid,uuid,text,text),
 public.save_monthly_member(uuid,uuid,uuid,uuid,integer,integer,date,text,integer),
 public.set_monthly_member_status(uuid,text,text), public.generate_monthly_charges(uuid,date),
 public.create_charge(uuid,text,uuid,uuid,uuid,text,integer,date,uuid), public.update_charge(uuid,integer,date,text,integer),
 public.cancel_charge(uuid,text), public.register_payment(uuid,integer,date,text,text,uuid,boolean),
 public.reverse_payment(uuid,text),
 public.save_finance_entry(uuid,uuid,text,text,text,integer,date,text,text,text,uuid,integer),
 public.cancel_finance_entry(uuid,text), public.get_finance_overview(uuid,date),
 public.get_finance_ledger(uuid,date,text,text,integer), public.get_finance_charges(uuid,date,text,uuid,uuid,text),
 public.get_finance_people(uuid), public.get_finance_report(uuid,date), public.get_finance_history(uuid,integer)
 to authenticated;
