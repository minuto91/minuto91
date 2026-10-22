-- Minuto 91 / 040: V4.3 phase 1, fixes from the V4.2 audit. Formulas and official Cards untouched.
--
-- 5.1 Privacy of draws: team_draws.input kept a copy of each player's name. Names are now read live from
--     pelada_memberships (which account deletion anonymizes), the stored copies are removed and a trigger
--     keeps names out of input forever.
-- 5.2 Stale lineups: use_lineup_in_match re-validates everything on the server (active members of the
--     pelada, current position compatible with the one recorded, no duplicates, state, rounds left,
--     staff, Pelada Premium). A lineup flagged for review is refused until revalidate_lineup (staff) is
--     called; a lineup with a member who left/was suspended must be edited or cancelled.
-- 5.3 Duel: only ACTIVE members of the same pelada (not "anything but retired").
-- 5.4 Independent draws: each round avoids the compositions already drawn in the sequence (teams A/B
--     swapped count as the same composition) whenever another valid split exists; the mandatory rules
--     (per position, total) are never relaxed. When it is impossible the draw says so (LIMITED_DIVERSITY).
-- 5.5 Seeds: official draws always use a server seed (gen_random_bytes). The seed, its source and the
--     algorithm version are stored. A manual seed exists only in private.create_team_draw_core, which the
--     app roles cannot execute (tests and audit reproduction run it as the database owner).
--
-- Position helpers used here are complete from the start (V4.3 ten positions, 041): the sector of a
-- position and the compatibility between the position recorded in a draw/lineup and the current one.

---------------------------------------------------------------------------------------------------
-- Position helpers (catalog in 041)
---------------------------------------------------------------------------------------------------

-- Sector of a position: the four legacy values map to themselves; the ten official codes to their sector.
create function private.position_sector(p text) returns text
language sql immutable set search_path = '' as $$
 select case
  when p in ('goalkeeper','defender','midfielder','attacker') then p
  when p = 'GOL' then 'goalkeeper'
  when p in ('ZAG','LD','LE') then 'defender'
  when p in ('VOL','MEI') then 'midfielder'
  when p in ('CA','PD','PE','ATA') then 'attacker' end;
$$;

-- Display/sort order: GOL, ZAG, LD, LE, VOL, MEI, CA, PD, PE, ATA; legacy groups right after their sector.
create function private.position_order(p text) returns integer
language sql immutable set search_path = '' as $$
 select coalesce(array_position(array['GOL','goalkeeper','ZAG','LD','LE','defender','VOL','MEI','midfielder',
  'CA','PD','PE','ATA','attacker'], p), 99);
$$;

-- The position a member counts with in draws and lineups (041 adds the specific position).
create function private.member_position_key(p_membership uuid) returns text
language sql stable security definer set search_path = '' as $$
 select preferred_position from public.pelada_memberships where id=p_membership;
$$;

-- Recorded position still valid for the member's current one? Equal, or a legacy group refined to a
-- specific position of the SAME sector (e.g. 'defender' -> 'ZAG', 'goalkeeper' -> 'GOL'): the player did not
-- change role, only made it precise. Anything else (other sector, other specific position) needs review.
create function private.position_compatible(p_recorded text, p_current text) returns boolean
language sql immutable set search_path = '' as $$
 select p_recorded is not distinct from p_current
  or (p_recorded in ('goalkeeper','defender','midfielder','attacker') and private.position_sector(p_current) = p_recorded);
$$;

---------------------------------------------------------------------------------------------------
-- 5.1 Privacy: no names inside team_draws.input
---------------------------------------------------------------------------------------------------

create function private.strip_names(p jsonb) returns jsonb
language sql immutable set search_path = '' as $$
 select case when jsonb_typeof(p) = 'array' then
  coalesce((select jsonb_agg(case when jsonb_typeof(x) = 'object' then x - 'name' - 'player_name' - 'display_name' else x end
   order by o) from jsonb_array_elements(p) with ordinality t(x, o)), '[]'::jsonb) else p end;
