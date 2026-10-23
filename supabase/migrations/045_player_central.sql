-- Minuto 91 / 045: V4.4 fases 3-9 (servidor) — Central do Jogador, Minha Carreira, Sala de Troféus, convites,
-- notificações por categoria e guia inicial.
--
-- Central do Jogador (one screen for everybody, admins included): independent, cheap reads, no history recount.
--  get_player_central()          peladas (escudo, papel, posição, principal), pendências (votação aberta, posição
--                                a atualizar, perfil incompleto), último jogo (placar, resultado, meus gols e
--                                assistências), próxima rodada (escalação ativa em que estou), guia inicial.
--                                Uses only indexed lookups bounded by the user's memberships.
--  set_primary_pelada(pelada)    discreet "principal" mark (null clears).
-- Minha Carreira:
--  get_player_career_summary(u)  same visibility and plan rules as get_player_career (030): totals per pelada and
--                                season and in total (counters only; overalls are never summed: each Card keeps its
--                                pelada and season), trophy counts. No achievement list (that is paged below).
--  get_my_match_history(...)     official finalized matches, paged (played_at, id desc), optional pelada filter.
-- Sala de Troféus (official awards only): Craque da Partida (match_craque), Rei do Mês (monthly_king), Bola Murcha
--  (bola_murcha). Counts come from the official awards table (the same rows the stats, the album and the
--  notifications use): no second counter. Detail on demand: get_trophy_history (paged).
--  PRODUCT DECISION (V4.4 prompt 7.2): Bola Murcha is one of the three official trophies of the Trophy Room.
--  Until V4.3 it was left out of the "conquistas" list and of the push notifications; that stays as it was.
-- Convites: get_invite_preview tells why an invite does not work (expired, used up, revoked, not found, pelada
--  inactive) and whether the person can come back (left) or not (suspended/retired), and whether
--  a position must be chosen. Authorization is unchanged (join_pelada, 004).
-- Notificações: one switch per category on top of the two master switches of 035 (they keep working for older
--  apps). Categories: match_voting, voting_reminder, results, awards, pelada. account_transferred always goes.
--  No finance notification exists and none is created.
-- Guia inicial: dismissible, server-side (follows the account); steps are computed from real data.

---------------------------------------------------------------------------------------------------
-- Per-account app state (principal pelada and the guide)
---------------------------------------------------------------------------------------------------

create table public.user_app_state (
 user_id uuid primary key references auth.users(id) on delete cascade,
 primary_pelada_id uuid references public.peladas(id) on delete set null,
 guide_dismissed_at timestamptz,
 guide_seen jsonb not null default '{}'::jsonb check (jsonb_typeof(guide_seen) = 'object'),
 updated_at timestamptz not null default now()
);
alter table public.user_app_state enable row level security;
revoke all on public.user_app_state from anon, authenticated;
grant select on public.user_app_state to authenticated;
create policy user_app_state_read_own on public.user_app_state for select to authenticated
 using (user_id = (select auth.uid()));

create index if not exists planned_lineup_players_by_membership on public.planned_lineup_players(membership_id);

