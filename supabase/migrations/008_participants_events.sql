-- Minuto 91 / 008: guests, match participants and events (Doc 02 RN-003/RN-014..017,
-- Doc 03 sec. 8-9, Doc 04 sec. 13-15).
-- The match sheet is written in one call (save_match_sheet) while the match is a
-- draft; corrections after publication arrive with versioning (009).
-- The score is ALWAYS derived from the events (goal + own_goal + unattributed_goal
-- of each benefiting team), so score and events cannot disagree (RN-015).
-- A member's position is a snapshot of the profile position at the time of the
-- sheet; a guest's position is informed on the sheet. Guests have no account,
-- card, vote or stickers; the admin/assistant declares they are 18+.

create table public.guests (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 display_name text not null check (length(btrim(display_name)) between 1 and 80),
 -- 18+ declaration made by the admin/assistant who registered the guest.
 adult_declared_at timestamptz not null,
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 unique (id, pelada_id)
);
create index guests_by_pelada on public.guests(pelada_id);

create table public.match_participants (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null,
 membership_id uuid,
 guest_id uuid,
 team text not null,
 primary_position text not null,
 created_at timestamptz not null default now(),
 constraint participant_team_check check (team in ('A','B')),
 constraint participant_position_check check (primary_position in ('goalkeeper','defender','midfielder','attacker')),
 constraint participant_identity_check check ((membership_id is null) <> (guest_id is null)),
 foreign key (match_id, pelada_id) references public.matches(id, pelada_id) on delete cascade,
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 foreign key (guest_id, pelada_id) references public.guests(id, pelada_id),
 unique (id, match_id)
);
-- One row per person and match => one official team per person (Doc 03 9.5).
create unique index one_member_per_match on public.match_participants(match_id, membership_id) where membership_id is not null;
create unique index one_guest_per_match on public.match_participants(match_id, guest_id) where guest_id is not null;
create index idx_match_participants_match on public.match_participants(match_id);
create index idx_match_participants_membership on public.match_participants(membership_id) where membership_id is not null;

create table public.match_events (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null,
 participant_id uuid,
 -- Team that benefits (goals) or the participant's team (assist, red card).
 team text not null check (team in ('A','B')),
 event_type text not null check (event_type in ('goal','assist','own_goal','red_card','unattributed_goal')),
 quantity integer not null check (quantity between 1 and 99),
 created_at timestamptz not null default now(),
 -- Unattributed goals never point to a player; own goal author is optional.
 constraint event_participant_check check (case event_type
  when 'unattributed_goal' then participant_id is null
  when 'own_goal' then true
  else participant_id is not null end),
 foreign key (match_id, pelada_id) references public.matches(id, pelada_id) on delete cascade,
 -- The participant must belong to the same match.
 foreign key (participant_id, match_id) references public.match_participants(id, match_id) on delete cascade
);
-- Events are aggregated: one row per (participant, type) or (team, type) when unattributed.
create unique index one_event_per_participant on public.match_events(match_id, participant_id, event_type) where participant_id is not null;
create unique index one_team_event on public.match_events(match_id, team, event_type) where participant_id is null;
create index idx_match_events_match on public.match_events(match_id);

alter table public.guests enable row level security;
alter table public.match_participants enable row level security;
alter table public.match_events enable row level security;
revoke all on public.guests, public.match_participants, public.match_events from anon,authenticated;
grant select on public.guests, public.match_participants, public.match_events to authenticated;
create policy guests_read_members on public.guests for select to authenticated
 using ((select private.is_active_member(pelada_id)));
-- Visible exactly when the match is visible (matches RLS hides drafts from players).
create policy participants_read_with_match on public.match_participants for select to authenticated
 using (exists(select 1 from public.matches m where m.id=match_id));
create policy events_read_with_match on public.match_events for select to authenticated
 using (exists(select 1 from public.matches m where m.id=match_id));
-- No client INSERT/UPDATE/DELETE: only the RPCs below write.

create function public.create_guest(p_pelada uuid, p_name text, p_adult_declared boolean) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_name text := nullif(btrim(p_name),''); v_id uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.is_active_staff(p_pelada) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 if v_name is null or length(v_name) > 80 then raise exception 'INVALID_NAME'; end if;
 if p_adult_declared is distinct from true then raise exception 'ADULT_DECLARATION_REQUIRED'; end if;
 insert into public.guests(pelada_id,display_name,adult_declared_at,created_by)
 values(p_pelada,v_name,now(),auth.uid()) returning id into v_id;
 return v_id;
