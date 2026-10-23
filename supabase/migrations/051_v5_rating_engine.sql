-- Minuto 91 / 051: V5 (Prompt Master v2.0), motor de atributos e OVR (formula_version 2).
--
-- OVR = 0,3325 ATU + 0,3325 EST + 0,19 PEQ + 0,095 RES + 0,05 DIS, por jogador e por pelada (carreira na
-- pelada, sem temporada), últimas 20 partidas oficiais disputadas. Exibido só com 5+ partidas.
-- Parâmetros aprovados em 23/10/2026 (C1-C5, D1-D8): docs/v5_fase_a_b_diagnostico_2026-10-23.md.
-- Referência em JS idêntica: supabase/local_db/rating/engine.mjs (conferida por rating_sql.test.mjs).
--
-- - private.rating_params: parâmetros versionados (versão ativa = maior com active). Constantes que fazem
--   parte das fórmulas aprovadas (29, 20, 1,3, 1,2, 6, 0,06...) ficam nas funções puras.
-- - public.player_ratings: valor atual por membro (fonte do card). public.player_rating_history: um registro
--   por evento (partida oficial, publicação de notas, correção, anulação, posição, cartões, defesas), com
--   'original' na primeira vez e 'recalculated' quando uma correção muda os valores; nada é sobrescrito.
-- - D1: a carta por temporada (player_cards) passa a carregar o OVR v2 (overall, faixa, provisória = menos de
--   5 partidas) nas temporadas que terminam a partir do corte; temporadas encerradas antes ficam como estavam.
--   As colunas antigas (finishing...peer_rating) continuam calculadas só como estatística interna.
-- - D2: bronze < 65 <= prata < 80 <= ouro sobre o OVR exibido.
-- - D3: a nota da partida é só a dos votos (q = 0,5 média companheiros + 0,5 média adversários; 052).
--   Partidas antigas entram no ATU pela parte dos votos que já tinham (peer_rating), nunca pela nota mista.
-- Rollback: recriar private.recompute_card (014), private.recompute_cards (037), private.after_match_finalized
-- (038), public.get_season_ranking (015) e dropar as tabelas e funções rating_*.

create table private.rating_params (
 version integer primary key,
 formula_version integer not null,
 params jsonb not null,
 active boolean not null default true,
 created_at timestamptz not null default now()
);
revoke all on private.rating_params from public, anon, authenticated;

insert into private.rating_params(version, formula_version, params) values (1, 2, jsonb_build_object(
 'weights', jsonb_build_object('ATU',0.3325,'EST',0.3325,'PEQ',0.19,'RES',0.095,'DIS',0.05),
 'window', 20, 'min_matches_for_ovr', 5,
 'def_share', jsonb_build_object('ZAG',0.65,'LAT',0.5,'VOL',0.5,'MEI',0.15,'ATA',0.05,'PON',0.05),
 'goal_share', jsonb_build_object('ZAG',0.45,'LAT',0.5,'VOL',0.5,'MEI',0.55,'ATA',0.7,'PON',0.7),
 'mu_g0', jsonb_build_object('ZAG',0.1,'LAT',0.15,'VOL',0.2,'MEI',0.4,'ATA',0.7,'PON',0.7),
 'mu_a0', jsonb_build_object('ZAG',0.1,'LAT',0.2,'VOL',0.25,'MEI',0.4,'ATA',0.3,'PON',0.3),
 'mu_c0', 3.0, 'mu_floor', 0.05,
 'local_window', 40, 'local_trim', 0.1, 'alpha_k', 150, 'alpha_max', 0.5,
 'ref_neutral', 65, 'ref_shrink', 3, 'transition_matches', 5,
 'dis', jsonb_build_object('start',70,'min',50,'max',99,'recovery',0.06,'yellow',8,'red',20),
 'tiers', jsonb_build_object('prata',65,'ouro',80),
 -- Temporadas encerradas antes deste dia mantêm a carta v1.
 'cutover_date', to_char(current_date,'YYYY-MM-DD')));

create function private.rating_params_active() returns private.rating_params
language sql stable security definer set search_path = '' as $$
 select * from private.rating_params where active order by version desc limit 1;
$$;

