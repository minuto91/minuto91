-- Minuto 91 / 053: motor matemático V7.7 (formula_version 3, rating_params version 2).
--
-- Substitui o OVR da V5 (ATU/EST/PEQ/RES/DIS, 051) pelos atributos definitivos:
--   jogador de linha: DEF, LET, APR, RES, DIS      goleiro: DEF, REF, APR, RES, DIS
--   OVR = pesos por posição (GOL 40/35/10/10/5, ZAG 45/30, LAT 40/35, VOL 35/40, MEI 25/50, ATA e PON 20/55).
-- Fonte das fórmulas: protótipo congelado v77_engine.py (+ v72_corrected.py, MovingState de v73_engine.py), cópias
-- versionadas em supabase/local_db/rating/v77_reference/. Referência em JS idêntica: supabase/local_db/rating/v77.mjs
-- (conferida contra o SQL por rating_v77_sql.test.mjs e contra o Python por rating_v77.test.mjs).
-- Diferenças deliberadas em relação ao protótipo (D1-D4) e comportamentos congelados (P1-P2): ver v77.mjs e
-- docs/relatorio_v77_2026-10-24.md.
--
-- Arquitetura
-- - Núcleo puro em SQL (private.v77_*): recebe a carreira do jogador em JSON e devolve o estado; mesma entrada do JS.
--   private.v77_member_input monta a entrada a partir das tabelas; private.recompute_pelada_ratings reprocessa a
--   pelada inteira em ordem cronológica (correção ou anulação refazem o histórico de forma determinística).
-- - Uma só implementação autoritativa no servidor; o app só lê. Despacho por versão: com a versão 2 de parâmetros
--   ativa roda a V7.7; desativada, volta o motor da V5 (rollback sem perder dados, ver fim do arquivo).
-- - Proteções: trava consultiva por pelada (cálculos simultâneos da mesma pelada são serializados), impressão
--   digital da entrada por jogador (reprocessar sem mudança não grava nada), histórico só quando algo muda,
--   registro de cada execução em private.rating_runs.
-- - Por temporada: public.player_season_ratings guarda o estado de cada jogador ao fim de cada temporada (cartas).
--   A herança entre temporadas usa 50% das observações válidas da temporada anterior (teto 20) e não divide o
--   valor publicado.
-- - Cartas e classificações históricas: temporadas encerradas antes do corte da V7.7 ficam como estavam
--   (cartas v1 e v2 não são reescritas); a carta da temporada atual em diante passa a formula_version 3.
-- Nada histórico é apagado: colunas novas são opcionais, atu/est/peq passam a aceitar nulo (linhas v3).

---------------------------------------------------------------------------------------------------
-- 1. Parâmetros versionados
---------------------------------------------------------------------------------------------------
insert into private.rating_params(version, formula_version, params) values (2, 3, jsonb_build_object(
 'weights', jsonb_build_object('GOL',jsonb_build_array(0.40,0.35,0.10,0.10,0.05),'ZAG',jsonb_build_array(0.45,0.30,0.10,0.10,0.05),
  'LAT',jsonb_build_array(0.40,0.35,0.10,0.10,0.05),'VOL',jsonb_build_array(0.35,0.40,0.10,0.10,0.05),
  'MEI',jsonb_build_array(0.25,0.50,0.10,0.10,0.05),'ATA',jsonb_build_array(0.20,0.55,0.10,0.10,0.05),
  'PON',jsonb_build_array(0.20,0.55,0.10,0.10,0.05)),
 -- Referências posicionais V7.5 (iguais às da V7.2): gols e assistências por partida.
 'mu_g', jsonb_build_object('ZAG',0.1,'LAT',0.15,'VOL',0.2,'MEI',0.4,'ATA',0.7,'PON',0.7),
 'mu_a', jsonb_build_object('ZAG',0.1,'LAT',0.2,'VOL',0.25,'MEI',0.4,'ATA',0.3,'PON',0.3),
 'def_mu', 3, 'ref_mu', 3, 'min_matches_for_ovr', 5, 'carry_share', 0.5, 'carry_cap', 20,
 'transition_matches', 5, 'window', 10,
 'dis', jsonb_build_object('start',70,'min',50,'max',99,'recovery',0.06,'yellow',8,'red',20),
 'tiers', jsonb_build_object('prata',65,'ouro',80),
 -- Temporadas encerradas antes deste dia mantêm a carta que tinham (v1 ou v2).
 'cutover_date', to_char(current_date,'YYYY-MM-DD')));

---------------------------------------------------------------------------------------------------
-- 2. Funções puras (double precision; arredondar só para exibir)
---------------------------------------------------------------------------------------------------
create function private.v77_clip(x float8, lo float8 default 40, hi float8 default 99) returns float8
language sql immutable set search_path = '' as $$ select least(hi, greatest(lo, x)) $$;

create function private.v77_vote(q float8) returns float8
language sql immutable set search_path = '' as $$
 select private.v77_clip(case when q <= 8 then 68 + 12*(q - 7) else 80 + 11*(q - 8) end);
$$;

-- LET (v72 let): g, a = totais nas n partidas válidas; q = média das notas na escala do atributo.
create function private.v77_let(g float8, a float8, n float8, mu_g float8, mu_a float8, q float8) returns float8
language sql immutable set search_path = '' as $$
 with z as (select 5*((g/n)/mu_g - 1) zg, 5*((a/n)/mu_a - 1) za),
 s as (select private.v77_clip(75 + (case when zg >= 0 then 24 else 25 end)*tanh(zg)) sg,
              private.v77_clip(75 + (case when za >= 0 then 24 else 25 end)*tanh(za)) sa from z),
 t as (select least(99, greatest(sg, sa) + 0.1*greatest(0, least(sg, sa) - 75)) stat from s)
 select private.v77_clip(0.75*(70 + (n/(n + 3))*(stat - 70)) + 0.25*q) from t;
$$;

