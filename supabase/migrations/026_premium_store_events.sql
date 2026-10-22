-- Minuto 91 / 026: hardening of the Premium purchase link and of the store events
-- (audit 21/10/2026, items PR-3..PR-7; Doc 02 RN-090..095, Doc 04 sec. 28).
-- 1) start_premium_purchase: a buyer keeps at most ONE pending purchase (pending rows of
--    other peladas are closed), and cannot start a purchase while another pelada still has
--    his paid period running (active or cancelled-but-paid).
-- 2) apply_subscription_event finds the purchase in this order:
--    a) buyer + pelada sent by the app as the RevenueCat subscriber attribute "pelada_id"
--       (only counts if that buyer registered that pelada through start_premium_purchase);
--    b) INITIAL_PURCHASE: the buyer's pending purchase;
--    c) the store subscription id (original_transaction_id) saved at the first activation;
--    d) the buyer's latest open purchase.
--    Expired purchases are found again by a)/c), so a renewal or reactivation after an
--    EXPIRATION is no longer "unmatched".
-- 3) Out of order: each purchase keeps the store time of the last applied event
--    (event_timestamp_ms); older events are recorded as "stale" and change nothing.
-- 4) EXPIRATION and refunds (CANCELLATION with cancel_reason CUSTOMER_SUPPORT) end the
--    paid period at the store date; activations still never shorten it.
-- 5) New types: SUBSCRIPTION_EXTENDED and REFUND_REVERSED activate; BILLING_ISSUE is
--    recorded (the store grace period arrives as expiration_at); TRANSFER (restore on another
--    app account) moves the buyer only when the new account is the pelada's active admin.
-- 6) An "unmatched" event can be processed again when the store resends it (it is no
--    longer answered as "duplicate"). The same event id is serialized by an advisory lock.

alter table public.subscription_purchasers add column last_event_at timestamptz;
create index subscription_purchasers_by_store_ref on public.subscription_purchasers(store_account_ref)
 where store_account_ref is not null;
create index subscription_purchasers_by_buyer on public.subscription_purchasers(buyer_user_id, created_at);

create function private.try_uuid(p text) returns uuid
language plpgsql immutable set search_path = '' as $$
begin
 return p::uuid;
exception when invalid_text_representation then return null;
end $$;
revoke all on function private.try_uuid(text) from public,anon,authenticated;

create or replace function public.start_premium_purchase(p_pelada uuid) returns uuid
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
 if exists(select 1 from public.subscription_purchasers s
   left join public.pelada_entitlements e on e.pelada_id=s.pelada_id
   where s.buyer_user_id=auth.uid() and s.pelada_id<>p_pelada
    and (s.status='active' or (s.status='cancelled' and e.premium_until > now()))) then
  raise exception 'BUYER_ALREADY_SUBSCRIBED'; end if;
 -- One pending purchase per buyer: abandoned attempts in other peladas are closed.
 update public.subscription_purchasers set status='expired', ended_at=now()
 where buyer_user_id=auth.uid() and status='pending' and pelada_id<>p_pelada;
 select id into v_id from public.subscription_purchasers where pelada_id=p_pelada and status='pending';
 if found then
  update public.subscription_purchasers set buyer_user_id=auth.uid() where id=v_id;
 else
  insert into public.subscription_purchasers(pelada_id,buyer_user_id) values(p_pelada,auth.uid()) returning id into v_id;
 end if;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'premium_purchase_started',jsonb_build_object('purchaser_id',v_id));
 return v_id;
end $$;

create or replace function public.apply_subscription_event(p_event jsonb) returns text
language plpgsql security definer set search_path = '' as $$
declare
 v_event_id text := p_event->>'id'; v_type text := p_event->>'type';
 v_buyer uuid := private.try_uuid(p_event->>'app_user_id');
 v_pelada uuid := private.try_uuid(p_event->'subscriber_attributes'->'pelada_id'->>'value');
 v_tx text := nullif(p_event->>'original_transaction_id','');
 v_exp timestamptz := to_timestamp((p_event->>'expiration_at_ms')::numeric / 1000);
 v_at timestamptz := coalesce(to_timestamp((p_event->>'event_timestamp_ms')::numeric / 1000), now());
 v_prev text; v_p public.subscription_purchasers; v_new_buyer uuid; v_result text;