---------------------------------------------------------------------------------------------------
-- Funções puras (double precision; arredondar só para exibir)
---------------------------------------------------------------------------------------------------
create function private.rating_position(p_code text, p_sector text) returns text
language sql immutable set search_path = '' as $$
 select case p_code when 'GOL' then 'GOL' when 'ZAG' then 'ZAG' when 'LD' then 'LAT' when 'LE' then 'LAT'
  when 'VOL' then 'VOL' when 'MEI' then 'MEI' when 'CA' then 'ATA' when 'ATA' then 'ATA'
  when 'PD' then 'PON' when 'PE' then 'PON' else
  case p_sector when 'goalkeeper' then 'GOL' when 'defender' then 'ZAG' when 'attacker' then 'ATA' else 'MEI' end end;
$$;

create function private.rating_round(x float8) returns integer
language sql immutable set search_path = '' as $$ select floor(x + 0.5)::int $$;

create function private.rating_atu_curve(q float8) returns float8
language sql immutable set search_path = '' as $$
 select case when x <= 5 then 10*x when x <= 6 then 50 + 8*(x-5) when x <= 7 then 58 + 10*(x-6)
  when x <= 8 then 68 + 12*(x-7) when x <= 9 then 80 + 11*(x-8) else 91 + 8*(x-9) end
 from (select least(10, greatest(0, q)) x) s;
$$;

create function private.rating_off(g float8, a float8, n float8, mu_g float8, mu_a float8, share float8) returns float8
language sql immutable set search_path = '' as $$
 select 70 + 29*tanh(1.3*greatest(0, z)) - 20*tanh(greatest(0, -z))
 from (select share*ln(((g + 6*mu_g)/(n + 6))/mu_g) + (1-share)*ln(((a + 6*mu_a)/(n + 6))/mu_a) z) s;
$$;

create function private.rating_def(c float8, n float8, mu_c float8) returns float8
language sql immutable set search_path = '' as $$
 select 70 + 29*tanh(1.2*greatest(0, l)) - 20*tanh(1.2*greatest(0, -l))
 from (select ln(mu_c/((c + 6*mu_c)/(n + 6))) l) s;
$$;

create function private.rating_ref_match(d float8) returns float8
language sql immutable set search_path = '' as $$
 select case when d <= 5 then 65 + 3*d else 80 + 19*(1 - exp(-(d-5)/4)) end;
$$;

create function private.rating_peq(v float8, e float8, n float8) returns float8
language sql immutable set search_path = '' as $$
 select case when n = 0 then 70 else least(99, greatest(0, 70 + 35*(2*((3*v + e)/(3*n)) - 1)*(n/(n + 4)))) end;
$$;

create function private.rating_res(a float8, n float8) returns float8
language sql immutable set search_path = '' as $$
 select case when n = 0 then 70 else 70 + (100*a - 70*n)/(n + 4) end;
$$;

create function private.rating_local_ref(mu0 float8, n integer, trimmed float8, p jsonb) returns float8
language sql immutable set search_path = '' as $$
 select greatest((p->>'mu_floor')::float8, case when n = 0 or trimmed is null then mu0 else
  (1 - least((p->>'alpha_max')::float8, n::float8/(n + (p->>'alpha_k')::float8)))*mu0
  + least((p->>'alpha_max')::float8, n::float8/(n + (p->>'alpha_k')::float8))*trimmed end);
$$;

---------------------------------------------------------------------------------------------------
-- Referências locais (C3): média aparada, sem o próprio jogador, últimas 40 partidas oficiais da pelada
---------------------------------------------------------------------------------------------------
create function private.rating_refs(p_pelada uuid, p_membership uuid, p_pos text, p jsonb)
returns table(mu_g float8, mu_a float8, mu_c float8)
language sql stable security definer set search_path = '' as $$
 with recent as (
  select m.id, m.team_a_score, m.team_b_score from public.matches m
  where m.pelada_id=p_pelada and m.status='finalized'
  order by m.played_at desc, m.id desc limit (p->>'local_window')::int),
 pm as (
  select p2.id, p2.match_id, p2.membership_id,
   coalesce(sum(e.quantity) filter (where e.event_type='goal'),0)::float8 g,
   coalesce(sum(e.quantity) filter (where e.event_type='assist'),0)::float8 a
  from recent r join public.match_participants p2 on p2.match_id=r.id
  left join public.match_events e on e.participant_id=p2.id
  where private.rating_position(p2.position_code, p2.primary_position)=p_pos
   and p2.membership_id is distinct from p_membership
  group by p2.id, p2.match_id, p2.membership_id),
 side as (
  select r.id, t.team, case t.team when 'A' then r.team_b_score else r.team_a_score end::float8 c
  from recent r cross join (values ('A'),('B')) t(team)
  where not exists(select 1 from public.match_participants x where x.match_id=r.id and x.team=t.team
   and x.membership_id=p_membership)),
 tg as (select g v, row_number() over (order by g) rn, count(*) over () n from pm),
 ta as (select a v, row_number() over (order by a) rn, count(*) over () n from pm),
 tc as (select c v, row_number() over (order by c) rn, count(*) over () n from side),
 trim_g as (select avg(v) filter (where rn > floor(n*(p->>'local_trim')::float8) and rn <= n - floor(n*(p->>'local_trim')::float8)) m,
   max(n)::int n from tg),
 trim_a as (select avg(v) filter (where rn > floor(n*(p->>'local_trim')::float8) and rn <= n - floor(n*(p->>'local_trim')::float8)) m,
   max(n)::int n from ta),
 trim_c as (select avg(v) filter (where rn > floor(n*(p->>'local_trim')::float8) and rn <= n - floor(n*(p->>'local_trim')::float8)) m,
   max(n)::int n from tc)
 select
  case when p_pos='GOL' then null else private.rating_local_ref((p->'mu_g0'->>p_pos)::float8, coalesce(trim_g.n,0), trim_g.m, p) end,
  case when p_pos='GOL' then null else private.rating_local_ref((p->'mu_a0'->>p_pos)::float8, coalesce(trim_a.n,0), trim_a.m, p) end,
  private.rating_local_ref((p->>'mu_c0')::float8, coalesce(trim_c.n,0), trim_c.m, p)
 from trim_g, trim_a, trim_c;