create function public.set_primary_pelada(p_pelada uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_pelada is not null and not private.is_active_member(p_pelada) then raise exception 'PELADA_NOT_FOUND'; end if;
 insert into public.user_app_state(user_id, primary_pelada_id) values(auth.uid(), p_pelada)
 on conflict (user_id) do update set primary_pelada_id = excluded.primary_pelada_id, updated_at = now();
end $$;

-- p_step: 'career' or 'cards' (seen), or 'dismiss' (hide the whole guide), or 'restore'.
create function public.set_guide_state(p_step text) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_step is null or p_step not in ('career','cards','dismiss','restore') then raise exception 'INVALID_GUIDE_STEP'; end if;
 insert into public.user_app_state(user_id) values(auth.uid()) on conflict (user_id) do nothing;
 update public.user_app_state set
  guide_dismissed_at = case p_step when 'dismiss' then now() when 'restore' then null else guide_dismissed_at end,
  guide_seen = case when p_step in ('career','cards') then guide_seen || jsonb_build_object(p_step, true) else guide_seen end,
  updated_at = now()
 where user_id = auth.uid();
end $$;

---------------------------------------------------------------------------------------------------
-- Central do Jogador
---------------------------------------------------------------------------------------------------

-- Last official or ongoing match (not draft, not annulled) of one membership: starts from the player's own
-- participations (index by membership) and reads only those matches (measured: building the pelada's whole match list
-- took 19 ms with 5,000 matches; this path reads one row per match played).
create function private.last_match_of(p_membership uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('match_id', m.id, 'pelada_id', m.pelada_id, 'pelada_name', p.name, 'crest_path', p.crest_path,
  'played_at', m.played_at, 'status', m.status, 'team_a_name', m.team_a_name, 'team_b_name', m.team_b_name,
  'team_a_score', m.team_a_score, 'team_b_score', m.team_b_score, 'my_team', mp.team,
  'result', case when m.team_a_score = m.team_b_score then 'draw'
   when (m.team_a_score > m.team_b_score) = (mp.team = 'A') then 'win' else 'loss' end,
  'goals', coalesce((select sum(e.quantity) from public.match_events e where e.match_id = m.id and e.participant_id = mp.id
    and e.event_type = 'goal'), 0),
  'assists', coalesce((select sum(e.quantity) from public.match_events e where e.match_id = m.id and e.participant_id = mp.id
    and e.event_type = 'assist'), 0),
  'official', m.status = 'finalized')
 from public.match_participants mp
 join public.matches m on m.id = mp.match_id
 join public.peladas p on p.id = m.pelada_id
 where mp.membership_id = p_membership and m.status in ('voting_open','finalizing','finalized')
 order by m.played_at desc, m.id desc
 limit 1;
$$;

create function public.get_player_central() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_state public.user_app_state; v_me jsonb; v_peladas jsonb; v_last jsonb; v_next jsonb;
 v_votes jsonb; v_positions jsonb; v_mem uuid; v_x jsonb;
begin
 if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_state from public.user_app_state where user_id = v_uid;
 select jsonb_build_object('display_name', display_name, 'avatar_path', avatar_path, 'dominant_foot', dominant_foot)
 into v_me from public.profiles where id = v_uid;

 select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'crest_path', p.crest_path, 'role', pm.role,
   'membership_id', pm.id, 'position', pm.preferred_position, 'position_code', pm.position_code,
   'is_primary', coalesce(p.id = v_state.primary_pelada_id, false),
   'drafts', case when pm.role in ('admin','assistant')
     then (select count(*) from public.matches m where m.pelada_id = p.id and m.status = 'draft') else 0 end,
   -- guide (admin steps): only for the admin, never other people's data
   'setup', case when pm.role = 'admin' then jsonb_build_object(
     'members', (select count(*) from public.pelada_memberships x where x.pelada_id = p.id and x.status = 'active'),
     'matches', (select count(*) from public.matches m where m.pelada_id = p.id),
     'configured', p.crest_path is not null or exists(select 1 from public.pelada_settings s where s.pelada_id = p.id
        and s.updated_at > p.created_at + interval '1 minute'),
     'invited', exists(select 1 from private.pelada_invites i where i.pelada_id = p.id)) end)
   order by (p.id = v_state.primary_pelada_id) desc nulls last, p.name)
 , '[]'::jsonb)
 into v_peladas
 from public.pelada_memberships pm join public.peladas p on p.id = pm.pelada_id
 where pm.user_id = v_uid and pm.status = 'active';

 -- One call per membership (a query would call it twice: in the filter and in the sort).
 for v_mem in select pm.id from public.pelada_memberships pm where pm.user_id = v_uid and pm.status in ('active','left') loop
  v_x := private.last_match_of(v_mem);
  if v_x is not null and (v_last is null or (v_x->>'played_at')::timestamptz > (v_last->>'played_at')::timestamptz) then
   v_last := v_x; end if;
 end loop;

 select coalesce(jsonb_agg(jsonb_build_object('lineup_id', l.id, 'pelada_id', l.pelada_id, 'pelada_name', p.name,
   'label', l.label, 'my_team', lp.team, 'team_name', case lp.team when 'A' then l.team_a_name else l.team_b_name end,
   'opponent_name', case lp.team when 'A' then l.team_b_name else l.team_a_name end, 'created_at', l.created_at)
   order by l.created_at desc), '[]'::jsonb)
 into v_next from (
  select lp.lineup_id, lp.team from public.planned_lineup_players lp
  join public.pelada_memberships pm on pm.id = lp.membership_id and pm.user_id = v_uid and pm.status = 'active') lp
 join public.planned_lineups l on l.id = lp.lineup_id and l.status = 'active'
 join public.peladas p on p.id = l.pelada_id;

 select coalesce(jsonb_agg(jsonb_build_object('match_id', s.match_id, 'pelada_id', s.pelada_id, 'pelada_name', p.name,
   'closes_at', s.closes_at, 'team_a_name', m.team_a_name, 'team_b_name', m.team_b_name,
   'team_a_score', m.team_a_score, 'team_b_score', m.team_b_score) order by s.closes_at), '[]'::jsonb)
 into v_votes
 from public.voting_sessions s join public.voting_eligible_members e on e.session_id = s.id
 join public.pelada_memberships pm on pm.id = e.membership_id and pm.user_id = v_uid and pm.status = 'active'
 join public.peladas p on p.id = s.pelada_id join public.matches m on m.id = s.match_id
 where s.status = 'open' and s.closes_at > now()
  and not exists(select 1 from public.vote_receipts r where r.session_id = s.id and r.membership_id = e.membership_id);

 select coalesce(jsonb_agg(jsonb_build_object('pelada_id', p.id, 'pelada_name', p.name, 'membership_id', pm.id,
   'position', pm.preferred_position) order by p.name), '[]'::jsonb)
 into v_positions
 from public.pelada_memberships pm join public.peladas p on p.id = pm.pelada_id
 where pm.user_id = v_uid and pm.status = 'active' and pm.position_code is null;

 return jsonb_build_object('me', v_me, 'primary_pelada_id', v_state.primary_pelada_id,
  'peladas', v_peladas, 'last_match', v_last, 'next_rounds', v_next,
  'pending', jsonb_build_object('votes', v_votes, 'positions', v_positions,
   'profile', jsonb_build_object('photo', (v_me->>'avatar_path') is null, 'foot', (v_me->>'dominant_foot') is null)),
  'guide', jsonb_build_object('dismissed', v_state.guide_dismissed_at is not null,
   'seen', coalesce(v_state.guide_seen, '{}'::jsonb)),
  'server_time', now());