create function private.v77_def(c float8, n float8, q float8, mu float8) returns float8
language sql immutable set search_path = '' as $$
 with r as (select ln(mu/((c + 6*mu)/(n + 6))) z),
 s as (select 75 + case when z >= 0 then 24*tanh(1.2*z) else 25*tanh(1.2*z) end stat from r)
 select private.v77_clip(0.75*(70 + (n/(n + 3))*(stat - 70)) + 0.25*q) from s;
$$;

-- REF (v72 reflex): s = total de defesas difíceis nas n partidas COM registro. Sem registro = 70.
create function private.v77_ref(s float8, n float8, q float8, mu float8) returns float8
language sql immutable set search_path = '' as $$
 select case when n = 0 then 70::float8 else (
  with z as (select ((s/n) - mu)/2 z),
  t as (select private.v77_clip(75 + case when z >= 0 then 24*tanh(1.4*z) else 25*tanh(1.4*z) end) stat from z)
  select private.v77_clip(0.75*(70 + (n/(n + 3))*(stat - 70)) + 0.25*q) from t) end;
$$;

-- APR: r = soma dos resultados (vitória 1, empate 1/3, derrota 0).
create function private.v77_apr(r float8, n float8, q float8) returns float8
language sql immutable set search_path = '' as $$
 select private.v77_clip(0.9*(70 + 35*(2*((r + 2)/(n + 4)) - 1)*n/(n + 4)) + 0.1*q);
$$;

-- Resenha de um jogador numa partida: yes confirmações entre voters eleitores válidos (sem o próprio).
create function private.v77_resenha(yes integer, voters integer) returns boolean
language sql immutable set search_path = '' as $$
 select case when voters < 2 then null else yes >= 2 and yes*2 > voters end;
$$;

create function private.v77_step_dis(cur float8, yellow integer, red integer, d jsonb) returns float8
language sql immutable set search_path = '' as $$
 select case when coalesce(yellow,0) <> 0 or coalesce(red,0) <> 0
  then greatest((d->>'min')::float8, cur - (d->>'yellow')::float8*coalesce(yellow,0) - (d->>'red')::float8*coalesce(red,0))
  else least((d->>'max')::float8, cur + (d->>'recovery')::float8*((d->>'max')::float8 - cur)) end;
$$;

-- Checkpoint de quedas (MovingState da V7.3): janela real das 10 últimas variações do valor bruto.
create type private.v77_smoother as (published float8, last_raw float8, recent float8[]);

create function private.v77_smooth(st private.v77_smoother, raw float8, win integer) returns private.v77_smoother
language plpgsql immutable set search_path = '' as $$
declare d float8; downs int := 0; tot float8 := 0; x float8; alpha float8;
begin
 if raw is null then return st; end if;
 if st.published is null then
  st.published := raw; st.last_raw := raw; st.recent := coalesce(st.recent,'{}') || 0::float8;
  if cardinality(st.recent) > win then st.recent := st.recent[cardinality(st.recent)-win+1:]; end if;
  return st;
 end if;
 d := case when st.last_raw is not null then raw - st.last_raw else 0 end;
 st.recent := coalesce(st.recent,'{}') || d;
 if cardinality(st.recent) > win then st.recent := st.recent[cardinality(st.recent)-win+1:]; end if;
 st.last_raw := raw;
 if raw >= st.published then st.published := raw; return st; end if;
 foreach x in array st.recent loop
  tot := tot + x;
  if x < -0.00001 then downs := downs + 1; end if;
 end loop;
 alpha := 0.3 + 0.35*(downs::float8/10) + 0.2*least(1, greatest(0, -tot)/12);
 st.published := private.v77_clip(st.published + alpha*(raw - st.published));
 return st;
end $$;

create function private.v77_ovr(p_pos text, d float8, s float8, a float8, r float8, x float8, p jsonb) returns float8
language sql immutable set search_path = '' as $$
 select private.v77_clip((w->>0)::float8*d + (w->>1)::float8*s + (w->>2)::float8*a + (w->>3)::float8*r + (w->>4)::float8*x)
 from (select p->'weights'->p_pos w) t;
$$;

-- Uma temporada (porte de evaluate da V7.7). Eventos em ordem cronológica, um por rodada oficial desde a entrada:
-- {played, q, goals, assists, conceded, saves, result, yellow, red, cardsKnown, resenha}; null = sem dado.
-- p_prev: {attrs:{DEF,SEC,APR,RES,DIS}, evidence:{DEF,SEC,APR}} ou null. p_before: partidas em temporadas anteriores.
create function private.v77_season(p_events jsonb, p_pos text, p_prev jsonb, p_before integer, p jsonb,
 p_rows boolean default false) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare e jsonb; has_prev boolean := p_prev is not null and jsonb_typeof(p_prev) = 'object';
 w int := (p->>'window')::int; dd jsonb := p->'dis';
 st_d private.v77_smoother; st_s private.v77_smoother; st_a private.v77_smoother;
 n_d int := 0; n_s int := 0; n_a int := 0; sum_c float8 := 0; sum_g float8 := 0; sum_as float8 := 0; sum_sv float8 := 0; sum_r float8 := 0;
 vn_d int := 0; vn_s int := 0; vn_a int := 0; vs_d float8 := 0; vs_s float8 := 0; vs_a float8 := 0;
 qn int := 0; qs float8 := 0; kn int := 0; ky int := 0;
 played int := 0; attended int := 0; rounds int := 0;
 active boolean; q float8; vq float8; ok_d boolean; ok_s boolean; ok_a boolean; raw float8; strength float8;
 o_d float8; o_s float8; o_a float8; v_res float8; v_dis float8; v_ovr float8; freq float8; post float8; qmean float8;
 pr jsonb := case when has_prev then p_prev->'attrs' end; ev jsonb := case when has_prev then p_prev->'evidence' end;
 out_rows jsonb := '[]'; v_last jsonb;
