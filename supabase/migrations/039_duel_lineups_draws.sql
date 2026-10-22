-- Minuto 91 / 039: V4.2 new features. Formulas and official Cards untouched.
--
-- 1) Duelo de Jogadores (Pelada Premium): get_player_duel compares two members of the same pelada in a
--    season the caller can open, using only official data (Card, season statistics, Craque awards).
--    Missing data stays null (never estimated). Photos follow the blocks (no photo across a block).
-- 2) Escalação visual:
--    - after the match (free): get_match_lineup reads the official sheet of a published match;
--    - before the match (Pelada Premium): planned_lineups, made by hand or from a confirmed draw. A
--      lineup never becomes a finalized match by itself: use_lineup_in_match only opens a DRAFT sheet
--      with those players, which the admin completes and publishes through the official flow.
-- 3) Sorteio automático de times (Pelada Premium, admin or assistant). Rules, in priority order:
--    1st per position: |team A - team B| <= 1 for EVERY position (goalkeepers included: 2 -> 1x1,
--        4 -> 2x2, 3 -> 2x1, 1 -> 1x0 with a warning; a position never compensates another);
--    2nd total: |size A - size B| <= 1;
--    3rd overall: the official Card overall of the current season is used only to reduce the strength
--        difference, by swapping two players of the SAME position between teams (a swap never changes the
--        counts, so rules 1 and 2 always hold).
--    Construction (always succeeds with 2+ players): each position is shuffled and split in halves; the
--    odd positions give their extra player alternately to A and B (so the totals differ by at most 1).
--    Then a same-position swap search lowers |overall A - overall B|. 40 random valid splits are built;
--    the final one is drawn among those within 1 overall point of the best (randomness among good
--    solutions). Pseudo-random numbers come from md5(seed, counter): the same seed and the same input
--    give the same teams (reproducible and auditable); the seed is stored.
--    Overall used: the player's Card in the current season (provisional Cards already follow the official
--    rule); without a Card, the official provisional base (0.7 x last season's overall + 0.3 x 50, or 50).
--    Members without a position (not possible today: preferred_position is mandatory) form the group
--    "none" with the same rule.
--    Modes: 'single' = one draw reused for N rounds; 'independent' = N different draws, one per round.
--    A draw is created as 'draft', confirmed once (then never changed) or cancelled. Confirming creates the
--    planned lineups. A lineup is flagged for review when one of its players left the pelada or changed
--    position after the draw (it is never changed silently).

---------------------------------------------------------------------------------------------------
-- Duelo
---------------------------------------------------------------------------------------------------

create function private.duel_side(p_membership uuid, p_season uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object(
  'membership_id', m.id, 'name', m.player_name, 'position', coalesce(c.position, m.preferred_position),
  'avatar_path', case when m.user_id is not null and not private.blocked_either_way(m.user_id)
    then (select p.avatar_path from public.profiles p where p.id=m.user_id) end,
  'card', case when c.id is not null then jsonb_build_object('tier',c.tier,'overall',c.overall,'finishing',c.finishing,
    'assisting',c.assisting,'attendance',c.attendance,'winning',c.winning,'peer_rating',c.peer_rating,
    'is_provisional',c.is_provisional,'matches_played',c.matches_played) end,
  'stats', jsonb_build_object('matches', coalesce(s.matches_played,0), 'goals', coalesce(s.goals,0),
    'assists', coalesce(s.assists,0), 'wins', coalesce(s.wins,0), 'avg_rating', s.avg_final_rating,
    'valid_ratings', coalesce(s.valid_ratings,0),
    'craque', (select count(*) from public.awards a where a.membership_id=m.id and a.season_id=p_season
      and a.award_type='match_craque' and a.status='active')))
 from public.pelada_memberships m
 left join public.player_cards c on c.membership_id=m.id and c.season_id=p_season
 left join public.player_season_stats s on s.membership_id=m.id and s.season_id=p_season
 where m.id=p_membership;
$$;

create function public.get_player_duel(p_season uuid, p_a uuid, p_b uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_pelada uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 v_pelada := private.check_season_access(p_season); -- member + season the plan allows
 if not private.pelada_has_premium(v_pelada) then raise exception 'PREMIUM_REQUIRED'; end if;
 if p_a is null or p_b is null or p_a = p_b then raise exception 'DUEL_SAME_PLAYER'; end if;
 if (select count(*) from public.pelada_memberships where id in (p_a,p_b) and pelada_id=v_pelada and status<>'retired') <> 2 then
  raise exception 'DUEL_INVALID_PLAYER'; end if;
 return jsonb_build_object('season_id', p_season,
  'season_name', (select name from public.seasons where id=p_season),
  'a', private.duel_side(p_a, p_season), 'b', private.duel_side(p_b, p_season));
end $$;

---------------------------------------------------------------------------------------------------
-- Escalação depois do jogo (grátis)
---------------------------------------------------------------------------------------------------

create function public.get_match_lineup(p_match uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_m public.matches;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match;
 if not found or not private.is_active_member(v_m.pelada_id) or v_m.status='draft' then raise exception 'MATCH_NOT_FOUND'; end if;
 return jsonb_build_object('match_id', v_m.id, 'played_at', v_m.played_at, 'status', v_m.status,
  'team_a_name', v_m.team_a_name, 'team_b_name', v_m.team_b_name,
  'team_a_score', v_m.team_a_score, 'team_b_score', v_m.team_b_score,
  'players', coalesce((select jsonb_agg(jsonb_build_object('team', p.team, 'membership_id', p.membership_id,
     'guest', p.guest_id is not null, 'name', coalesce(m.player_name, g.display_name, 'Jogador'), 'position', p.primary_position,
     'avatar_path', case when m.user_id is not null and not private.blocked_either_way(m.user_id)
       then (select pr.avatar_path from public.profiles pr where pr.id=m.user_id) end)
    order by p.team, case p.primary_position when 'goalkeeper' then 1 when 'defender' then 2 when 'midfielder' then 3 else 4 end,
     coalesce(m.player_name, g.display_name))
   from public.match_participants p
   left join public.pelada_memberships m on m.id=p.membership_id
   left join public.guests g on g.id=p.guest_id
   where p.match_id=v_m.id), '[]'::jsonb));
end $$;

---------------------------------------------------------------------------------------------------
-- Sorteio
---------------------------------------------------------------------------------------------------

create table public.team_draws (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 mode text not null check (mode in ('single','independent')),
 rounds_total integer not null check (rounds_total between 1 and 12),
 status text not null default 'draft' check (status in ('draft','confirmed','cancelled')),
 seed text not null,
 algorithm_version integer not null default 1,
 season_id uuid,
 input jsonb not null, -- [{membership_id, name, position, overall, provisional}] as considered
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 confirmed_at timestamptz,
 cancelled_at timestamptz
);
create index team_draws_by_pelada on public.team_draws(pelada_id, created_at desc);

create table public.team_draw_players (
 draw_id uuid not null references public.team_draws(id) on delete cascade,
 round_number integer not null check (round_number between 1 and 12),
 membership_id uuid not null references public.pelada_memberships(id),
 team text not null check (team in ('A','B')),
 position text,
 overall numeric(9,6) not null,
 primary key (draw_id, round_number, membership_id)
);

create table public.planned_lineups (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 draw_id uuid references public.team_draws(id),
 round_number integer,
 label text not null check (length(btrim(label)) between 1 and 60),
 team_a_name text not null default 'Time A' check (length(btrim(team_a_name)) between 1 and 40),
 team_b_name text not null default 'Time B' check (length(btrim(team_b_name)) between 1 and 40),
 rounds_total integer not null default 1 check (rounds_total between 1 and 12),
 rounds_used integer not null default 0 check (rounds_used >= 0),
 status text not null default 'active' check (status in ('active','used','cancelled')),
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique (draw_id, round_number)
);
create index planned_lineups_active on public.planned_lineups(pelada_id) where status='active';

create table public.planned_lineup_players (
 lineup_id uuid not null references public.planned_lineups(id) on delete cascade,
 membership_id uuid not null references public.pelada_memberships(id),
 team text not null check (team in ('A','B')),
 position_at_creation text,
 primary key (lineup_id, membership_id)
);

alter table public.team_draws enable row level security;
alter table public.team_draw_players enable row level security;
alter table public.planned_lineups enable row level security;
alter table public.planned_lineup_players enable row level security;
revoke all on public.team_draws, public.team_draw_players, public.planned_lineups, public.planned_lineup_players
 from anon, authenticated;
-- Reads and writes only through the functions below (draft draws are staff-only).

-- Deterministic pseudo-random number in [0, 1) from the seed and a counter.
create function private.draw_rand(p_seed text, p_i bigint) returns double precision
language sql immutable set search_path = '' as $$
 select ('x' || substr(md5(p_seed || ':' || p_i), 1, 12))::bit(48)::bigint / 281474976710656.0;
$$;

-- Rules 1 and 2 (and every slot filled with A or B).
create function private.draw_balanced(p_pos text[], p_team text[]) returns boolean
language sql immutable set search_path = '' as $$
 select cardinality(p_pos) = cardinality(p_team)
  and not exists(select 1 from unnest(p_team) t where t is null or t not in ('A','B'))
  and abs((select count(*) from unnest(p_team) t where t='A') - (select count(*) from unnest(p_team) t where t='B')) <= 1
  and not exists(
   select 1 from (select coalesce(p, 'none') p, t from unnest(p_pos, p_team) x(p, t)) y
   group by p having abs(count(*) filter (where t='A') - count(*) filter (where t='B')) > 1);
$$;

-- One valid split, optimized by overall. Returns the team ('A'/'B') of each input slot.
create function private.draw_split(p_pos text[], p_ov numeric[], p_seed text, p_candidates integer default 40)
returns text[]
language plpgsql immutable set search_path = '' as $$
declare
 n integer := cardinality(p_pos); pos text[]; positions text[]; odd text[]; k integer; extra_a integer;
 t text[]; idx integer[]; c integer; half integer; sa numeric; sb numeric; cur numeric; best_new numeric;
 bi integer; bj integer; nd numeric; cand integer; results text[][] := '{}'; diffs numeric[] := '{}';
 best numeric; pick double precision; ok integer[]; i integer; j integer; guard integer;
begin
 if n < 2 then raise exception 'DRAW_TOO_FEW_PLAYERS'; end if;
 pos := array(select coalesce(x, 'none') from unnest(p_pos) x);
 positions := array(select distinct x from unnest(pos) x order by 1);
 for cand in 1..p_candidates loop
  t := array_fill('B'::text, array[n]);
  -- Odd positions, shuffled; A gets half of the extras (the odd one out decided at random).
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
  -- Overall: swap two players of the same position while it lowers the difference.
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
 end loop;
 -- Random choice among the splits within 1 overall point of the best.
 best := (select min(d) from unnest(diffs) d);
 ok := array(select s from generate_subscripts(diffs, 1) s where diffs[s] <= best + 1 order by s);
 pick := private.draw_rand(p_seed, 999999937);
 t := results[ok[1 + floor(pick * cardinality(ok))::integer]:ok[1 + floor(pick * cardinality(ok))::integer]][1:n];
 t := array(select unnest(t));
 if not private.draw_balanced(p_pos, t) then raise exception 'DRAW_UNBALANCED'; end if;
 return t;
end $$;

-- Overall considered in the draw: current season Card; otherwise the official provisional base.
create function private.draw_overall(p_membership uuid, p_season uuid, out overall numeric, out provisional boolean)
language plpgsql stable security definer set search_path = '' as $$
declare v_s public.seasons; v_prev numeric;
begin
 select c.overall, c.is_provisional into overall, provisional from public.player_cards c
 where c.membership_id=p_membership and c.season_id=p_season;
 if found then return; end if;
 select * into v_s from public.seasons where id=p_season;
 select c.overall into v_prev from public.player_cards c join public.seasons s on s.id=c.season_id
 where c.membership_id=p_membership and s.pelada_id=v_s.pelada_id and s.ends_on < v_s.starts_on
 order by s.ends_on desc limit 1;
 overall := case when v_prev is null then 50 else round(0.7*v_prev + 0.3*50, 6) end;
 provisional := true;
end $$;

-- Draw as JSON (rounds, teams, counts per position, overall sums, warnings, review flags).
create function private.draw_json(p_draw uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('id', d.id, 'pelada_id', d.pelada_id, 'mode', d.mode, 'rounds_total', d.rounds_total,
  'status', d.status, 'seed', d.seed, 'algorithm_version', d.algorithm_version, 'created_at', d.created_at,
  'confirmed_at', d.confirmed_at,
  'warnings', (select coalesce(jsonb_agg(w), '[]'::jsonb) from (
    select 'ONE_GOALKEEPER' w where (select count(*) from jsonb_array_elements(d.input) x where x->>'position'='goalkeeper') = 1
    union all select 'ODD_GOALKEEPERS' where (select count(*) from jsonb_array_elements(d.input) x where x->>'position'='goalkeeper') in (3,5,7,9,11)
    union all select 'NO_POSITION' where exists(select 1 from jsonb_array_elements(d.input) x where x->>'position' is null)
    union all select 'PROVISIONAL_OVERALL' where exists(select 1 from jsonb_array_elements(d.input) x where (x->>'provisional')::boolean)
    union all select 'MEMBER_LEFT' where exists(select 1 from public.team_draw_players p join public.pelada_memberships m
      on m.id=p.membership_id where p.draw_id=d.id and m.status<>'active')
    union all select 'POSITION_CHANGED' where exists(select 1 from public.team_draw_players p join public.pelada_memberships m
      on m.id=p.membership_id where p.draw_id=d.id and p.position is distinct from m.preferred_position)) ws),
  'rounds', (select coalesce(jsonb_agg(r order by (r->>'round')::int), '[]'::jsonb) from (
    select jsonb_build_object('round', p.round_number,
     'overall_a', round(sum(p.overall) filter (where p.team='A'), 2), 'overall_b', round(sum(p.overall) filter (where p.team='B'), 2),
     'team_a', jsonb_agg(jsonb_build_object('membership_id', p.membership_id, 'name', m.player_name, 'position', p.position,
        'overall', round(p.overall, 1), 'active', m.status='active') order by p.position, m.player_name) filter (where p.team='A'),
     'team_b', jsonb_agg(jsonb_build_object('membership_id', p.membership_id, 'name', m.player_name, 'position', p.position,
        'overall', round(p.overall, 1), 'active', m.status='active') order by p.position, m.player_name) filter (where p.team='B'),
     'by_position', (select jsonb_agg(jsonb_build_object('position', q.position, 'a', q.a, 'b', q.b) order by q.position)
        from (select coalesce(x.position, 'none') position, count(*) filter (where x.team='A') a, count(*) filter (where x.team='B') b
              from public.team_draw_players x where x.draw_id=d.id and x.round_number=p.round_number group by 1) q)) r
    from public.team_draw_players p join public.pelada_memberships m on m.id=p.membership_id
    where p.draw_id=d.id group by p.round_number) rr))
 from public.team_draws d where d.id=p_draw;
$$;

create function private.require_draw_staff(p_pelada uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform 1 from public.peladas where id=p_pelada for update;
 if not found then raise exception 'PELADA_NOT_FOUND'; end if;
 if not private.is_active_staff(p_pelada) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 if not private.pelada_has_premium(p_pelada) then raise exception 'PREMIUM_REQUIRED'; end if;
end $$;

-- Creates a draft draw. p_seed only for tests/reproduction (the app leaves it null).
create function public.create_team_draw(p_pelada uuid, p_members uuid[], p_mode text, p_rounds integer,
 p_seed text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_season uuid; v_seed text; v_input jsonb; v_pos text[]; v_ov numeric[]; v_mem uuid[];
 v_team text[]; r integer;
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
 v_seed := coalesce(nullif(btrim(p_seed), ''), encode(extensions.gen_random_bytes(12), 'hex'));
 select jsonb_agg(jsonb_build_object('membership_id', m.id, 'name', m.player_name, 'position', m.preferred_position,
   'overall', o.overall, 'provisional', o.provisional) order by m.id),
  array_agg(m.id order by m.id), array_agg(m.preferred_position order by m.id), array_agg(o.overall order by m.id)
 into v_input, v_mem, v_pos, v_ov
 from public.pelada_memberships m cross join lateral private.draw_overall(m.id, v_season) o
 where m.id = any(p_members);

 -- One open draft per pelada: a new draw replaces the previous draft (no duplicates).
 update public.team_draws set status='cancelled', cancelled_at=now() where pelada_id=p_pelada and status='draft';
 insert into public.team_draws(pelada_id,mode,rounds_total,seed,season_id,input,created_by)
 values(p_pelada,p_mode,p_rounds,v_seed,v_season,v_input,auth.uid()) returning id into v_id;
 for r in 1..case when p_mode='single' then 1 else p_rounds end loop
  v_team := private.draw_split(v_pos, v_ov, v_seed || ':' || r);
  insert into public.team_draw_players(draw_id,round_number,membership_id,team,position,overall)
  select v_id, r, v_mem[i], v_team[i], v_pos[i], v_ov[i] from generate_subscripts(v_mem, 1) i;
 end loop;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'team_draw_created',jsonb_build_object('draw_id',v_id,'mode',p_mode,'rounds',p_rounds,
  'players',cardinality(p_members),'seed',v_seed));
 return private.draw_json(v_id);
end $$;

-- Re-checks every round of a stored draw (rules 1 and 2) from the persisted rows.
create function private.draw_rounds_balanced(p_draw uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select bool_and(private.draw_balanced(x.pos, x.team)) from (
  select array_agg(position order by membership_id) pos, array_agg(team order by membership_id) team
  from public.team_draw_players where draw_id=p_draw group by round_number) x;
$$;

-- Confirms the draft (once) and creates the planned lineups: one reused for N rounds (single) or one per round.
create function public.confirm_team_draw(p_draw uuid, p_team_a_name text default null, p_team_b_name text default null) returns jsonb
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
   where p.draw_id=p_draw and (m.status<>'active' or p.position is distinct from m.preferred_position)) then
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

create function public.cancel_team_draw(p_draw uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_d public.team_draws;
begin
 select * into v_d from public.team_draws where id=p_draw;
 if not found then raise exception 'DRAW_NOT_FOUND'; end if;
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform 1 from public.peladas where id=v_d.pelada_id for update;
 if not private.is_active_staff(v_d.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 update public.team_draws set status='cancelled', cancelled_at=now() where id=p_draw and status<>'cancelled';
 update public.planned_lineups set status='cancelled', updated_at=now() where draw_id=p_draw and status='active';
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_d.pelada_id,auth.uid(),'team_draw_cancelled',jsonb_build_object('draw_id',p_draw));
end $$;

-- Staff: the open draft and the confirmed draws (latest first). Members: confirmed only.
create function public.get_team_draws(p_pelada uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.is_active_member(p_pelada) then raise exception 'PELADA_NOT_FOUND'; end if;
 return coalesce((select jsonb_agg(private.draw_json(d.id) order by d.created_at desc) from public.team_draws d
  where d.pelada_id=p_pelada and (d.status='confirmed' or (d.status='draft' and private.is_active_staff(p_pelada)))), '[]'::jsonb);
end $$;

---------------------------------------------------------------------------------------------------
-- Escalação antes do jogo (Pelada Premium)
---------------------------------------------------------------------------------------------------

create function private.lineup_json(p_lineup uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('id', l.id, 'label', l.label, 'source', case when l.draw_id is null then 'manual' else 'draw' end,
  'draw_id', l.draw_id, 'round_number', l.round_number, 'team_a_name', l.team_a_name, 'team_b_name', l.team_b_name,
  'rounds_total', l.rounds_total, 'rounds_used', l.rounds_used, 'status', l.status, 'created_at', l.created_at,
  'needs_review', exists(select 1 from public.planned_lineup_players p join public.pelada_memberships m on m.id=p.membership_id
    where p.lineup_id=l.id and (m.status<>'active' or (l.draw_id is not null and p.position_at_creation is distinct from m.preferred_position))),
  'players', coalesce((select jsonb_agg(jsonb_build_object('membership_id', p.membership_id, 'team', p.team, 'name', m.player_name,
     'position', m.preferred_position, 'position_at_creation', p.position_at_creation, 'active', m.status='active',
     'avatar_path', case when m.user_id is not null and not private.blocked_either_way(m.user_id)
       then (select pr.avatar_path from public.profiles pr where pr.id=m.user_id) end)
    order by p.team, case m.preferred_position when 'goalkeeper' then 1 when 'defender' then 2 when 'midfielder' then 3 else 4 end, m.player_name)
   from public.planned_lineup_players p join public.pelada_memberships m on m.id=p.membership_id where p.lineup_id=l.id), '[]'::jsonb))
 from public.planned_lineups l where l.id=p_lineup;
$$;

-- Members see the active lineups of their pelada.
create function public.get_lineups(p_pelada uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.is_active_member(p_pelada) then raise exception 'PELADA_NOT_FOUND'; end if;
 return coalesce((select jsonb_agg(private.lineup_json(l.id) order by l.created_at, l.round_number) from public.planned_lineups l
  where l.pelada_id=p_pelada and l.status='active'), '[]'::jsonb);
end $$;

-- Manual lineup (new or edit of a manual one). The position balance is NOT enforced here: the app only
-- warns (V4.2, 11.12); the draw rules apply to the automatic draw.
create function public.save_lineup(p_pelada uuid, p_lineup uuid, p_label text, p_team_a uuid[], p_team_b uuid[],
 p_team_a_name text default null, p_team_b_name text default null) returns jsonb
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
  insert into public.planned_lineups(pelada_id,label,team_a_name,team_b_name,created_by)
  values(p_pelada,v_label,v_a,v_b,auth.uid()) returning * into v_l;
 else
  select * into v_l from public.planned_lineups where id=p_lineup and pelada_id=p_pelada and status='active' and draw_id is null for update;
  if not found then raise exception 'LINEUP_INVALID'; end if;
  update public.planned_lineups set label=v_label, team_a_name=v_a, team_b_name=v_b, updated_at=now() where id=v_l.id;
  delete from public.planned_lineup_players where lineup_id=v_l.id;
 end if;
 insert into public.planned_lineup_players(lineup_id,membership_id,team,position_at_creation)
 select v_l.id, m.id, case when m.id = any(p_team_a) then 'A' else 'B' end, m.preferred_position
 from public.pelada_memberships m where m.id = any(v_all);
 return private.lineup_json(v_l.id);
end $$;

create function public.cancel_lineup(p_lineup uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_l public.planned_lineups;
begin
 select * into v_l from public.planned_lineups where id=p_lineup;
 if not found then raise exception 'LINEUP_INVALID'; end if;
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform 1 from public.peladas where id=v_l.pelada_id for update;
 if not private.is_active_staff(v_l.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 update public.planned_lineups set status='cancelled', updated_at=now() where id=p_lineup and status='active';
end $$;

-- Opens a DRAFT sheet with the lineup's players (official flow continues: goals, publish, voting).
create function public.use_lineup_in_match(p_lineup uuid, p_played_at timestamptz default now()) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_l public.planned_lineups; v_match uuid;
begin
 select * into v_l from public.planned_lineups where id=p_lineup;
 if not found then raise exception 'LINEUP_INVALID'; end if;
 perform private.require_draw_staff(v_l.pelada_id);
 select * into v_l from public.planned_lineups where id=p_lineup for update;
 if v_l.status <> 'active' then raise exception 'LINEUP_INVALID'; end if;
 if exists(select 1 from public.planned_lineup_players p join public.pelada_memberships m on m.id=p.membership_id
   where p.lineup_id=p_lineup and m.status<>'active') then raise exception 'DRAW_STALE'; end if;
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

revoke all on function private.duel_side(uuid,uuid), private.draw_rand(text,bigint), private.draw_balanced(text[],text[]),
 private.draw_split(text[],numeric[],text,integer), private.draw_overall(uuid,uuid), private.draw_json(uuid),
 private.require_draw_staff(uuid), private.draw_rounds_balanced(uuid), private.lineup_json(uuid) from public,anon,authenticated;
revoke all on function public.get_player_duel(uuid,uuid,uuid), public.get_match_lineup(uuid),
 public.create_team_draw(uuid,uuid[],text,integer,text), public.confirm_team_draw(uuid,text,text),
 public.cancel_team_draw(uuid), public.get_team_draws(uuid), public.get_lineups(uuid),
 public.save_lineup(uuid,uuid,text,uuid[],uuid[],text,text), public.cancel_lineup(uuid),
 public.use_lineup_in_match(uuid,timestamptz) from public,anon;
grant execute on function public.get_player_duel(uuid,uuid,uuid), public.get_match_lineup(uuid),
 public.create_team_draw(uuid,uuid[],text,integer,text), public.confirm_team_draw(uuid,text,text),
 public.cancel_team_draw(uuid), public.get_team_draws(uuid), public.get_lineups(uuid),
 public.save_lineup(uuid,uuid,text,uuid[],uuid[],text,text), public.cancel_lineup(uuid),
 public.use_lineup_in_match(uuid,timestamptz) to authenticated;