begin
 if v_event_id is null or v_type is null then raise exception 'INVALID_EVENT'; end if;
 perform pg_advisory_xact_lock(hashtext('m91_store_event:'||v_event_id));
 select result into v_prev from private.subscription_events where event_id=v_event_id;
 if found and v_prev <> 'unmatched' then return 'duplicate'; end if;

 if v_type = 'TRANSFER' then
  select s.* into v_p from public.subscription_purchasers s
  where s.status in ('active','cancelled') and s.buyer_user_id in (
   select private.try_uuid(x) from jsonb_array_elements_text(coalesce(p_event->'transferred_from','[]'::jsonb)) x)
  order by s.created_at desc limit 1;
 else
  if v_pelada is not null and v_buyer is not null then
   select * into v_p from public.subscription_purchasers
   where buyer_user_id=v_buyer and pelada_id=v_pelada order by created_at desc limit 1;
  end if;
  if v_p.id is null and v_type = 'INITIAL_PURCHASE' and v_buyer is not null then
   select * into v_p from public.subscription_purchasers
   where buyer_user_id=v_buyer and status='pending' order by created_at desc limit 1;
  end if;
  if v_p.id is null and v_tx is not null then
   select * into v_p from public.subscription_purchasers
   where store_account_ref=v_tx order by created_at desc limit 1;
  end if;
  if v_p.id is null and v_buyer is not null then
   select * into v_p from public.subscription_purchasers where buyer_user_id=v_buyer
    and status in ('pending','active','cancelled') order by (status='active') desc, created_at desc limit 1;
  end if;
 end if;

 if v_p.id is null then
  v_result := 'unmatched';
 else
  -- Same lock order as start_premium_purchase: pelada first, then the purchaser row.
  perform 1 from public.peladas where id=v_p.pelada_id for update;
  select * into v_p from public.subscription_purchasers where id=v_p.id for update;
  if v_p.last_event_at is not null and v_at < v_p.last_event_at then
   v_result := 'stale';
  elsif v_type in ('INITIAL_PURCHASE','RENEWAL','UNCANCELLATION','PRODUCT_CHANGE','SUBSCRIPTION_EXTENDED','REFUND_REVERSED') then
   begin
    update public.subscription_purchasers set status='expired', ended_at=now()
    where pelada_id=v_p.pelada_id and status='pending' and id<>v_p.id;
    update public.subscription_purchasers set status='active', started_at=coalesce(started_at,v_at),
     store_account_ref=coalesce(v_tx,store_account_ref), product_id=coalesce(p_event->>'product_id',product_id),
     ended_at=null, last_event_at=v_at where id=v_p.id;
    insert into public.pelada_entitlements(pelada_id,plan,status,premium_until,source)
    values(v_p.pelada_id,'premium','active',v_exp,'store')
    on conflict (pelada_id) do update set plan='premium', status='active', source='store',
     premium_until=greatest(public.pelada_entitlements.premium_until, excluded.premium_until);
    v_result := 'activated';
   exception when unique_violation then
    -- The buyer already has another active subscription (one per store account at launch).
    v_result := 'conflict';
   end;
  elsif v_type = 'CANCELLATION' then
   update public.subscription_purchasers set status='cancelled', last_event_at=v_at where id=v_p.id;
   if p_event->>'cancel_reason' = 'CUSTOMER_SUPPORT' then
    -- Refund: the paid period ends at the store date.
    update public.pelada_entitlements set status='cancelled',
     premium_until=least(premium_until, coalesce(v_exp, now())) where pelada_id=v_p.pelada_id;
    v_result := 'refunded';
   else
    -- Renewal turned off: the paid period stays.
    update public.pelada_entitlements set status='cancelled' where pelada_id=v_p.pelada_id;
    v_result := 'cancelled';
   end if;
  elsif v_type = 'EXPIRATION' then
   update public.subscription_purchasers set status='expired', ended_at=coalesce(v_exp, now()), last_event_at=v_at
   where id=v_p.id;
   update public.pelada_entitlements set status='expired', plan='free',
    premium_until=least(premium_until, coalesce(v_exp, now())) where pelada_id=v_p.pelada_id;
   v_result := 'expired';
  elsif v_type = 'BILLING_ISSUE' then
   update public.subscription_purchasers set last_event_at=v_at where id=v_p.id;
   v_result := 'billing_issue';
  elsif v_type = 'TRANSFER' then
   select private.try_uuid(x) into v_new_buyer
   from jsonb_array_elements_text(coalesce(p_event->'transferred_to','[]'::jsonb)) x
   where private.try_uuid(x) is not null limit 1;
   if v_new_buyer is not null and exists(select 1 from public.pelada_memberships m
     where m.pelada_id=v_p.pelada_id and m.user_id=v_new_buyer and m.status='active' and m.role='admin') then
    begin
     update public.subscription_purchasers set buyer_user_id=v_new_buyer, last_event_at=v_at where id=v_p.id;
     v_result := 'transferred';
    exception when unique_violation then
     v_result := 'conflict';
    end;
   else
    -- The pelada keeps the paid period; the buyer stays the original account.
    v_result := 'transfer_kept';
   end if;
  else
   v_result := 'ignored';
  end if;
  insert into private.audit_events(pelada_id,event_type,metadata)
  values(v_p.pelada_id,'subscription_event',jsonb_build_object('event_id',v_event_id,'type',v_type,'result',v_result));
 end if;

 insert into private.subscription_events(event_id,event_type,app_user_id,product_id,payload,result)
 values(v_event_id,v_type,p_event->>'app_user_id',p_event->>'product_id',p_event,v_result)
 on conflict (event_id) do update set payload=excluded.payload, result=excluded.result, received_at=now();
 return v_result;
end $$;

-- create or replace keeps the 019 grants; repeated here so this file is self-explanatory.
revoke all on function public.start_premium_purchase(uuid), public.apply_subscription_event(jsonb)
 from public,anon,authenticated;
grant execute on function public.start_premium_purchase(uuid) to authenticated;
grant execute on function public.apply_subscription_event(jsonb) to service_role;
