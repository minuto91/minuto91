-- Minuto 91 / 013: finalization and results (Doc 02 RN-024/RN-034..049/RN-116,
-- Doc 03 sec. 32, Doc 04 sec. 21-22, 25.2 awards).
-- A session closes once (concurrent or repeated calls return the stored outcome):
-- when everyone submitted (automatic) or after closes_at (finalize_voting_session,
-- callable by any member; the scheduler arrives in 022).
-- Valid voting: submitted >= 50% of eligible voters and >= 3 (RN-116).
-- Peer rating V per player (only from submitted ballots, only if valid):
--  3-7 ratings: median; 8+: drop one lowest and one highest, then mean; <3: none.
-- Objective D = clamp(5 + 2*goals + assists + (win +1 / draw 0 / loss -1), 0, 10).
-- Base: attacker/midfielder 0.8V + 0.2D; defender/goalkeeper V (position snapshot).
-- Final = clamp(base - 1.0 * red cards, 0, 10). Six decimals stored; rounding only on display.
-- Awards (valid voting only): Craque by Craque votes; Bola Murcha when it was
-- required; ties are shared.
-- Voter-ballot links are deleted; anonymous submitted ballots stay until season end (022).
-- Non-voters (eligible but did not submit) cannot read the detailed results (RN-034/035).
-- Stats, cards, rankings, Seleção and album hook in through after_match_finalized (014-018).

create table public.match_player_results (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null,
 session_id uuid references public.voting_sessions(id),
 membership_id uuid not null,
 numeric_rating_count integer not null default 0 check (numeric_rating_count >= 0),
 peer_rating numeric(8,6) check (peer_rating between 0 and 10),
 objective_rating numeric(8,6) not null check (objective_rating between 0 and 10),
 final_rating numeric(8,6) check (final_rating between 0 and 10),
 has_valid_rating boolean not null,
 goals integer not null check (goals >= 0),
 assists integer not null check (assists >= 0),
 red_cards integer not null check (red_cards >= 0),
 match_result text not null check (match_result in ('win','draw','loss')),
 position_snapshot text not null check (position_snapshot in ('goalkeeper','defender','midfielder','attacker')),
 formula_version integer not null,
 calculated_at timestamptz not null default now(),
 constraint result_rating_presence check (has_valid_rating = (final_rating is not null)
  and has_valid_rating = (peer_rating is not null)),
 foreign key (match_id, pelada_id) references public.matches(id, pelada_id),
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 unique (match_id, membership_id)
);
create index idx_results_membership on public.match_player_results(membership_id);

create table public.awards (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid,
 season_id uuid not null,
 membership_id uuid not null,
 award_type text not null check (award_type in
  ('match_craque','bola_murcha','monthly_king','top_scorer','top_assist','most_improved')),
 period_month date,
 votes_count integer check (votes_count >= 0),
 is_shared boolean not null default false,
 status text not null default 'active' check (status in ('active','revoked')),
 created_at timestamptz not null default now(),
 revoked_at timestamptz,
 foreign key (match_id, pelada_id) references public.matches(id, pelada_id),
 foreign key (season_id, pelada_id) references public.seasons(id, pelada_id),
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 constraint award_period check ((match_id is null) = (period_month is not null))
);
create unique index one_active_match_award on public.awards(award_type, membership_id, match_id)
 where status='active' and match_id is not null;
create unique index one_active_period_award on public.awards(pelada_id, award_type, membership_id, period_month)
 where status='active' and match_id is null;
create index idx_awards_match on public.awards(match_id);

