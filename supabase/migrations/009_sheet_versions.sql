-- Minuto 91 / 009: match sheet versioning (Doc 02 RN-022..025 / RN-111, Doc 03 sec. 10,
-- Doc 04 sec. 16).
-- Convention: match_versions.snapshot is the sheet AFTER the change, and
-- version_number equals matches.sheet_version at that moment. Version 1 is the sheet
-- as published (recorded by the publication in 010, or lazily on the first correction).
-- Previous values of a correction = snapshot of the previous version.
-- Corrections: admin/assistant, only while voting is open, reason required, never
-- silent (no-op corrections are refused). After finalization the sheet is locked;
-- errors go through annulment (020).
-- Participant rows are now updated in place (stable ids), so ballots attached to
-- them in 010+ survive a correction. A member keeps the position snapshot taken when
-- first put on the sheet; a member already on the sheet stays valid even after
-- leaving the pelada.

create table public.match_versions (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null,
 version_number integer not null check (version_number >= 1),
 changed_by uuid references public.profiles(id) on delete set null,
 change_reason text check (change_reason is null or length(btrim(change_reason)) between 3 and 500),
 snapshot jsonb not null,
 eligible_voters_changed boolean not null default false,
 created_at timestamptz not null default now(),
 foreign key (match_id, pelada_id) references public.matches(id, pelada_id) on delete cascade,
 unique (match_id, version_number)
);
alter table public.match_versions enable row level security;
revoke all on public.match_versions from anon,authenticated;
grant select on public.match_versions to authenticated;
create policy versions_read_with_match on public.match_versions for select to authenticated
 using (exists(select 1 from public.matches m where m.id=match_id));
-- No client writes.

