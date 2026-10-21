-- Minuto 91 / 010: publication, voting sessions and voter eligibility
-- (Doc 02 RN-023/RN-026..028, Doc 03 sec. 11-12, Doc 04 sec. 17-18.1).
-- publish_match (admin/assistant, draft with players on both teams) records sheet
-- version 1 and opens the voting session. With fewer than 6 eligible voters (FIXED,
-- not configurable) the match is finalized without voting.
-- Voters: participants with an active membership and an onboarded account (no
-- guests, no players without account, no deleted accounts). The set is frozen
-- when the session opens.
-- Deadline: 2, 4 or 6 hours (default from settings, 4h); Premium may instead pick a
-- fixed closing time between 1h and 24h after opening.
-- Correction while open (009 hook): confirmations are invalidated and at least 1h
-- remains; if the set of voters changed, the session is cancelled and a new one is
-- opened (ballots of the cancelled session no longer count).
-- Ballots, receipts and submission: 011/012. Closing and results: 013.

create table public.voting_sessions (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null,
 status text not null default 'open' check (status in ('open','finalizing','finalized','cancelled')),
 opens_at timestamptz not null default now(),
 closes_at timestamptz not null,
 duration_minutes integer check (duration_minutes in (120,240,360)),
 fixed_close boolean not null default false,
 finalized_at timestamptz,
 cancelled_at timestamptz,
 sheet_version integer not null,
 bola_murcha_required boolean not null,
 minimum_numeric_ratings integer,
 formula_version integer not null,
 eligible_voter_count integer not null check (eligible_voter_count >= 6),
 is_valid boolean,
 created_at timestamptz not null default now(),
 constraint session_deadline_kind check (fixed_close = (duration_minutes is null)),
 foreign key (match_id, pelada_id) references public.matches(id, pelada_id),
 unique (id, pelada_id)
);
create unique index one_active_session_per_match on public.voting_sessions(match_id)
 where status in ('open','finalizing');
create index idx_voting_sessions_match on public.voting_sessions(match_id);

create table public.voting_eligible_members (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 session_id uuid not null,
 membership_id uuid not null,
 -- Null when a later correction removed the participant (that session is then cancelled).
 participant_id uuid references public.match_participants(id) on delete set null,
 -- Sheet version this voter confirmed; reset by corrections (RN-023). Not readable by clients.
 confirmed_sheet_version integer,
 created_at timestamptz not null default now(),
 foreign key (session_id, pelada_id) references public.voting_sessions(id, pelada_id) on delete cascade,
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 unique (session_id, membership_id)
);

alter table public.voting_sessions enable row level security;
alter table public.voting_eligible_members enable row level security;
revoke all on public.voting_sessions, public.voting_eligible_members from anon,authenticated;
grant select on public.voting_sessions to authenticated;
-- Who may vote is public to the pelada; who confirmed/when is not (own state: get_my_voting_state).
grant select (id, pelada_id, session_id, membership_id) on public.voting_eligible_members to authenticated;
create policy sessions_read_members on public.voting_sessions for select to authenticated
 using ((select private.is_active_member(pelada_id)));
create policy eligible_read_members on public.voting_eligible_members for select to authenticated
 using ((select private.is_active_member(pelada_id)));
-- No client writes.

create function private.match_voters(p_match uuid) returns table(membership_id uuid, participant_id uuid)
language sql stable security definer set search_path = '' as $$
 select p.membership_id, p.id from public.match_participants p
 join public.pelada_memberships m on m.id=p.membership_id
 join public.profiles pr on pr.id=m.user_id
 where p.match_id=p_match and m.status='active'
  and pr.adult_declared_at is not null and pr.terms_accepted_at is not null;
$$;

-- 009 compares voters before/after a correction: same definition as above.
create or replace function private.sheet_voter_memberships(p_match uuid) returns uuid[]
language sql stable security definer set search_path = '' as $$
 select coalesce(array_agg(v.membership_id order by v.membership_id), '{}') from private.match_voters(p_match) v;
