-- Minuto 91 / 042: V4.3 phase 3, tactical formations 4-3-3 and 4-4-2.
--
-- - A formation is chosen per team (A in 4-3-3 and B in 4-4-2 is fine) and only for a team with EXACTLY
--   eleven players (goalkeeper included). Smaller or larger teams keep the list by sector. No player is ever
--   invented to fill a formation and eleven players are never required to record a match.
-- - A formation only says WHERE each player appears on the field (slot). It never changes the team of a
--   player (the draw decides that) nor the registered position (a player may occupy another slot; the app
--   marks it discreetly).
-- - Slots (left to right, back to front):
--     4-3-3: GOL · LE ZAG1 ZAG2 LD · MEI1 VOL MEI2 · PE CA PD
--     4-4-2: GOL · LE ZAG1 ZAG2 LD · MEI1 VOL1 VOL2 MEI2 · CA ATA   (VOL2 = "VOL ou MEI")
-- - Persistence: formation per team, slot per player, registered position at that moment, author, time and a
--   version number (optimistic: a stale p_expected_version is refused with LINEUP_VERSION_CONFLICT). Every
--   save goes to the audit with the version.
-- - Using a lineup in a match copies the formations to match_formations. The free post-match lineup shows a
--   formation only when it was recorded and still fits the official sheet (eleven players of that team, all of
--   them in their slots); otherwise the list by sector. Old matches never get a formation.

alter table public.planned_lineups
 add column team_a_formation text check (team_a_formation in ('4-3-3','4-4-2')),
 add column team_b_formation text check (team_b_formation in ('4-3-3','4-4-2')),
 add column version integer not null default 1 check (version >= 1),
 add column updated_by uuid references public.profiles(id) on delete set null;

alter table public.planned_lineup_players add column slot text;
create unique index planned_lineup_slots on public.planned_lineup_players(lineup_id, team, slot) where slot is not null;

create table public.match_formations (
 match_id uuid not null references public.matches(id) on delete cascade,
 team text not null check (team in ('A','B')),
 formation text not null check (formation in ('4-3-3','4-4-2')),
 lineup_id uuid references public.planned_lineups(id) on delete set null,
 lineup_version integer,
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 primary key (match_id, team)
);
create table public.match_formation_slots (
 match_id uuid not null,
 team text not null,
 membership_id uuid not null references public.pelada_memberships(id),
 slot text not null,
 position_at_creation text,
 primary key (match_id, membership_id),
 unique (match_id, team, slot),
 foreign key (match_id, team) references public.match_formations(match_id, team) on delete cascade
);
alter table public.match_formations enable row level security;
alter table public.match_formation_slots enable row level security;
revoke all on public.match_formations, public.match_formation_slots from anon, authenticated;

create function private.formation_slots(p_formation text) returns text[]
language sql immutable set search_path = '' as $$
 select case p_formation
  when '4-3-3' then array['GOL','LE','ZAG1','ZAG2','LD','MEI1','VOL','MEI2','PE','CA','PD']
  when '4-4-2' then array['GOL','LE','ZAG1','ZAG2','LD','MEI1','VOL1','VOL2','MEI2','CA','ATA'] end;
$$;