$$;

-- EST de uma posição sobre a janela (totais já somados).
create function private.rating_est(p_pos text, g float8, a float8, c float8, n float8, ref float8,
 mu_g float8, mu_a float8, mu_c float8, p jsonb) returns float8
language sql immutable set search_path = '' as $$
 select case when p_pos='GOL' then 0.7*ref + 0.3*private.rating_def(c, n, mu_c)
  else (p->'def_share'->>p_pos)::float8*private.rating_def(c, n, mu_c)
   + (1 - (p->'def_share'->>p_pos)::float8)*private.rating_off(g, a, n, mu_g, mu_a, (p->'goal_share'->>p_pos)::float8) end;
$$;

---------------------------------------------------------------------------------------------------
-- Cálculo completo de um membro
---------------------------------------------------------------------------------------------------
create function private.rating_compute(p_membership uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare rp private.rating_params; p jsonb; v_m public.pelada_memberships; v_tracking boolean;
 r record; v_all int := 0; v_win int; i int := 0; d float8; dd jsonb;
 s_q float8 := 0; m_q int := 0; s_g float8 := 0; s_a float8 := 0; s_c float8 := 0; s_v int := 0; s_e int := 0; n_w int := 0;
 ref_sw float8 := 0; ref_sv float8 := 0; ref_n int := 0; v_ref float8;
 v_atu float8; v_est float8; v_est_old float8; v_peq float8; v_res float8; v_dis float8; v_ovr float8;
 v_pos text; v_prev text; v_change public.position_changes; v_k int; rf record; rf_old record;
 v_rounds int; v_present int; v_since timestamptz; v_eligible boolean;
begin
 rp := private.rating_params_active(); p := rp.params; dd := p->'dis';
 select * into v_m from public.pelada_memberships where id=p_membership;
 select coalesce(cards_tracking,false) into v_tracking from public.pelada_settings where pelada_id=v_m.pelada_id;
 v_tracking := coalesce(v_tracking,false);
 v_pos := private.rating_position(v_m.position_code, v_m.preferred_position);

 select count(*)::int into v_all from public.match_participants x join public.matches m on m.id=x.match_id
 where x.membership_id=p_membership and m.status='finalized';
 v_win := least(v_all, (p->>'window')::int);
 v_dis := (dd->>'start')::float8;

 for r in
  select m.id, m.played_at, x.team,
   case when res.has_valid_rating then res.peer_rating::float8 end q,
   coalesce(res.goals,0) g, coalesce(res.assists,0) a, res.match_result,
   (case x.team when 'A' then m.team_b_score else m.team_a_score end)::float8 c,
   ks.hard_saves sv, m.discipline_status ds,
   coalesce((select sum(quantity) from public.match_events e where e.participant_id=x.id and e.event_type='yellow_card'),0)::int y,
   coalesce((select sum(quantity) from public.match_events e where e.participant_id=x.id and e.event_type in ('red_card','second_yellow')),0)::int rc
  from public.match_participants x join public.matches m on m.id=x.match_id and m.status='finalized'
  left join public.match_player_results res on res.match_id=m.id and res.membership_id=p_membership
  left join public.match_keeper_saves ks on ks.participant_id=x.id
  where x.membership_id=p_membership
  order by m.played_at, m.id
 loop
  i := i + 1;
  -- DIS: todas as partidas, em ordem cronológica.
  if v_tracking and r.ds='confirmed' then
   if r.y = 0 and r.rc = 0 then
    v_dis := v_dis + (dd->>'recovery')::float8*((dd->>'max')::float8 - v_dis);
   else
    for k in 1..r.y loop v_dis := greatest((dd->>'min')::float8, v_dis - (dd->>'yellow')::float8); end loop;
    for k in 1..r.rc loop v_dis := greatest((dd->>'min')::float8, v_dis - (dd->>'red')::float8); end loop;
   end if;
  end if;
  -- Janela: as últimas 20.
  if i > v_all - v_win then
   n_w := n_w + 1;
   if r.q is not null then s_q := s_q + (private.rating_atu_curve(r.q) - 70); m_q := m_q + 1; end if;
   s_g := s_g + r.g; s_a := s_a + r.a; s_c := s_c + r.c;
   if r.match_result='win' then s_v := s_v + 1; elsif r.match_result='draw' then s_e := s_e + 1; end if;
   if r.sv is not null then
    d := 30 - (v_win - n_w); -- a mais recente pesa 30
    ref_sw := ref_sw + d; ref_sv := ref_sv + d*private.rating_ref_match(r.sv); ref_n := ref_n + 1;
   end if;
  end if;
 end loop;
 if not v_tracking then v_dis := (dd->>'start')::float8; end if;
 v_dis := least((dd->>'max')::float8, greatest((dd->>'min')::float8, v_dis));

 v_atu := case when m_q = 0 then 70 else 70 + s_q/(m_q + 2 + 0.25*(n_w - m_q)) end;
 v_ref := case when ref_n = 0 then (p->>'ref_neutral')::float8 else (p->>'ref_neutral')::float8
  + (ref_n::float8/(ref_n + (p->>'ref_shrink')::float8))*(ref_sv/ref_sw - (p->>'ref_neutral')::float8) end;

 select * into rf from private.rating_refs(v_m.pelada_id, p_membership, v_pos, p);
 v_est := private.rating_est(v_pos, s_g, s_a, s_c, n_w, v_ref, rf.mu_g, rf.mu_a, rf.mu_c, p);

 -- C5: transição de 5 partidas após a troca de posição (só o EST).
 select * into v_change from public.position_changes where membership_id=p_membership order by changed_at desc, position_version desc limit 1;
 if found then
  v_prev := private.rating_position(v_change.from_position_code, v_change.from_position);
  select count(*)::int into v_k from public.match_participants x join public.matches m on m.id=x.match_id
  where x.membership_id=p_membership and m.status='finalized' and m.played_at > v_change.changed_at;
  if v_prev is distinct from v_pos and v_k < (p->>'transition_matches')::int and v_change.from_position is not null then
   select * into rf_old from private.rating_refs(v_m.pelada_id, p_membership, v_prev, p);
   v_est_old := private.rating_est(v_prev, s_g, s_a, s_c, n_w, v_ref, rf_old.mu_g, rf_old.mu_a, rf_old.mu_c, p);
   v_est := (v_k::float8/(p->>'transition_matches')::float8)*v_est
    + (1 - v_k::float8/(p->>'transition_matches')::float8)*v_est_old;
  else v_k := null; v_prev := null;
  end if;
 end if;

 v_peq := private.rating_peq(s_v, s_e, n_w);

 -- RES: últimas 20 rodadas oficiais desde a entrada (uma partida por rodada nesta versão).
 select min(m.played_at) into v_since from public.match_participants x join public.matches m on m.id=x.match_id
 where x.membership_id=p_membership and m.status='finalized';
 v_since := least(v_m.joined_at, coalesce(v_since, v_m.joined_at));
 select count(*)::int, count(*) filter (where pl)::int into v_rounds, v_present from (
  select exists(select 1 from public.match_participants x where x.match_id=m.id and x.membership_id=p_membership) pl
  from public.matches m where m.pelada_id=v_m.pelada_id and m.status='finalized' and m.played_at >= v_since
  order by m.played_at desc, m.id desc limit (p->>'window')::int) t;
 v_res := private.rating_res(v_present, v_rounds);

 v_ovr := least(99, greatest(0, (p->'weights'->>'ATU')::float8*v_atu + (p->'weights'->>'EST')::float8*v_est
  + (p->'weights'->>'PEQ')::float8*v_peq + (p->'weights'->>'RES')::float8*v_res + (p->'weights'->>'DIS')::float8*v_dis));
 v_eligible := v_all >= (p->>'min_matches_for_ovr')::int;

 return jsonb_build_object('atu',v_atu,'est',v_est,'peq',v_peq,'res',v_res,'dis',v_dis,'ovr',v_ovr,
  'ovr_display',case when v_eligible then private.rating_round(v_ovr) end,'eligible',v_eligible,
  'matches_played',v_all,'position',v_pos,'previous_position',v_prev,'transition_k',v_k,'ref',v_ref,
  'refs',jsonb_build_object('mu_g',rf.mu_g,'mu_a',rf.mu_a,'mu_c',rf.mu_c),
  'cards_tracking',v_tracking,'formula_version',rp.formula_version,'params_version',rp.version);
end $$;

create function private.rating_tier(p_display integer) returns text
language sql stable security definer set search_path = '' as $$
 select case when p_display is null then null
  when p_display < ((private.rating_params_active()).params->'tiers'->>'prata')::int then 'bronze'
  when p_display < ((private.rating_params_active()).params->'tiers'->>'ouro')::int then 'prata' else 'ouro' end;
$$;

---------------------------------------------------------------------------------------------------
-- Estado atual e histórico
---------------------------------------------------------------------------------------------------
create table public.player_ratings (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 membership_id uuid not null,
 position text not null check (position in ('GOL','ZAG','LAT','VOL','MEI','ATA','PON')),
 atu numeric(9,6) not null, est numeric(9,6) not null, peq numeric(9,6) not null,
 res numeric(9,6) not null, dis numeric(9,6) not null,
 ovr numeric(9,6) not null check (ovr between 0 and 99),
 ovr_display integer check (ovr_display between 0 and 99),
 tier text check (tier in ('bronze','prata','ouro')),
 eligible boolean not null,
 matches_played integer not null,
 transition_k integer,
 formula_version integer not null,
 params_version integer not null,
 updated_at timestamptz not null default now(),
 constraint rating_display_when_eligible check (eligible = (ovr_display is not null)),
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 unique (membership_id)
);
create index player_ratings_by_pelada on public.player_ratings(pelada_id);

create table public.player_rating_history (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 membership_id uuid not null,
 match_id uuid references public.matches(id),
 event text not null check (event in ('match_finalized','votes_published','sheet_corrected','annulment',
  'position','cards_tracking','discipline','hard_saves','recompute')),
 kind text not null check (kind in ('original','recalculated')),
 position text not null,
 atu numeric(9,6) not null, est numeric(9,6) not null, peq numeric(9,6) not null,
 res numeric(9,6) not null, dis numeric(9,6) not null,
 ovr numeric(9,6) not null, ovr_display integer,
 formula_version integer not null,
 params_version integer not null,
 created_at timestamptz not null default now(),
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id)
);
create index rating_history_by_member on public.player_rating_history(membership_id, created_at);
create unique index one_original_rating_per_event on public.player_rating_history(membership_id, match_id, event)
 where kind='original' and match_id is not null;