$$;

-- Opens the session, or finalizes without voting below the fixed minimum.
-- Returns the session id (null when finalized without voting). Caller locks.
create function private.open_voting_session(p_match uuid, p_closes_at timestamptz,
 p_duration integer, p_fixed boolean) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c_min_voters constant integer := 6; -- RN-027: fixed, never configurable.
 v_m public.matches; v_s public.pelada_settings; v_count integer; v_id uuid;
begin
 select * into v_m from public.matches where id=p_match;
 select count(*) into v_count from private.match_voters(p_match);
 if v_count < c_min_voters then
  -- TODO(013): objective statistics only (no official rating, awards or Seleção).
  update public.matches set status='finalized', finalized_at=now() where id=p_match;
  return null;
 end if;
 select * into v_s from public.pelada_settings where pelada_id=v_m.pelada_id;
 insert into public.voting_sessions(pelada_id,match_id,closes_at,duration_minutes,fixed_close,sheet_version,
  bola_murcha_required,minimum_numeric_ratings,formula_version,eligible_voter_count)
 values(v_m.pelada_id,p_match,p_closes_at,p_duration,p_fixed,v_m.sheet_version,
  coalesce(v_s.bola_murcha_enabled,true) and private.pelada_has_premium(v_m.pelada_id),
  v_s.minimum_numeric_ratings,v_m.formula_version,v_count)
 returning id into v_id;
 insert into public.voting_eligible_members(pelada_id,session_id,membership_id,participant_id)
 select v_m.pelada_id,v_id,v.membership_id,v.participant_id from private.match_voters(p_match) v;
 update public.matches set status='voting_open' where id=p_match;
 return v_id;
end $$;

-- Publishes a draft. Pass either a duration (120/240/360) or, Premium only, a fixed
-- closing time (1h-24h ahead); neither = the pelada's default duration.
-- Returns {"status", "session_id", "closes_at", "eligible_voter_count"}.
create function public.publish_match(p_match uuid, p_duration_minutes integer default null,
 p_closes_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_m public.matches; v_dur integer; v_close timestamptz; v_session uuid; v_count integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_pelada for update;
 if not private.is_active_staff(v_pelada) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match for update;
 if v_m.status <> 'draft' then raise exception 'MATCH_NOT_DRAFT'; end if;
 if not exists(select 1 from public.match_participants where match_id=p_match and team='A')
  or not exists(select 1 from public.match_participants where match_id=p_match and team='B') then
  raise exception 'TEAMS_INCOMPLETE'; end if;

 if p_closes_at is not null then
  if p_duration_minutes is not null then raise exception 'INVALID_VOTING_DURATION'; end if;
  if not private.pelada_has_premium(v_pelada) then raise exception 'PREMIUM_REQUIRED'; end if;
  if p_closes_at < now()+interval '1 hour' or p_closes_at > now()+interval '24 hours' then
   raise exception 'INVALID_CLOSING_TIME'; end if;
  v_close := p_closes_at;
 else
  v_dur := coalesce(p_duration_minutes,
   (select voting_duration_minutes from public.pelada_settings where pelada_id=v_pelada), 240);
  if v_dur not in (120,240,360) then raise exception 'INVALID_VOTING_DURATION'; end if;
  v_close := now() + make_interval(mins => v_dur);
 end if;

 insert into public.match_versions(pelada_id,match_id,version_number,changed_by,snapshot)
 values(v_pelada,p_match,v_m.sheet_version,auth.uid(),private.sheet_snapshot(p_match));
 v_session := private.open_voting_session(p_match, v_close, v_dur, p_closes_at is not null);
 select count(*) into v_count from private.match_voters(p_match);
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_pelada,auth.uid(),'match_published',jsonb_build_object(
  'match_id',p_match,'session_id',v_session,'eligible_voter_count',v_count));
 return jsonb_build_object('status',(select status from public.matches where id=p_match),
  'session_id',v_session,'closes_at',case when v_session is not null then v_close end,
  'eligible_voter_count',v_count);
