-- Minuto 91 / 048: V4.6 — ordem estável dos pagamentos dentro de uma cobrança.
--
-- Problem confirmed in the V4.6 audit (Phase A):
--  P1-A (P3) private.finance_charges_json (044) ordered the payments of a charge by (received_on, created_at) only.
--     Payments registered in the same transaction share created_at (now()), so two reads of the same charge could
--     return its payments in different orders depending on the plan (one id vs. a whole page of ids). Seen as an
--     intermittent failure of tests_editor/037 ("mesmo formato": get_finance_charges vs. get_finance_charges_page),
--     38/39 in the full local suite on 23/10/2026. Effect in the app: the payment list of a charge could swap rows
--     with the same date between a reload and the update returned after a write. No amounts or totals were affected.
--
-- What changes: the id is the last tiebreaker (same rule as the cash book in 044). Same output shape, same access
-- rules; charge_json (044) goes through this function, so it is fixed too.

create or replace function private.finance_charges_json(p_pelada uuid, p_ids uuid[]) returns jsonb
language sql stable security definer set search_path = '' as $$
 with t as (select private.pelada_today(p_pelada) today),
 ids as (select u.id, u.ord from unnest(p_ids) with ordinality u(id, ord)),
 pay as (
  select p.charge_id, jsonb_agg(jsonb_build_object('id', p.id, 'amount_cents', p.amount_cents, 'received_on', p.received_on,
    'method', p.method, 'notes', p.notes, 'created_at', p.created_at, 'reversed_at', p.reversed_at,
    'reverse_reason', p.reverse_reason, 'created_by_name', pr.display_name) order by p.received_on, p.created_at, p.id) items
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