-- Canonical, order-stable picture of the sheet (ids only, no names).
create function private.sheet_snapshot(p_match uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object(
  'played_at', m.played_at, 'team_a_name', m.team_a_name, 'team_b_name', m.team_b_name,
  'team_a_score', m.team_a_score, 'team_b_score', m.team_b_score,
  'participants', coalesce((select jsonb_agg(jsonb_build_object('membership_id',p.membership_id,
     'guest_id',p.guest_id,'team',p.team,'position',p.primary_position)
     order by p.membership_id, p.guest_id)
    from public.match_participants p where p.match_id=m.id), '[]'::jsonb),
  'events', coalesce((select jsonb_agg(jsonb_build_object('membership_id',p.membership_id,
     'guest_id',p.guest_id,'team',e.team,'type',e.event_type,'quantity',e.quantity)
     order by e.event_type, e.team, p.membership_id, p.guest_id)
    from public.match_events e left join public.match_participants p on p.id=e.participant_id
    where e.match_id=m.id), '[]'::jsonb))
 from public.matches m where m.id=p_match;
$$;

-- Members on the sheet who could vote (authenticated account, active). 010 may refine.
create function private.sheet_voter_memberships(p_match uuid) returns uuid[]
language sql stable security definer set search_path = '' as $$
 select coalesce(array_agg(p.membership_id order by p.membership_id), '{}')
 from public.match_participants p join public.pelada_memberships m on m.id=p.membership_id
 where p.match_id=p_match and m.user_id is not null and m.status='active';
$$;

-- Hook for the voting stages: invalidate confirmations, extend closes_at (RN-023)
-- and restart the session when the voters changed. Replaced in 010/012.
create function private.on_sheet_corrected(p_match uuid, p_voters_changed boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
 null;
end $$;

-- Writes participants (in place) and events; recomputes the score. Caller locks.
create function private.write_match_sheet(p_m public.matches, p_participants jsonb, p_events jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e jsonb; v_mem uuid; v_guest uuid; v_team text; v_pos text; v_type text; v_qty int;
 v_part public.match_participants; v_id uuid; v_keep uuid[] := '{}'; v_a int; v_b int;
begin
 if jsonb_typeof(coalesce(p_participants,'[]')) <> 'array' or jsonb_typeof(coalesce(p_events,'[]')) <> 'array' then
  raise exception 'INVALID_SHEET'; end if;
 delete from public.match_events where match_id=p_m.id;

 begin
  for e in select * from jsonb_array_elements(coalesce(p_participants,'[]')) loop
   v_mem := (e->>'membership_id')::uuid; v_guest := (e->>'guest_id')::uuid; v_team := e->>'team';
   if (v_mem is null) = (v_guest is null) then raise exception 'INVALID_PARTICIPANT'; end if;
   if v_team is null or v_team not in ('A','B') then raise exception 'INVALID_TEAM'; end if;
   select id into v_id from public.match_participants
   where match_id=p_m.id and (membership_id=v_mem or guest_id=v_guest);
   if found and v_id = any(v_keep) then raise exception 'DUPLICATE_IN_SHEET'; end if;
   if v_guest is not null then
    if not exists(select 1 from public.guests where id=v_guest and pelada_id=p_m.pelada_id) then
     raise exception 'INVALID_PARTICIPANT'; end if;
    v_pos := e->>'position';
    if not private.valid_position(v_pos) then raise exception 'INVALID_POSITION'; end if;
   elsif v_id is null then
    -- New member on the sheet: must be active now; position snapshot from the profile.
    select preferred_position into v_pos from public.pelada_memberships
    where id=v_mem and pelada_id=p_m.pelada_id and status='active';
    if not found then raise exception 'INVALID_PARTICIPANT'; end if;
   end if;
   if v_id is not null then
    update public.match_participants set team=v_team,
     primary_position=case when guest_id is not null then v_pos else primary_position end
    where id=v_id;
   else
    insert into public.match_participants(pelada_id,match_id,membership_id,guest_id,team,primary_position)
    values(p_m.pelada_id,p_m.id,v_mem,v_guest,v_team,v_pos) returning id into v_id;
   end if;
   v_keep := v_keep || v_id;
   v_id := null;
  end loop;
  delete from public.match_participants where match_id=p_m.id and not (id = any(v_keep));

  for e in select * from jsonb_array_elements(coalesce(p_events,'[]')) loop
   v_mem := (e->>'membership_id')::uuid; v_guest := (e->>'guest_id')::uuid;
   v_type := e->>'type'; v_qty := (e->>'quantity')::int; v_team := e->>'team';
   if v_type is null or v_type not in ('goal','assist','own_goal','red_card','unattributed_goal') then
    raise exception 'INVALID_EVENT'; end if;
   if v_qty is null or v_qty not between 1 and 99 then raise exception 'INVALID_EVENT'; end if;
   v_part := null;
   if v_mem is not null or v_guest is not null then
    if v_mem is not null and v_guest is not null then raise exception 'INVALID_EVENT'; end if;
    select * into v_part from public.match_participants where match_id=p_m.id
     and (membership_id=v_mem or guest_id=v_guest);
    if not found then raise exception 'EVENT_PARTICIPANT_NOT_IN_MATCH'; end if;
   end if;
   if v_type='unattributed_goal' then
    if v_part.id is not null then raise exception 'INVALID_EVENT'; end if;
   elsif v_type='own_goal' then
    -- Own goal counts for the other team; the author is optional.
    if v_part.id is not null then v_team := case v_part.team when 'A' then 'B' else 'A' end; end if;
   else
    if v_part.id is null then raise exception 'INVALID_EVENT'; end if;
    v_team := v_part.team;
   end if;
   if v_team is null or v_team not in ('A','B') then raise exception 'INVALID_TEAM'; end if;
   insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
   values(p_m.pelada_id,p_m.id,v_part.id,v_team,v_type,v_qty);
  end loop;
 exception
  when unique_violation then raise exception 'DUPLICATE_IN_SHEET';
  when invalid_text_representation then raise exception 'INVALID_SHEET';
 end;

 -- Assists can never exceed the goals scored by the team's players and unattributed goals.
 if exists(select 1 from (values ('A'),('B')) t(team) where
   coalesce((select sum(quantity) from public.match_events where match_id=p_m.id and team=t.team and event_type='assist'),0)
   > coalesce((select sum(quantity) from public.match_events where match_id=p_m.id and team=t.team
       and event_type in ('goal','unattributed_goal')),0)) then
  raise exception 'ASSISTS_EXCEED_GOALS'; end if;

 select coalesce(sum(quantity) filter (where team='A'),0), coalesce(sum(quantity) filter (where team='B'),0)
 into v_a, v_b from public.match_events
 where match_id=p_m.id and event_type in ('goal','own_goal','unattributed_goal');
 update public.matches set team_a_score=v_a, team_b_score=v_b where id=p_m.id;
 return jsonb_build_object('team_a_score',v_a,'team_b_score',v_b);
end $$;

-- Draft sheet (same contract as 008), now through the shared writer.
create or replace function public.save_match_sheet(p_match uuid, p_participants jsonb, p_events jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches;
begin
 v_m := private.lock_match_draft(p_match);
 return private.write_match_sheet(v_m, p_participants, p_events);
end $$;

-- Correction while voting is open. Same JSON contract as save_match_sheet.
-- Returns scores + {"sheet_version": n, "eligible_voters_changed": bool}.
create function public.correct_match_sheet(p_match uuid, p_participants jsonb, p_events jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_m public.matches; v_reason text := nullif(btrim(p_reason),'');
 v_before jsonb; v_after jsonb; v_old uuid[]; v_changed boolean; v_r jsonb; v_version int;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_pelada for update;
 if not private.is_active_staff(v_pelada) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match for update;
 if v_m.status='draft' then raise exception 'MATCH_IS_DRAFT'; end if;
 if v_m.status <> 'voting_open' then raise exception 'SHEET_LOCKED'; end if;
 if v_reason is null or length(v_reason) not between 3 and 500 then raise exception 'REASON_REQUIRED'; end if;

 v_before := private.sheet_snapshot(p_match);
 if not exists(select 1 from public.match_versions where match_id=p_match and version_number=v_m.sheet_version) then
  insert into public.match_versions(pelada_id,match_id,version_number,snapshot)
  values(v_pelada,p_match,v_m.sheet_version,v_before);
 end if;
 v_old := private.sheet_voter_memberships(p_match);

 v_r := private.write_match_sheet(v_m, p_participants, p_events);
 v_after := private.sheet_snapshot(p_match);
 if v_after = v_before then raise exception 'NO_CHANGES'; end if;
 v_changed := v_old is distinct from private.sheet_voter_memberships(p_match);

 update public.matches set sheet_version=sheet_version+1 where id=p_match returning sheet_version into v_version;
 insert into public.match_versions(pelada_id,match_id,version_number,changed_by,change_reason,snapshot,eligible_voters_changed)
 values(v_pelada,p_match,v_version,auth.uid(),v_reason,v_after,v_changed);
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_pelada,auth.uid(),'match_sheet_corrected',jsonb_build_object(
  'match_id',p_match,'sheet_version',v_version,'eligible_voters_changed',v_changed));
 perform private.on_sheet_corrected(p_match, v_changed);
 return v_r || jsonb_build_object('sheet_version',v_version,'eligible_voters_changed',v_changed);
end $$;

revoke all on function private.sheet_snapshot(uuid), private.sheet_voter_memberships(uuid),
 private.on_sheet_corrected(uuid,boolean), private.write_match_sheet(public.matches,jsonb,jsonb)
 from public,anon,authenticated;
revoke all on function public.correct_match_sheet(uuid,jsonb,jsonb,text) from public,anon;
grant execute on function public.correct_match_sheet(uuid,jsonb,jsonb,text) to authenticated;
