-- Minuto 91 / 021: privacy and account deletion (Doc 02 RN-101..110, Doc 04 sec. 29).
-- PRODUCT DECISION: deletion takes effect at once and is purged after 30 days.
--  At request time: admin succession runs in every pelada (RN-109), the member becomes
--  "Aposentado" (status retired, public name "Aposentado", no navigable profile, card
--  hidden, no new individual awards - RN-102/106), leaves open votings without blocking
--  them (RN-108) and cannot create or join peladas.
--  For 30 days the user may sign in and recover: memberships come back with their
--  names and history, as players (admin roles are not returned).
--  After 30 days the scheduler (022) purges the profile and the auth account; the
--  retired records stay as "Aposentado" until the end of the season (022, RN-107).
--  The 30-day standby must be stated in the Privacy Policy and Terms [VALIDAR COM ADVOGADO].
-- Open votings: a voter who already submitted keeps the anonymous ballot (link removed);
-- otherwise the draft is dropped and the session counts one eligible voter less.

alter table public.voting_sessions drop constraint voting_sessions_eligible_voter_count_check;
alter table public.voting_sessions add constraint voting_sessions_eligible_voter_count_check
 check (eligible_voter_count >= 0); -- opening still requires 6 (open_voting_session)

create table private.account_deletion_requests (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null,
 requested_at timestamptz not null default now(),
 purge_after timestamptz not null,
 status text not null default 'pending' check (status in ('pending','cancelled','completed')),
 processed_at timestamptz,
 error_code text,
 -- Names and peladas to restore on recovery; wiped at purge.
 memberships_snapshot jsonb not null default '[]'::jsonb
);
create unique index one_pending_deletion on private.account_deletion_requests(user_id) where status='pending';
revoke all on private.account_deletion_requests from public,anon,authenticated;

-- No pelada creation or joining while a deletion is pending.
create or replace function private.require_onboarded() returns void language plpgsql
security definer set search_path = '' as $$
begin
 if not exists(select 1 from public.profiles
   where id=(select auth.uid()) and adult_declared_at is not null and terms_accepted_at is not null) then
  raise exception 'ONBOARDING_REQUIRED' using errcode='42501';
 end if;
 if exists(select 1 from private.account_deletion_requests where user_id=(select auth.uid()) and status='pending') then
  raise exception 'ACCOUNT_DELETION_PENDING' using errcode='42501';
 end if;
end $$;