-- RN-034/035: an eligible voter who did not submit cannot read that match's results.
create function private.can_see_match_results(p_match uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select private.is_active_member(m.pelada_id) and not exists(
  select 1 from public.voting_sessions s
  join public.voting_eligible_members e on e.session_id=s.id
  join public.pelada_memberships pm on pm.id=e.membership_id and pm.user_id=(select auth.uid())
  where s.match_id=m.id and s.status='finalized'
   and not exists(select 1 from public.vote_receipts r where r.session_id=s.id and r.membership_id=e.membership_id))
 from public.matches m where m.id=p_match;
$$;
revoke all on function private.can_see_match_results(uuid) from public,anon;
grant execute on function private.can_see_match_results(uuid) to authenticated;

alter table public.match_player_results enable row level security;
alter table public.awards enable row level security;
revoke all on public.match_player_results, public.awards from anon,authenticated;
grant select on public.match_player_results, public.awards to authenticated;
create policy results_read_voters on public.match_player_results for select to authenticated
 using ((select private.can_see_match_results(match_id)));
create policy awards_read_members on public.awards for select to authenticated
 using ((select private.is_active_member(pelada_id)));
-- No client writes.

-- (Re)computes one row per member on the sheet. p_session null = objective only.
create function private.compute_match_results(p_match uuid, p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 delete from public.match_player_results where match_id=p_match;
 insert into public.match_player_results(pelada_id,match_id,session_id,membership_id,numeric_rating_count,
  peer_rating,objective_rating,final_rating,has_valid_rating,goals,assists,red_cards,match_result,
  position_snapshot,formula_version)
 with m as (select * from public.matches where id=p_match),
 ev as (
  select participant_id,
   coalesce(sum(quantity) filter (where event_type='goal'),0)::int g,
   coalesce(sum(quantity) filter (where event_type='assist'),0)::int a,
   coalesce(sum(quantity) filter (where event_type='red_card'),0)::int rc
  from public.match_events where match_id=p_match and participant_id is not null group by participant_id),
 r as (
  select bs.target_membership_id t, count(*)::int n,
   case when count(*) between 3 and 7 then (percentile_cont(0.5) within group (order by bs.rating))::numeric
        when count(*) >= 8 then (sum(bs.rating)-min(bs.rating)-max(bs.rating))/(count(*)-2) end v
  from private.ballot_scores bs join private.secret_ballots b on b.id=bs.ballot_id
  where b.session_id=p_session and b.status='submitted' and bs.rating is not null
  group by bs.target_membership_id),
 c as (
  select p.membership_id, p.primary_position pos, coalesce(ev.g,0) g, coalesce(ev.a,0) a, coalesce(ev.rc,0) rc,
   case when (p.team='A' and m.team_a_score>m.team_b_score) or (p.team='B' and m.team_b_score>m.team_a_score) then 'win'
        when m.team_a_score=m.team_b_score then 'draw' else 'loss' end res,
   coalesce(r.n,0) n, r.v, m.pelada_id, m.formula_version
  from public.match_participants p cross join m
  left join ev on ev.participant_id=p.id
  left join r on r.t=p.membership_id
  where p.match_id=p_match and p.membership_id is not null),
 d as (
  select c.*, least(10, greatest(0, 5 + 2*g + a + case res when 'win' then 1 when 'loss' then -1 else 0 end))::numeric dv
  from c)
 select pelada_id, p_match, p_session, membership_id, n,
  case when v is not null then round(v,6) end,
  round(dv,6),
  case when v is not null then round(least(10, greatest(0,
   (case when pos in ('attacker','midfielder') then 0.8*v + 0.2*dv else v end) - 1.0*rc)),6) end,
  v is not null, g, a, rc, res, pos, formula_version
 from d;
end $$;

-- Craque and (when required) Bola Murcha from submitted ballots; ties shared.
create function private.grant_vote_awards(p_session uuid) returns void
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
   where b.session_id=p_session and b.status='submitted' and ba.award_type=t
   group by ba.target_membership_id),
  top as (select * from votes where c=(select max(c) from votes))
  select v_s.pelada_id, v_s.match_id, v_season, top.m,
   case t when 'craque' then 'match_craque' else 'bola_murcha' end, top.c, (select count(*) from top) > 1
  from top;
 end loop;
end $$;

-- Hook for 014-018 (stats, cards, rankings, Seleção, album).
create function private.after_match_finalized(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 null;
end $$;

create function private.finalize_match_without_voting(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid;
begin
 update public.matches set status='finalized', finalized_at=now() where id=p_match returning pelada_id into v_pelada;
 perform private.compute_match_results(p_match, null);
 perform private.after_match_finalized(p_match);
 insert into private.audit_events(pelada_id,event_type,metadata)
 values(v_pelada,'match_finalized',jsonb_build_object('match_id',p_match,'voting',false));
end $$;

-- Same as 010, but below the minimum it now records objective results.
create or replace function private.open_voting_session(p_match uuid, p_closes_at timestamptz,
 p_duration integer, p_fixed boolean) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c_min_voters constant integer := 6; -- RN-027: fixed, never configurable.
 v_m public.matches; v_s public.pelada_settings; v_count integer; v_id uuid;
begin
 select * into v_m from public.matches where id=p_match;
 select count(*) into v_count from private.match_voters(p_match);
 if v_count < c_min_voters then
  perform private.finalize_match_without_voting(p_match);
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

create function private.session_summary(p_session uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('session_status',s.status,'is_valid',s.is_valid,
  'submitted_count',(select count(*) from public.vote_receipts r where r.session_id=s.id),
  'eligible_voter_count',s.eligible_voter_count,
  'match_status',(select status from public.matches where id=s.match_id))
 from public.voting_sessions s where s.id=p_session;
$$;

-- Runs once; a finalized session returns its stored outcome.
create function private.finalize_session(p_session uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s public.voting_sessions; v_submitted integer; v_valid boolean;
begin
 select * into v_s from public.voting_sessions where id=p_session for update;
 if not found then raise exception 'SESSION_NOT_FOUND'; end if;
 if v_s.status='finalized' then return private.session_summary(p_session); end if;
 if v_s.status <> 'open' then raise exception 'SESSION_NOT_FINALIZABLE'; end if;
 select count(*) into v_submitted from public.vote_receipts where session_id=p_session;
 if now() < v_s.closes_at and v_submitted < v_s.eligible_voter_count then raise exception 'VOTING_STILL_OPEN'; end if;

 update public.voting_sessions set status='finalizing' where id=p_session;
 delete from private.secret_ballots where session_id=p_session and status='draft';
 v_valid := v_submitted >= 3 and v_submitted * 2 >= v_s.eligible_voter_count;
 perform private.compute_match_results(v_s.match_id, case when v_valid then p_session end);
 if v_valid then perform private.grant_vote_awards(p_session); end if;
 update public.matches set status='finalized', finalized_at=now() where id=v_s.match_id;
 update public.voting_sessions set status='finalized', finalized_at=now(), is_valid=v_valid where id=p_session;
 delete from private.ballot_voter_links where session_id=p_session;
 perform private.after_match_finalized(v_s.match_id);
 insert into private.audit_events(pelada_id,event_type,metadata)
 values(v_s.pelada_id,'match_finalized',jsonb_build_object('match_id',v_s.match_id,'voting',true,
  'session_id',p_session,'is_valid',v_valid,'submitted_count',v_submitted));
 return private.session_summary(p_session);
end $$;

-- Replaces the 012 hook: the last submission closes the voting.
create or replace function private.on_all_votes_submitted(p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 perform private.finalize_session(p_session);
end $$;

-- Any active member may trigger the closing after the deadline (idempotent).
create function public.finalize_voting_session(p_session uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.voting_sessions where id=p_session;
 if not found or not private.is_active_member(v_pelada) then raise exception 'SESSION_NOT_FOUND'; end if;
 return private.finalize_session(p_session);
end $$;

revoke all on function private.compute_match_results(uuid,uuid), private.grant_vote_awards(uuid),
 private.after_match_finalized(uuid), private.finalize_match_without_voting(uuid),
 private.session_summary(uuid), private.finalize_session(uuid) from public,anon,authenticated;
revoke all on function public.finalize_voting_session(uuid) from public,anon;
grant execute on function public.finalize_voting_session(uuid) to authenticated;
