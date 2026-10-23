-- Minuto 91 / 044: V4.4 fase 1, desempenho e confiabilidade do Financeiro (043).
--
-- Problems confirmed in the V4.3 code (audit):
--  F1 get_finance_report summed the categories over get_finance_ledger(..., 1000): a month with more than 1,000
--     movements lost the rest, so "by category" could differ from the official totals.
--  F2 get_finance_overview built and sorted the whole cash book (all months) to show the latest 8 movements.
--  F3 get_finance_charges had no paging and called charge_json per row (one subquery per charge for the person,
--     one for the payments and one per payment for the author).
--  F4 get_finance_people called finance_member_json per mensalista (two correlated sums each).
--  F5 the report "by person" ran a correlated payment sum for every person.
--  F6 exports and the cash-book screen were capped (1,000 / 500 rows) without saying so.
--
-- What changes (rules and numbers stay exactly the same; only how they are computed):
--  - Totals and categories come from SQL aggregates over the base tables (never from a paged list).
--    Category total of income = income total; category total of expenses = expense total (tested with 2,000+ rows).
--    Reversed payments never count; pending income/expenses are reported apart and never enter the result.
--  - Batch JSON builders (one query for a page of charges, their payments and authors).
--  - Keyset pages (stable order, limit per request) for charges, cash book and audit trail:
--      get_finance_charges_page  (due_date, created_at, id) ascending, 1..100 per page, summary on the first page
--      get_finance_ledger_page   (date, created_at, id) descending, 1..500 per page (export reads every page),
--                                optional total count to prove an export is complete
--      get_finance_history_page  id descending, 1..200 per page
--  - The V4.3 functions keep their signatures and output (older app versions keep working) but use the new code.
--  - Indexes for the page orders and the person filters.
-- Same access rules as 043 (private.require_finance: finance permission + Pelada Premium).

---------------------------------------------------------------------------------------------------
-- Indexes
---------------------------------------------------------------------------------------------------

create index if not exists finance_charges_page on public.finance_charges(pelada_id, due_date, created_at, id);
drop index if exists public.finance_charges_by_month; -- prefix of finance_charges_page
create index if not exists finance_charges_by_member on public.finance_charges(pelada_id, membership_id) where membership_id is not null;
create index if not exists finance_charges_by_payer on public.finance_charges(pelada_id, payer_id) where payer_id is not null;
create index if not exists finance_payments_ledger on public.finance_payments(pelada_id, received_on desc, created_at desc, id desc);
create index if not exists finance_entries_ledger on public.finance_entries(pelada_id, entry_date desc, created_at desc, id desc);
create index if not exists finance_entries_pending on public.finance_entries(pelada_id) where status='pending';
create index if not exists finance_events_by_id on public.finance_events(pelada_id, id desc);

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

-- Payment category = label of the charge kind. Written inline (a function with SET search_path is not inlined by the
-- planner and would run once per row: measured 4,179 internal calls in a 10,000-movement report).

-- Page size: default when null, never outside 1..p_max.
create function private.page_limit(p_limit integer, p_default integer, p_max integer) returns integer
language sql immutable set search_path = '' as $$
 select greatest(1, least(coalesce(p_limit, p_default), p_max));
$$;

