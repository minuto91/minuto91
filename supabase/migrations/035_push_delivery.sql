-- Minuto 91 / 035: push delivery (V4.1). Completes the outbox of 022 for the Edge Function push-sender.
-- Problem fixed: claim_notifications (022) marked rows as 'sent' BEFORE anything was sent; if the sender
-- crashed or Expo refused the request, the notification was lost and reported as sent.
-- New flow (service role only):
--  1. claim_notifications(limit): takes due 'pending' rows (and 'sending' rows whose 5-minute lease
--     expired, i.e. a sender crashed) with FOR UPDATE SKIP LOCKED, so two senders never take the same row.
--     Rows that should no longer go out become 'skipped' with the reason in last_error:
--       NO_ACCESS     the user is no longer an active member of the pelada (checked at send time);
--       OPTED_OUT     the user turned that category off (notification_preferences);
--       VOTING_CLOSED a voting notice whose voting is no longer open;
--       STALE         created more than 24 hours ago;
--       NO_DEVICE     no registered device (web, Expo Go, permission denied);
--       POLICY        Bola Murcha (shown only inside the app, V2).
--     After 5 attempts a row becomes 'failed' (MAX_ATTEMPTS). The rest become 'sending' (claimed_at,
--     attempt_count + 1) and are returned with the user's tokens.
--  2. complete_notifications(results): per row 'accepted' -> 'sent' (Expo ACCEPTED the message; this is
--     NOT proof it reached the phone), 'retry' -> back to 'pending' with backoff (2^attempt minutes,
--     'failed' after 5 attempts), 'failed' -> 'failed'. Tokens Expo reports as DeviceNotRegistered are
--     deleted. Only rows still 'sending' are completed (a late or duplicated answer changes nothing).
--  3. claim_push_receipts / record_push_receipts: 15 minutes after sending, the sender asks Expo for the
--     receipts (delivery to Apple/Google). Errors go to delivery_error; dead tokens are deleted.
-- Preferences: two switches per user (essential = votings, results, annulments, administration;
-- engagement = awards, stickers, season review). account_transferred is always sent (account security).
-- New producers (essential, to the affected member only): assistant_changed and successor_designated.
-- New engagement producer: season ended (season_cleanups row) -> season review available.
-- Payloads keep carrying only ids (never votes or ratings); the sender writes the texts.

alter table public.notification_events drop constraint notification_events_status_check;
alter table public.notification_events add constraint notification_events_status_check
 check (status in ('pending','sending','sent','suppressed','failed','skipped'));
alter table public.notification_events
 add column attempt_count integer not null default 0,
 add column claimed_at timestamptz,
 add column last_error text,
 add column push_tickets jsonb,
 add column receipts_checked_at timestamptz,
 add column delivery_error text;
create index notifications_sending on public.notification_events(claimed_at) where status='sending';
create index notifications_receipts on public.notification_events(sent_at)
 where status='sent' and push_tickets is not null and receipts_checked_at is null;

create table public.notification_preferences (
 user_id uuid primary key references auth.users(id) on delete cascade,
 essential boolean not null default true,
 engagement boolean not null default true,
 updated_at timestamptz not null default now()
);
alter table public.notification_preferences enable row level security;
revoke all on public.notification_preferences from anon, authenticated;
grant select on public.notification_preferences to authenticated;
create policy notification_preferences_read_own on public.notification_preferences for select to authenticated
 using (user_id = (select auth.uid()));