end $$;

-- Replaces the whole sheet of a draft match.
-- p_participants: [{"membership_id": uuid, "team": "A"|"B"}
--                  | {"guest_id": uuid, "team": "A"|"B", "position": "..."}]
-- p_events: [{"membership_id"|"guest_id": uuid (optional), "type": "...",
--             "quantity": n, "team": "A"|"B" (only for goals without a player)}]
-- Returns {"team_a_score": n, "team_b_score": n}.
create function public.save_match_sheet(p_match uuid, p_participants jsonb, p_events jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; e jsonb; v_mem uuid; v_guest uuid; v_team text; v_pos text;
 v_type text; v_qty int; v_part public.match_participants; v_a int; v_b int;
begin
 v_m := private.lock_match_draft(p_match);
 if jsonb_typeof(coalesce(p_participants,'[]')) <> 'array' or jsonb_typeof(coalesce(p_events,'[]')) <> 'array' then
  raise exception 'INVALID_SHEET'; end if;
 delete from public.match_events where match_id=p_match;
 delete from public.match_participants where match_id=p_match;

 begin
  for e in select * from jsonb_array_elements(coalesce(p_participants,'[]')) loop
   v_mem := (e->>'membership_id')::uuid; v_guest := (e->>'guest_id')::uuid; v_team := e->>'team';
   if (v_mem is null) = (v_guest is null) then raise exception 'INVALID_PARTICIPANT'; end if;
   if v_team is null or v_team not in ('A','B') then raise exception 'INVALID_TEAM'; end if;
   if v_mem is not null then
    select preferred_position into v_pos from public.pelada_memberships
    where id=v_mem and pelada_id=v_m.pelada_id and status='active';
    if not found then raise exception 'INVALID_PARTICIPANT'; end if;
   else
    if not exists(select 1 from public.guests where id=v_guest and pelada_id=v_m.pelada_id) then
     raise exception 'INVALID_PARTICIPANT'; end if;
    v_pos := e->>'position';
    if not private.valid_position(v_pos) then raise exception 'INVALID_POSITION'; end if;
   end if;
   insert into public.match_participants(pelada_id,match_id,membership_id,guest_id,team,primary_position)
   values(v_m.pelada_id,p_match,v_mem,v_guest,v_team,v_pos);
  end loop;

  for e in select * from jsonb_array_elements(coalesce(p_events,'[]')) loop
   v_mem := (e->>'membership_id')::uuid; v_guest := (e->>'guest_id')::uuid;
   v_type := e->>'type'; v_qty := (e->>'quantity')::int; v_team := e->>'team';
   if v_type is null or v_type not in ('goal','assist','own_goal','red_card','unattributed_goal') then
    raise exception 'INVALID_EVENT'; end if;
   if v_qty is null or v_qty not between 1 and 99 then raise exception 'INVALID_EVENT'; end if;
   v_part := null;
   if v_mem is not null or v_guest is not null then
    if v_mem is not null and v_guest is not null then raise exception 'INVALID_EVENT'; end if;
    select * into v_part from public.match_participants where match_id=p_match
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
   values(v_m.pelada_id,p_match,v_part.id,v_team,v_type,v_qty);
  end loop;
 exception
  when unique_violation then raise exception 'DUPLICATE_IN_SHEET';
  when invalid_text_representation then raise exception 'INVALID_SHEET';
 end;

 -- Assists can never exceed the goals scored by the team's players and unattributed goals.
 if exists(select 1 from (values ('A'),('B')) t(team) where
   coalesce((select sum(quantity) from public.match_events where match_id=p_match and team=t.team and event_type='assist'),0)
   > coalesce((select sum(quantity) from public.match_events where match_id=p_match and team=t.team
       and event_type in ('goal','unattributed_goal')),0)) then
  raise exception 'ASSISTS_EXCEED_GOALS'; end if;

 select coalesce(sum(quantity) filter (where team='A'),0), coalesce(sum(quantity) filter (where team='B'),0)
 into v_a, v_b from public.match_events
 where match_id=p_match and event_type in ('goal','own_goal','unattributed_goal');
 update public.matches set team_a_score=v_a, team_b_score=v_b where id=p_match;
 return jsonb_build_object('team_a_score',v_a,'team_b_score',v_b);
end $$;

revoke all on function public.create_guest(uuid,text,boolean), public.save_match_sheet(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.create_guest(uuid,text,boolean), public.save_match_sheet(uuid,jsonb,jsonb) to authenticated;