-- Charges of one pelada as JSON, in the order of p_ids, with payments and authors read in batch.
create function private.finance_charges_json(p_pelada uuid, p_ids uuid[]) returns jsonb
language sql stable security definer set search_path = '' as $$
 with t as (select private.pelada_today(p_pelada) today),
 ids as (select u.id, u.ord from unnest(p_ids) with ordinality u(id, ord)),
 pay as (
  select p.charge_id, jsonb_agg(jsonb_build_object('id', p.id, 'amount_cents', p.amount_cents, 'received_on', p.received_on,
    'method', p.method, 'notes', p.notes, 'created_at', p.created_at, 'reversed_at', p.reversed_at,
    'reverse_reason', p.reverse_reason, 'created_by_name', pr.display_name) order by p.received_on, p.created_at) items
  from public.finance_payments p left join public.profiles pr on pr.id = p.created_by
  where p.pelada_id = p_pelada and p.charge_id = any(p_ids)
  group by p.charge_id)
 select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'finance_member_id', c.finance_member_id,
   'membership_id', c.membership_id, 'payer_id', c.payer_id, 'person_name', coalesce(m.player_name, fp.display_name, '-'),
   'match_id', c.match_id, 'reference_month', c.reference_month, 'description', c.description,
   'amount_due_cents', c.amount_due_cents, 'amount_paid_cents', c.amount_paid_cents,
   'outstanding_cents', case when c.status = 'cancelled' then 0 else c.amount_due_cents - c.amount_paid_cents end,
   'due_date', c.due_date, 'status', c.status,
   'overdue', c.status in ('pending','partial') and c.due_date < t.today,
   'version', c.version, 'created_at', c.created_at, 'cancelled_at', c.cancelled_at, 'cancel_reason', c.cancel_reason,
   'payments', coalesce(pay.items, '[]'::jsonb)) order by ids.ord), '[]'::jsonb)
 from ids join public.finance_charges c on c.id = ids.id and c.pelada_id = p_pelada
 cross join t
 left join public.pelada_memberships m on m.id = c.membership_id
 left join public.finance_payers fp on fp.id = c.payer_id
 left join pay on pay.charge_id = c.id;
$$;

