-- Minuto 91 / 036: V4.2 critical fixes (independent audit of V3, items A01-A05, A10) and the lock
-- order between sheet correction and finalization (V4.2 sec. 8.1).
--
-- Lock order (every path that touches a voting): pelada row -> match row -> voting session row.
--  correct_match_sheet (009), publish_match (010) and annul_match (020) already lock pelada -> match;
--  confirm_match_sheet, the ballot functions (lock_voter) and finalize_session now do the same, so the
--  last ballot, the scheduler and a correction can never wait on each other in opposite order.
--
-- A01 Ballots of an old sheet version never count:
--  - a correction that keeps the same voters now invalidates every submitted ballot of the session
--    (it goes back to draft, content kept, so the voter only re-confirms and sends again) and deletes
--    the receipts, so "Falta o seu voto" comes back for everyone and nobody's old vote is counted;
--  - finalization counts and computes only ballots submitted for the session's current sheet version
--    (anything else is dropped before the computation, as a second guard);
--  - a correction after the deadline is refused (VOTING_EXPIRED): an expired voting is closed as it is.
--  The audit keeps the sheet versions (match_versions) and the number of invalidated ballots; ballot
--  content stays anonymous.
-- A10 Re-sending the last ballot (same idempotency key) after the voting closed answers "repeated"
--  instead of VOTING_NOT_OPEN.
-- A02 Account deletion anonymizes EVERY membership of the account (also those it had left and
--  suspended ones), and the purge does it again; recovery restores the names it saved.
-- A03 Store events: the original transaction (store_account_ref) is the immutable link to the pelada.
--  The "pelada_id" subscriber attribute only confirms the first purchase of a pending intent; a
--  transaction already linked never moves to another pelada; product and environment are checked here.
-- A04 Retention: once a season was cleaned (022) a retired member's season stats and Card are never
--  rebuilt by a later recomputation.
-- A05 Store events have a processing status (received, validated, applied, pending_reconciliation,
--  rejected), attempts and last error; recoverable ones are retried by the scheduler and raise an alert.

---------------------------------------------------------------------------------------------------
-- Lock order
---------------------------------------------------------------------------------------------------

-- Locks pelada -> match -> session and returns the session row (no status check).
create function private.lock_session_chain(p_session uuid) returns public.voting_sessions
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_match uuid; v_s public.voting_sessions;
begin
 select pelada_id, match_id into v_pelada, v_match from public.voting_sessions where id=p_session;
 if not found then return null; end if;
 perform 1 from public.peladas where id=v_pelada for update;
 perform 1 from public.matches where id=v_match for update;
 select * into v_s from public.voting_sessions where id=p_session for update;
 return v_s;
end $$;

