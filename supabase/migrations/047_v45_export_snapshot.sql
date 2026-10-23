-- Minuto 91 / 047: V4.5 — exportação financeira num único instantâneo e permissão financeira que não "volta sozinha".
--
-- Problems confirmed in the V4.4 code (audit V4.5):
--  E1 (P1) The CSV export read the month with get_finance_ledger_page in pages of 500, one HTTP request (one
--     transaction, one snapshot) per page, and only compared the row count with the count of the first page.
--     Writes committed between two pages could make the file inconsistent without changing the count:
--      - a reversal (estorno) after its page was read keeps the row as "Efetivado" in the file;
--      - an entry edited from one date to another moves across the cursor: it appears twice or never;
--      - a backdated payment lands behind the cursor and the count no longer matches (export fails).
--     Reproduced on PostgreSQL 17 with writes between pages (supabase/local_db/concurrency.mjs, V4.5 section).
--  S1 (P2) finance_access (043) was never removed when the assistant stopped being an assistant (demoted, left,
--     suspended, removed, retired). has_finance_access requires role 'assistant', so nothing leaked at that moment,
--     but the old grant came back by itself when the same membership became assistant again (a person who leaves
--     and rejoins keeps the same membership row): the admin never re-authorized it.
--
-- What changes:
--  - public.get_finance_export(...): the whole period in ONE call. The function is STABLE, so every query in it
--    (rows and totals) uses the snapshot of the calling statement: a write either is entirely in the file or
--    entirely out of it. Returns the rows (same shape as the cash book), the totals computed in that same snapshot
--    (the app checks rows x totals before writing the file) and as_of (the moment of the snapshot).
--    Hard cap of 20,000 movements per export (FINANCE_EXPORT_TOO_LARGE: choose a shorter period); the
--    measured worst month (10,000 movements) is half of it.
--  - get_finance_ledger_page stays (screen lists, older apps). The V4.5 app no longer exports through it.
--  - Trigger: when a membership stops being an active assistant, its finance permission is removed and the
--    removal is written to the audit trail (actor = who made the change, or null when done by the system).
--    One-time cleanup of grants that are already stale. The rule of has_finance_access is unchanged.
-- Same access rules as 043/044 (private.require_finance: finance permission + Pelada Premium).

---------------------------------------------------------------------------------------------------
-- E1: export in one snapshot
---------------------------------------------------------------------------------------------------

create function public.get_finance_export(p_pelada uuid, p_from date, p_to date, p_direction text default null,
 p_category text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_cap constant integer := 20000; v_cat text := nullif(btrim(p_category), ''); v_items jsonb; v_total jsonb;
begin
 perform private.require_finance(p_pelada, false);
 if p_from is null or p_to is null or p_from > p_to then raise exception 'FINANCE_INVALID_DATE'; end if;
 if p_to - p_from > 366 then raise exception 'FINANCE_INVALID_DATE'; end if;
 if p_direction is not null and p_direction not in ('income','expense') then raise exception 'FINANCE_INVALID_FILTER'; end if;

 v_items := private.finance_ledger(p_pelada, p_from, p_to, p_direction, v_cat, null, null, null, v_cap + 1);
 if jsonb_array_length(v_items) > v_cap then raise exception 'FINANCE_EXPORT_TOO_LARGE'; end if;

 -- Totals from the base tables, in the same snapshot as the rows above.
 select jsonb_build_object('count', count(*),
   'settled_income_cents', coalesce(sum(amount) filter (where dir = 'income' and st = 'settled'), 0),
   'settled_expense_cents', coalesce(sum(amount) filter (where dir = 'expense' and st = 'settled'), 0),
   'pending_income_cents', coalesce(sum(amount) filter (where dir = 'income' and st = 'pending'), 0),
   'pending_expense_cents', coalesce(sum(amount) filter (where dir = 'expense' and st = 'pending'), 0),
   'reversed_cents', coalesce(sum(amount) filter (where st = 'reversed'), 0),
   'cancelled_cents', coalesce(sum(amount) filter (where st = 'cancelled'), 0))
 into v_total from (
  select 'income' dir, case when p.reversed_at is null then 'settled' else 'reversed' end st, p.amount_cents amount
  from public.finance_payments p
  where p.pelada_id = p_pelada and p.received_on between p_from and p_to
   and (p_direction is null or p_direction = 'income')
   and (v_cat is null or exists(select 1 from public.finance_charges c where c.id = p.charge_id
        and (case c.kind when 'monthly' then 'Mensalidade' when 'single' then 'Avulso' else 'Contribuição extraordinária' end) = v_cat))
  union all
  select e.direction, e.status, e.amount_cents from public.finance_entries e
  where e.pelada_id = p_pelada and e.entry_date between p_from and p_to
   and (p_direction is null or e.direction = p_direction) and (v_cat is null or e.category = v_cat)) x;

 return jsonb_build_object('as_of', now(), 'from', p_from, 'to', p_to, 'items', v_items, 'total', v_total);
end $$;

revoke all on function public.get_finance_export(uuid,date,date,text,text) from public, anon;
grant execute on function public.get_finance_export(uuid,date,date,text,text) to authenticated;

---------------------------------------------------------------------------------------------------
-- S1: finance permission ends with the assistant role
---------------------------------------------------------------------------------------------------

create function private.finance_access_follow_role() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := auth.uid();
begin
 if new.role = 'assistant' and new.status = 'active' then return null; end if;
 if v_actor is not null and not exists(select 1 from public.profiles where id = v_actor) then v_actor := null; end if;
 with gone as (delete from public.finance_access a where a.membership_id = new.id returning a.pelada_id)
 insert into public.finance_events(pelada_id, actor_user_id, event_type, entity, entity_id, before_data, after_data)
 select g.pelada_id, v_actor, 'access_revoked', 'access', new.id, null,
  jsonb_build_object('reason', 'role_changed', 'role', new.role, 'status', new.status)
 from gone g;
 return null;
end $$;
revoke all on function private.finance_access_follow_role() from public, anon, authenticated;

create trigger finance_access_follow_role after update of role, status on public.pelada_memberships
 for each row when (old.role is distinct from new.role or old.status is distinct from new.status)
 execute function private.finance_access_follow_role();

-- Grants that are already stale (assistant demoted or gone before this migration).
with gone as (
 delete from public.finance_access a using public.pelada_memberships m
 where m.id = a.membership_id and not (m.role = 'assistant' and m.status = 'active')
 returning a.pelada_id, a.membership_id, m.role, m.status)
insert into public.finance_events(pelada_id, actor_user_id, event_type, entity, entity_id, before_data, after_data)
select g.pelada_id, null, 'access_revoked', 'access', g.membership_id, null,
 jsonb_build_object('reason', 'role_changed', 'role', g.role, 'status', g.status, 'migration', '047')
from gone g;