create function public.set_notification_preferences(p_essential boolean, p_engagement boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_essential is null or p_engagement is null then raise exception 'INVALID_PREFERENCES'; end if;
 insert into public.notification_preferences(user_id, essential, engagement)
 values(auth.uid(), p_essential, p_engagement)
 on conflict (user_id) do update set essential=excluded.essential, engagement=excluded.engagement, updated_at=now();
end $$;

-- Why a notification should not go out now (null = send).
create function private.push_skip_reason(p_id uuid) returns text
language sql stable security definer set search_path = '' as $$
 select case
  when e.attempt_count >= 5 then 'MAX_ATTEMPTS'
  when e.created_at < now() - interval '24 hours' then 'STALE'
  -- Bola Murcha fica só na tela (V2: não é conquista); não vira aviso no celular.
  when e.event_type = 'award_bola_murcha' then 'POLICY'
  when e.pelada_id is not null and not exists(select 1 from public.pelada_memberships m
    where m.pelada_id=e.pelada_id and m.user_id=e.user_id and m.status='active') then 'NO_ACCESS'
  when e.event_type <> 'account_transferred' and exists(select 1 from public.notification_preferences p
    where p.user_id=e.user_id and ((e.category='essential' and not p.essential) or (e.category='engagement' and not p.engagement)))
   then 'OPTED_OUT'
  when e.event_type in ('voting_opened','voting_closing_soon','sheet_corrected','voting_restarted')
   and not exists(select 1 from public.voting_sessions v where v.match_id=private.try_uuid(e.payload->>'match_id')
    and v.status='open') then 'VOTING_CLOSED'
  when not exists(select 1 from public.push_devices d where d.user_id=e.user_id) then 'NO_DEVICE'
 end
 from public.notification_events e where e.id=p_id;
$$;

drop function public.claim_notifications(integer);
create function public.claim_notifications(p_limit integer default 100) returns table(id uuid, user_id uuid,
 pelada_id uuid, event_type text, payload jsonb, tokens text[], attempt integer)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
begin
 return query
 with cand as (
  select e.id from public.notification_events e
  where (e.status='pending' and e.scheduled_at <= now())
   or (e.status='sending' and e.claimed_at < now() - interval '5 minutes')
  order by e.scheduled_at
  limit greatest(1, least(coalesce(p_limit,100), 500))
  for update skip locked),
 ev as (select c.id, private.push_skip_reason(c.id) reason from cand c),
 upd as (
  update public.notification_events n set
   status = case when ev.reason is null then 'sending' when ev.reason='MAX_ATTEMPTS' then 'failed' else 'skipped' end,
   claimed_at = case when ev.reason is null then now() else n.claimed_at end,
   attempt_count = n.attempt_count + case when ev.reason is null then 1 else 0 end,
   last_error = ev.reason
  from ev where n.id=ev.id
  returning n.id, n.user_id, n.pelada_id, n.event_type, n.payload, n.attempt_count, n.status)
 select u.id, u.user_id, u.pelada_id, u.event_type, u.payload,
  coalesce((select array_agg(d.expo_push_token order by d.last_seen_at desc) from public.push_devices d
   where d.user_id=u.user_id), '{}'), u.attempt_count
 from upd u where u.status='sending';
end $$;

-- p_results: [{"id": uuid, "outcome": "accepted"|"retry"|"failed", "error": text,
--              "tickets": [{"token": .., "ticket_id": ..}], "invalid_tokens": [text]}]
create function public.complete_notifications(p_results jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; v_n integer := 0; v_rows integer;
begin
 if p_results is null or jsonb_typeof(p_results) <> 'array' then raise exception 'INVALID_RESULTS'; end if;
 for r in select * from jsonb_to_recordset(p_results) as x(id uuid, outcome text, error text, tickets jsonb,
   invalid_tokens text[]) loop
  if r.outcome not in ('accepted','retry','failed') then raise exception 'INVALID_OUTCOME'; end if;
  if r.invalid_tokens is not null then
   delete from public.push_devices d using public.notification_events e
   where e.id=r.id and d.user_id=e.user_id and d.expo_push_token = any(r.invalid_tokens);
  end if;
  update public.notification_events e set
   status = case r.outcome when 'accepted' then 'sent'
    when 'retry' then case when e.attempt_count >= 5 then 'failed' else 'pending' end else 'failed' end,
   sent_at = case when r.outcome='accepted' then now() else e.sent_at end,
   scheduled_at = case when r.outcome='retry' then now() + make_interval(mins => power(2, least(e.attempt_count, 6))::int)
    else e.scheduled_at end,
   push_tickets = case when r.outcome='accepted' then r.tickets else e.push_tickets end,
   last_error = case when r.outcome='accepted' then null else left(r.error, 500) end,
   claimed_at = null
  where e.id=r.id and e.status='sending';
  get diagnostics v_rows = row_count;
  v_n := v_n + v_rows;
 end loop;
 return v_n;
end $$;

create function public.claim_push_receipts(p_limit integer default 300) returns table(id uuid, tickets jsonb,
 sent_at timestamptz)
language sql stable security definer set search_path = '' as $$
 select e.id, e.push_tickets, e.sent_at from public.notification_events e
 where e.status='sent' and e.push_tickets is not null and e.receipts_checked_at is null
  and e.sent_at < now() - interval '15 minutes'
 order by e.sent_at limit greatest(1, least(coalesce(p_limit,300), 1000));
$$;

-- p_results: [{"id": uuid, "error": text|null, "invalid_tokens": [text]}]
create function public.record_push_receipts(p_results jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; v_n integer := 0; v_rows integer;
begin
 if p_results is null or jsonb_typeof(p_results) <> 'array' then raise exception 'INVALID_RESULTS'; end if;
 for r in select * from jsonb_to_recordset(p_results) as x(id uuid, error text, invalid_tokens text[]) loop
  if r.invalid_tokens is not null then
   delete from public.push_devices d using public.notification_events e
   where e.id=r.id and d.user_id=e.user_id and d.expo_push_token = any(r.invalid_tokens);
  end if;
  update public.notification_events set receipts_checked_at=now(), delivery_error=left(r.error, 500)
  where id=r.id and receipts_checked_at is null;
  get diagnostics v_rows = row_count;
  v_n := v_n + v_rows;
 end loop;
 return v_n;
end $$;

-- Administration changes that concern one member (the 022 trigger stays as it is).
create function private.notify_member_from_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_user uuid;
begin
 if new.event_type not in ('assistant_changed','successor_designated') or new.subject_membership_id is null then
  return new; end if;
 select user_id into v_user from public.pelada_memberships where id=new.subject_membership_id and status='active';
 if v_user is null or v_user = new.actor_user_id then return new; end if;
 perform private.notify(v_user, new.pelada_id,
  case new.event_type when 'assistant_changed' then 'role_changed' else 'successor_designated' end,
  'essential', new.event_type||':'||new.id,
  jsonb_build_object('pelada_id', new.pelada_id, 'is_assistant', (new.metadata->>'is_assistant')::boolean));
 return new;
end $$;
create trigger audit_member_notifications after insert on private.audit_events
for each row execute function private.notify_member_from_audit();

-- Season ended (022 cleans it up once): the season review is complete.
create function private.notify_season_review() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; u uuid;
begin
 select pelada_id into v_pelada from public.seasons where id=new.season_id;
 if v_pelada is null then return new; end if;
 for u in select * from private.pelada_users(v_pelada) loop
  perform private.notify(u, v_pelada, 'season_review', 'engagement', 'season_review:'||new.season_id||':'||u,
   jsonb_build_object('pelada_id', v_pelada, 'season_id', new.season_id));
 end loop;
 return new;
end $$;
create trigger season_review_notifications after insert on private.season_cleanups
for each row execute function private.notify_season_review();

revoke all on function private.push_skip_reason(uuid), private.notify_member_from_audit(),
 private.notify_season_review() from public, anon, authenticated;
revoke all on function public.claim_notifications(integer), public.complete_notifications(jsonb),
 public.claim_push_receipts(integer), public.record_push_receipts(jsonb) from public, anon, authenticated;
grant execute on function public.claim_notifications(integer), public.complete_notifications(jsonb),
 public.claim_push_receipts(integer), public.record_push_receipts(jsonb) to service_role;
revoke all on function public.set_notification_preferences(boolean, boolean) from public, anon;
grant execute on function public.set_notification_preferences(boolean, boolean) to authenticated;