alter table public.player_ratings enable row level security;
alter table public.player_rating_history enable row level security;
revoke all on public.player_ratings, public.player_rating_history from anon,authenticated;
grant select on public.player_ratings, public.player_rating_history to authenticated;
-- Mesma regra das cartas: membros ativos da pelada. Antes de 5 partidas o OVR não é exibido:
-- a coluna ovr (cálculo interno) não é legível pelo app; o app lê ovr_display e os atributos.
create policy ratings_read on public.player_ratings for select to authenticated
 using ((select private.is_active_member(pelada_id)));
create policy rating_history_read on public.player_rating_history for select to authenticated
 using ((select private.is_active_member(pelada_id)));
revoke select on public.player_ratings, public.player_rating_history from authenticated;
grant select (id, pelada_id, membership_id, position, atu, est, peq, res, dis, ovr_display, tier, eligible,
 matches_played, transition_k, formula_version, params_version, updated_at) on public.player_ratings to authenticated;
grant select (id, pelada_id, membership_id, match_id, event, kind, position, atu, est, peq, res, dis, ovr_display,
 formula_version, params_version, created_at) on public.player_rating_history to authenticated;

-- Evento corrente (definido por quem dispara o recálculo na mesma transação).
create function private.rating_event() returns text
language sql stable set search_path = '' as $$
 select coalesce(nullif(current_setting('minuto91.rating_event', true),''), 'match_finalized');
