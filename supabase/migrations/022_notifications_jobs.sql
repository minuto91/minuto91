-- Minuto 91 / 022: notifications and scheduled tasks (Doc 02 RN-099/RN-100/RN-107,
-- Doc 03 sec. 13.3, Doc 04 sec. 33).
-- notification_events is an outbox: the server enqueues, a sender (Edge Function with
-- Expo push, after the development build) claims and marks them sent. Payloads never
-- carry vote data. dedupe_key makes every notification unique (retries never repeat).
-- Essential (no weekly limit): voting opened/closing soon, sheet corrected, voting
-- restarted, result published, match annulled, admin succession, subscription,
-- account transfer. Engagement (max 3 per user per rolling week, counting awards and
-- stickers): beyond the limit they are stored as 'suppressed'.
-- Producers: triggers on private.audit_events, public.awards and private.sticker_events,
-- so the earlier functions stay untouched.
-- run_scheduled_tasks() (pg_cron, every 5 minutes) closes expired votings, warns voters
-- 1 hour before the deadline, closes ended months, purges accounts after the 30-day
-- standby (021) and runs end-of-season clean-up (RN-107: retired records leave the
-- individual rankings; anonymous ballots are deleted, only aggregates remain).
-- Each task runs isolated; failures are logged in private.background_jobs.

create table public.push_devices (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 expo_push_token text not null unique check (length(expo_push_token) between 10 and 300),
 platform text not null check (platform in ('ios','android')),
 created_at timestamptz not null default now(),
 last_seen_at timestamptz not null default now()
);
create index push_devices_by_user on public.push_devices(user_id);

create table public.notification_events (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 pelada_id uuid references public.peladas(id),
 event_type text not null,
 category text not null check (category in ('essential','engagement')),
 dedupe_key text not null unique,
 payload jsonb not null default '{}'::jsonb,
 scheduled_at timestamptz not null default now(),
 sent_at timestamptz,
 status text not null default 'pending' check (status in ('pending','sent','suppressed','failed')),
 created_at timestamptz not null default now()
);
create index notifications_pending on public.notification_events(scheduled_at) where status='pending';
create index notifications_by_user on public.notification_events(user_id, created_at desc);

create table private.background_jobs (
 id uuid primary key default gen_random_uuid(),
 job_type text not null,
 entity_id uuid,
 status text not null check (status in ('completed','failed')),
 attempt_count integer not null default 1,
 scheduled_at timestamptz not null default now(),
 started_at timestamptz,
 completed_at timestamptz,
 last_error text
);
create index background_jobs_failed on private.background_jobs(job_type, entity_id) where status='failed';

create table private.season_cleanups (
 season_id uuid primary key references public.seasons(id),
 cleaned_at timestamptz not null default now()
);
revoke all on private.background_jobs, private.season_cleanups from public,anon,authenticated;

alter table public.push_devices enable row level security;
alter table public.notification_events enable row level security;
revoke all on public.push_devices, public.notification_events from anon,authenticated;
grant select on public.push_devices, public.notification_events to authenticated;
create policy devices_read_own on public.push_devices for select to authenticated
 using (user_id = (select auth.uid()));
create policy notifications_read_own on public.notification_events for select to authenticated
 using (user_id = (select auth.uid()));
-- Writes only through the functions below.

create function public.register_push_device(p_token text, p_platform text) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_token is null or length(p_token) not between 10 and 300 or p_platform not in ('ios','android') then
  raise exception 'INVALID_DEVICE'; end if;
 insert into public.push_devices(user_id,expo_push_token,platform) values(auth.uid(),p_token,p_platform)
 on conflict (expo_push_token) do update set user_id=auth.uid(), platform=excluded.platform, last_seen_at=now();
end $$;

create function public.unregister_push_device(p_token text) returns void
language sql security definer set search_path = '' as $$
 delete from public.push_devices where expo_push_token=p_token and user_id=(select auth.uid());
$$;

-- Enqueues one notification (idempotent by dedupe key). Applies the weekly engagement limit.
create function private.notify(p_user uuid, p_pelada uuid, p_type text, p_category text, p_dedupe text,
 p_payload jsonb default '{}'::jsonb, p_at timestamptz default now()) returns void
language plpgsql security definer set search_path = '' as $$
declare c_weekly_engagement constant integer := 3; v_status text := 'pending';
begin
 if p_user is null then return; end if;
 if p_category='engagement' and (select count(*) from public.notification_events where user_id=p_user
   and category='engagement' and status in ('pending','sent') and created_at > now() - interval '7 days')
   >= c_weekly_engagement then
  v_status := 'suppressed';
 end if;
 insert into public.notification_events(user_id,pelada_id,event_type,category,dedupe_key,payload,scheduled_at,status)
 values(p_user,p_pelada,p_type,p_category,p_dedupe,p_payload,p_at,v_status)
 on conflict (dedupe_key) do nothing;