-- Validates and writes the formations and slots of a lineup (players already saved). p_slots:
-- [{membership_id, slot}] for the teams that have a formation. Raises LINEUP_FORMATION_SIZE (team without
-- exactly 11), LINEUP_FORMATION_INVALID (unknown formation) or LINEUP_SLOTS_INVALID.
create function private.apply_lineup_formation(p_lineup uuid, p_fa text, p_fb text, p_slots jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare v_team text; v_f text; v_given jsonb;
begin
 if (p_fa is not null and p_fa not in ('4-3-3','4-4-2')) or (p_fb is not null and p_fb not in ('4-3-3','4-4-2')) then
  raise exception 'LINEUP_FORMATION_INVALID'; end if;
 if p_slots is not null and jsonb_typeof(p_slots) <> 'array' then raise exception 'LINEUP_SLOTS_INVALID'; end if;
 update public.planned_lineup_players set slot=null where lineup_id=p_lineup;
 foreach v_team in array array['A','B'] loop
  v_f := case v_team when 'A' then p_fa else p_fb end;
  v_given := coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(p_slots,'[]')) x
    where (x->>'membership_id') in (select membership_id::text from public.planned_lineup_players where lineup_id=p_lineup and team=v_team)), '[]');
  if v_f is null then
   if jsonb_array_length(v_given) > 0 then raise exception 'LINEUP_SLOTS_INVALID'; end if;
   continue;
  end if;
  if (select count(*) from public.planned_lineup_players where lineup_id=p_lineup and team=v_team) <> 11 then
   raise exception 'LINEUP_FORMATION_SIZE'; end if;
  -- eleven entries, eleven distinct players of the team, the eleven slots of the formation
  if jsonb_array_length(v_given) <> 11
    or (select count(distinct x->>'membership_id') from jsonb_array_elements(v_given) x) <> 11
    or (select array_agg(x->>'slot' order by x->>'slot') from jsonb_array_elements(v_given) x)
       is distinct from (select array_agg(s order by s) from unnest(private.formation_slots(v_f)) s) then
   raise exception 'LINEUP_SLOTS_INVALID'; end if;
  update public.planned_lineup_players p set slot = x->>'slot'
  from jsonb_array_elements(v_given) x where p.lineup_id=p_lineup and p.membership_id=(x->>'membership_id')::uuid;
 end loop;
 -- every slot in p_slots must belong to a player of this lineup
 if exists(select 1 from jsonb_array_elements(coalesce(p_slots,'[]')) x where not exists(
   select 1 from public.planned_lineup_players p where p.lineup_id=p_lineup and p.membership_id::text = x->>'membership_id')) then
  raise exception 'LINEUP_SLOTS_INVALID'; end if;
 update public.planned_lineups set team_a_formation=p_fa, team_b_formation=p_fb where id=p_lineup;
end $$;

