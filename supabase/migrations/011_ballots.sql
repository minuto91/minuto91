-- Minuto 91 / 011: protected ballots and vote receipts (Doc 02 RN-031/RN-033,
-- Doc 03 sec. 13, Doc 04 sec. 18.2-19).
-- Ballots live in the private schema: no SELECT for anyone (players, admins,
-- assistants); only server functions read or write them. They carry no
-- timestamps, so metadata cannot help identify a voter.
-- The voter-ballot link exists only while voting is open (to block duplicates and
-- allow edits) and is deleted at finalization (013). Anonymous ballots stay until
-- the end of the season (022), then only aggregates remain.
-- Who rates whom: the session's eligible voters rate each other (never themselves);
-- players without an account do not receive ratings (product decision).
-- A receipt exists once a voter has SUBMITTED: everyone sees who has not voted yet
-- (eligible minus receipts), without times.

create table private.secret_ballots (
 id uuid primary key default gen_random_uuid(),
 session_id uuid not null references public.voting_sessions(id) on delete cascade,
 status text not null default 'draft' check (status in ('draft','submitted')),
 -- Sheet version confirmed at submission (null while draft).
 sheet_version integer,
 constraint ballot_submitted_version check ((status='submitted') = (sheet_version is not null))
);
create index secret_ballots_by_session on private.secret_ballots(session_id, status);

-- One row per rated colleague: a 0-10 rating (one decimal) or "não vi jogar".
-- A colleague left blank simply has no row (never converted to zero).
create table private.ballot_scores (
 ballot_id uuid not null references private.secret_ballots(id) on delete cascade,
 target_membership_id uuid not null references public.pelada_memberships(id),
 rating numeric(3,1) check (rating between 0 and 10),
 not_seen boolean not null default false,
 primary key (ballot_id, target_membership_id),
 constraint score_kind check (not_seen = (rating is null))
);

create table private.ballot_awards (
 ballot_id uuid not null references private.secret_ballots(id) on delete cascade,
 award_type text not null check (award_type in ('craque','bola_murcha')),
 target_membership_id uuid not null references public.pelada_memberships(id),
 primary key (ballot_id, award_type)
);

-- Temporary voter-ballot link (deleted at finalization).
create table private.ballot_voter_links (
 ballot_id uuid primary key references private.secret_ballots(id) on delete cascade,
 session_id uuid not null references public.voting_sessions(id) on delete cascade,
 voter_membership_id uuid not null references public.pelada_memberships(id),
 unique (session_id, voter_membership_id)
);

revoke all on private.secret_ballots, private.ballot_scores, private.ballot_awards,
 private.ballot_voter_links from public, anon, authenticated;

create table public.vote_receipts (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 session_id uuid not null,
 membership_id uuid not null,
 -- Last idempotency key used by submit_ballot (not readable by clients).
 idempotency_key text not null,
 foreign key (session_id, pelada_id) references public.voting_sessions(id, pelada_id) on delete cascade,
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 unique (session_id, membership_id)
);
alter table public.vote_receipts enable row level security;
revoke all on public.vote_receipts from anon,authenticated;
grant select (id, pelada_id, session_id, membership_id) on public.vote_receipts to authenticated;
create policy receipts_read_members on public.vote_receipts for select to authenticated
 using ((select private.is_active_member(pelada_id)));
-- No client writes.

-- Ballots of a cancelled session (voting restarted) never count.
create function private.drop_cancelled_ballots() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 delete from private.secret_ballots where session_id=new.id;
 return new;
end $$;
create trigger sessions_drop_cancelled_ballots after update of status on public.voting_sessions
for each row when (new.status='cancelled' and old.status is distinct from 'cancelled')
execute function private.drop_cancelled_ballots();
revoke all on function private.drop_cancelled_ballots() from public,anon,authenticated;