begin
 st_d := row((pr->>'DEF')::float8, null, '{}'::float8[]);
 st_s := row((pr->>'SEC')::float8, null, '{}'::float8[]);
 st_a := row((pr->>'APR')::float8, null, '{}'::float8[]);
 v_res := case when has_prev then (pr->>'RES')::float8 else 70 end;
 v_dis := case when has_prev then (pr->>'DIS')::float8 else (dd->>'start')::float8 end;
 for e in select value from jsonb_array_elements(coalesce(p_events,'[]')) with ordinality t(value, o) order by o loop
  rounds := rounds + 1;
  active := coalesce((e->>'played')::boolean, true);
  ok_d := e->>'conceded' is not null;
  ok_s := case when p_pos = 'GOL' then e->>'saves' is not null else e->>'goals' is not null and e->>'assists' is not null end;
  ok_a := e->>'result' is not null;
  if active then
   attended := attended + 1; played := played + 1;
   q := (e->>'q')::float8;
   vq := case when q is not null then private.v77_vote(q) end;
   if ok_d then n_d := n_d + 1; sum_c := sum_c + (e->>'conceded')::float8;
    if vq is not null then vn_d := vn_d + 1; vs_d := vs_d + vq; end if; end if;
   if ok_s then n_s := n_s + 1;
    if p_pos = 'GOL' then sum_sv := sum_sv + (e->>'saves')::float8;
    else sum_g := sum_g + (e->>'goals')::float8; sum_as := sum_as + (e->>'assists')::float8; end if;
    if vq is not null then vn_s := vn_s + 1; vs_s := vs_s + vq; end if; end if;
   if ok_a then n_a := n_a + 1; sum_r := sum_r + (e->>'result')::float8;
    if vq is not null then vn_a := vn_a + 1; vs_a := vs_a + vq; end if; end if;
   if vq is not null then qn := qn + 1; qs := qs + vq; end if;
   if e->>'resenha' is not null then kn := kn + 1; if (e->>'resenha')::boolean then ky := ky + 1; end if; end if;
   if coalesce((e->>'cardsKnown')::boolean, true) then
    v_dis := private.v77_step_dis(v_dis, coalesce((e->>'yellow')::int,0), coalesce((e->>'red')::int,0), dd);
   end if;
  end if;
  -- DEF
  if not active or n_d = 0 or not ok_d then o_d := coalesce(st_d.published, 70);
  else
   raw := private.v77_def(sum_c, n_d, case when vn_d > 0 then vs_d/vn_d else 70 end, (p->>'def_mu')::float8);
   if has_prev then strength := (p->>'carry_share')::float8*least((p->>'carry_cap')::float8, coalesce((ev->>'DEF')::float8,0));
    if strength > 0 then raw := (strength*(pr->>'DEF')::float8 + n_d*raw)/(strength + n_d); end if; end if;
   st_d := private.v77_smooth(st_d, raw, w); o_d := st_d.published;
  end if;
  -- LET / REF
  if not active or n_s = 0 or not ok_s then o_s := coalesce(st_s.published, 70);
  else
   if p_pos = 'GOL' then raw := private.v77_ref(sum_sv, n_s, case when vn_s > 0 then vs_s/vn_s else 70 end, (p->>'ref_mu')::float8);
   else raw := private.v77_let(sum_g, sum_as, n_s, (p->'mu_g'->>p_pos)::float8, (p->'mu_a'->>p_pos)::float8,
     case when vn_s > 0 then vs_s/vn_s else 70 end); end if;
   if has_prev then strength := (p->>'carry_share')::float8*least((p->>'carry_cap')::float8, coalesce((ev->>'SEC')::float8,0));
    if strength > 0 then raw := (strength*(pr->>'SEC')::float8 + n_s*raw)/(strength + n_s); end if; end if;
   st_s := private.v77_smooth(st_s, raw, w); o_s := st_s.published;
  end if;
  -- APR
  if not active or n_a = 0 or not ok_a then o_a := coalesce(st_a.published, 70);
  else
   raw := private.v77_apr(sum_r, n_a, case when vn_a > 0 then vs_a/vn_a else 70 end);
   if has_prev then strength := (p->>'carry_share')::float8*least((p->>'carry_cap')::float8, coalesce((ev->>'APR')::float8,0));
    if strength > 0 then raw := (strength*(pr->>'APR')::float8 + n_a*raw)/(strength + n_a); end if; end if;
   st_a := private.v77_smooth(st_a, raw, w); o_a := st_a.published;
  end if;
  -- RES (sem checkpoint): 60% frequência nas rodadas, 40% resenha; falta de resposta não conta.
  freq := (attended + 2)::float8/(rounds + 4);
  if kn > 0 then
   post := (ky + 2)::float8/(kn + 4);
   qmean := case when qn > 0 then qs/qn else 70 end;
   v_res := private.v77_clip(0.95*(0.6*(40 + 59*freq) + 0.4*(40 + 59*post)) + 0.05*qmean);
  elsif not has_prev then
   v_res := private.v77_clip(0.95*(0.6*(40 + 59*freq) + 0.4*(40 + 59*0.5)) + 0.05*70);
  else
   v_res := private.v77_clip((pr->>'RES')::float8 + 0.95*0.6*59*(freq - 0.5));
  end if;
  v_ovr := private.v77_ovr(p_pos, o_d, o_s, o_a, v_res, v_dis, p);
  v_last := jsonb_build_object('round',rounds,'played',played,'DEF',o_d,'SEC',o_s,'APR',o_a,'RES',v_res,'DIS',v_dis,
   'ovr',v_ovr,'eligible',p_before + played >= (p->>'min_matches_for_ovr')::int,
   'evidence',jsonb_build_object('DEF',n_d,'SEC',n_s,'APR',n_a));
  if p_rows then out_rows := out_rows || v_last; end if;
 end loop;
 return jsonb_build_object('played',played,'last',v_last,
  'payload',case when played > 0 then jsonb_build_object('attrs',jsonb_build_object('DEF',v_last->'DEF','SEC',v_last->'SEC',
    'APR',v_last->'APR','RES',v_last->'RES','DIS',v_last->'DIS'),'evidence',v_last->'evidence') else p_prev end)
  || case when p_rows then jsonb_build_object('rows',out_rows) else '{}'::jsonb end;