create or replace function private.lineup_json(p_lineup uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('id', l.id, 'label', l.label, 'source', case when l.draw_id is null then 'manual' else 'draw' end,
  'draw_id', l.draw_id, 'round_number', l.round_number, 'team_a_name', l.team_a_name, 'team_b_name', l.team_b_name,
  'team_a_formation', l.team_a_formation, 'team_b_formation', l.team_b_formation, 'version', l.version,
  'rounds_total', l.rounds_total, 'rounds_used', l.rounds_used, 'status', l.status, 'created_at', l.created_at,
  'updated_at', l.updated_at,
  'needs_review', private.lineup_review_reason(l.id) is not null, 'review_reason', private.lineup_review_reason(l.id),
  'players', coalesce((select jsonb_agg(jsonb_build_object('membership_id', p.membership_id, 'team', p.team, 'name', m.player_name,
     'position', private.member_position_key(m.id), 'position_at_creation', p.position_at_creation, 'slot', p.slot,
     'active', m.status='active',
     'avatar_path', case when m.user_id is not null and not private.blocked_either_way(m.user_id)
       then (select pr.avatar_path from public.profiles pr where pr.id=m.user_id) end)
    order by p.team, private.position_order(private.member_position_key(m.id)), m.player_name)
   from public.planned_lineup_players p join public.pelada_memberships m on m.id=p.membership_id where p.lineup_id=l.id), '[]'::jsonb))
 from public.planned_lineups l where l.id=p_lineup;
$$;

-- Manual lineup (new or edit of a manual one), with optional formations. Position balance is only a warning
-- in the app (V4.2); the draw rules apply to the automatic draw.
drop function public.save_lineup(uuid,uuid,text,uuid[],uuid[],text,text);
create function public.save_lineup(p_pelada uuid, p_lineup uuid, p_label text, p_team_a uuid[], p_team_b uuid[],
 p_team_a_name text default null, p_team_b_name text default null, p_team_a_formation text default null,
 p_team_b_formation text default null, p_slots jsonb default null, p_expected_version integer default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_l public.planned_lineups; v_label text := coalesce(nullif(btrim(p_label),''),'Escalação');
 v_a text := coalesce(nullif(btrim(p_team_a_name),''),'Time A'); v_b text := coalesce(nullif(btrim(p_team_b_name),''),'Time B');
 v_all uuid[] := coalesce(p_team_a,'{}') || coalesce(p_team_b,'{}');
begin
 perform private.require_draw_staff(p_pelada);
 if coalesce(cardinality(p_team_a),0) < 1 or coalesce(cardinality(p_team_b),0) < 1
   or (select count(distinct x) from unnest(v_all) x) <> cardinality(v_all) or array_position(v_all, null) is not null
   or (select count(*) from public.pelada_memberships where id = any(v_all) and pelada_id=p_pelada and status='active') <> cardinality(v_all)
   or length(v_label) > 60 or length(v_a) > 40 or length(v_b) > 40 then
  raise exception 'LINEUP_INVALID'; end if;
 if p_lineup is null then
  insert into public.planned_lineups(pelada_id,label,team_a_name,team_b_name,created_by,updated_by)
  values(p_pelada,v_label,v_a,v_b,auth.uid(),auth.uid()) returning * into v_l;
 else
  select * into v_l from public.planned_lineups where id=p_lineup and pelada_id=p_pelada and status='active' and draw_id is null for update;
  if not found then raise exception 'LINEUP_INVALID'; end if;
  if p_expected_version is not null and p_expected_version <> v_l.version then raise exception 'LINEUP_VERSION_CONFLICT'; end if;
  update public.planned_lineups set label=v_label, team_a_name=v_a, team_b_name=v_b, updated_at=now(),
   version=version+1, updated_by=auth.uid() where id=v_l.id returning * into v_l;
  delete from public.planned_lineup_players where lineup_id=v_l.id;
 end if;
 insert into public.planned_lineup_players(lineup_id,membership_id,team,position_at_creation)
 select v_l.id, m.id, case when m.id = any(p_team_a) then 'A' else 'B' end, private.member_position_key(m.id)
 from public.pelada_memberships m where m.id = any(v_all);
 perform private.apply_lineup_formation(v_l.id, p_team_a_formation, p_team_b_formation, p_slots);
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'lineup_saved',jsonb_build_object('lineup_id',v_l.id,'version',v_l.version,
  'formation_a',p_team_a_formation,'formation_b',p_team_b_formation));
 return private.lineup_json(v_l.id);
end $$;

-- Formations of any active lineup (manual or from a draw). Never changes who plays in each team.
create function public.set_lineup_formation(p_lineup uuid, p_team_a_formation text, p_team_b_formation text,
 p_slots jsonb, p_expected_version integer default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_l public.planned_lineups;
begin
 select * into v_l from public.planned_lineups where id=p_lineup;
 if not found then raise exception 'LINEUP_INVALID'; end if;
 perform private.require_draw_staff(v_l.pelada_id);
 select * into v_l from public.planned_lineups where id=p_lineup for update;
 if v_l.status <> 'active' then raise exception 'LINEUP_INVALID'; end if;
 if p_expected_version is not null and p_expected_version <> v_l.version then raise exception 'LINEUP_VERSION_CONFLICT'; end if;
 perform private.apply_lineup_formation(p_lineup, p_team_a_formation, p_team_b_formation, p_slots);
 update public.planned_lineups set version=version+1, updated_at=now(), updated_by=auth.uid() where id=p_lineup returning * into v_l;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_l.pelada_id,auth.uid(),'lineup_formation_saved',jsonb_build_object('lineup_id',p_lineup,'version',v_l.version,
  'formation_a',p_team_a_formation,'formation_b',p_team_b_formation));
 return private.lineup_json(p_lineup);
end $$;

-- Same server checks as 040, and the formations go with the draft sheet.
create or replace function public.use_lineup_in_match(p_lineup uuid, p_played_at timestamptz default now()) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_l public.planned_lineups; v_match uuid; v_reason text; v_team text; v_f text;
begin
 select * into v_l from public.planned_lineups where id=p_lineup;
 if not found then raise exception 'LINEUP_INVALID'; end if;
 perform private.require_draw_staff(v_l.pelada_id);
 select * into v_l from public.planned_lineups where id=p_lineup for update;
 if v_l.status <> 'active' or v_l.rounds_used >= v_l.rounds_total then raise exception 'LINEUP_INVALID'; end if;
 v_reason := private.lineup_review_reason(p_lineup);
 if v_reason = 'MEMBER_INACTIVE' then raise exception 'DRAW_STALE'; end if;
 if v_reason = 'POSITION_CHANGED' then raise exception 'LINEUP_NEEDS_REVIEW'; end if;
 if not exists(select 1 from public.planned_lineup_players where lineup_id=p_lineup and team='A')
   or not exists(select 1 from public.planned_lineup_players where lineup_id=p_lineup and team='B') then
  raise exception 'LINEUP_INVALID'; end if;
 v_match := public.create_match(v_l.pelada_id, p_played_at, v_l.team_a_name, v_l.team_b_name);
 perform public.save_match_sheet(v_match,
  (select jsonb_agg(jsonb_build_object('membership_id', membership_id, 'team', team)) from public.planned_lineup_players where lineup_id=p_lineup),
  '[]'::jsonb);
 foreach v_team in array array['A','B'] loop
  v_f := case v_team when 'A' then v_l.team_a_formation else v_l.team_b_formation end;
  continue when v_f is null;
  insert into public.match_formations(match_id,team,formation,lineup_id,lineup_version,created_by)
  values(v_match,v_team,v_f,p_lineup,v_l.version,auth.uid());
  insert into public.match_formation_slots(match_id,team,membership_id,slot,position_at_creation)
  select v_match, v_team, membership_id, slot, position_at_creation from public.planned_lineup_players
  where lineup_id=p_lineup and team=v_team and slot is not null;
 end loop;
 update public.planned_lineups set rounds_used=rounds_used+1, updated_at=now(),
  status=case when rounds_used+1 >= rounds_total then 'used' else 'active' end where id=p_lineup;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_l.pelada_id,auth.uid(),'lineup_used',jsonb_build_object('lineup_id',p_lineup,'match_id',v_match,'version',v_l.version));
 return v_match;
