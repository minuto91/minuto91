-- Minuto 91 / 012: saving, submitting and editing votes (Doc 02 RN-020/RN-029..032/
-- RN-047/RN-049, Doc 03 sec. 12, Doc 04 sec. 20).
-- p_scores: [{"membership_id": uuid, "rating": 0..10 (one decimal)}
--            | {"membership_id": uuid, "not_seen": true}]  (blank colleagues: omitted)
-- save_ballot_draft: partial ballot, editable until the deadline (RN-032).
-- submit_ballot: full validation (confirmed current sheet version, "não vi jogar"
-- limit, minimum numeric ratings, Craque and, when required, Bola Murcha); may be
-- called again to edit until the deadline. Same idempotency key = no reprocessing.
-- Every call re-checks eligibility on the server. Calls of a session are serialized
-- by locking the session row (no double ballots under concurrency).

-- Locks the open session (row lock held until commit) and returns the caller's eligible membership.
create function private.lock_voter(p_session uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare o_session public.voting_sessions; o_voter uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into o_session from public.voting_sessions where id=p_session for update;
 if not found or o_session.status <> 'open' or now() > o_session.closes_at then
  raise exception 'VOTING_NOT_OPEN'; end if;
 select e.membership_id into o_voter from public.voting_eligible_members e
 join public.pelada_memberships m on m.id=e.membership_id
 where e.session_id=p_session and m.user_id=auth.uid() and m.status='active';
 if not found then raise exception 'NOT_ELIGIBLE_VOTER' using errcode='42501'; end if;
 return o_voter;
end $$;

-- Replaces the caller's ballot content. Validates each line (target, scale, awards).
create function private.write_ballot(p_s public.voting_sessions, p_voter uuid, p_scores jsonb,
 p_craque uuid, p_bola_murcha uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_ballot uuid; e jsonb; v_target uuid; v_rating numeric; v_not_seen boolean;
begin
 if jsonb_typeof(coalesce(p_scores,'[]')) <> 'array' then raise exception 'INVALID_BALLOT'; end if;
 select ballot_id into v_ballot from private.ballot_voter_links where session_id=p_s.id and voter_membership_id=p_voter;
 if not found then
  insert into private.secret_ballots(session_id) values(p_s.id) returning id into v_ballot;
  insert into private.ballot_voter_links(ballot_id,session_id,voter_membership_id) values(v_ballot,p_s.id,p_voter);
 end if;
 delete from private.ballot_scores where ballot_id=v_ballot;
 delete from private.ballot_awards where ballot_id=v_ballot;

 begin
  for e in select * from jsonb_array_elements(coalesce(p_scores,'[]')) loop
   v_target := (e->>'membership_id')::uuid;
   v_not_seen := coalesce((e->>'not_seen')::boolean, false);
   v_rating := (e->>'rating')::numeric;
   if v_target is null or v_target=p_voter or not exists(select 1 from public.voting_eligible_members
     where session_id=p_s.id and membership_id=v_target) then
    raise exception 'INVALID_RATING_TARGET'; end if;
   if v_not_seen then
    if v_rating is not null then raise exception 'INVALID_RATING'; end if;
   elsif v_rating is null or v_rating < 0 or v_rating > 10 or v_rating <> round(v_rating,1) then
    raise exception 'INVALID_RATING';
   end if;
   insert into private.ballot_scores(ballot_id,target_membership_id,rating,not_seen)
   values(v_ballot,v_target,case when v_not_seen then null else v_rating end,v_not_seen);
  end loop;
 exception
  when unique_violation then raise exception 'DUPLICATE_RATING';
  when invalid_text_representation then raise exception 'INVALID_BALLOT';
 end;

 if p_craque is not null then
  if p_craque=p_voter or not exists(select 1 from public.voting_eligible_members
    where session_id=p_s.id and membership_id=p_craque) then raise exception 'INVALID_AWARD_TARGET'; end if;
  insert into private.ballot_awards values(v_ballot,'craque',p_craque);
 end if;
 if p_bola_murcha is not null then
  if not p_s.bola_murcha_required then raise exception 'BOLA_MURCHA_DISABLED'; end if;
  if p_bola_murcha=p_voter or not exists(select 1 from public.voting_eligible_members
    where session_id=p_s.id and membership_id=p_bola_murcha) then raise exception 'INVALID_AWARD_TARGET'; end if;
  insert into private.ballot_awards values(v_ballot,'bola_murcha',p_bola_murcha);
 end if;
 return v_ballot;
end $$;

-- Hook: everyone submitted -> finalize. Replaced in 013.
create function private.on_all_votes_submitted(p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 null;
end $$;

create function public.save_ballot_draft(p_session uuid, p_scores jsonb,
 p_craque uuid default null, p_bola_murcha uuid default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_s public.voting_sessions; v_voter uuid; v_ballot uuid;
begin
 v_voter := private.lock_voter(p_session);
 select * into v_s from public.voting_sessions where id=p_session;
 if exists(select 1 from public.vote_receipts where session_id=p_session and membership_id=v_voter) then
  raise exception 'BALLOT_ALREADY_SUBMITTED'; end if;
 v_ballot := private.write_ballot(v_s, v_voter, p_scores, p_craque, p_bola_murcha);
end $$;

-- Returns {"submitted": true, "all_voted": bool, "repeated": bool}.
create function public.submit_ballot(p_session uuid, p_sheet_version integer, p_scores jsonb,
 p_craque uuid, p_bola_murcha uuid, p_idempotency_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s public.voting_sessions; v_voter uuid; v_ballot uuid; v_current integer; v_confirmed integer;
 v_colleagues integer; v_not_seen integer; v_numeric integer; v_required integer; v_receipts integer;
 v_key text := nullif(btrim(p_idempotency_key),'');
begin
 v_voter := private.lock_voter(p_session);
 select * into v_s from public.voting_sessions where id=p_session;
 if v_key is null or length(v_key) not between 8 and 100 then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
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
 -- Default: rate every colleague not marked "não vi jogar"; a pelada may require fewer.
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

-- The caller's own ballot (to resume a draft or edit), only while voting is open.
-- Returns {"status": "none"|"draft"|"submitted", "scores": [...], "craque": uuid, "bola_murcha": uuid}.
create function public.get_my_ballot(p_session uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s public.voting_sessions; v_voter uuid; v_ballot uuid; v_status text;
begin
 v_voter := private.lock_voter(p_session);
 select * into v_s from public.voting_sessions where id=p_session;
 select b.id, b.status into v_ballot, v_status from private.ballot_voter_links l
 join private.secret_ballots b on b.id=l.ballot_id
 where l.session_id=p_session and l.voter_membership_id=v_voter;
 if not found then return jsonb_build_object('status','none','scores','[]'::jsonb); end if;
 return jsonb_build_object('status',v_status,
  'scores',coalesce((select jsonb_agg(case when not_seen
     then jsonb_build_object('membership_id',target_membership_id,'not_seen',true)
     else jsonb_build_object('membership_id',target_membership_id,'rating',rating) end)
    from private.ballot_scores where ballot_id=v_ballot),'[]'::jsonb),
  'craque',(select target_membership_id from private.ballot_awards where ballot_id=v_ballot and award_type='craque'),
  'bola_murcha',(select target_membership_id from private.ballot_awards where ballot_id=v_ballot and award_type='bola_murcha'));
end $$;

revoke all on function private.lock_voter(uuid), private.write_ballot(public.voting_sessions,uuid,jsonb,uuid,uuid),
 private.on_all_votes_submitted(uuid) from public,anon,authenticated;
revoke all on function public.save_ballot_draft(uuid,jsonb,uuid,uuid),
 public.submit_ballot(uuid,integer,jsonb,uuid,uuid,text), public.get_my_ballot(uuid) from public,anon;
grant execute on function public.save_ballot_draft(uuid,jsonb,uuid,uuid),
 public.submit_ballot(uuid,integer,jsonb,uuid,uuid,text), public.get_my_ballot(uuid) to authenticated;