$$;

update public.team_draws set input = private.strip_names(input)
where exists(select 1 from jsonb_array_elements(input) x where x ?| array['name','player_name','display_name']);

create function private.team_draws_no_names() returns trigger
language plpgsql set search_path = '' as $$
begin
 new.input := private.strip_names(new.input);
 return new;
end $$;
create trigger team_draws_no_names before insert or update of input on public.team_draws
 for each row execute function private.team_draws_no_names();

---------------------------------------------------------------------------------------------------
-- 5.3 Duel: active members only
---------------------------------------------------------------------------------------------------

create or replace function public.get_player_duel(p_season uuid, p_a uuid, p_b uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_pelada uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 v_pelada := private.check_season_access(p_season); -- member + season the plan allows
 if not private.pelada_has_premium(v_pelada) then raise exception 'PREMIUM_REQUIRED'; end if;
 if p_a is null or p_b is null or p_a = p_b then raise exception 'DUEL_SAME_PLAYER'; end if;
 if (select count(*) from public.pelada_memberships where id in (p_a,p_b) and pelada_id=v_pelada and status='active') <> 2 then
  raise exception 'DUEL_INVALID_PLAYER'; end if;
 return jsonb_build_object('season_id', p_season,
  'season_name', (select name from public.seasons where id=p_season),
  'a', private.duel_side(p_a, p_season), 'b', private.duel_side(p_b, p_season));
end $$;

---------------------------------------------------------------------------------------------------
-- 5.4 / 5.5 Draws: server seed, diversity between independent rounds
---------------------------------------------------------------------------------------------------

alter table public.team_draws
 add column seed_source text not null default 'server' check (seed_source in ('server','manual_test')),
 add column diversity jsonb;

-- Canonical composition of a split: the sorted ids of the team that holds the smallest id (so A/B swapped
-- is the same composition).
create function private.draw_canon(p_mem uuid[], p_team text[]) returns text
language sql immutable set search_path = '' as $$
 select string_agg(m::text, ',' order by m) from unnest(p_mem, p_team) x(m, t)
 where t = (select y.t from unnest(p_mem, p_team) y(m, t) order by y.m limit 1);
$$;

-- Algorithm 2: same construction and same-position overall swaps as draw_split (039), plus avoidance of the
-- compositions in p_exclude. Among the candidates that are NOT excluded, the best by overall (random among
-- those within 1 point of it) is chosen. If every candidate is excluded (the overall optimization tends to
-- converge), single A<->B exchanges that keep rules 1 and 2 are searched from the best candidates; only when
-- none gives a new composition the plain rule of 039 applies (and the draw reports limited diversity).
create function private.draw_split_v2(p_pos text[], p_ov numeric[], p_mem uuid[], p_seed text,
 p_candidates integer default 40, p_exclude text[] default '{}') returns text[]
language plpgsql immutable set search_path = '' as $$
declare
 n integer := cardinality(p_pos); pos text[]; positions text[]; odd text[]; k integer; extra_a integer;
 t text[]; idx integer[]; c integer; half integer; sa numeric; sb numeric; cur numeric; best_new numeric;
 bi integer; bj integer; nd numeric; cand integer; results text[][] := '{}'; diffs numeric[] := '{}';
 fresh boolean[] := '{}'; best numeric; pick double precision; ok integer[]; i integer; j integer; guard integer;
 v_sel integer; t2 text[]; tt text[];
begin
 if n < 2 then raise exception 'DRAW_TOO_FEW_PLAYERS'; end if;
 if cardinality(p_mem) <> n or cardinality(p_ov) <> n then raise exception 'DRAW_INVALID_INPUT'; end if;
 pos := array(select coalesce(x, 'none') from unnest(p_pos) x);
 positions := array(select distinct x from unnest(pos) x order by 1);
 for cand in 1..p_candidates loop
  t := array_fill('B'::text, array[n]);
  odd := array(select x from unnest(positions) x where (select count(*) from unnest(pos) y where y=x) % 2 = 1
               order by private.draw_rand(p_seed, cand * 1000003 + array_position(positions, x)));
  k := coalesce(cardinality(odd), 0);
  extra_a := k / 2 + case when k % 2 = 1 and private.draw_rand(p_seed, cand * 1000033) < 0.5 then 1 else 0 end;
  foreach i in array array(select generate_subscripts(positions, 1)) loop
   idx := array(select s from generate_subscripts(pos, 1) s where pos[s] = positions[i]
                order by private.draw_rand(p_seed, cand * 1000037 + s));
   c := cardinality(idx);
   half := c / 2 + case when c % 2 = 1 and array_position(odd, positions[i]) <= extra_a then 1 else 0 end;
   for j in 1..half loop t[idx[j]] := 'A'; end loop;
  end loop;
  sa := 0; sb := 0;
  for i in 1..n loop if t[i] = 'A' then sa := sa + p_ov[i]; else sb := sb + p_ov[i]; end if; end loop;
  guard := 0;
  loop
   cur := abs(sa - sb); best_new := cur; bi := null; bj := null; guard := guard + 1;
   for i in 1..n loop
    continue when t[i] <> 'A';
    for j in 1..n loop
     continue when t[j] <> 'B' or pos[j] <> pos[i];
     nd := abs((sa - p_ov[i] + p_ov[j]) - (sb - p_ov[j] + p_ov[i]));
     if nd < best_new - 0.000001 then best_new := nd; bi := i; bj := j; end if;
    end loop;
   end loop;
   exit when bi is null or guard > 200;
   t[bi] := 'B'; t[bj] := 'A';
   sa := sa - p_ov[bi] + p_ov[bj]; sb := sb - p_ov[bj] + p_ov[bi];
  end loop;
  results := results || array[t];
  diffs := diffs || abs(sa - sb);
  fresh := fresh || not (private.draw_canon(p_mem, t) = any(coalesce(p_exclude, '{}')));
 end loop;
 if exists(select 1 from unnest(fresh) f where f) then
  best := (select min(diffs[s]) from generate_subscripts(diffs, 1) s where fresh[s]);
  ok := array(select s from generate_subscripts(diffs, 1) s where fresh[s] and diffs[s] <= best + 1 order by s);
 elsif cardinality(coalesce(p_exclude, '{}')) > 0 then
  -- Every candidate converged to a composition already used: from the 5 best candidates, try each exchange of
  -- one A player with one B player that keeps rules 1 and 2 and gives a new composition; keep the best overall.
  best := null; t2 := null;
  foreach c in array array(select s from generate_subscripts(diffs, 1) s order by diffs[s], s limit 5) loop
   t := array(select unnest(results[c:c][1:n]));
   sa := 0; sb := 0;
   for i in 1..n loop if t[i] = 'A' then sa := sa + p_ov[i]; else sb := sb + p_ov[i]; end if; end loop;
   for i in 1..n loop
    continue when t[i] <> 'A';
    for j in 1..n loop
     continue when t[j] <> 'B';
     tt := t; tt[i] := 'B'; tt[j] := 'A';
     continue when pos[i] <> pos[j] and not private.draw_balanced(p_pos, tt);
     continue when private.draw_canon(p_mem, tt) = any(p_exclude);
     nd := abs((sa - p_ov[i] + p_ov[j]) - (sb - p_ov[j] + p_ov[i]));
     if best is null or nd < best - 0.000001 then best := nd; t2 := tt; end if;
    end loop;
   end loop;
  end loop;
  if t2 is not null then
   if not private.draw_balanced(p_pos, t2) then raise exception 'DRAW_UNBALANCED'; end if;
   return t2;
  end if;
  best := (select min(d) from unnest(diffs) d);
  ok := array(select s from generate_subscripts(diffs, 1) s where diffs[s] <= best + 1 order by s);
 else
  best := (select min(d) from unnest(diffs) d);
  ok := array(select s from generate_subscripts(diffs, 1) s where diffs[s] <= best + 1 order by s);
 end if;
 pick := private.draw_rand(p_seed, 999999937);
 v_sel := ok[1 + floor(pick * cardinality(ok))::integer];
 t := array(select unnest(results[v_sel:v_sel][1:n]));
 if not private.draw_balanced(p_pos, t) then raise exception 'DRAW_UNBALANCED'; end if;
 return t;
end $$;

-- Draw as JSON. Names are read live (anonymized accounts show "Aposentado"); warnings include the review
-- flags with position compatibility, legacy positions and limited diversity.
create or replace function private.draw_json(p_draw uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('id', d.id, 'pelada_id', d.pelada_id, 'mode', d.mode, 'rounds_total', d.rounds_total,
  'status', d.status, 'seed', d.seed, 'seed_source', d.seed_source, 'algorithm_version', d.algorithm_version,
  'created_at', d.created_at, 'confirmed_at', d.confirmed_at, 'diversity', d.diversity,
  'warnings', (select coalesce(jsonb_agg(w), '[]'::jsonb) from (
    select 'ONE_GOALKEEPER' w where (select count(*) from jsonb_array_elements(d.input) x
      where private.position_sector(x->>'position')='goalkeeper') = 1
    union all select 'ODD_GOALKEEPERS' where (select count(*) from jsonb_array_elements(d.input) x
      where private.position_sector(x->>'position')='goalkeeper') in (3,5,7,9,11)
    union all select 'NO_POSITION' where exists(select 1 from jsonb_array_elements(d.input) x where x->>'position' is null)
    union all select 'LEGACY_POSITIONS' where exists(select 1 from jsonb_array_elements(d.input) x
      where x->>'position' in ('defender','midfielder','attacker'))
    union all select 'PROVISIONAL_OVERALL' where exists(select 1 from jsonb_array_elements(d.input) x where (x->>'provisional')::boolean)
    union all select 'LIMITED_DIVERSITY' where coalesce((d.diversity->>'limited')::boolean, false)
    union all select 'MEMBER_LEFT' where exists(select 1 from public.team_draw_players p join public.pelada_memberships m
      on m.id=p.membership_id where p.draw_id=d.id and m.status<>'active')
    union all select 'POSITION_CHANGED' where exists(select 1 from public.team_draw_players p
      where p.draw_id=d.id and not private.position_compatible(p.position, private.member_position_key(p.membership_id)))) ws),
  'rounds', (select coalesce(jsonb_agg(r order by (r->>'round')::int), '[]'::jsonb) from (
    select jsonb_build_object('round', p.round_number,
     'overall_a', round(sum(p.overall) filter (where p.team='A'), 2), 'overall_b', round(sum(p.overall) filter (where p.team='B'), 2),
     'team_a', jsonb_agg(jsonb_build_object('membership_id', p.membership_id, 'name', m.player_name, 'position', p.position,
        'overall', round(p.overall, 1), 'active', m.status='active') order by private.position_order(p.position), m.player_name) filter (where p.team='A'),
     'team_b', jsonb_agg(jsonb_build_object('membership_id', p.membership_id, 'name', m.player_name, 'position', p.position,
        'overall', round(p.overall, 1), 'active', m.status='active') order by private.position_order(p.position), m.player_name) filter (where p.team='B'),
     'by_position', (select jsonb_agg(jsonb_build_object('position', q.position, 'a', q.a, 'b', q.b) order by private.position_order(q.position), q.position)
        from (select coalesce(x.position, 'none') position, count(*) filter (where x.team='A') a, count(*) filter (where x.team='B') b
              from public.team_draw_players x where x.draw_id=d.id and x.round_number=p.round_number group by 1) q)) r
    from public.team_draw_players p join public.pelada_memberships m on m.id=p.membership_id
    where p.draw_id=d.id group by p.round_number) rr))
 from public.team_draws d where d.id=p_draw;
$$;

-- The draw itself. p_seed: null = server seed (the only path the app can reach); a value is accepted only
-- here, and this function is not executable by anon/authenticated.
create function private.create_team_draw_core(p_pelada uuid, p_members uuid[], p_mode text, p_rounds integer,
 p_seed text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_season uuid; v_seed text; v_input jsonb; v_pos text[]; v_ov numeric[]; v_mem uuid[];
 v_team text[]; r integer; v_keys text[] := '{}'; v_key text; v_rounds integer; v_distinct integer;
begin
 perform private.require_draw_staff(p_pelada);
 if p_mode is null or p_mode not in ('single','independent') then raise exception 'DRAW_INVALID_MODE'; end if;
 if p_rounds is null or p_rounds not between 1 and 12 then raise exception 'DRAW_INVALID_ROUNDS'; end if;
 if coalesce(cardinality(p_members), 0) < 2 then raise exception 'DRAW_TOO_FEW_PLAYERS'; end if;
 if (select count(distinct x) from unnest(p_members) x) <> cardinality(p_members) or array_position(p_members, null) is not null then
  raise exception 'DRAW_DUPLICATE_PLAYER'; end if;
 if (select count(*) from public.pelada_memberships where id = any(p_members) and pelada_id=p_pelada and status='active')
   <> cardinality(p_members) then raise exception 'DRAW_INVALID_PLAYER'; end if;

 v_season := private.season_for_date(p_pelada, private.pelada_today(p_pelada));
 v_seed := coalesce(nullif(btrim(p_seed), ''), encode(extensions.gen_random_bytes(16), 'hex'));
 -- No names in the stored input (5.1): the name is always read live.
 select jsonb_agg(jsonb_build_object('membership_id', m.id, 'position', private.member_position_key(m.id),
   'overall', o.overall, 'provisional', o.provisional) order by m.id),
  array_agg(m.id order by m.id), array_agg(private.member_position_key(m.id) order by m.id), array_agg(o.overall order by m.id)
 into v_input, v_mem, v_pos, v_ov
 from public.pelada_memberships m cross join lateral private.draw_overall(m.id, v_season) o
 where m.id = any(p_members);

 update public.team_draws set status='cancelled', cancelled_at=now() where pelada_id=p_pelada and status='draft';
 insert into public.team_draws(pelada_id,mode,rounds_total,seed,seed_source,algorithm_version,season_id,input,created_by)
 values(p_pelada,p_mode,p_rounds,v_seed,case when p_seed is null then 'server' else 'manual_test' end,2,v_season,v_input,auth.uid())
 returning id into v_id;
 v_rounds := case when p_mode='single' then 1 else p_rounds end;
 for r in 1..v_rounds loop
  v_team := private.draw_split_v2(v_pos, v_ov, v_mem, v_seed || ':' || r,
   case when p_mode='independent' then 60 else 40 end, v_keys);
  v_key := private.draw_canon(v_mem, v_team);
  v_keys := v_keys || v_key;
  insert into public.team_draw_players(draw_id,round_number,membership_id,team,position,overall)
  select v_id, r, v_mem[i], v_team[i], v_pos[i], v_ov[i] from generate_subscripts(v_mem, 1) i;
 end loop;
 v_distinct := (select count(distinct k) from unnest(v_keys) k);
 update public.team_draws set diversity = jsonb_build_object('rounds', v_rounds, 'distinct', v_distinct,
  'limited', v_distinct < v_rounds) where id=v_id;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'team_draw_created',jsonb_build_object('draw_id',v_id,'mode',p_mode,'rounds',p_rounds,
  'players',cardinality(p_members),'seed',v_seed,'seed_source',case when p_seed is null then 'server' else 'manual_test' end,
  'algorithm_version',2,'distinct',v_distinct));
 return private.draw_json(v_id);
end $$;

drop function public.create_team_draw(uuid,uuid[],text,integer,text);
create function public.create_team_draw(p_pelada uuid, p_members uuid[], p_mode text, p_rounds integer) returns jsonb
language sql security definer set search_path = '' as $$
 select private.create_team_draw_core(p_pelada, p_members, p_mode, p_rounds, null);
$$;

create or replace function public.confirm_team_draw(p_draw uuid, p_team_a_name text default null, p_team_b_name text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_d public.team_draws; v_l uuid; r integer; v_a text := coalesce(nullif(btrim(p_team_a_name),''),'Time A');
 v_b text := coalesce(nullif(btrim(p_team_b_name),''),'Time B');
begin
 select * into v_d from public.team_draws where id=p_draw;
 if not found then raise exception 'DRAW_NOT_FOUND'; end if;
 perform private.require_draw_staff(v_d.pelada_id);
 select * into v_d from public.team_draws where id=p_draw for update;
 if v_d.status='confirmed' then raise exception 'DRAW_ALREADY_CONFIRMED'; end if;
 if v_d.status='cancelled' then raise exception 'DRAW_CANCELLED'; end if;
 if length(v_a) > 40 or length(v_b) > 40 then raise exception 'INVALID_TEAM_NAME'; end if;
 if exists(select 1 from public.team_draw_players p join public.pelada_memberships m on m.id=p.membership_id
   where p.draw_id=p_draw and (m.status<>'active' or m.pelada_id<>v_d.pelada_id
    or not private.position_compatible(p.position, private.member_position_key(m.id)))) then
  raise exception 'DRAW_STALE'; end if;
 if not coalesce(private.draw_rounds_balanced(p_draw), false) then raise exception 'DRAW_UNBALANCED'; end if;

 update public.team_draws set status='confirmed', confirmed_at=now() where id=p_draw;
 for r in select distinct round_number from public.team_draw_players where draw_id=p_draw order by 1 loop
  insert into public.planned_lineups(pelada_id,draw_id,round_number,label,team_a_name,team_b_name,rounds_total,created_by)
  values(v_d.pelada_id,p_draw,r,
   case when v_d.mode='single' then 'Sorteio único · '||v_d.rounds_total||case when v_d.rounds_total=1 then ' rodada' else ' rodadas' end
        else 'Rodada '||r||' de '||v_d.rounds_total end,
   v_a,v_b,case when v_d.mode='single' then v_d.rounds_total else 1 end,auth.uid()) returning id into v_l;
  insert into public.planned_lineup_players(lineup_id,membership_id,team,position_at_creation)
  select v_l, membership_id, team, position from public.team_draw_players where draw_id=p_draw and round_number=r;
 end loop;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_d.pelada_id,auth.uid(),'team_draw_confirmed',jsonb_build_object('draw_id',p_draw));
 return private.draw_json(p_draw);
end $$;

---------------------------------------------------------------------------------------------------
-- 5.2 Lineups: server-side re-validation
---------------------------------------------------------------------------------------------------

-- Why a lineup cannot be used as it is (null = usable): a member is no longer active in the pelada
-- (MEMBER_INACTIVE: edit or cancel) or changed position since it was recorded (POSITION_CHANGED:
-- revalidate_lineup after looking at it).
create function private.lineup_review_reason(p_lineup uuid) returns text
language sql stable security definer set search_path = '' as $$
 select case
  when exists(select 1 from public.planned_lineup_players p join public.pelada_memberships m on m.id=p.membership_id
    join public.planned_lineups l on l.id=p.lineup_id
    where p.lineup_id=p_lineup and (m.status<>'active' or m.pelada_id<>l.pelada_id)) then 'MEMBER_INACTIVE'
  when exists(select 1 from public.planned_lineup_players p
    where p.lineup_id=p_lineup and not private.position_compatible(p.position_at_creation, private.member_position_key(p.membership_id)))
   then 'POSITION_CHANGED' end;
$$;

create or replace function private.lineup_json(p_lineup uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('id', l.id, 'label', l.label, 'source', case when l.draw_id is null then 'manual' else 'draw' end,
  'draw_id', l.draw_id, 'round_number', l.round_number, 'team_a_name', l.team_a_name, 'team_b_name', l.team_b_name,
  'rounds_total', l.rounds_total, 'rounds_used', l.rounds_used, 'status', l.status, 'created_at', l.created_at,
  'needs_review', private.lineup_review_reason(l.id) is not null, 'review_reason', private.lineup_review_reason(l.id),
  'players', coalesce((select jsonb_agg(jsonb_build_object('membership_id', p.membership_id, 'team', p.team, 'name', m.player_name,
     'position', private.member_position_key(m.id), 'position_at_creation', p.position_at_creation, 'active', m.status='active',
     'avatar_path', case when m.user_id is not null and not private.blocked_either_way(m.user_id)
       then (select pr.avatar_path from public.profiles pr where pr.id=m.user_id) end)
    order by p.team, private.position_order(private.member_position_key(m.id)), m.player_name)
   from public.planned_lineup_players p join public.pelada_memberships m on m.id=p.membership_id where p.lineup_id=l.id), '[]'::jsonb))
 from public.planned_lineups l where l.id=p_lineup;
$$;

-- The staff looked at a lineup whose players changed position and keeps it: positions are recorded again.
-- A lineup with a member who is no longer active cannot be revalidated (edit or cancel it).
create function public.revalidate_lineup(p_lineup uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_l public.planned_lineups;
begin
 select * into v_l from public.planned_lineups where id=p_lineup;
 if not found then raise exception 'LINEUP_INVALID'; end if;
 perform private.require_draw_staff(v_l.pelada_id);
 select * into v_l from public.planned_lineups where id=p_lineup for update;
 if v_l.status <> 'active' then raise exception 'LINEUP_INVALID'; end if;
 if private.lineup_review_reason(p_lineup) = 'MEMBER_INACTIVE' then raise exception 'DRAW_STALE'; end if;
 update public.planned_lineup_players set position_at_creation = private.member_position_key(membership_id)
 where lineup_id=p_lineup;
 update public.planned_lineups set updated_at=now() where id=p_lineup;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_l.pelada_id,auth.uid(),'lineup_revalidated',jsonb_build_object('lineup_id',p_lineup));
 return private.lineup_json(p_lineup);
end $$;

-- Opens a DRAFT sheet with the lineup's players, after re-checking everything on the server.
create or replace function public.use_lineup_in_match(p_lineup uuid, p_played_at timestamptz default now()) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_l public.planned_lineups; v_match uuid; v_reason text;
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
 update public.planned_lineups set rounds_used=rounds_used+1, updated_at=now(),
  status=case when rounds_used+1 >= rounds_total then 'used' else 'active' end where id=p_lineup;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_l.pelada_id,auth.uid(),'lineup_used',jsonb_build_object('lineup_id',p_lineup,'match_id',v_match));
 return v_match;
end $$;

revoke all on function private.position_sector(text), private.position_order(text), private.member_position_key(uuid),
 private.position_compatible(text,text), private.strip_names(jsonb), private.team_draws_no_names(),
 private.draw_canon(uuid[],text[]), private.draw_split_v2(text[],numeric[],uuid[],text,integer,text[]),
 private.create_team_draw_core(uuid,uuid[],text,integer,text), private.lineup_review_reason(uuid)
 from public, anon, authenticated;
revoke all on function public.create_team_draw(uuid,uuid[],text,integer), public.revalidate_lineup(uuid) from public, anon;
grant execute on function public.create_team_draw(uuid,uuid[],text,integer), public.revalidate_lineup(uuid) to authenticated;