end $$;

-- A recorded formation still fits the official sheet of the match?
create function private.match_formation_valid(p_match uuid, p_team text) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.match_formations f where f.match_id=p_match and f.team=p_team)
  and (select count(*) from public.match_participants p where p.match_id=p_match and p.team=p_team) = 11
  and (select count(*) from public.match_formation_slots s join public.match_participants p
       on p.match_id=s.match_id and p.membership_id=s.membership_id and p.team=s.team
       where s.match_id=p_match and s.team=p_team) = 11;
$$;

-- Free post-match lineup: official sheet, specific positions when recorded, formation when recorded and valid.
create or replace function public.get_match_lineup(p_match uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_m public.matches;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match;
 if not found or not private.is_active_member(v_m.pelada_id) or v_m.status='draft' then raise exception 'MATCH_NOT_FOUND'; end if;
 return jsonb_build_object('match_id', v_m.id, 'played_at', v_m.played_at, 'status', v_m.status,
  'team_a_name', v_m.team_a_name, 'team_b_name', v_m.team_b_name,
  'team_a_score', v_m.team_a_score, 'team_b_score', v_m.team_b_score,
  'team_a_formation', case when private.match_formation_valid(v_m.id,'A') then
    (select formation from public.match_formations where match_id=v_m.id and team='A') end,
  'team_b_formation', case when private.match_formation_valid(v_m.id,'B') then
    (select formation from public.match_formations where match_id=v_m.id and team='B') end,
  'players', coalesce((select jsonb_agg(jsonb_build_object('team', p.team, 'membership_id', p.membership_id,
     'guest', p.guest_id is not null, 'name', coalesce(m.player_name, g.display_name, 'Jogador'),
     'position', coalesce(p.position_code, p.primary_position),
     'slot', case when private.match_formation_valid(v_m.id, p.team) then s.slot end,
     'avatar_path', case when m.user_id is not null and not private.blocked_either_way(m.user_id)
       then (select pr.avatar_path from public.profiles pr where pr.id=m.user_id) end)
    order by p.team, private.position_order(coalesce(p.position_code, p.primary_position)), coalesce(m.player_name, g.display_name))
   from public.match_participants p
   left join public.pelada_memberships m on m.id=p.membership_id
   left join public.guests g on g.id=p.guest_id
   left join public.match_formation_slots s on s.match_id=p.match_id and s.membership_id=p.membership_id and s.team=p.team
   where p.match_id=v_m.id), '[]'::jsonb));
end $$;

revoke all on function private.formation_slots(text), private.apply_lineup_formation(uuid,text,text,jsonb),
 private.match_formation_valid(uuid,text) from public, anon, authenticated;
revoke all on function public.save_lineup(uuid,uuid,text,uuid[],uuid[],text,text,text,text,jsonb,integer),
 public.set_lineup_formation(uuid,text,text,jsonb,integer) from public, anon;
grant execute on function public.save_lineup(uuid,uuid,text,uuid[],uuid[],text,text,text,text,jsonb,integer),
 public.set_lineup_formation(uuid,text,text,jsonb,integer) to authenticated;