end $$;

-- Carreira na pelada (mesmo formato de computeCareer em v77.mjs):
-- entrada {position, previousPosition, transitionK, seasons:[{seasonId, events:[...]}]}.
create function private.v77_career_pos(p_input jsonb, p_pos text, p jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare s jsonb; r jsonb; v_prev jsonb; v_before int := 0; v_out jsonb := '[]';
begin
 for s in select value from jsonb_array_elements(coalesce(p_input->'seasons','[]')) with ordinality t(value, o) order by o loop
  r := private.v77_season(s->'events', p_pos, v_prev, v_before, p);
  v_before := v_before + (r->>'played')::int;
  if (r->>'played')::int > 0 then v_prev := r->'payload'; end if;
  v_out := v_out || jsonb_build_object('seasonId',s->'seasonId','played',r->'played','careerPlayed',v_before,'last',r->'last');
 end loop;
 return v_out;
end $$;

create function private.v77_career(p_input jsonb, p jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare v_pos text := p_input->>'position'; v_old text := p_input->>'previousPosition'; v_k int := (p_input->>'transitionK')::int;
 v_t int := (p->>'transition_matches')::int; v_min int := (p->>'min_matches_for_ovr')::int;
 cur jsonb; old jsonb; v_in boolean; i int; n int; s jsonb; a jsonb; v_ovr float8; v_el boolean; v_seasons jsonb := '[]'; v_current jsonb;
begin
 cur := private.v77_career_pos(p_input, v_pos, p);
 v_in := v_old is not null and v_old <> v_pos and v_k is not null and v_k < v_t;
 if v_in then old := private.v77_career_pos(p_input, v_old, p); end if;
 n := jsonb_array_length(cur);
 for i in 0..n-1 loop
  s := cur->i; a := s->'last';
  if a is null or jsonb_typeof(a) = 'null' then
   v_seasons := v_seasons || jsonb_build_object('seasonId',s->'seasonId','played',0,'careerPlayed',s->'careerPlayed','state',null);
   continue;
  end if;
  v_ovr := (a->>'ovr')::float8;
  if v_in and i = n - 1 then
   v_ovr := (v_k::float8/v_t)*v_ovr + (1 - v_k::float8/v_t)*(old->i->'last'->>'ovr')::float8;
  end if;
  v_el := (s->>'careerPlayed')::int >= v_min;
  v_current := jsonb_build_object('DEF',a->'DEF','SEC',a->'SEC','APR',a->'APR','RES',a->'RES','DIS',a->'DIS','ovr',v_ovr,
   'eligible',v_el,'ovrDisplay',case when v_el then floor(v_ovr + 0.5)::int end,'evidence',a->'evidence');
  v_seasons := v_seasons || jsonb_build_object('seasonId',s->'seasonId','played',s->'played','careerPlayed',s->'careerPlayed','state',v_current);
 end loop;
 return jsonb_build_object('position',v_pos,'secCode',case when v_pos='GOL' then 'REF' else 'LET' end,
  'transitionK',case when v_in then v_k end,'previousPosition',case when v_in then v_old end,
  'matchesPlayed',coalesce((cur->(n-1)->>'careerPlayed')::int,0),
  'current',(select x->'state' from jsonb_array_elements(v_seasons) with ordinality t(x, o)
    where jsonb_typeof(x->'state') = 'object' order by o desc limit 1),
  'seasons',v_seasons);
end $$;

---------------------------------------------------------------------------------------------------
-- 3. Entrada do motor a partir das tabelas
---------------------------------------------------------------------------------------------------
-- Resenha apurada por jogador e partida (preenchida na publicação da votação, 054).
alter table public.match_player_results add column resenha boolean;

create function private.v77_member_input(p_membership uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_m public.pelada_memberships; v_tracking boolean; v_pos text; v_since timestamptz;
 v_change public.position_changes; v_prev text; v_k int; v_seasons jsonb;
begin
 select * into v_m from public.pelada_memberships where id=p_membership;
 if not found then return null; end if;
 v_tracking := coalesce((select cards_tracking from public.pelada_settings where pelada_id=v_m.pelada_id), false);
 v_pos := private.rating_position(v_m.position_code, v_m.preferred_position);
 -- Participação = está na súmula ou tem resultado oficial na partida.
 select min(m.played_at) into v_since from public.matches m where m.pelada_id=v_m.pelada_id and m.status='finalized'
  and (exists(select 1 from public.match_participants x where x.match_id=m.id and x.membership_id=p_membership)
   or exists(select 1 from public.match_player_results r where r.match_id=m.id and r.membership_id=p_membership));
 v_since := least(v_m.joined_at, coalesce(v_since, v_m.joined_at));

 with rounds as (
  select m.id, m.season_id, m.played_at, m.discipline_status, m.team_a_score, m.team_b_score, x.id part_id, x.team,
   res.has_valid_rating, res.peer_rating, res.goals, res.assists, res.match_result, res.resenha, ks.hard_saves,
   coalesce((select sum(quantity) from public.match_events e where e.participant_id=x.id and e.event_type='yellow_card'),0)::int yc,
   coalesce((select sum(quantity) from public.match_events e where e.participant_id=x.id and e.event_type='second_yellow'),0)::int sy,
   coalesce((select sum(quantity) from public.match_events e where e.participant_id=x.id and e.event_type='red_card'),0)::int rc
  from public.matches m
  left join public.match_participants x on x.match_id=m.id and x.membership_id=p_membership
  left join public.match_player_results res on res.match_id=m.id and res.membership_id=p_membership
  left join public.match_keeper_saves ks on ks.participant_id=x.id
  where m.pelada_id=v_m.pelada_id and m.status='finalized' and m.played_at >= v_since),
 ev as (
  select r.season_id, r.played_at, r.id,
   case when r.part_id is null and r.match_result is null then jsonb_build_object('played',false)
   else jsonb_build_object('played',true,
    'q',case when r.has_valid_rating then r.peer_rating::float8 end,
    'goals',r.goals, 'assists',r.assists,
    'conceded',(case r.team when 'A' then r.team_b_score when 'B' then r.team_a_score end), -- sem súmula: ausente
    'saves',r.hard_saves,
    'result',case r.match_result when 'win' then 1::float8 when 'draw' then 1::float8/3 when 'loss' then 0::float8 end,
    -- Segundo amarelo = uma expulsão e absorve os amarelos; no máximo uma expulsão e um amarelo por partida.
    'yellow',case when r.sy > 0 then 0 else least(1, r.yc) end,
    'red',least(1, r.rc + r.sy),
    'cardsKnown',v_tracking and r.discipline_status='confirmed' and r.part_id is not null,
    'resenha',r.resenha) end e
  from rounds r)
 select coalesce(jsonb_agg(jsonb_build_object('seasonId',s.id,'events',x.events) order by s.starts_on, s.id),'[]')
 into v_seasons
 from public.seasons s
 join lateral (select jsonb_agg(ev.e order by ev.played_at, ev.id) events from ev where ev.season_id=s.id) x on x.events is not null
 where s.pelada_id=v_m.pelada_id;

 select * into v_change from public.position_changes where membership_id=p_membership
 order by changed_at desc, position_version desc limit 1;
 if found and v_change.from_position is not null then
  v_prev := private.rating_position(v_change.from_position_code, v_change.from_position);
  select count(*)::int into v_k from public.match_participants x join public.matches m on m.id=x.match_id
  where x.membership_id=p_membership and m.status='finalized' and m.played_at > v_change.changed_at;
 end if;
 return jsonb_build_object('position',v_pos,'previousPosition',v_prev,'transitionK',v_k,'seasons',v_seasons);
end $$;

---------------------------------------------------------------------------------------------------
-- 4. Estado publicado, por temporada, histórico e auditoria
---------------------------------------------------------------------------------------------------
alter table public.player_ratings alter column atu drop not null, alter column est drop not null, alter column peq drop not null,
 add column def numeric(9,6), add column sec numeric(9,6), add column apr numeric(9,6),
 add column sec_code text check (sec_code in ('LET','REF')),
 add column previous_position text, add column input_hash text;
alter table public.player_ratings add constraint rating_v3_attributes check (formula_version < 3 or
 (def is not null and sec is not null and apr is not null and sec_code is not null));

alter table public.player_rating_history alter column atu drop not null, alter column est drop not null, alter column peq drop not null,
 add column def numeric(9,6), add column sec numeric(9,6), add column apr numeric(9,6),
 add column sec_code text check (sec_code in ('LET','REF')), add column season_id uuid references public.seasons(id);

create table public.player_season_ratings (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 season_id uuid not null,
 membership_id uuid not null,
 position text not null check (position in ('GOL','ZAG','LAT','VOL','MEI','ATA','PON')),
 sec_code text not null check (sec_code in ('LET','REF')),
 def numeric(9,6) not null check (def between 40 and 99),
 sec numeric(9,6) not null check (sec between 40 and 99),
 apr numeric(9,6) not null check (apr between 40 and 99),
 res numeric(9,6) not null check (res between 40 and 99),
 dis numeric(9,6) not null check (dis between 50 and 99),
 ovr numeric(9,6) not null check (ovr between 40 and 99),
 ovr_display integer check (ovr_display between 40 and 99),
 tier text check (tier in ('bronze','prata','ouro')),
 eligible boolean not null,
 matches_played integer not null,
 career_matches integer not null,
 evidence jsonb not null,
 formula_version integer not null,
 params_version integer not null,
 updated_at timestamptz not null default now(),
 constraint season_rating_display_when_eligible check (eligible = (ovr_display is not null)),
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 foreign key (season_id, pelada_id) references public.seasons(id, pelada_id),
 unique (season_id, membership_id)
);
create index player_season_ratings_by_member on public.player_season_ratings(membership_id);
alter table public.player_season_ratings enable row level security;
revoke all on public.player_season_ratings from anon, authenticated;
create policy season_ratings_read on public.player_season_ratings for select to authenticated
 using ((select private.is_active_member(pelada_id)));
-- O OVR interno (antes de 5 partidas) não é legível pelo app, como na V5.
grant select (id, pelada_id, season_id, membership_id, position, sec_code, def, sec, apr, res, dis, ovr_display, tier,
 eligible, matches_played, career_matches, formula_version, params_version, updated_at) on public.player_season_ratings to authenticated;
grant select (def, sec, apr, sec_code, previous_position) on public.player_ratings to authenticated;
grant select (def, sec, apr, sec_code, season_id) on public.player_rating_history to authenticated;

create table private.rating_runs (
 id bigint generated always as identity primary key,
 pelada_id uuid not null,
 match_id uuid,
 event text not null,
 formula_version integer not null,
 params_version integer not null,
 members integer not null,
 changed integer not null,
 skipped integer not null,
 actor uuid,
 started_at timestamptz not null default clock_timestamp(),
 finished_at timestamptz
);
create index rating_runs_by_pelada on private.rating_runs(pelada_id, started_at desc);
revoke all on private.rating_runs from public, anon, authenticated;

alter table public.player_cards add column def numeric(9,6), add column sec numeric(9,6), add column apr numeric(9,6),
 add column sec_code text check (sec_code in ('LET','REF'));

---------------------------------------------------------------------------------------------------
-- 5. Reprocessamento (despacho por versão)
---------------------------------------------------------------------------------------------------
alter function private.recompute_pelada_ratings(uuid,uuid) rename to recompute_pelada_ratings_v2;

create function private.recompute_pelada_ratings(p_pelada uuid, p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare rp private.rating_params := private.rating_params_active(); p jsonb := rp.params;
 v_mem uuid; v_in jsonb; v_hash text; j jsonb; c jsonb; s jsonb; v_old public.player_ratings;
 v_event text := private.rating_event(); v_last public.player_rating_history; v_kind text; v_run bigint;
 v_members int := 0; v_changed int := 0; v_skipped int := 0; v_season uuid; v_disp int;
begin
 -- Mesma pelada: um cálculo por vez (dois eventos simultâneos não intercalam leituras e gravações).
 perform pg_advisory_xact_lock(hashtextextended('minuto91:rating:'||p_pelada::text, 0));
 if rp.formula_version < 3 then
  perform private.recompute_pelada_ratings_v2(p_pelada, p_match);
  return;
 end if;
 if p_match is not null and exists(select 1 from public.matches where id=p_match and status='annulled') then
  v_event := 'annulment'; end if;
 insert into private.rating_runs(pelada_id,match_id,event,formula_version,params_version,members,changed,skipped,actor)
 values(p_pelada,p_match,v_event,rp.formula_version,rp.version,0,0,0,auth.uid()) returning id into v_run;

 for v_mem in select m.id from public.pelada_memberships m where m.pelada_id=p_pelada
   and (m.status='active' or exists(select 1 from public.player_ratings r where r.membership_id=m.id))
   order by m.id loop
  v_members := v_members + 1;
  v_in := private.v77_member_input(v_mem);
  v_hash := md5(rp.version::text||':'||v_in::text);
  select * into v_old from public.player_ratings where membership_id=v_mem;
  if found and v_old.input_hash = v_hash and v_old.formula_version = rp.formula_version and v_old.params_version = rp.version then
   v_skipped := v_skipped + 1;
   continue; -- entrada idêntica: resultado idêntico, nada a gravar
  end if;
  j := private.v77_career(v_in, p);
  c := case when jsonb_typeof(j->'current') = 'object' then j->'current' else jsonb_build_object('DEF',70,'SEC',70,'APR',70,'RES',70,'DIS',(p->'dis'->>'start')::float8,
   'ovr',70,'eligible',false,'ovrDisplay',null) end; -- sem nenhuma rodada ainda: neutro
  v_disp := (c->>'ovrDisplay')::int;
  insert into public.player_ratings(pelada_id,membership_id,position,atu,est,peq,def,sec,apr,sec_code,res,dis,ovr,ovr_display,
   tier,eligible,matches_played,transition_k,previous_position,formula_version,params_version,input_hash)
  values(p_pelada,v_mem,j->>'position',null,null,null,(c->>'DEF')::numeric,(c->>'SEC')::numeric,(c->>'APR')::numeric,j->>'secCode',
   (c->>'RES')::numeric,(c->>'DIS')::numeric,(c->>'ovr')::numeric,v_disp,private.rating_tier(v_disp),(c->>'eligible')::boolean,
   (j->>'matchesPlayed')::int,(j->>'transitionK')::int,j->>'previousPosition',rp.formula_version,rp.version,v_hash)
  on conflict (membership_id) do update set position=excluded.position, atu=null, est=null, peq=null, def=excluded.def,
   sec=excluded.sec, apr=excluded.apr, sec_code=excluded.sec_code, res=excluded.res, dis=excluded.dis, ovr=excluded.ovr,
   ovr_display=excluded.ovr_display, tier=excluded.tier, eligible=excluded.eligible, matches_played=excluded.matches_played,
   transition_k=excluded.transition_k, previous_position=excluded.previous_position, formula_version=excluded.formula_version,
   params_version=excluded.params_version, input_hash=excluded.input_hash, updated_at=now();

  -- Estado ao fim de cada temporada (cartas e estatísticas por temporada).
  delete from public.player_season_ratings r where r.membership_id=v_mem
   and not exists(select 1 from jsonb_array_elements(j->'seasons') x where (x->>'seasonId')::uuid=r.season_id
    and jsonb_typeof(x->'state')='object');
  for s in select value from jsonb_array_elements(j->'seasons') loop
   continue when jsonb_typeof(s->'state') <> 'object';
   v_disp := (s->'state'->>'ovrDisplay')::int;
   insert into public.player_season_ratings(pelada_id,season_id,membership_id,position,sec_code,def,sec,apr,res,dis,ovr,
    ovr_display,tier,eligible,matches_played,career_matches,evidence,formula_version,params_version)
   values(p_pelada,(s->>'seasonId')::uuid,v_mem,j->>'position',j->>'secCode',(s->'state'->>'DEF')::numeric,
    (s->'state'->>'SEC')::numeric,(s->'state'->>'APR')::numeric,(s->'state'->>'RES')::numeric,(s->'state'->>'DIS')::numeric,
    (s->'state'->>'ovr')::numeric,v_disp,private.rating_tier(v_disp),(s->'state'->>'eligible')::boolean,(s->>'played')::int,
    (s->>'careerPlayed')::int,s->'state'->'evidence',rp.formula_version,rp.version)
   on conflict (season_id, membership_id) do update set position=excluded.position, sec_code=excluded.sec_code,
    def=excluded.def, sec=excluded.sec, apr=excluded.apr, res=excluded.res, dis=excluded.dis, ovr=excluded.ovr,
    ovr_display=excluded.ovr_display, tier=excluded.tier, eligible=excluded.eligible, matches_played=excluded.matches_played,
    career_matches=excluded.career_matches, evidence=excluded.evidence, formula_version=excluded.formula_version,
    params_version=excluded.params_version, updated_at=now();
  end loop;

  -- Histórico auditável: só quando algo mudou desde o último registro.
  v_season := (select (x->>'seasonId')::uuid from jsonb_array_elements(j->'seasons') with ordinality t(x, o)
   where jsonb_typeof(x->'state')='object' order by o desc limit 1);
  select * into v_last from public.player_rating_history where membership_id=v_mem order by created_at desc, id desc limit 1;
  if found and v_last.formula_version = rp.formula_version and v_last.ovr = round((c->>'ovr')::numeric,6)
    and v_last.def = round((c->>'DEF')::numeric,6) and v_last.sec = round((c->>'SEC')::numeric,6)
    and v_last.apr = round((c->>'APR')::numeric,6) and v_last.res = round((c->>'RES')::numeric,6)
    and v_last.dis = round((c->>'DIS')::numeric,6) and v_last.position = j->>'position'
    and v_last.ovr_display is not distinct from (c->>'ovrDisplay')::int then
   continue;
  end if;
  v_changed := v_changed + 1;
  v_kind := case when v_event in ('match_finalized','votes_published','position','cards_tracking')
    and not exists(select 1 from public.player_rating_history h where h.membership_id=v_mem
     and h.match_id is not distinct from p_match and h.event=v_event and h.kind='original')
   then 'original' else 'recalculated' end;
  -- clock_timestamp: vários recálculos na mesma transação ficam em ordem (now() empataria e o "último" seria aleatório).
  insert into public.player_rating_history(pelada_id,membership_id,match_id,event,kind,position,atu,est,peq,def,sec,apr,sec_code,
   res,dis,ovr,ovr_display,formula_version,params_version,season_id,created_at)
  values(p_pelada,v_mem,p_match,v_event,v_kind,j->>'position',null,null,null,(c->>'DEF')::numeric,(c->>'SEC')::numeric,
   (c->>'APR')::numeric,j->>'secCode',(c->>'RES')::numeric,(c->>'DIS')::numeric,(c->>'ovr')::numeric,(c->>'ovrDisplay')::int,
   rp.formula_version,rp.version,v_season,clock_timestamp());
 end loop;
 update private.rating_runs set members=v_members, changed=v_changed, skipped=v_skipped, finished_at=clock_timestamp()
 where id=v_run;
end $$;

---------------------------------------------------------------------------------------------------
-- 6. Cartas: temporada atual em diante com a V7.7; temporadas antigas preservadas
---------------------------------------------------------------------------------------------------
alter function private.recompute_card(uuid,uuid,uuid) rename to recompute_card_v2;

create function private.recompute_card(p_season uuid, p_membership uuid, p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare rp private.rating_params := private.rating_params_active(); v_s public.seasons; v_r public.player_season_ratings; v_card uuid;
begin
 if rp.formula_version < 3 then
  perform private.recompute_card_v2(p_season, p_membership, p_match);
  return;
 end if;
 select * into v_s from public.seasons where id=p_season;
 if v_s.ends_on < (rp.params->>'cutover_date')::date then
  -- Carta histórica (temporada encerrada antes da V7.7): v1 continua v1; v2 fica como foi publicada.
  if v_s.ends_on < ((select params from private.rating_params where version=1)->>'cutover_date')::date then
   perform private.recompute_card_v1(p_season, p_membership, p_match);
  end if;
  return;
 end if;
 perform private.recompute_card_v1(p_season, p_membership, null); -- estatísticas internas da carta (como na V5)
 select * into v_r from public.player_season_ratings where season_id=p_season and membership_id=p_membership;
 if not found then return; end if;
 update public.player_cards set overall=round(v_r.ovr,6),
  tier=coalesce(v_r.tier, case when round(v_r.ovr,0) < 65 then 'bronze' when round(v_r.ovr,0) < 80 then 'prata' else 'ouro' end),
  is_provisional=not v_r.eligible, formula_version=v_r.formula_version, atu=null, est=null, peq=null,
  def=round(v_r.def,6), sec=round(v_r.sec,6), apr=round(v_r.apr,6), sec_code=v_r.sec_code,
  res=round(v_r.res,6), dis=round(v_r.dis,6), ovr_display=v_r.ovr_display, rating_position=v_r.position, updated_at=now()
 where season_id=p_season and membership_id=p_membership returning id into v_card;
 if v_card is not null and p_match is not null then
  insert into public.card_snapshots(card_id,match_id,snapshot_data,formula_version)
  select c.id, p_match, jsonb_build_object('position',c.position,'rating_position',v_r.position,'overall',c.overall,
   'ovr_display',v_r.ovr_display,'tier',c.tier,'is_provisional',c.is_provisional,'matches_played',v_r.matches_played,
   'def',v_r.def,'sec',v_r.sec,'apr',v_r.apr,'sec_code',v_r.sec_code,'res',v_r.res,'dis',v_r.dis,
   'params_version',v_r.params_version), v_r.formula_version
  from public.player_cards c where c.id=v_card
  on conflict (card_id, match_id) do update set snapshot_data=excluded.snapshot_data,
   formula_version=excluded.formula_version, created_at=now();
 end if;
end $$;

---------------------------------------------------------------------------------------------------
-- 7. Leitura do card atual (Central do Jogador, perfil)
---------------------------------------------------------------------------------------------------
create or replace function public.get_player_rating(p_membership uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_r public.player_ratings; v_pelada uuid; v_min int := coalesce(((private.rating_params_active()).params->>'min_matches_for_ovr')::int, 5);
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.pelada_memberships where id=p_membership;
 if not found or not private.is_active_member(v_pelada) then raise exception 'NOT_FOUND'; end if;
 select * into v_r from public.player_ratings where membership_id=p_membership;
 if not found then
  return jsonb_build_object('membership_id',p_membership,'eligible',false,'matches_played',0,'matches_needed',v_min,'ovr',null);
 end if;
 return jsonb_build_object('membership_id',p_membership,'position',v_r.position,'eligible',v_r.eligible,
  'matches_played',v_r.matches_played,'matches_needed',greatest(0, v_min - v_r.matches_played),
  'ovr',v_r.ovr_display,'tier',v_r.tier,
  'atu',round(v_r.atu,1),'est',round(v_r.est,1),'peq',round(v_r.peq,1),
  'def',round(v_r.def,1),'sec',round(v_r.sec,1),'apr',round(v_r.apr,1),'sec_code',v_r.sec_code,
  'res',round(v_r.res,1),'dis',round(v_r.dis,1),
  'in_transition',v_r.transition_k is not null,'formula_version',v_r.formula_version,'params_version',v_r.params_version,
  'history',coalesce((select jsonb_agg(jsonb_build_object('at',h.created_at,'event',h.event,'kind',h.kind,
    'ovr',h.ovr_display,'atu',round(h.atu,1),'est',round(h.est,1),'peq',round(h.peq,1),
    'def',round(h.def,1),'sec',round(h.sec,1),'apr',round(h.apr,1),'sec_code',h.sec_code,
    'res',round(h.res,1),'dis',round(h.dis,1),'formula_version',h.formula_version) order by h.created_at)
   from (select * from public.player_rating_history where membership_id=p_membership and ovr_display is not null
    and formula_version = v_r.formula_version order by created_at desc limit 60) h),'[]'::jsonb));
end $$;

-- Minha Carreira (051; hoje private.get_player_career_summary_v46, base das camadas 056/058/066/068): a carta de cada temporada leva também os atributos V7.7. Mesmo método de cópia do catálogo
-- da 051: se o texto esperado não existir, a migração para.
do $patch$
declare v_def text; v_new text;
begin
 v_def := pg_get_functiondef('private.get_player_career_summary_v46(uuid)'::regprocedure);
 v_new := replace(v_def, 'c.ovr_display v_ovr,', 'c.ovr_display v_ovr, c.def v_def, c.sec v_sec, c.apr v_apr, c.sec_code v_sec_code,');
 v_new := replace(v_new, '''ovr_display'', v_ovr) end)',
  '''ovr_display'', v_ovr, ''def'', v_def, ''sec'', v_sec, ''apr'', v_apr, ''sec_code'', v_sec_code) end)');
 if v_new = v_def or position('v_sec_code' in v_new) = 0 or position('''sec_code'', v_sec_code' in v_new) = 0 then
  raise exception 'PATCH_CAREER_SUMMARY_V77_FAILED'; end if;
 execute v_new;
end $patch$;

-- Evolução (037/051): pontos e valor atual trazem DEF, LET/REF e APR.
do $patch$
declare v_def text; v_new text; v_mid text;
begin
 v_def := pg_get_functiondef('public.get_player_evolution(uuid,uuid)'::regprocedure);
 v_mid := replace(v_def, '''dis'', (s.snapshot_data->>''dis'')::numeric, ''formula_version'', s.formula_version,',
  '''dis'', (s.snapshot_data->>''dis'')::numeric, ''formula_version'', s.formula_version,
   ''def'', (s.snapshot_data->>''def'')::numeric, ''sec'', (s.snapshot_data->>''sec'')::numeric,
   ''apr'', (s.snapshot_data->>''apr'')::numeric, ''sec_code'', s.snapshot_data->>''sec_code'',');
 if v_mid = v_def then raise exception 'PATCH_EVOLUTION_V77_FAILED (pontos)'; end if;
 v_new := replace(v_mid, '''dis'', c.dis, ''formula_version'', c.formula_version,',
  '''dis'', c.dis, ''formula_version'', c.formula_version, ''def'', c.def, ''sec'', c.sec, ''apr'', c.apr,
   ''sec_code'', c.sec_code,');
 if v_new = v_mid then raise exception 'PATCH_EVOLUTION_V77_FAILED (atual)'; end if;
 execute v_new;
end $patch$;

revoke all on function private.v77_clip(float8,float8,float8), private.v77_vote(float8),
 private.v77_let(float8,float8,float8,float8,float8,float8), private.v77_def(float8,float8,float8,float8),
 private.v77_ref(float8,float8,float8,float8), private.v77_apr(float8,float8,float8), private.v77_resenha(integer,integer),
 private.v77_step_dis(float8,integer,integer,jsonb), private.v77_smooth(private.v77_smoother,float8,integer),
 private.v77_ovr(text,float8,float8,float8,float8,float8,jsonb), private.v77_season(jsonb,text,jsonb,integer,jsonb,boolean),
 private.v77_career_pos(jsonb,text,jsonb), private.v77_career(jsonb,jsonb), private.v77_member_input(uuid),
 private.recompute_pelada_ratings(uuid,uuid), private.recompute_pelada_ratings_v2(uuid,uuid),
 private.recompute_card(uuid,uuid,uuid), private.recompute_card_v2(uuid,uuid,uuid) from public, anon, authenticated;

---------------------------------------------------------------------------------------------------
-- 8. Publicação inicial: recalcula todas as peladas com partidas oficiais (temporada atual em diante)
---------------------------------------------------------------------------------------------------
do $init$
declare v_p uuid; v_season uuid;
begin
 perform set_config('minuto91.rating_event', 'recompute', true);
 for v_p in select distinct pelada_id from public.matches where status='finalized' order by 1 loop
  select m.season_id into v_season from public.matches m where m.pelada_id=v_p and m.status='finalized'
  order by m.played_at desc, m.id desc limit 1;
  perform private.recompute_cards(v_season, null);
 end loop;
 perform set_config('minuto91.rating_event', '', true);
end $init$;

-- Rollback (sem apagar nada):
--   update private.rating_params set active=false where version=2;
--   select private.recompute_cards(<temporada atual>, null) para cada pelada (volta o OVR da V5 em player_ratings e
--   nas cartas da temporada atual; histórico V7.7 fica guardado com formula_version 3).
-- Para remover a estrutura (só depois do rollback acima): renomear de volta recompute_pelada_ratings_v2 e
-- recompute_card_v2, dropar as funções v77_*, private.rating_runs e public.player_season_ratings; colunas novas
-- podem ficar (opcionais).