$$;

create function private.recompute_pelada_ratings(p_pelada uuid, p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_mem uuid; j jsonb; v_event text := private.rating_event(); v_last public.player_rating_history; v_kind text;
begin
 if p_match is not null and exists(select 1 from public.matches where id=p_match and status='annulled') then
  v_event := 'annulment'; end if;
 for v_mem in select m.id from public.pelada_memberships m where m.pelada_id=p_pelada
   and (m.status='active' or exists(select 1 from public.player_ratings r where r.membership_id=m.id))
   order by m.id loop
  j := private.rating_compute(v_mem);
  insert into public.player_ratings(pelada_id,membership_id,position,atu,est,peq,res,dis,ovr,ovr_display,tier,eligible,
   matches_played,transition_k,formula_version,params_version)
  values(p_pelada,v_mem,j->>'position',(j->>'atu')::numeric,(j->>'est')::numeric,(j->>'peq')::numeric,(j->>'res')::numeric,
   (j->>'dis')::numeric,(j->>'ovr')::numeric,(j->>'ovr_display')::int,private.rating_tier((j->>'ovr_display')::int),
   (j->>'eligible')::boolean,(j->>'matches_played')::int,(j->>'transition_k')::int,(j->>'formula_version')::int,
   (j->>'params_version')::int)
  on conflict (membership_id) do update set position=excluded.position, atu=excluded.atu, est=excluded.est,
   peq=excluded.peq, res=excluded.res, dis=excluded.dis, ovr=excluded.ovr, ovr_display=excluded.ovr_display,
   tier=excluded.tier, eligible=excluded.eligible, matches_played=excluded.matches_played,
   transition_k=excluded.transition_k, formula_version=excluded.formula_version,
   params_version=excluded.params_version, updated_at=now();

  -- Histórico: só quando algo mudou desde o último registro (reprocessar não duplica).
  select * into v_last from public.player_rating_history where membership_id=v_mem order by created_at desc, id desc limit 1;
  if found and v_last.ovr = round((j->>'ovr')::numeric,6) and v_last.atu = round((j->>'atu')::numeric,6)
    and v_last.est = round((j->>'est')::numeric,6) and v_last.peq = round((j->>'peq')::numeric,6)
    and v_last.res = round((j->>'res')::numeric,6) and v_last.dis = round((j->>'dis')::numeric,6)
    and v_last.position = j->>'position' then
   continue;
  end if;
  v_kind := case when v_event in ('match_finalized','votes_published','position','cards_tracking')
    and not exists(select 1 from public.player_rating_history h where h.membership_id=v_mem
     and h.match_id is not distinct from p_match and h.event=v_event and h.kind='original')
   then 'original' else 'recalculated' end;
  insert into public.player_rating_history(pelada_id,membership_id,match_id,event,kind,position,atu,est,peq,res,dis,
   ovr,ovr_display,formula_version,params_version)
  values(p_pelada,v_mem,p_match,v_event,v_kind,j->>'position',(j->>'atu')::numeric,(j->>'est')::numeric,
   (j->>'peq')::numeric,(j->>'res')::numeric,(j->>'dis')::numeric,(j->>'ovr')::numeric,(j->>'ovr_display')::int,
   (j->>'formula_version')::int,(j->>'params_version')::int);
 end loop;
end $$;

---------------------------------------------------------------------------------------------------
-- Cartas (D1): a carta da temporada passa a mostrar o OVR v2
---------------------------------------------------------------------------------------------------
alter function private.recompute_card(uuid,uuid,uuid) rename to recompute_card_v1;

-- Atributos v2 na própria carta (o app lê a carta como antes; nulos nas cartas v1).
alter table public.player_cards add column atu numeric(9,6), add column est numeric(9,6), add column peq numeric(9,6),
 add column res numeric(9,6), add column dis numeric(9,6), add column ovr_display integer, add column rating_position text;

create function private.recompute_card(p_season uuid, p_membership uuid, p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_s public.seasons; v_r public.player_ratings; v_card uuid;
begin
 select * into v_s from public.seasons where id=p_season;
 if v_s.ends_on < ((private.rating_params_active()).params->>'cutover_date')::date then
  perform private.recompute_card_v1(p_season, p_membership, p_match);
  return;
 end if;
 perform private.recompute_card_v1(p_season, p_membership, null);
 select * into v_r from public.player_ratings where membership_id=p_membership;
 if not found then return; end if;
 update public.player_cards set overall=round(v_r.ovr,6),
  tier=coalesce(v_r.tier, case when round(v_r.ovr,0) < 65 then 'bronze' when round(v_r.ovr,0) < 80 then 'prata' else 'ouro' end),
  is_provisional=not v_r.eligible, formula_version=v_r.formula_version,
  atu=round(v_r.atu,6), est=round(v_r.est,6),
  peq=round(v_r.peq,6), res=round(v_r.res,6), dis=round(v_r.dis,6), ovr_display=v_r.ovr_display,
  rating_position=v_r.position, updated_at=now()
 where season_id=p_season and membership_id=p_membership returning id into v_card;
 if v_card is not null and p_match is not null then
  insert into public.card_snapshots(card_id,match_id,snapshot_data,formula_version)
  select c.id, p_match, jsonb_build_object('position',c.position,'rating_position',v_r.position,'overall',c.overall,
   'ovr_display',v_r.ovr_display,'tier',c.tier,'is_provisional',c.is_provisional,'matches_played',v_r.matches_played,
   'atu',v_r.atu,'est',v_r.est,'peq',v_r.peq,'res',v_r.res,'dis',v_r.dis,'params_version',v_r.params_version),
   v_r.formula_version
  from public.player_cards c where c.id=v_card
  on conflict (card_id, match_id) do update set snapshot_data=excluded.snapshot_data,
   formula_version=excluded.formula_version, created_at=now();
 end if;
end $$;

-- Antes das cartas, o OVR de todos os membros da pelada (RES e referências locais mudam a cada rodada).
create or replace function private.recompute_cards(p_season uuid, p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_next uuid; v_pelada uuid;
begin
 select pelada_id into v_pelada from public.seasons where id=p_season;
 perform private.recompute_pelada_ratings(v_pelada, p_match);
 perform private.recompute_season_cards(p_season, p_match);
 for v_next in select s2.id from public.seasons s1 join public.seasons s2 on s2.pelada_id=s1.pelada_id
   and s2.starts_on > s1.starts_on where s1.id=p_season order by s2.starts_on loop
  if exists(select 1 from public.player_cards where season_id=v_next) then
   perform private.recompute_season_cards(v_next, null);
  end if;
 end loop;
end $$;

-- Mudanças fora da finalização (posição, cartões, defesas, disciplina): OVR + cartas da temporada atual.
create or replace function private.after_rating_inputs_changed(p_pelada uuid, p_match uuid, p_event text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_season uuid;
begin
 perform set_config('minuto91.rating_event', p_event, true);
 select m.season_id into v_season from public.matches m where m.pelada_id=p_pelada and m.status='finalized'
 order by m.played_at desc, m.id desc limit 1;
 if v_season is null then
  perform private.recompute_pelada_ratings(p_pelada, p_match);
 else
  perform private.recompute_cards(v_season, p_match);
 end if;
 perform set_config('minuto91.rating_event', '', true);
end $$;

-- Ranking por OVR: só quem já tem OVR exibido (5+ partidas) nas temporadas v2.
create or replace function public.get_season_ranking(p_season uuid, p_metric text)
returns table(rank_position bigint, membership_id uuid, metric_value numeric)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
 perform private.check_season_access(p_season);
 if p_metric is null or p_metric not in ('overall','goals','assists','avg_rating','matches','wins') then
  raise exception 'INVALID_METRIC'; end if;
 return query
 select rank() over (order by t.v desc), t.mem, t.v from (
  select c.membership_id mem, case when c.formula_version >= 2 then round(c.overall,0) else c.overall end v
  from public.player_cards c where p_metric='overall' and c.season_id=p_season
   and (c.formula_version < 2 or not c.is_provisional)
  union all
  select s.membership_id, case p_metric when 'goals' then s.goals when 'assists' then s.assists
   when 'matches' then s.matches_played when 'wins' then s.wins else s.avg_final_rating end
  from public.player_season_stats s where p_metric<>'overall' and s.season_id=p_season
   and (p_metric<>'avg_rating' or s.avg_final_rating is not null)) t
 order by 1, 2;
end $$;

-- Leitura do card v2 de um membro (respeita a mesma visibilidade das cartas).
create function public.get_player_rating(p_membership uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_r public.player_ratings; v_pelada uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.pelada_memberships where id=p_membership;
 if not found or not private.is_active_member(v_pelada) then raise exception 'NOT_FOUND'; end if;
 select * into v_r from public.player_ratings where membership_id=p_membership;
 if not found then
  return jsonb_build_object('membership_id',p_membership,'eligible',false,'matches_played',0,'ovr',null);
 end if;
 return jsonb_build_object('membership_id',p_membership,'position',v_r.position,'eligible',v_r.eligible,
  'matches_played',v_r.matches_played,'matches_needed',greatest(0, 5 - v_r.matches_played),
  'ovr',v_r.ovr_display,'tier',v_r.tier,
  'atu',round(v_r.atu,1),'est',round(v_r.est,1),'peq',round(v_r.peq,1),'res',round(v_r.res,1),'dis',round(v_r.dis,1),
  'in_transition',v_r.transition_k is not null,'formula_version',v_r.formula_version,'params_version',v_r.params_version,
  'history',coalesce((select jsonb_agg(jsonb_build_object('at',h.created_at,'event',h.event,'kind',h.kind,
    'ovr',h.ovr_display,'atu',round(h.atu,1),'est',round(h.est,1),'peq',round(h.peq,1),'res',round(h.res,1),
    'dis',round(h.dis,1)) order by h.created_at)
   from (select * from public.player_rating_history where membership_id=p_membership and ovr_display is not null
    order by created_at desc limit 60) h),'[]'::jsonb));
end $$;

revoke all on function private.rating_params_active(), private.rating_refs(uuid,uuid,text,jsonb),
 private.rating_compute(uuid), private.rating_tier(integer), private.recompute_pelada_ratings(uuid,uuid),
 private.recompute_card_v1(uuid,uuid,uuid), private.recompute_card(uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.get_player_rating(uuid) from public,anon;
grant execute on function public.get_player_rating(uuid) to authenticated;

-- Minha Carreira (049): a carta de cada temporada leva também os atributos v2. A função é copiada do catálogo e
-- recebe só os campos novos (o restante fica idêntico ao da 049); se o texto esperado não existir, a migração para.
do $patch$
declare v_def text; v_new text;
begin
 v_def := pg_get_functiondef('public.get_player_career_summary(uuid)'::regprocedure);
 v_new := replace(v_def, 'c.finishing, c.assisting, c.attendance, c.winning, c.peer_rating, c.matches_played card_matches,',
  'c.finishing, c.assisting, c.attendance, c.winning, c.peer_rating, c.matches_played card_matches,
   c.formula_version card_fv, c.atu v_atu, c.est v_est, c.peq v_peq, c.res v_res, c.dis v_dis, c.ovr_display v_ovr,');
 v_new := replace(v_new, '''peer_rating'', peer_rating, ''matches_played'', card_matches) end)',
  '''peer_rating'', peer_rating, ''matches_played'', card_matches, ''formula_version'', card_fv, ''atu'', v_atu,
       ''est'', v_est, ''peq'', v_peq, ''res'', v_res, ''dis'', v_dis, ''ovr_display'', v_ovr) end)');
 if v_new = v_def or (length(v_new) - length(v_def)) < 200 then raise exception 'PATCH_CAREER_SUMMARY_FAILED'; end if;
 execute v_new;
end $patch$;

-- Evolução (037), em Minha Carreira: pontos e valor atual trazem os atributos v2; nas cartas v2 o overall é o OVR
-- exibido (nulo antes de 5 partidas: o gráfico não mostra número fictício). Mesmo método de cópia do catálogo.
do $patch$
declare v_def text; v_new text;
begin
 v_def := pg_get_functiondef('public.get_player_evolution(uuid,uuid)'::regprocedure);
 v_new := replace(v_def, '''overall'', (s.snapshot_data->>''overall'')::numeric, ''finishing''',
  '''overall'', case when s.formula_version >= 2 then (s.snapshot_data->>''ovr_display'')::numeric
     else (s.snapshot_data->>''overall'')::numeric end,
   ''atu'', (s.snapshot_data->>''atu'')::numeric, ''est'', (s.snapshot_data->>''est'')::numeric,
   ''peq'', (s.snapshot_data->>''peq'')::numeric, ''res'', (s.snapshot_data->>''res'')::numeric,
   ''dis'', (s.snapshot_data->>''dis'')::numeric, ''formula_version'', s.formula_version, ''finishing''');
 v_new := replace(v_new, 'select jsonb_build_object(''overall'', c.overall, ''finishing''',
  'select jsonb_build_object(''overall'', case when c.formula_version >= 2 then c.ovr_display else c.overall end,
   ''atu'', c.atu, ''est'', c.est, ''peq'', c.peq, ''res'', c.res, ''dis'', c.dis, ''formula_version'', c.formula_version,
   ''finishing''');
 if (length(v_new) - length(v_def)) < 400 then raise exception 'PATCH_EVOLUTION_FAILED'; end if;
 execute v_new;
end $patch$;