end $$;

-- Replaces the 009 hook (called by correct_match_sheet, which holds the pelada lock).
create or replace function private.on_sheet_corrected(p_match uuid, p_voters_changed boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_s public.voting_sessions; v_close timestamptz; v_new uuid;
begin
 select * into v_s from public.voting_sessions where match_id=p_match and status='open' for update;
 if not found then return; end if;
 if p_voters_changed then
  update public.voting_sessions set status='cancelled', cancelled_at=now() where id=v_s.id;
  v_close := case when v_s.fixed_close then greatest(v_s.closes_at, now()+interval '1 hour')
                  else now() + make_interval(mins => v_s.duration_minutes) end;
  v_new := private.open_voting_session(p_match, v_close, v_s.duration_minutes, v_s.fixed_close);
  insert into private.audit_events(pelada_id,event_type,metadata)
  values(v_s.pelada_id,'voting_restarted',jsonb_build_object(
   'match_id',p_match,'cancelled_session_id',v_s.id,'new_session_id',v_new));
 else
  update public.voting_eligible_members set confirmed_sheet_version=null where session_id=v_s.id;
  update public.voting_sessions set
   sheet_version=(select sheet_version from public.matches where id=p_match),
   closes_at=greatest(closes_at, now()+interval '1 hour')
  where id=v_s.id;
 end if;
end $$;

-- RN-020: the voter confirms having checked the CURRENT sheet version.
create function public.confirm_match_sheet(p_match uuid, p_sheet_version integer) returns void
language plpgsql security definer set search_path = '' as $$
declare v_s public.voting_sessions; v_version integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 -- Same row lock as corrections, so a confirmation never targets a stale version.
 select * into v_s from public.voting_sessions where match_id=p_match and status='open' for update;
 if not found or now() > v_s.closes_at then raise exception 'VOTING_NOT_OPEN'; end if;
 select sheet_version into v_version from public.matches where id=p_match;
 if p_sheet_version is distinct from v_version then raise exception 'SHEET_VERSION_OUTDATED'; end if;
 update public.voting_eligible_members e set confirmed_sheet_version=v_version
 from public.pelada_memberships m
 where e.session_id=v_s.id and m.id=e.membership_id and m.user_id=auth.uid() and m.status='active';
 if not found then raise exception 'NOT_ELIGIBLE_VOTER' using errcode='42501'; end if;
end $$;

-- The caller's own voting state for a match (null when not a member).
create function public.get_my_voting_state(p_match uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('session_id',s.id,'closes_at',s.closes_at,'sheet_version',m.sheet_version,
  'eligible',e.id is not null,
  'sheet_confirmed',coalesce(e.confirmed_sheet_version=m.sheet_version,false))
 from public.matches m
 left join public.voting_sessions s on s.match_id=m.id and s.status='open'
 left join public.voting_eligible_members e on e.session_id=s.id
  and e.membership_id=(select pm.id from public.pelada_memberships pm
   where pm.pelada_id=m.pelada_id and pm.user_id=auth.uid() and pm.status='active')
 where m.id=p_match and private.is_active_member(m.pelada_id) and m.status <> 'draft';
$$;

revoke all on function private.match_voters(uuid), private.open_voting_session(uuid,timestamptz,integer,boolean)
 from public,anon,authenticated;
revoke all on function public.publish_match(uuid,integer,timestamptz), public.confirm_match_sheet(uuid,integer),
 public.get_my_voting_state(uuid) from public,anon;
grant execute on function public.publish_match(uuid,integer,timestamptz), public.confirm_match_sheet(uuid,integer),
 public.get_my_voting_state(uuid) to authenticated;