end $$;

---------------------------------------------------------------------------------------------------
-- Minha Carreira
---------------------------------------------------------------------------------------------------

-- Totals per pelada/season and in total, cards per pelada/season, and the three trophy counts.
-- Same rules as get_player_career (030): career_visibility, blocks, retired records excluded, free peladas show the
-- current and the previous season only (hidden_seasons says how many are left out). Counters are summed
-- (a match belongs to one pelada and one season); overalls and averages are never summed.
create function public.get_player_career_summary(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_level text; v_peladas jsonb; v_trophies jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select career_visibility into v_level from public.profiles where id = p_user;
 if not found or not private.can_view_global(p_user, v_level) then return jsonb_build_object('visible', false); end if;

 with mem as (
  select m.id, m.pelada_id, m.status, m.preferred_position, m.position_code, m.joined_at, p.name, p.crest_path,
   private.pelada_has_premium(m.pelada_id) full_history,
   array(select private.career_seasons(m.pelada_id)) shown_seasons
  from public.pelada_memberships m join public.peladas p on p.id = m.pelada_id
  where m.user_id = p_user and m.status in ('active','left')),
 st as (
  select mem.id membership_id, s.id season_id, s.name, s.starts_on, s.ends_on, s.status season_status,
   x.matches_played, x.wins, x.draws, x.losses, x.goals, x.assists, x.red_cards, x.craque_awards,
   x.valid_ratings, x.avg_final_rating, c.overall, c.tier, c.is_provisional, c.position card_position,
   c.finishing, c.assisting, c.attendance, c.winning, c.peer_rating, c.matches_played card_matches,
   s.id = any(mem.shown_seasons) shown
  from mem join public.player_season_stats x on x.membership_id = mem.id
  join public.seasons s on s.id = x.season_id
  left join public.player_cards c on c.membership_id = mem.id and c.season_id = s.id
  where x.matches_played > 0),
 tr as (
  select a.membership_id, a.award_type, count(*) n
  from mem join public.awards a on a.membership_id = mem.id
  where a.status = 'active' and a.award_type in ('match_craque','monthly_king','bola_murcha')
   and a.season_id = any(mem.shown_seasons)
  group by a.membership_id, a.award_type)
 select coalesce(jsonb_agg(jsonb_build_object(
   'pelada_id', mem.pelada_id, 'name', mem.name, 'crest_path', mem.crest_path, 'membership_id', mem.id,
   'status', mem.status, 'position', mem.preferred_position, 'position_code', mem.position_code,
   'joined_at', mem.joined_at, 'full_history', mem.full_history,
   'hidden_seasons', (select count(*) from st where st.membership_id = mem.id and not st.shown),
   'totals', (select jsonb_build_object('matches_played', coalesce(sum(matches_played),0), 'wins', coalesce(sum(wins),0),
      'draws', coalesce(sum(draws),0), 'losses', coalesce(sum(losses),0), 'goals', coalesce(sum(goals),0),
      'assists', coalesce(sum(assists),0), 'red_cards', coalesce(sum(red_cards),0),
      'craque_awards', coalesce(sum(craque_awards),0))
     from st where st.membership_id = mem.id and st.shown),
   'trophies', jsonb_build_object(
      'match_craque', coalesce((select n from tr where tr.membership_id = mem.id and tr.award_type = 'match_craque'), 0),
      'monthly_king', coalesce((select n from tr where tr.membership_id = mem.id and tr.award_type = 'monthly_king'), 0),
      'bola_murcha', coalesce((select n from tr where tr.membership_id = mem.id and tr.award_type = 'bola_murcha'), 0)),
   'seasons', coalesce((select jsonb_agg(jsonb_build_object('season_id', season_id, 'name', name,
      'starts_on', starts_on, 'ends_on', ends_on, 'status', season_status, 'matches_played', matches_played,
      'wins', wins, 'draws', draws, 'losses', losses, 'goals', goals, 'assists', assists, 'red_cards', red_cards,
      'craque_awards', craque_awards, 'valid_ratings', valid_ratings, 'avg_final_rating', avg_final_rating,
      'card', case when overall is null then null else jsonb_build_object('overall', overall, 'tier', tier,
       'is_provisional', is_provisional, 'position', card_position, 'finishing', finishing, 'assisting', assisting,
       'attendance', attendance, 'winning', winning, 'peer_rating', peer_rating, 'matches_played', card_matches) end)
      order by starts_on desc)
     from st where st.membership_id = mem.id and st.shown), '[]'::jsonb))
  order by mem.status, mem.joined_at), '[]'::jsonb)
 into v_peladas from mem;

 select jsonb_build_object(
  'match_craque', coalesce(sum((e->'trophies'->>'match_craque')::int), 0),
  'monthly_king', coalesce(sum((e->'trophies'->>'monthly_king')::int), 0),
  'bola_murcha', coalesce(sum((e->'trophies'->>'bola_murcha')::int), 0))
 into v_trophies from jsonb_array_elements(v_peladas) e;

 return jsonb_build_object('visible', true, 'is_me', p_user = auth.uid(),
  'totals', (select jsonb_build_object(
    'matches_played', coalesce(sum((e->'totals'->>'matches_played')::int),0),
    'wins', coalesce(sum((e->'totals'->>'wins')::int),0), 'draws', coalesce(sum((e->'totals'->>'draws')::int),0),
    'losses', coalesce(sum((e->'totals'->>'losses')::int),0), 'goals', coalesce(sum((e->'totals'->>'goals')::int),0),
    'assists', coalesce(sum((e->'totals'->>'assists')::int),0),
    'red_cards', coalesce(sum((e->'totals'->>'red_cards')::int),0),
    'craque_awards', coalesce(sum((e->'totals'->>'craque_awards')::int),0))
   from jsonb_array_elements(v_peladas) e),
  'partial', exists(select 1 from jsonb_array_elements(v_peladas) e where (e->>'hidden_seasons')::int > 0),
  'trophies', v_trophies, 'peladas', v_peladas);
end $$;

-- Trophy history on demand (one type, newest first, paged). p_after: "next" of the previous page.
create function public.get_trophy_history(p_user uuid, p_type text, p_after jsonb default null, p_limit integer default 20)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_level text; v_lim integer := private.page_limit(p_limit, 20, 50); a_at timestamptz; a_id uuid; v_items jsonb;
 v_next jsonb; v_n integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_type is null or p_type not in ('match_craque','monthly_king','bola_murcha') then raise exception 'INVALID_TROPHY'; end if;
 select career_visibility into v_level from public.profiles where id = p_user;
 if not found or not private.can_view_global(p_user, v_level) then return jsonb_build_object('visible', false); end if;
 if p_after is not null then
  begin a_at := (p_after->>'at')::timestamptz; a_id := (p_after->>'id')::uuid;
  exception when others then raise exception 'INVALID_CURSOR'; end;
  if a_at is null or a_id is null then raise exception 'INVALID_CURSOR'; end if;
 end if;

 with mem as (
  select m.id, m.pelada_id, p.name, p.crest_path, array(select private.career_seasons(m.pelada_id)) shown
  from public.pelada_memberships m join public.peladas p on p.id = m.pelada_id
  where m.user_id = p_user and m.status in ('active','left')),
 t as (
  select a.id, a.match_id, a.period_month, a.is_shared, mem.pelada_id, mem.name pelada_name, mem.crest_path,
   s.name season_name, mt.played_at, mt.team_a_name, mt.team_b_name, mt.team_a_score, mt.team_b_score,
   coalesce(mt.played_at, (a.period_month::timestamp at time zone 'UTC'), a.created_at) sort_at
  from mem join public.awards a on a.membership_id = mem.id
  join public.seasons s on s.id = a.season_id
  left join public.matches mt on mt.id = a.match_id
  where a.status = 'active' and a.award_type = p_type and a.season_id = any(mem.shown)),
 page as (select * from t where a_id is null or (t.sort_at, t.id) < (a_at, a_id) order by t.sort_at desc, t.id desc limit v_lim + 1)
 -- Placar e nomes dos times só para o próprio jogador e para quem joga naquela pelada (perfil público mostra o
 -- troféu, a pelada e a data, como get_player_career).
 select coalesce(jsonb_agg(jsonb_build_object('id', id, 'match_id', case when inside then match_id end, 'period_month', period_month,
   'is_shared', is_shared, 'pelada_id', pelada_id, 'pelada_name', pelada_name, 'crest_path', case when inside then crest_path end,
   'season_name', season_name, 'played_at', played_at,
   'team_a_name', case when inside then team_a_name end, 'team_b_name', case when inside then team_b_name end,
   'team_a_score', case when inside then team_a_score end, 'team_b_score', case when inside then team_b_score end, 'at', sort_at)
   order by sort_at desc, id desc), '[]'::jsonb), count(*)
 into v_items, v_n
 from (select page.*, p_user = auth.uid() or private.is_active_member(page.pelada_id) inside from page) page;

 if v_n > v_lim then
  v_items := (select jsonb_agg(x order by o) from jsonb_array_elements(v_items) with ordinality q(x, o) where o <= v_lim);
  v_next := jsonb_build_object('at', v_items->(v_lim-1)->'at', 'id', v_items->(v_lim-1)->'id');
 end if;
 return jsonb_build_object('visible', true, 'items', v_items, 'next', v_next);
end $$;

-- My official match history (finalized, not annulled), newest first, paged; optional pelada. Ratings are not
-- returned here (they follow the voting rules on the match screen). Plan rule of the pelada applies.
create function public.get_my_match_history(p_pelada uuid default null, p_after jsonb default null, p_limit integer default 20)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_lim integer := private.page_limit(p_limit, 20, 50); a_at timestamptz; a_id uuid; v_items jsonb; v_next jsonb; v_n integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_after is not null then
  begin a_at := (p_after->>'played_at')::timestamptz; a_id := (p_after->>'match_id')::uuid;
  exception when others then raise exception 'INVALID_CURSOR'; end;
  if a_at is null or a_id is null then raise exception 'INVALID_CURSOR'; end if;
 end if;
 with mem as (
  select m.id, m.pelada_id, p.name, p.crest_path, array(select private.career_seasons(m.pelada_id)) shown
  from public.pelada_memberships m join public.peladas p on p.id = m.pelada_id
  where m.user_id = auth.uid() and m.status in ('active','left') and (p_pelada is null or m.pelada_id = p_pelada)),
 page as (
  select x.* from mem cross join lateral (
   select mt.id match_id, mt.played_at, mt.team_a_name, mt.team_b_name, mt.team_a_score, mt.team_b_score,
    r.match_result, r.goals, r.assists, mp.team my_team, mem.pelada_id, mem.name pelada_name, mem.crest_path
   from public.matches mt
   join public.match_player_results r on r.match_id = mt.id and r.membership_id = mem.id
   left join public.match_participants mp on mp.match_id = mt.id and mp.membership_id = mem.id
   where mt.pelada_id = mem.pelada_id and mt.status = 'finalized' and mt.season_id = any(mem.shown)
    and (a_id is null or (mt.played_at, mt.id) < (a_at, a_id))
   order by mt.played_at desc, mt.id desc limit v_lim + 1) x
  order by x.played_at desc, x.match_id desc limit v_lim + 1)
 select coalesce(jsonb_agg(to_jsonb(page) order by played_at desc, match_id desc), '[]'::jsonb), count(*)
 into v_items, v_n from page;
 if v_n > v_lim then
  v_items := (select jsonb_agg(x order by o) from jsonb_array_elements(v_items) with ordinality q(x, o) where o <= v_lim);
  v_next := jsonb_build_object('played_at', v_items->(v_lim-1)->'played_at', 'match_id', v_items->(v_lim-1)->'match_id');
 end if;
 return jsonb_build_object('items', v_items, 'next', v_next);
end $$;

---------------------------------------------------------------------------------------------------
-- Convites
---------------------------------------------------------------------------------------------------

-- Same signature and the same "valid/already_member/pelada_id" fields as 034, plus why it does not work and what
-- happens on entry. Nothing here lets anyone in: join_pelada (004) keeps every rule.
create or replace function public.get_invite_preview(p_token text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_inv private.pelada_invites%rowtype; v_p public.peladas%rowtype; v_m public.pelada_memberships%rowtype; v_reason text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return jsonb_build_object('valid', false, 'reason', 'not_found'); end if;
 select * into v_inv from private.pelada_invites where token_hash=encode(extensions.digest(p_token,'sha256'),'hex');
 if not found then return jsonb_build_object('valid', false, 'reason', 'not_found'); end if;
 select * into v_p from public.peladas where id = v_inv.pelada_id;
 v_reason := case when v_p.status is distinct from 'active' then 'pelada_inactive'
  when v_inv.revoked_at is not null then 'revoked' when v_inv.expires_at <= now() then 'expired'
  when v_inv.uses >= v_inv.max_uses then 'used_up' end;
 select * into v_m from public.pelada_memberships where pelada_id = v_inv.pelada_id and user_id = auth.uid();
 if v_m.id is not null and v_m.status = 'active' then
  return jsonb_build_object('valid', true, 'pelada_name', v_p.name, 'already_member', true,
   'pelada_id', v_inv.pelada_id);
 end if;
 if v_reason is not null then
  return jsonb_build_object('valid', false, 'reason', v_reason, 'pelada_name', case when v_reason <> 'pelada_inactive' then v_p.name end);
 end if;
 return jsonb_build_object('valid', true, 'pelada_name', v_p.name, 'already_member', false,
  'pelada_id', null, 'expires_at', v_inv.expires_at,
  'membership_status', v_m.status,
  'can_join', v_m.id is null or v_m.status = 'left',
  'needs_position', v_m.id is null);
end $$;

---------------------------------------------------------------------------------------------------
-- Notificações por categoria
---------------------------------------------------------------------------------------------------

alter table public.notification_preferences add column categories jsonb not null default '{}'::jsonb
 check (jsonb_typeof(categories) = 'object');

create function private.notification_category(p_event text) returns text
language sql immutable set search_path = '' as $$
 select case
  when p_event in ('voting_opened','voting_restarted','sheet_corrected') then 'match_voting'
  when p_event = 'voting_closing_soon' then 'voting_reminder'
  when p_event in ('result_published','match_annulled') then 'results'
  when p_event like 'award\_%' or p_event in ('sticker_unlocked','season_review') then 'awards'
  when p_event in ('admin_succession','role_changed','successor_designated','subscription_changed') then 'pelada'
  when p_event = 'account_transferred' then 'account'
  else 'other' end;
$$;

-- 035 + the category switch (OPTED_OUT). Order and other reasons unchanged.
create or replace function private.push_skip_reason(p_id uuid) returns text
language sql stable security definer set search_path = '' as $$
 select case
  when e.attempt_count >= 5 then 'MAX_ATTEMPTS'
  when e.created_at < now() - interval '24 hours' then 'STALE'
  when e.event_type = 'award_bola_murcha' then 'POLICY'
  when e.pelada_id is not null and not exists(select 1 from public.pelada_memberships m
    where m.pelada_id=e.pelada_id and m.user_id=e.user_id and m.status='active') then 'NO_ACCESS'
  when e.event_type <> 'account_transferred' and exists(select 1 from public.notification_preferences p
    where p.user_id=e.user_id and ((e.category='essential' and not p.essential) or (e.category='engagement' and not p.engagement)
     or (p.categories ->> private.notification_category(e.event_type)) = 'false'))
   then 'OPTED_OUT'
  when e.event_type in ('voting_opened','voting_closing_soon','sheet_corrected','voting_restarted')
   and not exists(select 1 from public.voting_sessions v where v.match_id=private.try_uuid(e.payload->>'match_id')
    and v.status='open') then 'VOTING_CLOSED'
  when not exists(select 1 from public.push_devices d where d.user_id=e.user_id) then 'NO_DEVICE'
 end
 from public.notification_events e where e.id=p_id;
$$;

create function public.get_notification_preferences() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v public.notification_preferences;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v from public.notification_preferences where user_id = auth.uid();
 return jsonb_build_object('essential', coalesce(v.essential, true), 'engagement', coalesce(v.engagement, true),
  'categories', (select jsonb_object_agg(k, coalesce((v.categories ->> k)::boolean, true))
    from unnest(array['match_voting','voting_reminder','results','awards','pelada']) k));
end $$;

create function public.set_notification_category(p_category text, p_enabled boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_category is null or p_category not in ('match_voting','voting_reminder','results','awards','pelada') or p_enabled is null then
  raise exception 'INVALID_PREFERENCES'; end if;
 insert into public.notification_preferences(user_id, categories) values(auth.uid(), jsonb_build_object(p_category, p_enabled))
 on conflict (user_id) do update set categories = public.notification_preferences.categories || jsonb_build_object(p_category, p_enabled),
  updated_at = now();
 return public.get_notification_preferences();
end $$;

---------------------------------------------------------------------------------------------------
-- Grants
---------------------------------------------------------------------------------------------------

revoke all on function private.last_match_of(uuid), private.notification_category(text) from public, anon, authenticated;
revoke all on function public.set_primary_pelada(uuid), public.set_guide_state(text), public.get_player_central(),
 public.get_player_career_summary(uuid), public.get_trophy_history(uuid,text,jsonb,integer),
 public.get_my_match_history(uuid,jsonb,integer), public.get_notification_preferences(),
 public.set_notification_category(text,boolean) from public, anon;
grant execute on function public.set_primary_pelada(uuid), public.set_guide_state(text), public.get_player_central(),
 public.get_player_career_summary(uuid), public.get_trophy_history(uuid,text,jsonb,integer),
 public.get_my_match_history(uuid,jsonb,integer), public.get_notification_preferences(),
 public.set_notification_category(text,boolean) to authenticated;