end $$;

-- Accounts of the active members of a pelada / of the eligible voters of a session.
create function private.pelada_users(p_pelada uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
 select user_id from public.pelada_memberships where pelada_id=p_pelada and status='active' and user_id is not null;
$$;
create function private.session_users(p_session uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
 select m.user_id from public.voting_eligible_members e join public.pelada_memberships m on m.id=e.membership_id
 where e.session_id=p_session and m.user_id is not null and m.status='active';
$$;

-- Audit events -> essential notifications.
create function private.notify_from_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_match uuid := (new.metadata->>'match_id')::uuid; v_session uuid; u uuid; v_payload jsonb;
begin
 v_payload := jsonb_build_object('pelada_id',new.pelada_id,'match_id',v_match);
 if new.event_type in ('match_published','match_sheet_corrected','voting_restarted') then
  v_session := coalesce((new.metadata->>'new_session_id')::uuid, (new.metadata->>'session_id')::uuid,
   (select id from public.voting_sessions where match_id=v_match and status='open'));
  if v_session is not null then
   for u in select * from private.session_users(v_session) loop
    perform private.notify(u,new.pelada_id,
     case new.event_type when 'match_published' then 'voting_opened' when 'voting_restarted' then 'voting_restarted'
      else 'sheet_corrected' end,'essential',new.event_type||':'||new.id||':'||u,v_payload);
   end loop;
  end if;
 elsif new.event_type in ('match_finalized','match_annulled') then
  for u in select * from private.pelada_users(new.pelada_id) loop
   perform private.notify(u,new.pelada_id,
    case new.event_type when 'match_finalized' then 'result_published' else 'match_annulled' end,
    'essential',new.event_type||':'||v_match||':'||u,v_payload);
  end loop;
 elsif new.event_type in ('admin_succeeded','pelada_without_eligible_admin') then
  for u in select * from private.pelada_users(new.pelada_id) loop
   perform private.notify(u,new.pelada_id,'admin_succession','essential',new.event_type||':'||new.id||':'||u,
    jsonb_build_object('pelada_id',new.pelada_id));
  end loop;
 elsif new.event_type='subscription_event' then
  perform private.notify(m.user_id,new.pelada_id,'subscription_changed','essential','subscription:'||new.id,
   jsonb_build_object('pelada_id',new.pelada_id,'result',new.metadata->>'result'))
  from public.pelada_memberships m where m.pelada_id=new.pelada_id and m.role='admin' and m.status='active';
 end if;
 return new;
end $$;
create trigger audit_notifications after insert on private.audit_events
for each row execute function private.notify_from_audit();

-- Awards -> engagement notification to the winner.
create function private.notify_from_award() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.status='active' then
  perform private.notify(m.user_id,new.pelada_id,'award_'||new.award_type,'engagement','award:'||new.id,
   jsonb_build_object('pelada_id',new.pelada_id,'match_id',new.match_id,'award_type',new.award_type,
    'period_month',new.period_month))
  from public.pelada_memberships m where m.id=new.membership_id and m.status='active';
 end if;
 return new;
end $$;
create trigger award_notifications after insert on public.awards
for each row execute function private.notify_from_award();

-- Sticker unlocked -> engagement notification.
create function private.notify_from_sticker() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.event_type in ('unlocked','reactivated') then
  perform private.notify(m.user_id,new.pelada_id,'sticker_unlocked','engagement','sticker:'||new.id,
   jsonb_build_object('pelada_id',new.pelada_id,'sticker_definition_id',new.sticker_definition_id))
  from public.pelada_memberships m where m.id=new.membership_id and m.status='active';
 end if;
 return new;
end $$;
create trigger sticker_notifications after insert on private.sticker_events
for each row execute function private.notify_from_sticker();

-- Sender (Edge Function, service role): takes pending notifications with the devices.
create function public.claim_notifications(p_limit integer default 100) returns table(id uuid, user_id uuid,
 event_type text, payload jsonb, tokens text[])
language sql security definer set search_path = '' as $$
 with n as (
  update public.notification_events e set status='sent', sent_at=now()
  where e.id in (select x.id from public.notification_events x where x.status='pending' and x.scheduled_at <= now()
   order by x.scheduled_at limit p_limit for update skip locked)
  returning e.id, e.user_id, e.event_type, e.payload)
 select n.id, n.user_id, n.event_type, n.payload,
  coalesce((select array_agg(d.expo_push_token) from public.push_devices d where d.user_id=n.user_id),'{}')
 from n;
$$;

-- RN-107: after the season, retired records leave the individual rankings and cards,
-- and the anonymous ballots of its matches are deleted (aggregates stay).
create function private.cleanup_season(p_season uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 delete from public.player_season_stats s using public.pelada_memberships m
 where s.season_id=p_season and m.id=s.membership_id and m.status='retired';
 delete from public.player_cards c using public.pelada_memberships m
 where c.season_id=p_season and m.id=c.membership_id and m.status='retired';
 delete from private.secret_ballots b using public.voting_sessions v, public.matches x
 where b.session_id=v.id and v.match_id=x.id and x.season_id=p_season and v.status in ('finalized','cancelled');
 insert into private.season_cleanups(season_id) values(p_season) on conflict do nothing;
end $$;

-- Runs one task, isolating failures in background_jobs.
create function private.run_job(p_type text, p_entity uuid, p_sql text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_start timestamptz := clock_timestamp();
begin
 begin
  execute p_sql using p_entity;
 exception when others then
  insert into private.background_jobs(job_type,entity_id,status,attempt_count,started_at,completed_at,last_error)
  values(p_type,p_entity,'failed',1+(select count(*) from private.background_jobs where job_type=p_type
   and entity_id is not distinct from p_entity and status='failed'),v_start,clock_timestamp(),sqlerrm);
 end;
end $$;

create function private.run_scheduled_tasks() returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
 -- 1. Votings past their deadline.
 for r in select id from public.voting_sessions where status='open' and closes_at <= now() loop
  perform private.run_job('finalize_voting', r.id, 'select private.finalize_session($1)');
 end loop;
 -- 2. Deadline in less than 1 hour: remind who has not voted (once per voter).
 perform private.notify(m.user_id, v.pelada_id, 'voting_closing_soon', 'essential',
  'closing:'||v.id||':'||m.user_id, jsonb_build_object('pelada_id',v.pelada_id,'match_id',v.match_id))
 from public.voting_sessions v join public.voting_eligible_members e on e.session_id=v.id
 join public.pelada_memberships m on m.id=e.membership_id and m.status='active' and m.user_id is not null
 where v.status='open' and v.closes_at > now() and v.closes_at <= now() + interval '1 hour'
  and not exists(select 1 from public.vote_receipts r2 where r2.session_id=v.id and r2.membership_id=e.membership_id);
 -- 3. Ended months not closed yet.
 for r in select distinct m.pelada_id from public.matches m where m.status='finalized'
   and not exists(select 1 from public.monthly_closures c where c.pelada_id=m.pelada_id
    and c.period_month=date_trunc('month', private.pelada_local_date(m.pelada_id, m.played_at))::date) loop
  perform private.run_job('close_months', r.pelada_id, 'select private.close_pending_months($1, null)');
 end loop;
 -- 4. Accounts past the 30-day standby.
 for r in select id from private.account_deletion_requests where status='pending' and purge_after <= now() loop
  perform private.run_job('purge_account', r.id, 'select private.purge_account($1)');
 end loop;
 -- 5. Seasons that ended (pelada timezone) and were not cleaned yet.
 for r in select s.id from public.seasons s where s.ends_on < private.pelada_today(s.pelada_id)
   and not exists(select 1 from private.season_cleanups c where c.season_id=s.id) loop
  perform private.run_job('cleanup_season', r.id, 'select private.cleanup_season($1)');
 end loop;
 delete from private.background_jobs where completed_at < now() - interval '90 days';
end $$;

revoke all on function private.notify(uuid,uuid,text,text,text,jsonb,timestamptz), private.pelada_users(uuid),
 private.session_users(uuid), private.notify_from_audit(), private.notify_from_award(), private.notify_from_sticker(),
 private.cleanup_season(uuid), private.run_job(text,uuid,text), private.run_scheduled_tasks()
 from public,anon,authenticated;
revoke all on function public.register_push_device(text,text), public.unregister_push_device(text),
 public.claim_notifications(integer) from public,anon,authenticated;
grant execute on function public.register_push_device(text,text), public.unregister_push_device(text) to authenticated;
grant execute on function public.claim_notifications(integer) to service_role;

-- Every 5 minutes (needs the pg_cron extension: Database > Extensions > pg_cron).
do $cron$
begin
 if exists(select 1 from pg_extension where extname='pg_cron') then
  execute $q$select cron.schedule('minuto91-tasks', '*/5 * * * *', 'select private.run_scheduled_tasks()')$q$;
 else
  raise notice 'pg_cron not enabled: enable it and run cron.schedule for private.run_scheduled_tasks()';
 end if;
end $cron$;