-- Removes a member from the open votings of the pelada (RN-108). Caller locks the pelada.
create function private.retire_from_open_votings(p_membership uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare s record;
begin
 for s in select v.id, v.eligible_voter_count from public.voting_sessions v
   join public.voting_eligible_members e on e.session_id=v.id
   where e.membership_id=p_membership and v.status='open' for update of v loop
  if exists(select 1 from public.vote_receipts where session_id=s.id and membership_id=p_membership) then
   delete from private.ballot_voter_links where session_id=s.id and voter_membership_id=p_membership;
  else
   delete from private.secret_ballots where id in (select ballot_id from private.ballot_voter_links
    where session_id=s.id and voter_membership_id=p_membership);
   delete from public.voting_eligible_members where session_id=s.id and membership_id=p_membership;
   update public.voting_sessions set eligible_voter_count=eligible_voter_count-1 where id=s.id;
   if (select count(*) from public.vote_receipts where session_id=s.id) >= s.eligible_voter_count - 1 then
    perform private.finalize_session(s.id); -- everyone left has voted
   end if;
  end if;
 end loop;
end $$;

create function public.request_account_deletion(p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_req private.account_deletion_requests; m record; v_snapshot jsonb;
begin
 if v_user is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_req from private.account_deletion_requests where user_id=v_user and status='pending';
 if found then return jsonb_build_object('purge_after',v_req.purge_after,'already_requested',true); end if;
 if p_confirm is distinct from true then raise exception 'CONFIRMATION_REQUIRED'; end if;

 select coalesce(jsonb_agg(jsonb_build_object('membership_id',id,'pelada_id',pelada_id,'player_name',player_name)),'[]')
 into v_snapshot from public.pelada_memberships where user_id=v_user and status='active';
 for m in select id, pelada_id from public.pelada_memberships where user_id=v_user and status='active' order by pelada_id loop
  perform public.leave_pelada(m.pelada_id); -- succession, pelada lock, audit
  update public.pelada_memberships set status='retired', player_name='Aposentado' where id=m.id;
  perform private.retire_from_open_votings(m.id);
 end loop;

 insert into private.account_deletion_requests(user_id,purge_after,memberships_snapshot)
 values(v_user, now() + interval '30 days', v_snapshot) returning * into v_req;
 insert into private.audit_events(actor_user_id,event_type,metadata)
 values(v_user,'account_deletion_requested',jsonb_build_object('request_id',v_req.id,'peladas',jsonb_array_length(v_snapshot)));
 return jsonb_build_object('purge_after',v_req.purge_after,'already_requested',false);
end $$;

-- Recovery within 30 days: memberships return with their names, as players.
create function public.cancel_account_deletion() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_req private.account_deletion_requests; s jsonb; v_restored integer := 0;
begin
 if v_user is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_req from private.account_deletion_requests where user_id=v_user and status='pending' for update;
 if not found or v_req.purge_after <= now() then raise exception 'NO_PENDING_DELETION'; end if;
 for s in select * from jsonb_array_elements(v_req.memberships_snapshot) loop
  perform 1 from public.peladas where id=(s->>'pelada_id')::uuid for update;
  update public.pelada_memberships set status='active', role='player', assistant_since=null,
   player_name=s->>'player_name'
  where id=(s->>'membership_id')::uuid and user_id=v_user and status='retired'
   and (select count(*) from public.pelada_memberships x where x.pelada_id=(s->>'pelada_id')::uuid and x.status='active') < 100;
  if found then v_restored := v_restored + 1; end if;
 end loop;
 update private.account_deletion_requests set status='cancelled', processed_at=now(), memberships_snapshot='[]'
 where id=v_req.id;
 insert into private.audit_events(actor_user_id,event_type,metadata)
 values(v_user,'account_deletion_cancelled',jsonb_build_object('request_id',v_req.id,'restored',v_restored));
 return jsonb_build_object('restored_memberships',v_restored);
end $$;

create function public.get_account_status() returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('deletion_pending', r.id is not null, 'purge_after', r.purge_after)
 from (select 1) one left join private.account_deletion_requests r
  on r.user_id=(select auth.uid()) and r.status='pending';
$$;

-- Final step (scheduler, 022): personal data and the auth account go away.
create function private.purge_account(p_request uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_req private.account_deletion_requests; v_error text;
begin
 select * into v_req from private.account_deletion_requests where id=p_request and status='pending' for update;
 if not found or v_req.purge_after > now() then return; end if;
 update public.pelada_memberships set user_id=null where user_id=v_req.user_id;
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

-- RN-102: a retired member has no accessible card.
drop policy cards_read on public.player_cards;
create policy cards_read on public.player_cards for select to authenticated
 using ((select private.is_active_member(pelada_id)) and exists(select 1 from public.pelada_memberships m
  where m.id=membership_id and m.status<>'retired'));

-- RN-106: retired members get no new individual awards.
create or replace function private.grant_month_award(p_pelada uuid, p_season uuid, p_month date, p_type text,
 p_winners uuid[]) returns void
language sql security definer set search_path = '' as $$
 with w as (select m.id from public.pelada_memberships m where m.id = any(p_winners) and m.status<>'retired')
 insert into public.awards(pelada_id,season_id,membership_id,award_type,period_month,is_shared)
 select p_pelada, p_season, w.id, p_type, p_month, (select count(*) from w) > 1 from w;
$$;

create or replace function private.grant_vote_awards(p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_s public.voting_sessions; v_season uuid; t text;
begin
 select * into v_s from public.voting_sessions where id=p_session;
 select season_id into v_season from public.matches where id=v_s.match_id;
 foreach t in array case when v_s.bola_murcha_required then array['craque','bola_murcha'] else array['craque'] end loop
  insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count,is_shared)
  with votes as (
   select ba.target_membership_id m, count(*)::int c from private.ballot_awards ba
   join private.secret_ballots b on b.id=ba.ballot_id
   join public.pelada_memberships pm on pm.id=ba.target_membership_id and pm.status<>'retired'
   where b.session_id=p_session and b.status='submitted' and ba.award_type=t
   group by ba.target_membership_id),
  top as (select * from votes where c=(select max(c) from votes))
  select v_s.pelada_id, v_s.match_id, v_season, top.m,
   case t when 'craque' then 'match_craque' else 'bola_murcha' end, top.c, (select count(*) from top) > 1
  from top;
 end loop;
end $$;

revoke all on function private.retire_from_open_votings(uuid), private.purge_account(uuid) from public,anon,authenticated;
revoke all on function public.request_account_deletion(boolean), public.cancel_account_deletion(),
 public.get_account_status() from public,anon;
grant execute on function public.request_account_deletion(boolean), public.cancel_account_deletion(),
 public.get_account_status() to authenticated;