create or replace function private.lock_voter(p_session uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare o_session public.voting_sessions; o_voter uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 o_session := private.lock_session_chain(p_session);
 if o_session.id is null or o_session.status <> 'open' or now() > o_session.closes_at then
  raise exception 'VOTING_NOT_OPEN'; end if;
 select e.membership_id into o_voter from public.voting_eligible_members e
 join public.pelada_memberships m on m.id=e.membership_id
 where e.session_id=p_session and m.user_id=auth.uid() and m.status='active';
 if not found then raise exception 'NOT_ELIGIBLE_VOTER' using errcode='42501'; end if;
 return o_voter;
end $$;

create or replace function public.confirm_match_sheet(p_match uuid, p_sheet_version integer) returns void
language plpgsql security definer set search_path = '' as $$
declare v_s public.voting_sessions; v_version integer; v_id uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select id into v_id from public.voting_sessions where match_id=p_match and status='open';
 if found then v_s := private.lock_session_chain(v_id); end if;
 if v_s.id is null or v_s.status <> 'open' or now() > v_s.closes_at then raise exception 'VOTING_NOT_OPEN'; end if;
 select sheet_version into v_version from public.matches where id=p_match;
 if p_sheet_version is distinct from v_version then raise exception 'SHEET_VERSION_OUTDATED'; end if;
 update public.voting_eligible_members e set confirmed_sheet_version=v_version
 from public.pelada_memberships m
 where e.session_id=v_s.id and m.id=e.membership_id and m.user_id=auth.uid() and m.status='active';
 if not found then raise exception 'NOT_ELIGIBLE_VOTER' using errcode='42501'; end if;
end $$;

---------------------------------------------------------------------------------------------------
-- A01: correction invalidates submitted ballots
---------------------------------------------------------------------------------------------------

-- Called by correct_match_sheet, which already holds pelada -> match.
create or replace function private.on_sheet_corrected(p_match uuid, p_voters_changed boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_s public.voting_sessions; v_close timestamptz; v_new uuid; v_invalidated integer;
begin
 select * into v_s from public.voting_sessions where match_id=p_match and status='open' for update;
 if not found then return; end if;
 if now() > v_s.closes_at then raise exception 'VOTING_EXPIRED'; end if;
 if p_voters_changed then
  update public.voting_sessions set status='cancelled', cancelled_at=now() where id=v_s.id;
  v_close := case when v_s.fixed_close then greatest(v_s.closes_at, now()+interval '1 hour')
                  else now() + make_interval(mins => v_s.duration_minutes) end;
  v_new := private.open_voting_session(p_match, v_close, v_s.duration_minutes, v_s.fixed_close);
  insert into private.audit_events(pelada_id,event_type,metadata)
  values(v_s.pelada_id,'voting_restarted',jsonb_build_object(
   'match_id',p_match,'cancelled_session_id',v_s.id,'new_session_id',v_new));
 else
  -- Every submitted ballot refers to the previous sheet: back to draft (content kept for the voter).
  update private.secret_ballots set status='draft', sheet_version=null
  where session_id=v_s.id and status='submitted';
  get diagnostics v_invalidated = row_count;
  delete from public.vote_receipts where session_id=v_s.id;
  update public.voting_eligible_members set confirmed_sheet_version=null where session_id=v_s.id;
  update public.voting_sessions set
   sheet_version=(select sheet_version from public.matches where id=p_match),
   closes_at=greatest(closes_at, now()+interval '1 hour')
  where id=v_s.id;
  if v_invalidated > 0 then
   insert into private.audit_events(pelada_id,event_type,metadata)
   values(v_s.pelada_id,'ballots_invalidated',jsonb_build_object('match_id',p_match,'session_id',v_s.id,
    'sheet_version',(select sheet_version from public.matches where id=p_match),'ballots',v_invalidated));
  end if;
 end if;
end $$;

-- Runs once; a finalized session returns its stored outcome. Only ballots of the current sheet count.
create or replace function private.finalize_session(p_session uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s public.voting_sessions; v_submitted integer; v_valid boolean; v_version integer;
begin
 v_s := private.lock_session_chain(p_session);
 if v_s.id is null then raise exception 'SESSION_NOT_FOUND'; end if;
 if v_s.status='finalized' then return private.session_summary(p_session); end if;
 if v_s.status <> 'open' then raise exception 'SESSION_NOT_FINALIZABLE'; end if;
 select sheet_version into v_version from public.matches where id=v_s.match_id;
 select count(*) into v_submitted from public.vote_receipts where session_id=p_session;
 if now() < v_s.closes_at and v_submitted < v_s.eligible_voter_count then raise exception 'VOTING_STILL_OPEN'; end if;

 update public.voting_sessions set status='finalizing' where id=p_session;
 -- Second guard (A01): a ballot that is not a submission for the current sheet never counts (its
 -- receipt goes too, so the voter is treated as a non-voter). Receipts of retired voters (021: ballot
 -- kept, link removed) are not touched.
 delete from public.vote_receipts r using private.ballot_voter_links l, private.secret_ballots b
 where r.session_id=p_session and l.session_id=p_session and l.voter_membership_id=r.membership_id
  and b.id=l.ballot_id and (b.status<>'submitted' or b.sheet_version is distinct from v_version);
 delete from private.secret_ballots where session_id=p_session
  and (status='draft' or sheet_version is distinct from v_version);
 select count(*) into v_submitted from private.secret_ballots where session_id=p_session and status='submitted';
 v_valid := v_submitted >= 3 and v_submitted * 2 >= v_s.eligible_voter_count;
 perform private.compute_match_results(v_s.match_id, case when v_valid then p_session end);
 if v_valid then perform private.grant_vote_awards(p_session); end if;
 update public.matches set status='finalized', finalized_at=now() where id=v_s.match_id;
 update public.voting_sessions set status='finalized', finalized_at=now(), is_valid=v_valid where id=p_session;
 delete from private.ballot_voter_links where session_id=p_session;
 perform private.after_match_finalized(v_s.match_id);
 insert into private.audit_events(pelada_id,event_type,metadata)
 values(v_s.pelada_id,'match_finalized',jsonb_build_object('match_id',v_s.match_id,'voting',true,
  'session_id',p_session,'is_valid',v_valid,'submitted_count',v_submitted,'sheet_version',v_version));
 return private.session_summary(p_session);
end $$;

-- Same contract as 012. A10: the same idempotency key after the voting closed = "repeated".
create or replace function public.submit_ballot(p_session uuid, p_sheet_version integer, p_scores jsonb,
 p_craque uuid, p_bola_murcha uuid, p_idempotency_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s public.voting_sessions; v_voter uuid; v_ballot uuid; v_current integer; v_confirmed integer;
 v_colleagues integer; v_not_seen integer; v_numeric integer; v_required integer; v_receipts integer;
 v_key text := nullif(btrim(p_idempotency_key),'');
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if v_key is null or length(v_key) not between 8 and 100 then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
 if exists(select 1 from public.vote_receipts r join public.pelada_memberships m on m.id=r.membership_id
   where r.session_id=p_session and m.user_id=auth.uid() and r.idempotency_key=v_key) then
  return jsonb_build_object('submitted',true,'repeated',true,
   'all_voted',(select status in ('finalizing','finalized') from public.voting_sessions where id=p_session));
 end if;
 v_voter := private.lock_voter(p_session);
 select * into v_s from public.voting_sessions where id=p_session;
 -- Re-checked under the lock (two calls with the same key at the same time).
 if exists(select 1 from public.vote_receipts where session_id=p_session and membership_id=v_voter
   and idempotency_key=v_key) then
  return jsonb_build_object('submitted',true,'all_voted',false,'repeated',true);
 end if;

 -- RN-020/RN-032: the confirmation must match the current sheet version.
 select sheet_version into v_current from public.matches where id=v_s.match_id;
 select confirmed_sheet_version into v_confirmed from public.voting_eligible_members
 where session_id=p_session and membership_id=v_voter;
 if p_sheet_version is distinct from v_current or v_confirmed is distinct from v_current then
  raise exception 'SHEET_NOT_CONFIRMED'; end if;

 v_ballot := private.write_ballot(v_s, v_voter, p_scores, p_craque, p_bola_murcha);

 v_colleagues := v_s.eligible_voter_count - 1;
 select count(*) filter (where not_seen), count(*) filter (where rating is not null)
 into v_not_seen, v_numeric from private.ballot_scores where ballot_id=v_ballot;
 if v_not_seen > v_colleagues / 2 then raise exception 'NOT_SEEN_LIMIT'; end if;
 v_required := least(coalesce(v_s.minimum_numeric_ratings, v_colleagues), v_colleagues - v_not_seen);
 if v_numeric < v_required then raise exception 'MINIMUM_RATINGS_REQUIRED'; end if;
 if p_craque is null then raise exception 'CRAQUE_REQUIRED'; end if;
 if v_s.bola_murcha_required and p_bola_murcha is null then raise exception 'BOLA_MURCHA_REQUIRED'; end if;

 update private.secret_ballots set status='submitted', sheet_version=v_current where id=v_ballot;
 insert into public.vote_receipts(pelada_id,session_id,membership_id,idempotency_key)
 values(v_s.pelada_id,p_session,v_voter,v_key)
 on conflict (session_id, membership_id) do update set idempotency_key=excluded.idempotency_key;

 select count(*) into v_receipts from public.vote_receipts where session_id=p_session;
 if v_receipts >= v_s.eligible_voter_count then
  perform private.on_all_votes_submitted(p_session);
  return jsonb_build_object('submitted',true,'all_voted',true,'repeated',false);
 end if;
 return jsonb_build_object('submitted',true,'all_voted',false,'repeated',false);
end $$;

-- The voter's own state now tells whether a previous submission was invalidated by a correction.
create or replace function public.get_my_voting_state(p_match uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('session_id',s.id,'closes_at',s.closes_at,'sheet_version',m.sheet_version,
  'eligible',e.id is not null,
  'sheet_confirmed',coalesce(e.confirmed_sheet_version=m.sheet_version,false),
  'submitted',exists(select 1 from public.vote_receipts r where r.session_id=s.id and r.membership_id=e.membership_id))
 from public.matches m
 left join public.voting_sessions s on s.match_id=m.id and s.status='open'
 left join public.voting_eligible_members e on e.session_id=s.id
  and e.membership_id=(select pm.id from public.pelada_memberships pm
   where pm.pelada_id=m.pelada_id and pm.user_id=auth.uid() and pm.status='active')
 where m.id=p_match and private.is_active_member(m.pelada_id) and m.status <> 'draft';
$$;

---------------------------------------------------------------------------------------------------
-- A02: account deletion anonymizes every membership
---------------------------------------------------------------------------------------------------

create or replace function public.request_account_deletion(p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_req private.account_deletion_requests; m record; v_snapshot jsonb;
begin
 if v_user is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_req from private.account_deletion_requests where user_id=v_user and status='pending';
 if found then return jsonb_build_object('purge_after',v_req.purge_after,'already_requested',true); end if;
 if p_confirm is distinct from true then raise exception 'CONFIRMATION_REQUIRED'; end if;

 -- Every record of the account (the names come back only if the account is recovered).
 select coalesce(jsonb_agg(jsonb_build_object('membership_id',id,'pelada_id',pelada_id,'player_name',player_name,
   'status',status)),'[]')
 into v_snapshot from public.pelada_memberships where user_id=v_user and status in ('active','left','suspended');
 for m in select id, pelada_id from public.pelada_memberships where user_id=v_user and status='active' order by pelada_id loop
  perform public.leave_pelada(m.pelada_id); -- succession, pelada lock, audit
  update public.pelada_memberships set status='retired', player_name='Aposentado' where id=m.id;
  perform private.retire_from_open_votings(m.id);
 end loop;
 update public.pelada_memberships set player_name='Aposentado'
 where user_id=v_user and status in ('left','suspended') and player_name <> 'Aposentado';

 insert into private.account_deletion_requests(user_id,purge_after,memberships_snapshot)
 values(v_user, now() + interval '30 days', v_snapshot) returning * into v_req;
 insert into private.audit_events(actor_user_id,event_type,metadata)
 values(v_user,'account_deletion_requested',jsonb_build_object('request_id',v_req.id,
  'peladas',(select count(*) from jsonb_array_elements(v_snapshot) x where x->>'status'='active')));
 return jsonb_build_object('purge_after',v_req.purge_after,'already_requested',false);
end $$;

-- Recovery: active memberships return as players (as in 021); former ones get their name back.
create or replace function public.cancel_account_deletion() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_req private.account_deletion_requests; s jsonb; v_restored integer := 0;
begin
 if v_user is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_req from private.account_deletion_requests where user_id=v_user and status='pending' for update;
 if not found or v_req.purge_after <= now() then raise exception 'NO_PENDING_DELETION'; end if;
 for s in select * from jsonb_array_elements(v_req.memberships_snapshot) loop
  perform 1 from public.peladas where id=(s->>'pelada_id')::uuid for update;
  if coalesce(s->>'status','active') = 'active' then
   update public.pelada_memberships set status='active', role='player', assistant_since=null,
    player_name=s->>'player_name'
   where id=(s->>'membership_id')::uuid and user_id=v_user and status='retired'
    and (select count(*) from public.pelada_memberships x where x.pelada_id=(s->>'pelada_id')::uuid and x.status='active') < 100;
   if found then v_restored := v_restored + 1; end if;
  else
   update public.pelada_memberships set player_name=s->>'player_name'
   where id=(s->>'membership_id')::uuid and user_id=v_user and status=s->>'status';
  end if;
 end loop;
 update private.account_deletion_requests set status='cancelled', processed_at=now(), memberships_snapshot='[]'
 where id=v_req.id;
 insert into private.audit_events(actor_user_id,event_type,metadata)
 values(v_user,'account_deletion_cancelled',jsonb_build_object('request_id',v_req.id,'restored',v_restored));
 return jsonb_build_object('restored_memberships',v_restored);
end $$;

-- Final step (scheduler): personal data and the auth account go away. Sporting records stay as
-- "Aposentado" (RN-107) without any link to the person.
create or replace function private.purge_account(p_request uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_req private.account_deletion_requests; v_error text;
begin
 select * into v_req from private.account_deletion_requests where id=p_request and status='pending' for update;
 if not found or v_req.purge_after > now() then return; end if;
 update public.pelada_memberships set player_name='Aposentado',
  status=case when status='active' then 'retired' else status end, user_id=null
 where user_id=v_req.user_id;
 update public.content_reports set reporter_user_id=null where reporter_user_id=v_req.user_id;
 delete from public.user_blocks where blocker_user_id=v_req.user_id or blocked_user_id=v_req.user_id;
 delete from public.push_devices where user_id=v_req.user_id;
 delete from public.notification_events where user_id=v_req.user_id;
 delete from public.profiles where id=v_req.user_id;
 begin
  delete from auth.users where id=v_req.user_id;
 exception when others then
  v_error := 'AUTH_DELETE_FAILED'; -- finish through the Auth admin API
 end;
 update private.account_deletion_requests set status='completed', processed_at=now(), error_code=v_error,
  memberships_snapshot='[]' where id=p_request;
 insert into private.audit_events(event_type,metadata)
 values('account_purged',jsonb_build_object('request_id',p_request,'error_code',v_error));
end $$;

-- Back-fill: former memberships of accounts already purged (021 kept their names). The link is the
-- audit of the departure (member_left, actor = the deleted account). Pending requests are anonymized
-- by their purge (their names must survive a recovery).
update public.pelada_memberships m set player_name='Aposentado'
where m.player_name <> 'Aposentado' and m.user_id is null and m.status in ('left','suspended','retired')
 and exists(select 1 from private.audit_events a join private.account_deletion_requests r
  on r.user_id=a.actor_user_id and r.status='completed'
  where a.event_type='member_left' and a.subject_membership_id=m.id);

---------------------------------------------------------------------------------------------------
-- A04: retention of retired members after the season clean-up
---------------------------------------------------------------------------------------------------

create function private.retention_excluded(p_season uuid, p_membership uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from private.season_cleanups c where c.season_id=p_season)
  and exists(select 1 from public.pelada_memberships m where m.id=p_membership and m.status='retired');
$$;

create or replace function private.recompute_stats(p_pelada uuid, p_season uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_mem uuid; s public.player_season_stats;
begin
 delete from public.player_season_stats where season_id=p_season;
 delete from public.player_career_stats where pelada_id=p_pelada;
 for v_mem in select distinct r.membership_id from public.match_player_results r
   join public.matches m on m.id=r.match_id where m.pelada_id=p_pelada and m.status='finalized' loop
  s := private.compute_stats(p_pelada, v_mem, null);
  insert into public.player_career_stats(pelada_id,membership_id,matches_played,wins,draws,losses,goals,assists,
   red_cards,valid_ratings,avg_final_rating,high_ratings,best_final_rating,max_goals_in_match,craque_awards,
   best_win_streak,best_unbeaten_streak,best_high_rating_streak,current_win_streak,current_unbeaten_streak,
   current_high_rating_streak)
  values(p_pelada,v_mem,s.matches_played,s.wins,s.draws,s.losses,s.goals,s.assists,s.red_cards,s.valid_ratings,
   s.avg_final_rating,s.high_ratings,s.best_final_rating,s.max_goals_in_match,s.craque_awards,s.best_win_streak,
   s.best_unbeaten_streak,s.best_high_rating_streak,s.current_win_streak,s.current_unbeaten_streak,
   s.current_high_rating_streak);
  if private.retention_excluded(p_season, v_mem) then continue; end if;
  s := private.compute_stats(p_pelada, v_mem, p_season);
  if s.matches_played > 0 then
   s.id := gen_random_uuid(); s.updated_at := now();
   insert into public.player_season_stats values (s.*);
  end if;
 end loop;
end $$;

create or replace function private.recompute_cards(p_season uuid, p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_mem uuid;
begin
 for v_mem in select membership_id from public.player_cards where season_id=p_season
   union select r.membership_id from public.match_player_results r join public.matches m on m.id=r.match_id
   where m.season_id=p_season and m.status='finalized' loop
  if private.retention_excluded(p_season, v_mem) then
   delete from public.player_cards where season_id=p_season and membership_id=v_mem;
   continue;
  end if;
  perform private.recompute_card(p_season, v_mem, p_match);
 end loop;
end $$;

---------------------------------------------------------------------------------------------------
-- A03 + A05: store events
---------------------------------------------------------------------------------------------------

alter table private.subscription_events
 add column status text not null default 'applied'
  check (status in ('received','validated','applied','pending_reconciliation','rejected')),
 add column attempt_count integer not null default 1,
 add column last_error text,
 add column last_attempt_at timestamptz not null default now(),
 add column validated_at timestamptz,
 add column applied_at timestamptz,
 add column purchaser_id uuid,
 add column environment text;
update private.subscription_events set status=case result
  when 'unmatched' then 'pending_reconciliation' when 'conflict' then 'pending_reconciliation'
  when 'stale' then 'rejected' else 'applied' end;
create index subscription_events_to_retry on private.subscription_events(last_attempt_at)
 where status in ('received','pending_reconciliation');

-- Product and environment accepted by this database. premium_product_ids: JSON array of store product
-- ids (unset = any product, development only). store_environment: 'PRODUCTION' or 'SANDBOX' (unset = any).
insert into private.app_config(key,value) values ('premium_product_ids','null'::jsonb), ('store_environment','null'::jsonb)
on conflict (key) do nothing;

-- One subscription (original transaction) belongs to one pelada forever.
create unique index subscription_purchasers_one_per_store_ref on public.subscription_purchasers(store_account_ref)
 where store_account_ref is not null;

create or replace function public.apply_subscription_event(p_event jsonb) returns text
language plpgsql security definer set search_path = '' as $$
declare
 v_event_id text := p_event->>'id'; v_type text := p_event->>'type';
 v_buyer uuid := private.try_uuid(p_event->>'app_user_id');
 v_pelada uuid := private.try_uuid(p_event->'subscriber_attributes'->'pelada_id'->>'value');
 v_tx text := nullif(p_event->>'original_transaction_id','');
 v_product text := p_event->>'product_id';
 v_env text := p_event->>'environment';
 v_exp timestamptz := to_timestamp((p_event->>'expiration_at_ms')::numeric / 1000);
 v_at timestamptz := coalesce(to_timestamp((p_event->>'event_timestamp_ms')::numeric / 1000), now());
 v_prev private.subscription_events; v_p public.subscription_purchasers; v_new_buyer uuid; v_result text;
 v_status text; v_products jsonb; v_want_env text; v_activation boolean;
begin
 if v_event_id is null or v_type is null then raise exception 'INVALID_EVENT'; end if;
 perform pg_advisory_xact_lock(hashtext('m91_store_event:'||v_event_id));
 select * into v_prev from private.subscription_events where event_id=v_event_id;
 if found and v_prev.status in ('applied','rejected') then return 'duplicate'; end if;
 v_activation := v_type in ('INITIAL_PURCHASE','RENEWAL','UNCANCELLATION','PRODUCT_CHANGE','SUBSCRIPTION_EXTENDED','REFUND_REVERSED');

 -- Validation: environment and product (rejected events never give anything).
 select value into v_products from private.app_config where key='premium_product_ids';
 select value #>> '{}' into v_want_env from private.app_config where key='store_environment';
 if v_want_env is not null and v_env is distinct from v_want_env then
  v_result := 'wrong_environment';
 elsif v_activation and jsonb_typeof(v_products)='array' and not (v_products ? coalesce(v_product,'')) then
  v_result := 'invalid_product';
 end if;

 if v_result is null then
  if v_type = 'TRANSFER' then
   select s.* into v_p from public.subscription_purchasers s
   where s.status in ('active','cancelled') and s.buyer_user_id in (
    select private.try_uuid(x) from jsonb_array_elements_text(coalesce(p_event->'transferred_from','[]'::jsonb)) x)
   order by s.created_at desc limit 1;
  else
   -- 1) The original transaction is the immutable link (renewals, cancellations, refunds...).
   if v_tx is not null then
    select * into v_p from public.subscription_purchasers where store_account_ref=v_tx;
   end if;
   -- 2) First purchase: the buyer's pending intent; the attribute must agree with it when present.
   if v_p.id is null and v_type = 'INITIAL_PURCHASE' and v_buyer is not null then
    select * into v_p from public.subscription_purchasers
    where buyer_user_id=v_buyer and status='pending' and store_account_ref is null
     and (v_pelada is null or pelada_id=v_pelada)
    order by created_at desc limit 1;
   end if;
   -- 3) Events without a transaction id (should not happen with the store): the buyer's only open purchase.
   if v_p.id is null and v_tx is null and not v_activation and v_buyer is not null
     and (select count(*) from public.subscription_purchasers where buyer_user_id=v_buyer
          and status in ('active','cancelled')) = 1 then
    select * into v_p from public.subscription_purchasers where buyer_user_id=v_buyer and status in ('active','cancelled');
   end if;
  end if;

  if v_p.id is null then
   v_result := 'unmatched';
  else
   -- Same lock order as start_premium_purchase: pelada first, then the purchaser row.
   perform 1 from public.peladas where id=v_p.pelada_id for update;
   select * into v_p from public.subscription_purchasers where id=v_p.id for update;
   if v_tx is not null and v_p.store_account_ref is not null and v_p.store_account_ref <> v_tx and v_type <> 'TRANSFER' then
    v_result := 'conflict'; -- another transaction already owns this purchase row
   elsif v_p.last_event_at is not null and v_at < v_p.last_event_at then
    v_result := 'stale';
   elsif v_activation then
    begin
     update public.subscription_purchasers set status='expired', ended_at=now()
     where pelada_id=v_p.pelada_id and status='pending' and id<>v_p.id;
     update public.subscription_purchasers set status='active', started_at=coalesce(started_at,v_at),
      store_account_ref=coalesce(store_account_ref,v_tx), product_id=coalesce(v_product,product_id),
      ended_at=null, last_event_at=v_at where id=v_p.id;
     insert into public.pelada_entitlements(pelada_id,plan,status,premium_until,source)
     values(v_p.pelada_id,'premium','active',v_exp,'store')
     on conflict (pelada_id) do update set plan='premium', status='active', source='store',
      premium_until=greatest(public.pelada_entitlements.premium_until, excluded.premium_until);
     v_result := 'activated';
    exception when unique_violation then
     -- The buyer already has another active subscription, or the transaction is bound elsewhere.
     v_result := 'conflict';
    end;
   elsif v_type = 'CANCELLATION' then
    update public.subscription_purchasers set status='cancelled', last_event_at=v_at where id=v_p.id;
    if p_event->>'cancel_reason' = 'CUSTOMER_SUPPORT' then
     update public.pelada_entitlements set status='cancelled',
      premium_until=least(premium_until, coalesce(v_exp, now())) where pelada_id=v_p.pelada_id;
     v_result := 'refunded';
    else
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
     v_result := 'transfer_kept'; -- the pelada keeps the paid period; the buyer stays the original account
    end if;
   else
    v_result := 'ignored';
   end if;
   if v_result not in ('conflict') then
    insert into private.audit_events(pelada_id,event_type,metadata)
    values(v_p.pelada_id,'subscription_event',jsonb_build_object('event_id',v_event_id,'type',v_type,'result',v_result));
   end if;
  end if;
 end if;

 v_status := case when v_result in ('unmatched','conflict') then 'pending_reconciliation'
                  when v_result in ('stale','invalid_product','wrong_environment') then 'rejected'
                  else 'applied' end;
 insert into private.subscription_events(event_id,event_type,app_user_id,product_id,payload,result,status,
  attempt_count,last_attempt_at,validated_at,applied_at,purchaser_id,environment)
 values(v_event_id,v_type,p_event->>'app_user_id',v_product,p_event,v_result,v_status,1,now(),
  case when v_status<>'rejected' then now() end, case when v_status='applied' then now() end,v_p.id,v_env)
 on conflict (event_id) do update set payload=excluded.payload, result=excluded.result, status=excluded.status,
  attempt_count=private.subscription_events.attempt_count+1, last_attempt_at=now(), last_error=null,
  validated_at=coalesce(private.subscription_events.validated_at, excluded.validated_at),
  applied_at=excluded.applied_at, purchaser_id=excluded.purchaser_id, environment=excluded.environment;
 return v_result;
end $$;

-- The webhook records an event the database could not process (error, timeout) before answering 500,
-- so it is visible and retried even if the store gives up.
create function public.record_store_event_failure(p_event jsonb, p_error text) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if p_event->>'id' is null or p_event->>'type' is null then return; end if;
 insert into private.subscription_events(event_id,event_type,app_user_id,product_id,payload,result,status,
  last_error,environment)
 values(p_event->>'id',p_event->>'type',p_event->>'app_user_id',p_event->>'product_id',p_event,'error','received',
  left(p_error,500),p_event->>'environment')
 on conflict (event_id) do update set attempt_count=private.subscription_events.attempt_count+1,
  last_attempt_at=now(), last_error=left(p_error,500)
 where private.subscription_events.status in ('received','pending_reconciliation');
end $$;

-- Retries recoverable events (received / pending_reconciliation): oldest first, with a growing wait
-- (5 min * attempts, up to 6 h), at most 20 attempts. Each event runs isolated.
create function private.reconcile_store_events() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; v_n integer := 0;
begin
 for r in select event_id, payload from private.subscription_events
   where status in ('received','pending_reconciliation') and attempt_count < 20
    and last_attempt_at < now() - least(interval '6 hours', make_interval(mins => 5*attempt_count))
   order by received_at limit 50 loop
  begin
   perform public.apply_subscription_event(r.payload);
   v_n := v_n + 1;
  exception when others then
   update private.subscription_events set attempt_count=attempt_count+1, last_attempt_at=now(), last_error=left(sqlerrm,500)
   where event_id=r.event_id;
  end;
 end loop;
 return v_n;
end $$;

-- Support: events that need a person (3+ attempts or stuck for more than 1 hour).
create view private.store_event_alerts as
 select event_id, event_type, app_user_id, result, status, attempt_count, last_error, received_at, last_attempt_at
 from private.subscription_events
 where status in ('received','pending_reconciliation')
  and (attempt_count >= 3 or received_at < now() - interval '1 hour')
 order by received_at;

create or replace function private.run_scheduled_tasks() returns void
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
 -- 6. Store events waiting for reconciliation (A05).
 perform private.run_job('reconcile_store_events', null, 'select private.reconcile_store_events()');
 delete from private.background_jobs where completed_at < now() - interval '90 days';
end $$;

revoke all on function private.lock_session_chain(uuid), private.retention_excluded(uuid,uuid),
 private.reconcile_store_events() from public,anon,authenticated;
revoke all on private.store_event_alerts from public,anon,authenticated;
revoke all on function public.record_store_event_failure(jsonb,text) from public,anon,authenticated;
grant execute on function public.record_store_event_failure(jsonb,text) to service_role;
revoke all on function public.apply_subscription_event(jsonb) from public,anon,authenticated;
grant execute on function public.apply_subscription_event(jsonb) to service_role;