-- Same output as 043 (used after every write); one shape for single and batch reads.
create or replace function private.charge_json(p_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select private.finance_charges_json(c.pelada_id, array[c.id]) -> 0 from public.finance_charges c where c.id = p_id;
$$;

-- Charge filter shared by the page, its summary and the V4.3 list. Status: open, overdue, pending, partial, paid,
-- cancelled or null (all). Month: by due date.
create function private.finance_charge_filter_ok(p_status text, p_kind text) returns void
language plpgsql immutable set search_path = '' as $$
begin
 if p_status is not null and p_status not in ('open','overdue','pending','partial','paid','cancelled') then
  raise exception 'FINANCE_INVALID_FILTER'; end if;
 if p_kind is not null and p_kind not in ('monthly','single','extra') then raise exception 'FINANCE_INVALID_FILTER'; end if;
end $$;

---------------------------------------------------------------------------------------------------
-- Charges
---------------------------------------------------------------------------------------------------

-- p_after: the "next" object of the previous page ({due_date, created_at, id}); null = first page.
-- First page also brings the summary of the whole filter (count and amount still open), so the screen never
-- adds up only what it has loaded.
create function public.get_finance_charges_page(p_pelada uuid, p_month date default null, p_status text default null,
 p_membership uuid default null, p_payer uuid default null, p_kind text default null, p_after jsonb default null,
 p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_from date; v_to date; v_today date; v_lim integer := private.page_limit(p_limit, 50, 100);
 a_due date; a_created timestamptz; a_id uuid; v_rows record; v_ids uuid[] := '{}'; v_next jsonb; v_n integer := 0;
 v_summary jsonb;
begin
 perform private.require_finance(p_pelada, false);
 perform private.finance_charge_filter_ok(p_status, p_kind);
 v_today := private.pelada_today(p_pelada);
 if p_month is not null then v_from := date_trunc('month', p_month)::date; v_to := (v_from + interval '1 month - 1 day')::date; end if;
 if p_after is not null then
  begin
   a_due := (p_after->>'due_date')::date; a_created := (p_after->>'created_at')::timestamptz; a_id := (p_after->>'id')::uuid;
  exception when others then raise exception 'FINANCE_INVALID_CURSOR'; end;
  if a_due is null or a_created is null or a_id is null then raise exception 'FINANCE_INVALID_CURSOR'; end if;
 end if;

 for v_rows in
  select c.id, c.due_date, c.created_at from public.finance_charges c
  where c.pelada_id = p_pelada and (v_from is null or c.due_date between v_from and v_to)
   and (p_status is null or c.status = p_status or (p_status = 'open' and c.status in ('pending','partial'))
        or (p_status = 'overdue' and c.status in ('pending','partial') and c.due_date < v_today))
   and (p_membership is null or c.membership_id = p_membership) and (p_payer is null or c.payer_id = p_payer)
   and (p_kind is null or c.kind = p_kind)
   and (p_after is null or (c.due_date, c.created_at, c.id) > (a_due, a_created, a_id))
  order by c.due_date, c.created_at, c.id
  limit v_lim + 1
 loop
  v_n := v_n + 1;
  if v_n > v_lim then exit; end if;
  v_ids := v_ids || v_rows.id;
  v_next := jsonb_build_object('due_date', v_rows.due_date, 'created_at', v_rows.created_at, 'id', v_rows.id);
 end loop;
 if v_n <= v_lim then v_next := null; end if;

 if p_after is null then
  select jsonb_build_object('count', count(*),
   'outstanding_cents', coalesce(sum(c.amount_due_cents - c.amount_paid_cents) filter (where c.status in ('pending','partial')), 0),
   'partial_count', count(*) filter (where c.status = 'partial'))
  into v_summary
  from public.finance_charges c
  where c.pelada_id = p_pelada and (v_from is null or c.due_date between v_from and v_to)
   and (p_status is null or c.status = p_status or (p_status = 'open' and c.status in ('pending','partial'))
        or (p_status = 'overdue' and c.status in ('pending','partial') and c.due_date < v_today))
   and (p_membership is null or c.membership_id = p_membership) and (p_payer is null or c.payer_id = p_payer)
   and (p_kind is null or c.kind = p_kind);
 end if;

 return jsonb_build_object('items', private.finance_charges_json(p_pelada, v_ids), 'next', v_next, 'summary', v_summary);
end $$;

-- V4.3 list (older app versions): same output, now built in batch.
create or replace function public.get_finance_charges(p_pelada uuid, p_month date default null, p_status text default null,
 p_membership uuid default null, p_payer uuid default null, p_kind text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_from date; v_to date; v_today date;
begin
 perform private.require_finance(p_pelada, false);
 v_today := private.pelada_today(p_pelada);
 if p_month is not null then v_from := date_trunc('month', p_month)::date; v_to := (v_from + interval '1 month - 1 day')::date; end if;
 return private.finance_charges_json(p_pelada, array(select c.id from public.finance_charges c
  where c.pelada_id=p_pelada and (v_from is null or c.due_date between v_from and v_to)
   and (p_status is null or c.status=p_status or (p_status='open' and c.status in ('pending','partial'))
        or (p_status='overdue' and c.status in ('pending','partial') and c.due_date < v_today))
   and (p_membership is null or c.membership_id=p_membership) and (p_payer is null or c.payer_id=p_payer)
   and (p_kind is null or c.kind=p_kind)
  order by c.due_date, c.created_at, c.id));
end $$;

---------------------------------------------------------------------------------------------------
-- Cash book (payments received/reversed + other income and expenses)
---------------------------------------------------------------------------------------------------

-- Up to p_limit movements after the cursor, newest first. Each branch picks its page from the base table first
-- (index order, sargable period and cursor), and only those rows get the charge, the person and the author: the cost
-- depends on the page size, not on the history.
create function private.finance_ledger(p_pelada uuid, p_from date, p_to date, p_direction text, p_category text,
 a_date date, a_created timestamptz, a_id uuid, p_limit integer) returns jsonb
language sql stable security definer set search_path = '' as $$
 with pay as (
  select p.id, p.charge_id, p.amount_cents, p.received_on d, p.method, p.reversed_at, p.reverse_reason, p.created_by, p.created_at
  from public.finance_payments p
  where p.pelada_id = p_pelada
   and p.received_on between coalesce(p_from, '-infinity'::date) and coalesce(p_to, 'infinity'::date)
   and (p.received_on, p.created_at, p.id) < (coalesce(a_date, 'infinity'::date), coalesce(a_created, 'infinity'::timestamptz),
        coalesce(a_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
   and (p_direction is null or p_direction = 'income')
   and (p_category is null or exists(select 1 from public.finance_charges c where c.id = p.charge_id
        and (case c.kind when 'monthly' then 'Mensalidade' when 'single' then 'Avulso' else 'Contribuição extraordinária' end) = p_category))
  order by p.received_on desc, p.created_at desc, p.id desc limit p_limit),
 ent as (
  select e.id, e.direction, e.category, e.description, e.amount_cents, e.entry_date d, e.method, e.status, e.version, e.notes,
   e.cancel_reason, e.created_by, e.created_at
  from public.finance_entries e
  where e.pelada_id = p_pelada
   and e.entry_date between coalesce(p_from, '-infinity'::date) and coalesce(p_to, 'infinity'::date)
   and (e.entry_date, e.created_at, e.id) < (coalesce(a_date, 'infinity'::date), coalesce(a_created, 'infinity'::timestamptz),
        coalesce(a_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
   and (p_direction is null or e.direction = p_direction) and (p_category is null or e.category = p_category)
  order by e.entry_date desc, e.created_at desc, e.id desc limit p_limit),
 u as (
  select * from (
   select 'payment'::text source, pay.id, pay.charge_id, 'income'::text direction, null::text category, null::text description,
    pay.amount_cents, pay.d, pay.method, case when pay.reversed_at is null then 'settled' else 'reversed' end status,
    null::integer version, null::text notes, pay.reverse_reason cancel_reason, pay.created_by, pay.created_at from pay
   union all
   select 'entry', ent.id, null, ent.direction, ent.category, ent.description, ent.amount_cents, ent.d, ent.method, ent.status,
    ent.version, ent.notes, ent.cancel_reason, ent.created_by, ent.created_at from ent) x
  order by d desc, created_at desc, id desc limit p_limit)
 select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('source', u.source, 'id', u.id, 'charge_id', u.charge_id,
   'direction', u.direction,
   'category', coalesce(u.category, (case c.kind when 'monthly' then 'Mensalidade' when 'single' then 'Avulso' else 'Contribuição extraordinária' end)),
   'description', coalesce(u.description, c.description || ' · ' || coalesce(m.player_name, fp.display_name, '-')),
   'amount_cents', u.amount_cents, 'date', u.d, 'method', u.method, 'status', u.status, 'version', u.version, 'notes', u.notes,
   'cancel_reason', u.cancel_reason, 'created_at', u.created_at))
   || jsonb_build_object('author', pr.display_name, 'method', u.method)
   order by u.d desc, u.created_at desc, u.id desc), '[]'::jsonb)
 from u
 left join public.finance_charges c on c.id = u.charge_id
 left join public.pelada_memberships m on m.id = c.membership_id
 left join public.finance_payers fp on fp.id = c.payer_id
 left join public.profiles pr on pr.id = u.created_by;
$$;

-- Page of the cash book. p_from/p_to: any period (null = no bound). p_with_total: also counts every movement of
-- the filter (the export compares it with what it read).
create function public.get_finance_ledger_page(p_pelada uuid, p_from date default null, p_to date default null,
 p_direction text default null, p_category text default null, p_after jsonb default null, p_limit integer default 50,
 p_with_total boolean default false) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_lim integer := private.page_limit(p_limit, 50, 500); a_date date; a_created timestamptz; a_id uuid;
 v_items jsonb; v_next jsonb; v_total jsonb; v_last jsonb;
begin
 perform private.require_finance(p_pelada, false);
 if p_direction is not null and p_direction not in ('income','expense') then raise exception 'FINANCE_INVALID_FILTER'; end if;
 if p_from is not null and p_to is not null and p_from > p_to then raise exception 'FINANCE_INVALID_DATE'; end if;
 if p_after is not null then
  begin
   a_date := (p_after->>'date')::date; a_created := (p_after->>'created_at')::timestamptz; a_id := (p_after->>'id')::uuid;
  exception when others then raise exception 'FINANCE_INVALID_CURSOR'; end;
  if a_date is null or a_created is null or a_id is null then raise exception 'FINANCE_INVALID_CURSOR'; end if;
 end if;
 v_items := private.finance_ledger(p_pelada, p_from, p_to, p_direction, nullif(btrim(p_category), ''), a_date, a_created, a_id, v_lim + 1);
 if jsonb_array_length(v_items) > v_lim then
  v_items := (select jsonb_agg(x order by o) from jsonb_array_elements(v_items) with ordinality t(x, o) where o <= v_lim);
  v_last := v_items -> (v_lim - 1);
  v_next := jsonb_build_object('date', v_last->'date', 'created_at', v_last->'created_at', 'id', v_last->'id');
 end if;
 if coalesce(p_with_total, false) then
  select jsonb_build_object('count', count(*), 'settled_income_cents', coalesce(sum(amount) filter (where dir='income' and st='settled'), 0),
    'settled_expense_cents', coalesce(sum(amount) filter (where dir='expense' and st='settled'), 0))
  into v_total from (
   select 'income' dir, case when p.reversed_at is null then 'settled' else 'reversed' end st, p.amount_cents amount
   from public.finance_payments p
   where p.pelada_id = p_pelada and p.received_on between coalesce(p_from, '-infinity'::date) and coalesce(p_to, 'infinity'::date)
    and (p_direction is null or p_direction = 'income')
    and (nullif(btrim(p_category), '') is null or exists(select 1 from public.finance_charges c where c.id = p.charge_id
         and (case c.kind when 'monthly' then 'Mensalidade' when 'single' then 'Avulso' else 'Contribuição extraordinária' end) = btrim(p_category)))
   union all
   select e.direction, e.status, e.amount_cents from public.finance_entries e
   where e.pelada_id = p_pelada and e.entry_date between coalesce(p_from, '-infinity'::date) and coalesce(p_to, 'infinity'::date)
    and (p_direction is null or e.direction = p_direction)
    and (nullif(btrim(p_category), '') is null or e.category = btrim(p_category))) x;
 end if;
 return jsonb_build_object('items', v_items, 'next', v_next, 'total', v_total);
end $$;

-- V4.3 list (older app versions): same output and the same 1..1000 cap, without sorting the whole history.
create or replace function public.get_finance_ledger(p_pelada uuid, p_month date default null, p_direction text default null,
 p_category text default null, p_limit integer default 200) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_from date; v_to date;
begin
 perform private.require_finance(p_pelada, false);
 if p_month is not null then v_from := date_trunc('month', p_month)::date; v_to := (v_from + interval '1 month - 1 day')::date; end if;
 return private.finance_ledger(p_pelada, v_from, v_to, p_direction, p_category, null, null, null,
  private.page_limit(p_limit, 200, 1000));
end $$;

---------------------------------------------------------------------------------------------------
-- Dashboard, people, reports, audit
---------------------------------------------------------------------------------------------------

-- Same numbers as 043; the latest movements come from the limited cash book (no full sort).
create or replace function public.get_finance_overview(p_pelada uuid, p_month date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_today date; v_from date; v_to date; v_all jsonb; v_m jsonb; v_recv bigint; v_recv_overdue bigint; v_pexp bigint; v_pinc bigint;
 v_partial integer; v_overdue_n integer;
begin
 perform private.require_finance(p_pelada, false);
 v_today := private.pelada_today(p_pelada);
 v_from := date_trunc('month', coalesce(p_month, v_today))::date;
 v_to := (v_from + interval '1 month - 1 day')::date;
 v_all := private.finance_totals(p_pelada, '0001-01-01', '9999-12-31');
 v_m := private.finance_totals(p_pelada, v_from, v_to);
 select coalesce(sum(amount_due_cents - amount_paid_cents), 0),
  coalesce(sum(amount_due_cents - amount_paid_cents) filter (where due_date < v_today), 0),
  count(*) filter (where status = 'partial'), count(*) filter (where due_date < v_today)
 into v_recv, v_recv_overdue, v_partial, v_overdue_n
 from public.finance_charges where pelada_id=p_pelada and status in ('pending','partial');
 select coalesce(sum(amount_cents) filter (where direction='expense'), 0), coalesce(sum(amount_cents) filter (where direction='income'), 0)
 into v_pexp, v_pinc from public.finance_entries where pelada_id=p_pelada and status='pending';
 return jsonb_build_object('today', v_today, 'month', v_from,
  'balance_cents', (v_all->>'income_cents')::bigint - (v_all->>'expense_cents')::bigint,
  'month_income_cents', (v_m->>'income_cents')::bigint, 'month_expense_cents', (v_m->>'expense_cents')::bigint,
  'receivable_cents', v_recv + v_pinc, 'overdue_cents', v_recv_overdue, 'pending_expense_cents', v_pexp,
  'projected_balance_cents', (v_all->>'income_cents')::bigint - (v_all->>'expense_cents')::bigint + v_recv + v_pinc - v_pexp,
  'partial_count', v_partial, 'overdue_count', v_overdue_n,
  'monthly_active', (select count(*) from public.finance_members where pelada_id=p_pelada and status='active'),
  'monthly_late', (select count(distinct c.finance_member_id) from public.finance_charges c join public.finance_members f on f.id=c.finance_member_id
     where c.pelada_id=p_pelada and f.status='active' and c.status in ('pending','partial') and c.due_date < v_today),
  'single_count_month', (select count(*) from public.finance_charges where pelada_id=p_pelada and kind='single' and status<>'cancelled'
     and due_date between v_from and v_to),
  'month_charges_missing', (select count(*) from public.finance_members f where f.pelada_id=p_pelada and f.status='active'
     and f.starts_on <= v_to and not exists(select 1 from public.finance_charges c where c.finance_member_id=f.id and c.reference_month=v_from)),
  'latest', private.finance_ledger(p_pelada, null, null, null, null, null, null, null, 8));
end $$;

-- Same output as 043, with the open/overdue sums of the mensalistas aggregated once.
create or replace function public.get_finance_people(p_pelada uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_today date;
begin
 perform private.require_finance(p_pelada, false);
 v_today := private.pelada_today(p_pelada);
 return jsonb_build_object(
  'monthly', coalesce((
   with agg as (
    select c.finance_member_id, sum(c.amount_due_cents - c.amount_paid_cents) open_cents,
     sum(c.amount_due_cents - c.amount_paid_cents) filter (where c.due_date < v_today) overdue_cents
    from public.finance_charges c
    where c.pelada_id = p_pelada and c.finance_member_id is not null and c.status in ('pending','partial')
    group by c.finance_member_id)
   select jsonb_agg(jsonb_build_object('id', f.id, 'membership_id', f.membership_id, 'payer_id', f.payer_id,
     'person_name', coalesce(m.player_name, fp.display_name, '-'),
     'person_active', case when f.membership_id is not null then m.status = 'active' else fp.archived_at is null end,
     'amount_cents', f.amount_cents, 'due_day', f.due_day, 'starts_on', f.starts_on, 'ends_on', f.ends_on,
     'status', f.status, 'notes', f.notes, 'version', f.version,
     'overdue_cents', coalesce(agg.overdue_cents, 0), 'open_cents', coalesce(agg.open_cents, 0))
     order by f.status, coalesce(m.player_name, fp.display_name, '-'))
   from public.finance_members f
   left join public.pelada_memberships m on m.id = f.membership_id
   left join public.finance_payers fp on fp.id = f.payer_id
   left join agg on agg.finance_member_id = f.id
   where f.pelada_id = p_pelada), '[]'::jsonb),
  'payers', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.display_name, 'notes', p.notes) order by p.display_name)
    from public.finance_payers p where p.pelada_id=p_pelada and p.archived_at is null), '[]'::jsonb),
  'members', coalesce((select jsonb_agg(jsonb_build_object('membership_id', m.id, 'name', m.player_name) order by m.player_name)
    from public.pelada_memberships m where m.pelada_id=p_pelada and m.status='active'), '[]'::jsonb));
end $$;

-- Report of one month, every figure aggregated in SQL over the base tables (no list, no cap):
--  income/expense/result: the official totals (finance_totals, same as the dashboard);
--  by_category: settled income (payments not reversed, by charge kind, + settled income entries) and settled expenses;
--   the sum of each direction equals its total;
--  pending_*: income/expense entries still pending in the month (never in the result);
--  reversed_cents: payments of the month that were reversed (informative, never income);
--  by_person: due (charges due in the month, not cancelled), paid (payments received in the month, not reversed),
--   open in total; one pass over charges and one over payments.
create or replace function public.get_finance_report(p_pelada uuid, p_month date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_from date; v_to date; v_t jsonb; v_cat jsonb; v_person jsonb; v_pinc bigint; v_pexp bigint; v_rev bigint; v_open bigint;
 v_moves bigint;
begin
 perform private.require_finance(p_pelada, false);
 v_from := date_trunc('month', coalesce(p_month, private.pelada_today(p_pelada)))::date;
 v_to := (v_from + interval '1 month - 1 day')::date;
 v_t := private.finance_totals(p_pelada, v_from, v_to);

 select coalesce(jsonb_agg(jsonb_build_object('direction', direction, 'category', category, 'amount_cents', total, 'count', n)
   order by direction, total desc, category), '[]'::jsonb)
 into v_cat from (
  select direction, category, sum(amount) total, count(*) n from (
   select 'income'::text direction, (case c.kind when 'monthly' then 'Mensalidade' when 'single' then 'Avulso' else 'Contribuição extraordinária' end) category, p.amount_cents amount
   from public.finance_payments p join public.finance_charges c on c.id = p.charge_id
   where p.pelada_id = p_pelada and p.reversed_at is null and p.received_on between v_from and v_to
   union all
   select e.direction, e.category, e.amount_cents from public.finance_entries e
   where e.pelada_id = p_pelada and e.status = 'settled' and e.entry_date between v_from and v_to) x
  group by direction, category) q;

 select coalesce(sum(amount_cents) filter (where direction = 'income'), 0), coalesce(sum(amount_cents) filter (where direction = 'expense'), 0)
 into v_pinc, v_pexp from public.finance_entries where pelada_id = p_pelada and status = 'pending' and entry_date between v_from and v_to;
 select coalesce(sum(amount_cents), 0) into v_rev from public.finance_payments
 where pelada_id = p_pelada and reversed_at is not null and received_on between v_from and v_to;
 select coalesce(sum(amount_due_cents - amount_paid_cents), 0) into v_open from public.finance_charges
 where pelada_id = p_pelada and status in ('pending','partial') and due_date between v_from and v_to;
 select (select count(*) from public.finance_payments where pelada_id = p_pelada and received_on between v_from and v_to)
  + (select count(*) from public.finance_entries where pelada_id = p_pelada and entry_date between v_from and v_to)
 into v_moves;

 with rows as (
  select c.membership_id, c.payer_id,
   case when c.status <> 'cancelled' and c.due_date between v_from and v_to then c.amount_due_cents else 0 end due,
   0::bigint paid,
   case when c.status in ('pending','partial') then c.amount_due_cents - c.amount_paid_cents else 0 end open_total
  from public.finance_charges c where c.pelada_id = p_pelada
  union all
  select c.membership_id, c.payer_id, 0, p.amount_cents, 0
  from public.finance_payments p join public.finance_charges c on c.id = p.charge_id
  where p.pelada_id = p_pelada and p.reversed_at is null and p.received_on between v_from and v_to),
 per as (
  select membership_id, payer_id, sum(due) due, sum(paid) paid, sum(open_total) open_total
  from rows group by membership_id, payer_id)
 select coalesce(jsonb_agg(jsonb_build_object('membership_id', per.membership_id, 'payer_id', per.payer_id,
   'name', coalesce(m.player_name, fp.display_name, '-'), 'due_cents', per.due, 'paid_cents', per.paid,
   'open_total_cents', per.open_total) order by coalesce(m.player_name, fp.display_name, '-'), per.membership_id, per.payer_id), '[]'::jsonb)
 into v_person
 from per left join public.pelada_memberships m on m.id = per.membership_id
 left join public.finance_payers fp on fp.id = per.payer_id
 where per.due > 0 or per.paid > 0 or per.open_total > 0;

 return jsonb_build_object('month', v_from,
  'income_cents', (v_t->>'income_cents')::bigint, 'expense_cents', (v_t->>'expense_cents')::bigint,
  'result_cents', (v_t->>'income_cents')::bigint - (v_t->>'expense_cents')::bigint,
  'open_cents', v_open, 'pending_income_cents', v_pinc, 'pending_expense_cents', v_pexp, 'reversed_cents', v_rev,
  'movements_count', v_moves, 'by_category', v_cat, 'by_person', v_person);
end $$;

-- Audit trail page: p_before = smallest id already shown (null = newest).
create function public.get_finance_history_page(p_pelada uuid, p_before bigint default null, p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_lim integer := private.page_limit(p_limit, 50, 200); v_items jsonb; v_min bigint; v_n integer;
begin
 perform private.require_finance(p_pelada, false);
 select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'event_type', e.event_type, 'entity', e.entity, 'entity_id', e.entity_id,
   'before', e.before_data, 'after', e.after_data, 'created_at', e.created_at, 'author', pr.display_name) order by e.id desc), '[]'::jsonb),
  min(e.id), count(*)
 into v_items, v_min, v_n
 from (select * from public.finance_events where pelada_id = p_pelada and (p_before is null or id < p_before)
       order by id desc limit v_lim) e
 left join public.profiles pr on pr.id = e.actor_user_id;
 return jsonb_build_object('items', v_items, 'next', case when v_n = v_lim and exists(select 1 from public.finance_events
   where pelada_id = p_pelada and id < v_min) then v_min end);
end $$;

---------------------------------------------------------------------------------------------------
-- Grants
---------------------------------------------------------------------------------------------------

revoke all on function private.page_limit(integer,integer,integer),
 private.finance_charges_json(uuid,uuid[]), private.finance_charge_filter_ok(text,text),
 private.finance_ledger(uuid,date,date,text,text,date,timestamptz,uuid,integer) from public, anon, authenticated;

revoke all on function public.get_finance_charges_page(uuid,date,text,uuid,uuid,text,jsonb,integer),
 public.get_finance_ledger_page(uuid,date,date,text,text,jsonb,integer,boolean),
 public.get_finance_history_page(uuid,bigint,integer) from public, anon;
grant execute on function public.get_finance_charges_page(uuid,date,text,uuid,uuid,text,jsonb,integer),
 public.get_finance_ledger_page(uuid,date,date,text,text,jsonb,integer,boolean),
 public.get_finance_history_page(uuid,bigint,integer) to authenticated;
