-- Minuto 91 / 068: V8.7 — Artilheiro da Temporada, Maestro da Temporada e Luva de Ouro (A01–A05, B01–B10, C01–C12, F01–F04, AD01).
-- Especificação normativa: docs/V8.7_DECISOES_COMPLETAS.md. Rastreabilidade: docs/V8.7_MATRIZ_RASTREABILIDADE.md.
--
-- Não altera: fórmulas de OVR/REF (051), votação, Craque da Temporada, Paredão do Mês, os seis prêmios tradicionais,
-- a Sala de Troféus (só ganha contadores), o álbum de 48 figurinhas, RLS e isolamento entre peladas.
-- Acrescenta:
--  * awards.award_type 'season_top_scorer' (Artilheiro da Temporada), 'season_maestro' (Maestro da Temporada) e
--    'season_golden_glove' (Luva de Ouro). O Artilheiro da Temporada NÃO existia no repositório (só o do Mês): é criado aqui
--    UMA vez, pela regra do anexo. "Chuteira de Ouro" é só a arte, nunca um prêmio paralelo.
--  * Apuração conjunta, transacional e idempotente (private.season_awards_sync) depois do encerramento e da consolidação
--    (season_consolidation.ready); versões imutáveis em private.season_award_results; auditoria em private.v87_events.
--  * REF "do encerramento" (F04): a MESMA fórmula da 051 (janela móvel das últimas N partidas do jogador, N = rating_params.window,
--    peso de recência 30 − partidas posteriores, encolhimento e neutro) aplicada só às partidas até o fim da temporada,
--    portanto pode incluir temporadas anteriores (C09) e não é afetada por partidas posteriores. Precisão persistida: 6 casas.
--  * Exceção administrativa da Luva (F01/C08): só admin, só sem elegível normal, com justificativa e auditoria, piso de 3 atuações.
--  * Recálculo em correções, anulações, restaurações, mudança de posição e defesas difíceis (ganchos em close_month e
--    after_rating_inputs_changed) e no agendador (process_season_awards).
--  * Sala de Troféus: apenas contadores. Minha Carreira: get_player_season_titles (AD01). Retrospectiva: bloco season_awards.
-- LACUNA registrada (não inventada): o anexo não diz se vale para temporadas já encerradas. Padrão conservador, como o Craque
-- (CT-13): sem concessão retroativa; private.v87_activation.min_season_end pode ser baixado pelo operador para conceder antes.
-- Rollback: dropar as funções/tabelas v87/season_award*/golden_glove*, restaurar close_month (066), after_rating_inputs_changed (051),
-- run_scheduled_tasks (055), get_player_career_summary / get_trophy_history (066) e get_season_retrospective_official (058)
-- (as versões anteriores ficam renomeadas como *_pre87 / close_month_v86), e recriar as constraints de awards (066) depois de
-- apagar os prêmios dos três tipos novos.

---------------------------------------------------------------------------------------------------
-- Ativação
---------------------------------------------------------------------------------------------------
create table private.v87_activation (
 feature text primary key check (feature = 'season_awards'),
 activated_at timestamptz not null default now(),
 min_season_end date not null default current_date
);
revoke all on private.v87_activation from public, anon, authenticated;
insert into private.v87_activation(feature) values ('season_awards');

---------------------------------------------------------------------------------------------------
-- awards: tipos novos (temporada: sem partida e sem mês)
---------------------------------------------------------------------------------------------------
do $$
declare v_name text;
begin
 select c.conname into v_name from pg_constraint c
 where c.conrelid = 'public.awards'::regclass and c.contype = 'c' and pg_get_constraintdef(c.oid) like '%award_type%in%';
 execute format('alter table public.awards drop constraint %I', v_name);
end $$;
alter table public.awards add constraint awards_award_type_check check (award_type in
 ('match_craque','bola_murcha','monthly_king','top_scorer','top_assist','most_improved','match_garcom','monthly_garcom',
  'monthly_goalkeeper','season_craque','season_top_scorer','season_maestro','season_golden_glove'));
alter table public.awards drop constraint award_period;
alter table public.awards add constraint award_period check (
 (award_type in ('season_craque','season_top_scorer','season_maestro','season_golden_glove')
   and match_id is null and period_month is null)
 or (award_type not in ('season_craque','season_top_scorer','season_maestro','season_golden_glove')
   and (match_id is null) = (period_month is not null)));
-- Uma concessão ativa por pelada/temporada/categoria/jogador (idempotência e concorrência).
create unique index one_active_season_award on public.awards(season_id, award_type, membership_id)
 where award_type in ('season_top_scorer','season_maestro','season_golden_glove') and status = 'active';

---------------------------------------------------------------------------------------------------
-- Auditoria, resultados versionados e exceção
---------------------------------------------------------------------------------------------------
create table private.v87_events (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 season_id uuid not null,
 category text,
 kind text not null,
 actor_user_id uuid,
 detail jsonb not null default '{}'::jsonb,
 occurred_at timestamptz not null default clock_timestamp()
);
create index idx_v87_events on private.v87_events(season_id, occurred_at);
revoke all on private.v87_events from public, anon, authenticated;
create function private.v87_events_immutable() returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'V87_EVENTS_IMMUTABLE'; end $$;
create trigger v87_events_immutable before update or delete on private.v87_events
for each row execute function private.v87_events_immutable();

-- Cada mudança de vencedores/estado vira uma versão nova; a anterior fica guardada (C10). Só a versão corrente é viva.
create table private.season_award_results (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 season_id uuid not null references public.seasons(id),
 category text not null check (category in ('top_scorer','maestro','golden_glove')),
 version integer not null,
 is_current boolean not null default true,
 status text not null check (status in ('published','no_winner','awaiting_exception')),
 basis text not null default 'normal' check (basis in ('normal','exception')),
 winners uuid[] not null default '{}',
 criteria jsonb not null default '{}'::jsonb,
 ranking jsonb not null default '[]'::jsonb,
 rules_version text not null,
 computed_at timestamptz not null default now(),
 published_at timestamptz,
 rectifies uuid,
 unique (season_id, category, version)
);
create unique index one_current_season_award_result on private.season_award_results(season_id, category) where is_current;
revoke all on private.season_award_results from public, anon, authenticated;

create table private.golden_glove_exceptions (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 season_id uuid not null references public.seasons(id),
 min_percent integer not null check (min_percent between 0 and 50),
 min_matches integer not null check (min_matches between 3 and 5), -- piso absoluto de 3 atuações como GOL (F01)
 reason text not null check (length(reason) between 10 and 500),
 authorized_by uuid not null,
 authorized_at timestamptz not null default now(),
 status text not null default 'active' check (status in ('active','revoked','void')),
 closed_reason text,
 closed_at timestamptz,
 check (min_percent < 50 or min_matches < 5)
);
create unique index one_active_glove_exception on private.golden_glove_exceptions(season_id) where status = 'active';
revoke all on private.golden_glove_exceptions from public, anon, authenticated;

create function private.v87_rules_version() returns text language sql immutable set search_path = '' as $$ select 'v8.7-1' $$;

create function private.v87_award_type(p_category text) returns text language sql immutable set search_path = '' as $$
 select case p_category when 'top_scorer' then 'season_top_scorer' when 'maestro' then 'season_maestro'
  when 'golden_glove' then 'season_golden_glove' end $$;

---------------------------------------------------------------------------------------------------
-- Contexto do encerramento e REF (B04/B05/F04)
---------------------------------------------------------------------------------------------------
-- Fim da temporada: o instante em que começa o dia seguinte a ends_on, no fuso da pelada.
create function private.v87_season_cutoff(p_season uuid) returns timestamptz
language sql stable security definer set search_path = '' as $$
 select ((s.ends_on + 1)::timestamp at time zone coalesce(
  (select ps.timezone from public.pelada_settings ps where ps.pelada_id = s.pelada_id), 'America/Sao_Paulo'))
 from public.seasons s where s.id = p_season;
$$;

-- REF oficial do jogador no contexto de um instante. É a conta de private.rating_compute (051) sem mudar nada:
-- as últimas `window` partidas finalizadas em que o jogador esteve (em qualquer posição) formam a janela; só as com
-- defesas difíceis registradas entram na média, com peso 30 − (partidas posteriores na janela); encolhimento ref_shrink
-- rumo a ref_neutral. A única diferença é o corte: partidas com played_at < p_cutoff (estado oficial corrigido, mas sem
-- partidas posteriores ao encerramento). Persistência: 6 casas (a mesma das tabelas de rating).
create function private.v87_ref_at(p_membership uuid, p_cutoff timestamptz) returns numeric
language sql stable security definer set search_path = '' as $$
 with prm as (
  select (params->>'ref_neutral')::float8 neutral, (params->>'ref_shrink')::float8 shrink, (params->>'window')::int win
  from private.rating_params_active()),
 w as (
  select ks.hard_saves sv, row_number() over (order by m.played_at desc, m.id desc) rn
  from public.match_participants x
  join public.matches m on m.id = x.match_id and m.status = 'finalized' and m.played_at < p_cutoff
  left join public.match_keeper_saves ks on ks.participant_id = x.id
  where x.membership_id = p_membership),
 agg as (
  select count(*) filter (where w.sv is not null)::float8 n,
   sum((30 - (w.rn - 1))::float8) filter (where w.sv is not null) sw,
   sum((30 - (w.rn - 1))::float8 * private.rating_ref_match(w.sv::float8)) filter (where w.sv is not null) swv
  from w cross join prm where w.rn <= prm.win)
 select round((case when a.n = 0 then prm.neutral
  else prm.neutral + (a.n / (a.n + prm.shrink)) * (a.swv / a.sw - prm.neutral) end)::numeric, 6)
 from agg a cross join prm;
$$;

---------------------------------------------------------------------------------------------------
-- Artilheiro e Maestro (A01, A02): estatística oficial da temporada, mínimo 1, empate compartilhado
---------------------------------------------------------------------------------------------------
-- Só partidas finalizadas da temporada (anuladas/canceladas ficam de fora; restauradas voltam), gols de jogador
-- (gol contra e gol sem autoria não entram em match_player_results.goals). O ranking inclui quem se aposentou da conta
-- (retired), mas esses não recebem o título (RN-106).
create function private.v87_stat_result(p_season uuid, p_stat text) returns jsonb
language sql stable security definer set search_path = '' as $$
 with t as (
  select r.membership_id, sum(case when p_stat = 'goals' then r.goals else r.assists end)::int v, pm.status st
  from public.match_player_results r
  join public.matches m on m.id = r.match_id and m.status = 'finalized' and m.season_id = p_season
  join public.pelada_memberships pm on pm.id = r.membership_id
  group by r.membership_id, pm.status
  having sum(case when p_stat = 'goals' then r.goals else r.assists end) >= 1),
 k as (select t.*, rank() over (order by t.v desc) rk from t)
 select jsonb_build_object(
  'winners', coalesce((select jsonb_agg(k.membership_id order by k.membership_id) from k where k.rk = 1 and k.st <> 'retired'), '[]'::jsonb),
  'ranking', coalesce((select jsonb_agg(jsonb_build_object('membership_id', k.membership_id, 'value', k.v, 'rank', k.rk)
     order by k.rk, k.membership_id) from k), '[]'::jsonb));
$$;

---------------------------------------------------------------------------------------------------
-- Luva de Ouro (A03–A05, B04–B09, F01–F03)
---------------------------------------------------------------------------------------------------
-- Métricas por goleiro que atuou no gol na temporada. Elegível = posição oficial GOL no encerramento (histórico de
-- position_changes; ex-integrante usa a última posição cadastrada, F03) E atuações como GOL ≥ max(p_min, ceil(p_percent% × partidas
-- oficiais da pelada na temporada)). Improvisado (posição oficial ≠ GOL) nunca é elegível (B07), mesmo na exceção.
create function private.glove_candidates(p_season uuid, p_percent integer, p_min integer)
returns table(membership_id uuid, gk_matches integer, saves_matches integer, saves_total integer, avg_saves numeric,
 ref numeric, official_position text, official_gol boolean, required integer, season_matches integer, eligible boolean,
 retired boolean)
language sql stable security definer set search_path = '' as $$
 with tot as (select count(*)::int n from public.matches m where m.season_id = p_season and m.status = 'finalized'),
 req as (select greatest(p_min, (p_percent * tot.n + 99) / 100) r, tot.n from tot), -- teto do percentual (B06)
 gk as (
  select x.membership_id, count(*)::int gk, count(ks.hard_saves)::int sm, coalesce(sum(ks.hard_saves), 0)::int st
  from public.matches m join public.match_participants x on x.match_id = m.id
  left join public.match_keeper_saves ks on ks.participant_id = x.id and ks.match_id = m.id
  where m.season_id = p_season and m.status = 'finalized' and x.primary_position = 'goalkeeper' and x.membership_id is not null
  group by x.membership_id)
 select gk.membership_id, gk.gk, gk.sm, gk.st, case when gk.sm > 0 then gk.st::numeric / gk.sm end,
  case when pos.p = 'GOL' then private.v87_ref_at(gk.membership_id, private.v87_season_cutoff(p_season)) end,
  pos.p, coalesce(pos.p = 'GOL', false), req.r, req.n,
  coalesce(pos.p = 'GOL', false) and gk.gk >= req.r, pm.status = 'retired'
 from gk cross join req
 join public.pelada_memberships pm on pm.id = gk.membership_id
 cross join lateral (select private.v86_official_position(gk.membership_id, private.v87_season_cutoff(p_season)) p) pos;
$$;

-- Desempate: maior REF (precisão persistida) → maior média de defesas difíceis por partida como GOL (só partidas com
-- registro; sem registro não vira zero) → mais partidas como GOL → empate total = prêmio compartilhado. Recorte: a temporada.
create function private.glove_pick(p_season uuid, p_percent integer, p_min integer) returns jsonb
language sql stable security definer set search_path = '' as $$
 with c as materialized (select * from private.glove_candidates(p_season, p_percent, p_min)),
 e as (select * from c where c.eligible),
 top as (select e.ref, coalesce(e.avg_saves, -1) a, e.gk_matches g from e order by e.ref desc, coalesce(e.avg_saves, -1) desc, e.gk_matches desc limit 1),
 w as (select e.membership_id, e.retired from e, top where e.ref = top.ref and coalesce(e.avg_saves, -1) = top.a and e.gk_matches = top.g)
 select jsonb_build_object(
  'eligible_count', (select count(*) from e),
  'winners', coalesce((select jsonb_agg(w.membership_id order by w.membership_id) from w where not w.retired), '[]'::jsonb),
  'required', (select max(c.required) from c), 'season_matches', (select max(c.season_matches) from c),
  'ranking', coalesce((select jsonb_agg(jsonb_build_object('membership_id', c.membership_id, 'value', c.ref, 'ref', c.ref,
     'gk_matches', c.gk_matches, 'saves_matches', c.saves_matches, 'avg_saves', c.avg_saves,
     'official_position', c.official_position, 'eligible', c.eligible)
     order by c.eligible desc, c.ref desc nulls last, coalesce(c.avg_saves, -1) desc, c.gk_matches desc, c.membership_id) from c), '[]'::jsonb));
$$;

-- Resultado da categoria sem escrever nada: estado (published | no_winner | awaiting_exception), base (normal | exception),
-- vencedores, ranking e critérios usados.
create function private.v87_glove_result(p_season uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_norm jsonb; v_ex private.golden_glove_exceptions; v_use jsonb; v_basis text := 'normal'; v_status text; v_floor jsonb;
 v_crit jsonb; v_void boolean := false;
begin
 v_norm := private.glove_pick(p_season, 50, 5);
 select * into v_ex from private.golden_glove_exceptions where season_id = p_season and status = 'active';
 v_use := v_norm;
 if (v_norm->>'eligible_count')::int > 0 then
  v_void := found; -- há elegível normal: a exceção (se existia) perde o sentido (C08)
  v_status := case when jsonb_array_length(v_norm->'winners') > 0 then 'published' else 'no_winner' end;
 elsif found then
  v_basis := 'exception';
  v_use := private.glove_pick(p_season, v_ex.min_percent, v_ex.min_matches);
  v_status := case when jsonb_array_length(v_use->'winners') > 0 then 'published' else 'no_winner' end;
 else
  v_floor := private.glove_pick(p_season, 0, 3);
  v_status := case when (v_floor->>'eligible_count')::int > 0 then 'awaiting_exception' else 'no_winner' end;
 end if;
 v_crit := jsonb_build_object('rules_version', private.v87_rules_version(), 'percent', 50, 'min_matches', 5,
  'required', v_norm->'required', 'season_matches', v_norm->'season_matches',
  'ref_cutoff', private.v87_season_cutoff(p_season),
  'ref_window_note', 'REF oficial publicada no encerramento: janela móvel das últimas partidas do goleiro (até 20), que pode incluir temporadas anteriores.');
 if v_basis = 'exception' then
  v_crit := v_crit || jsonb_build_object('exception', jsonb_build_object('min_percent', v_ex.min_percent,
   'min_matches', v_ex.min_matches, 'required', v_use->'required', 'authorized_at', v_ex.authorized_at));
 end if;
 return jsonb_build_object('status', v_status, 'basis', v_basis, 'winners', v_use->'winners', 'ranking', v_use->'ranking',
  'criteria', v_crit, 'void_exception', v_void, 'exception_id', v_ex.id);
end $$;

---------------------------------------------------------------------------------------------------
-- Aplicação idempotente de uma categoria (versões + awards)
---------------------------------------------------------------------------------------------------
create function private.season_award_apply(p_season uuid, p_category text, p_status text, p_basis text,
 p_winners uuid[], p_criteria jsonb, p_ranking jsonb) returns text
language plpgsql security definer set search_path = '' as $$
declare s public.seasons; v_last private.season_award_results; v_same boolean; v_res text; v_type text := private.v87_award_type(p_category);
 v_id uuid; v_shared boolean := cardinality(p_winners) > 1;
begin
 select * into s from public.seasons where id = p_season;
 select * into v_last from private.season_award_results where season_id = p_season and category = p_category and is_current for update;
 v_same := found and v_last.status = p_status and v_last.basis = p_basis and v_last.winners @> p_winners and p_winners @> v_last.winners;
 if not found then
  insert into private.season_award_results(pelada_id, season_id, category, version, status, basis, winners, criteria, ranking,
   rules_version, published_at)
  values(s.pelada_id, p_season, p_category, 1, p_status, p_basis, p_winners, p_criteria, p_ranking,
   private.v87_rules_version(), case when p_status = 'published' then now() end) returning id into v_id;
  insert into private.v87_events(pelada_id, season_id, category, kind, detail)
  values(s.pelada_id, p_season, p_category, case p_status when 'published' then 'published' else p_status end,
   jsonb_build_object('result_id', v_id, 'version', 1, 'status', p_status, 'basis', p_basis, 'winners', p_winners, 'criteria', p_criteria));
  v_res := 'created';
 elsif v_same then
  if v_last.ranking is distinct from p_ranking or v_last.criteria is distinct from p_criteria then
   update private.season_award_results set ranking = p_ranking, criteria = p_criteria, computed_at = now() where id = v_last.id;
  end if;
  v_res := 'unchanged';
 else
  update private.season_award_results set is_current = false where id = v_last.id;
  insert into private.season_award_results(pelada_id, season_id, category, version, status, basis, winners, criteria, ranking,
   rules_version, published_at, rectifies)
  values(s.pelada_id, p_season, p_category, v_last.version + 1, p_status, p_basis, p_winners, p_criteria, p_ranking,
   private.v87_rules_version(), case when p_status = 'published' then now() end, v_last.id) returning id into v_id;
  insert into private.v87_events(pelada_id, season_id, category, kind, detail)
  values(s.pelada_id, p_season, p_category, 'corrected',
   jsonb_build_object('result_id', v_id, 'version', v_last.version + 1, 'from', jsonb_build_object('status', v_last.status,
    'basis', v_last.basis, 'winners', v_last.winners), 'to', jsonb_build_object('status', p_status, 'basis', p_basis, 'winners', p_winners),
    'criteria', p_criteria));
  v_res := 'changed';
 end if;
 -- Prêmios ativos = vencedores da versão corrente (corrige também qualquer divergência herdada).
 update public.awards set status = 'revoked', revoked_at = now()
 where season_id = p_season and award_type = v_type and status = 'active'
  and (p_status <> 'published' or not (membership_id = any(p_winners)));
 if p_status = 'published' then
  update public.awards set is_shared = v_shared
  where season_id = p_season and award_type = v_type and status = 'active' and is_shared <> v_shared;
  insert into public.awards(pelada_id, season_id, membership_id, award_type, is_shared)
  select s.pelada_id, p_season, w, v_type, v_shared from unnest(p_winners) w
  where not exists(select 1 from public.awards a where a.season_id = p_season and a.award_type = v_type
   and a.status = 'active' and a.membership_id = w);
 end if;
 return v_res;
end $$;

---------------------------------------------------------------------------------------------------
-- Sincronização conjunta (B10): calcula e publica as três categorias, ou nada
---------------------------------------------------------------------------------------------------
create function private.season_awards_sync(p_season uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seasons; v_min date; v_had boolean; v_sc jsonb; v_ma jsonb; v_gl jsonb; r_sc text; r_ma text; r_gl text;
 v_sig text; v_any boolean;
begin
 select * into s from public.seasons where id = p_season;
 if not found then return jsonb_build_object('status', 'SEASON_NOT_FOUND'); end if;
 select min_season_end into v_min from private.v87_activation where feature = 'season_awards';
 if v_min is null or s.ends_on < v_min then return jsonb_build_object('status', 'BEFORE_ACTIVATION'); end if;
 perform pg_advisory_xact_lock(hashtextextended('v87:' || p_season::text, 0));
 if not coalesce((private.season_consolidation(p_season)->>'ready')::boolean, false) then
  return jsonb_build_object('status', 'SEASON_NOT_READY');
 end if;
 v_had := exists(select 1 from private.season_award_results where season_id = p_season);

 v_sc := private.v87_stat_result(p_season, 'goals');
 v_ma := private.v87_stat_result(p_season, 'assists');
 v_gl := private.v87_glove_result(p_season);

 r_sc := private.season_award_apply(p_season, 'top_scorer',
  case when jsonb_array_length(v_sc->'winners') > 0 then 'published' else 'no_winner' end, 'normal',
  array(select jsonb_array_elements_text(v_sc->'winners')::uuid),
  jsonb_build_object('rules_version', private.v87_rules_version(), 'stat', 'goals', 'minimum', 1), v_sc->'ranking');
 r_ma := private.season_award_apply(p_season, 'maestro',
  case when jsonb_array_length(v_ma->'winners') > 0 then 'published' else 'no_winner' end, 'normal',
  array(select jsonb_array_elements_text(v_ma->'winners')::uuid),
  jsonb_build_object('rules_version', private.v87_rules_version(), 'stat', 'assists', 'minimum', 1), v_ma->'ranking');
 if (v_gl->>'void_exception')::boolean then
  update private.golden_glove_exceptions set status = 'void', closed_reason = 'normal_eligible', closed_at = now()
  where id = (v_gl->>'exception_id')::uuid;
  insert into private.v87_events(pelada_id, season_id, category, kind, detail)
  values(s.pelada_id, p_season, 'golden_glove', 'exception_void', jsonb_build_object('reason', 'normal_eligible'));
 end if;
 r_gl := private.season_award_apply(p_season, 'golden_glove', v_gl->>'status', v_gl->>'basis',
  array(select jsonb_array_elements_text(v_gl->'winners')::uuid), v_gl->'criteria', v_gl->'ranking');

 -- Aviso coletivo (C07): uma vez por estado oficial; nunca traz vencedores nem dados privados.
 v_any := 'created' in (r_sc, r_ma, r_gl) or 'changed' in (r_sc, r_ma, r_gl);
 if v_any and not private.quiet_effects() and exists(select 1 from private.season_award_results
   where season_id = p_season and is_current and status = 'published') then
  select md5(string_agg(category || ':' || version, ',' order by category)) into v_sig
  from private.season_award_results where season_id = p_season and is_current;
  perform private.notify(u, s.pelada_id, case when v_had then 'season_awards_corrected' else 'season_awards_published' end,
   'essential', 'season_awards:' || p_season || ':' || v_sig || ':' || u,
   jsonb_build_object('pelada_id', s.pelada_id, 'season_id', p_season))
  from private.pelada_users(s.pelada_id) u;
 end if;
 return jsonb_build_object('status', 'ok', 'top_scorer', r_sc, 'maestro', r_ma, 'golden_glove', r_gl);
end $$;

-- Mesma coisa, mas sem derrubar o fluxo de quem chamou (finalização, correção, agendador): a falha vira evento.
create function private.season_awards_sync_safe(p_season uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
 begin
  v := private.season_awards_sync(p_season);
 exception when others then
  insert into private.v87_events(pelada_id, season_id, kind, detail)
  select s.pelada_id, s.id, 'sync_failed', jsonb_build_object('sqlstate', sqlstate, 'message', sqlerrm)
  from public.seasons s where s.id = p_season;
  v := jsonb_build_object('status', 'SYNC_FAILED');
 end;
 return v;
end $$;

-- Ganchos (B03/F04): qualquer mudança oficial que pode alterar vencedores recalcula as temporadas já encerradas que ela alcança.
create function private.season_awards_after_change(p_pelada uuid, p_from date) returns void
language plpgsql security definer set search_path = '' as $$
declare r record; v_min date;
begin
 select min_season_end into v_min from private.v87_activation where feature = 'season_awards';
 if v_min is null then return; end if;
 for r in select s.id from public.seasons s
  where s.pelada_id = p_pelada and s.ends_on >= v_min and s.ends_on < private.pelada_today(p_pelada)
   and (p_from is null or s.ends_on >= p_from) order by s.starts_on loop
  perform private.season_awards_sync_safe(r.id);
 end loop;
end $$;

alter function private.close_month(uuid, date) rename to close_month_v86;
create function private.close_month(p_pelada uuid, p_month date) returns void
language plpgsql security definer set search_path = '' as $$
begin
 perform private.close_month_v86(p_pelada, p_month);
 perform private.season_awards_after_change(p_pelada, date_trunc('month', p_month)::date);
end $$;

alter function private.after_rating_inputs_changed(uuid, uuid, text) rename to after_rating_inputs_changed_pre87;
create function private.after_rating_inputs_changed(p_pelada uuid, p_match uuid, p_event text) returns void
language plpgsql security definer set search_path = '' as $$
begin
 perform private.after_rating_inputs_changed_pre87(p_pelada, p_match, p_event);
 perform private.season_awards_after_change(p_pelada, null);
end $$;

-- Agendador: temporadas encerradas ainda sem apuração (inclui encerramento antecipado pelo calendário).
create function private.process_season_awards() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0; v_min date;
begin
 select min_season_end into v_min from private.v87_activation where feature = 'season_awards';
 if v_min is null then return 0; end if;
 for r in select s.id from public.seasons s
  where s.ends_on >= v_min and s.ends_on < private.pelada_today(s.pelada_id) and s.lifecycle = 'normal'
   and not exists(select 1 from private.season_award_results x where x.season_id = s.id) loop
  perform private.season_awards_sync_safe(r.id);
  n := n + 1;
 end loop;
 return n;
end $$;
create function public.process_season_awards() returns integer
language sql security definer set search_path = '' as $$ select private.process_season_awards() $$;

alter function private.run_scheduled_tasks() rename to run_scheduled_tasks_pre87;
create function private.run_scheduled_tasks() returns void
language plpgsql security definer set search_path = '' as $$
begin
 perform private.run_scheduled_tasks_pre87();
 perform private.process_season_awards();
end $$;

---------------------------------------------------------------------------------------------------
-- Avisos (C07)
---------------------------------------------------------------------------------------------------
-- Quem perdeu o título numa correção recebe aviso próprio (só ele); nada de dados de terceiros.
create function private.notify_season_award_revoked() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if old.status = 'active' and new.status = 'revoked' and not private.quiet_effects() then
  perform private.notify(m.user_id, new.pelada_id, 'season_award_revoked', 'essential', 'season_award_revoked:' || new.id,
   jsonb_build_object('pelada_id', new.pelada_id, 'award_type', new.award_type))
  from public.pelada_memberships m where m.id = new.membership_id and m.status = 'active';
 end if;
 return new;
end $$;
create trigger season_award_revoked_notifications after update of status on public.awards
for each row when (new.award_type in ('season_top_scorer','season_maestro','season_golden_glove'))
execute function private.notify_season_award_revoked();

---------------------------------------------------------------------------------------------------
-- Leitura (ranking/critérios só para o admin)
---------------------------------------------------------------------------------------------------
create function private.v87_winner_entries(p_pelada uuid, p_winners uuid[], p_ranking jsonb) returns jsonb
language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_agg(jsonb_build_object('membership_id', m.id, 'name', m.player_name,
   'avatar_path', case when m.user_id is not null and not private.blocked_either_way(m.user_id)
     then (select p.avatar_path from public.profiles p where p.id = m.user_id) end,
   'value', (select e->'value' from jsonb_array_elements(p_ranking) e where e->>'membership_id' = m.id::text limit 1),
   'is_shared', cardinality(p_winners) > 1) order by m.player_name, m.id), '[]'::jsonb)
 from public.pelada_memberships m where m.id = any(p_winners) and m.pelada_id = p_pelada;
$$;

-- Ranking com nomes (só o admin recebe): ajuda a decidir a exceção sem expor ids soltos.
create function private.v87_named_ranking(p_ranking jsonb) returns jsonb
language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_agg(e || jsonb_build_object('name', m.player_name) order by o), '[]'::jsonb)
 from jsonb_array_elements(p_ranking) with ordinality q(e, o)
 left join public.pelada_memberships m on m.id = (e->>'membership_id')::uuid;
$$;

-- Vencedores publicados (para a retrospectiva): só a versão corrente, só o que é público dentro da pelada.
create function private.season_awards_public(p_season uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb := '{}'::jsonb; x private.season_award_results;
begin
 if not exists(select 1 from private.season_award_results where season_id = p_season) then
  perform private.season_awards_sync_safe(p_season);
 end if;
 for x in select * from private.season_award_results where season_id = p_season and is_current and status = 'published' loop
  v := v || jsonb_build_object(x.category, jsonb_build_object('version', x.version, 'basis', x.basis,
   'winners', private.v87_winner_entries(x.pelada_id, x.winners, x.ranking)));
 end loop;
 return v;
end $$;

create function public.get_season_awards(p_season uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_admin boolean; v jsonb := '{}'::jsonb; x private.season_award_results; v_ex private.golden_glove_exceptions;
 v_floor jsonb; v_cons jsonb; v_exc jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 v_pelada := private.check_season_access(p_season);
 v_admin := private.is_active_admin(v_pelada);
 if not exists(select 1 from private.season_award_results where season_id = p_season) then
  perform private.season_awards_sync_safe(p_season);
 end if;
 v_cons := private.season_consolidation(p_season);
 for x in select * from private.season_award_results where season_id = p_season and is_current loop
  v := v || jsonb_build_object(x.category, jsonb_build_object(
   'status', case when x.status = 'awaiting_exception' and not v_admin then 'pending' else x.status end,
   'version', x.version, 'basis', x.basis, 'published_at', x.published_at,
   'winners', case when x.status = 'published' then private.v87_winner_entries(x.pelada_id, x.winners, x.ranking) else '[]'::jsonb end)
   || case when v_admin then jsonb_build_object('ranking', private.v87_named_ranking(x.ranking), 'criteria', x.criteria) else '{}'::jsonb end);
 end loop;
 if v_admin then
  select * into v_ex from private.golden_glove_exceptions where season_id = p_season and status = 'active';
  if coalesce(v->'golden_glove'->>'status', '') = 'awaiting_exception' or found then
   v_floor := private.glove_pick(p_season, 0, 3);
   v_exc := jsonb_build_object(
    'available', coalesce(v->'golden_glove'->>'status', '') = 'awaiting_exception' or found,
    'active', case when v_ex.id is null then null else jsonb_build_object('min_percent', v_ex.min_percent,
      'min_matches', v_ex.min_matches, 'reason', v_ex.reason, 'authorized_at', v_ex.authorized_at) end,
    'floor_matches', 3, 'candidates', (select coalesce(jsonb_agg(e), '[]'::jsonb)
      from jsonb_array_elements(private.v87_named_ranking(v_floor->'ranking')) e where (e->>'official_position') = 'GOL' and (e->>'gk_matches')::int >= 3));
  end if;
 end if;
 return jsonb_build_object('season_id', p_season, 'rules_version', private.v87_rules_version(),
  'ready', coalesce((v_cons->>'ready')::boolean, false), 'is_admin', v_admin, 'categories', v,
  'ref_note', 'A REF da Luva de Ouro é a REF oficial no encerramento: janela móvel das últimas 20 partidas do goleiro, que pode incluir temporadas anteriores.')
  || case when v_exc is not null then jsonb_build_object('golden_glove_exception', v_exc) else '{}'::jsonb end;
end $$;

---------------------------------------------------------------------------------------------------
-- Exceção administrativa da Luva (F01 / C08 / B09)
---------------------------------------------------------------------------------------------------
create function public.grant_golden_glove_exception(p_season uuid, p_min_percent integer, p_min_matches integer, p_reason text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seasons; v_reason text := btrim(coalesce(p_reason, '')); v_cur private.season_award_results; v_ex private.golden_glove_exceptions;
 v_res jsonb; v_new uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 select * into s from public.seasons where id = p_season;
 if not found or not private.is_active_member(s.pelada_id) then raise exception 'SEASON_NOT_FOUND'; end if;
 if not private.is_active_admin(s.pelada_id) then raise exception 'ADMIN_REQUIRED' using errcode = '42501'; end if;
 if length(v_reason) not between 10 and 500 then raise exception 'EXCEPTION_REASON_REQUIRED'; end if;
 if p_min_percent is null or p_min_matches is null or p_min_percent not between 0 and 50 or p_min_matches not between 3 and 5
  or (p_min_percent >= 50 and p_min_matches >= 5) then raise exception 'INVALID_EXCEPTION_PARAMS'; end if;
 perform pg_advisory_xact_lock(hashtextextended('v87:' || p_season::text, 0));
 perform private.season_awards_sync(p_season);
 select * into v_cur from private.season_award_results where season_id = p_season and category = 'golden_glove' and is_current;
 select * into v_ex from private.golden_glove_exceptions where season_id = p_season and status = 'active';
 if v_cur.id is null then raise exception 'SEASON_NOT_CONSOLIDATED'; end if;
 if not (v_cur.status = 'awaiting_exception' or v_ex.id is not null) then raise exception 'EXCEPTION_NOT_AVAILABLE'; end if;
 if v_ex.id is not null then
  update private.golden_glove_exceptions set status = 'revoked', closed_reason = 'replaced', closed_at = now() where id = v_ex.id;
 end if;
 insert into private.golden_glove_exceptions(pelada_id, season_id, min_percent, min_matches, reason, authorized_by)
 values(s.pelada_id, p_season, p_min_percent, p_min_matches, v_reason, auth.uid()) returning id into v_new;
 insert into private.v87_events(pelada_id, season_id, category, kind, actor_user_id, detail)
 values(s.pelada_id, p_season, 'golden_glove', 'exception_granted', auth.uid(),
  jsonb_build_object('exception_id', v_new, 'min_percent', p_min_percent, 'min_matches', p_min_matches, 'reason', v_reason));
 insert into private.audit_events(pelada_id, actor_user_id, event_type, metadata)
 values(s.pelada_id, auth.uid(), 'golden_glove_exception_granted',
  jsonb_build_object('season_id', p_season, 'min_percent', p_min_percent, 'min_matches', p_min_matches, 'reason', v_reason));
 v_res := private.season_awards_sync(p_season);
 select * into v_cur from private.season_award_results where season_id = p_season and category = 'golden_glove' and is_current;
 return jsonb_build_object('status', v_cur.status, 'basis', v_cur.basis, 'winners', cardinality(v_cur.winners));
end $$;

create function public.revoke_golden_glove_exception(p_season uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seasons; v_reason text := btrim(coalesce(p_reason, '')); v_ex private.golden_glove_exceptions; v_cur private.season_award_results;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 select * into s from public.seasons where id = p_season;
 if not found or not private.is_active_member(s.pelada_id) then raise exception 'SEASON_NOT_FOUND'; end if;
 if not private.is_active_admin(s.pelada_id) then raise exception 'ADMIN_REQUIRED' using errcode = '42501'; end if;
 if length(v_reason) not between 10 and 500 then raise exception 'EXCEPTION_REASON_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended('v87:' || p_season::text, 0));
 select * into v_ex from private.golden_glove_exceptions where season_id = p_season and status = 'active' for update;
 if not found then raise exception 'EXCEPTION_NOT_FOUND'; end if;
 update private.golden_glove_exceptions set status = 'revoked', closed_reason = v_reason, closed_at = now() where id = v_ex.id;
 insert into private.v87_events(pelada_id, season_id, category, kind, actor_user_id, detail)
 values(s.pelada_id, p_season, 'golden_glove', 'exception_revoked', auth.uid(), jsonb_build_object('exception_id', v_ex.id, 'reason', v_reason));
 insert into private.audit_events(pelada_id, actor_user_id, event_type, metadata)
 values(s.pelada_id, auth.uid(), 'golden_glove_exception_revoked', jsonb_build_object('season_id', p_season, 'reason', v_reason));
 perform private.season_awards_sync(p_season);
 select * into v_cur from private.season_award_results where season_id = p_season and category = 'golden_glove' and is_current;
 return jsonb_build_object('status', v_cur.status, 'basis', v_cur.basis);
end $$;

---------------------------------------------------------------------------------------------------
-- Sala de Troféus: SÓ contadores (C02/F02). Layout e demais tipos como na V8.6.
---------------------------------------------------------------------------------------------------
alter function public.get_player_career_summary(uuid) rename to get_player_career_summary_pre87;
alter function public.get_player_career_summary_pre87(uuid) set schema private;
create function public.get_player_career_summary(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := private.get_player_career_summary_pre87(p_user); v_p jsonb;
begin
 if not coalesce((v->>'visible')::boolean, false) then return v; end if;
 select coalesce(jsonb_agg(e || jsonb_build_object('trophies', (e->'trophies') || jsonb_build_object(
   'season_top_scorer', c.a, 'season_maestro', c.b, 'season_golden_glove', c.g)) order by o), '[]'::jsonb)
 into v_p
 from jsonb_array_elements(v->'peladas') with ordinality q(e, o)
 cross join lateral (
  select count(*) filter (where a.award_type = 'season_top_scorer')::int a, count(*) filter (where a.award_type = 'season_maestro')::int b,
   count(*) filter (where a.award_type = 'season_golden_glove')::int g
  from public.awards a
  where a.membership_id = (e->>'membership_id')::uuid and a.status = 'active'
   and a.award_type in ('season_top_scorer','season_maestro','season_golden_glove')
   and a.season_id = any(array(select private.career_seasons((e->>'pelada_id')::uuid)))) c;
 return v || jsonb_build_object('peladas', v_p, 'trophies', (v->'trophies') || jsonb_build_object(
  'season_top_scorer', (select coalesce(sum((e->'trophies'->>'season_top_scorer')::int), 0) from jsonb_array_elements(v_p) e),
  'season_maestro', (select coalesce(sum((e->'trophies'->>'season_maestro')::int), 0) from jsonb_array_elements(v_p) e),
  'season_golden_glove', (select coalesce(sum((e->'trophies'->>'season_golden_glove')::int), 0) from jsonb_array_elements(v_p) e)));
end $$;

-- Histórico detalhado destes três tipos NÃO vai para a Sala (F02): ficam nos registros internos, em Meus Prêmios e na Retrospectiva.
alter function public.get_trophy_history(uuid,text,jsonb,integer) rename to get_trophy_history_pre87;
alter function public.get_trophy_history_pre87(uuid,text,jsonb,integer) set schema private;
create function public.get_trophy_history(p_user uuid, p_type text, p_after jsonb default null, p_limit integer default 20)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_level text;
begin
 if p_type is null or p_type not in ('season_top_scorer','season_maestro','season_golden_glove') then
  return private.get_trophy_history_pre87(p_user, p_type, p_after, p_limit);
 end if;
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 select career_visibility into v_level from public.profiles where id = p_user;
 if not found or not private.can_view_global(p_user, v_level) then return jsonb_build_object('visible', false); end if;
 return jsonb_build_object('visible', true, 'items', '[]'::jsonb, 'next', null, 'counter_only', true);
end $$;

---------------------------------------------------------------------------------------------------
-- AD01: Minha Carreira — Meus Prêmios (todos os títulos oficiais de temporada, um por linha)
---------------------------------------------------------------------------------------------------
create function public.get_player_season_titles(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_level text; v_items jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 select career_visibility into v_level from public.profiles where id = p_user;
 if not found or not private.can_view_global(p_user, v_level) then return jsonb_build_object('visible', false); end if;
 select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'award_type', t.award_type, 'season_id', t.season_id,
   'season_name', t.sname, 'year', t.yr, 'starts_on', t.starts_on, 'is_shared', t.is_shared,
   'pelada_id', t.pelada_id, 'pelada_name', t.pname) order by t.starts_on desc, t.ord, t.pname, t.id), '[]'::jsonb)
 into v_items
 from (select a.id, a.award_type, a.season_id, s.name sname, extract(year from s.ends_on)::int yr, s.starts_on, a.is_shared,
   mem.pelada_id, p.name pname,
   case a.award_type when 'season_craque' then 1 when 'season_top_scorer' then 2 when 'season_maestro' then 3 else 4 end ord
  from public.pelada_memberships mem
  join public.awards a on a.membership_id = mem.id
  join public.peladas p on p.id = mem.pelada_id
  join public.seasons s on s.id = a.season_id
  where mem.user_id = p_user and mem.status in ('active','left') and a.status = 'active'
   and a.award_type in ('season_craque','season_top_scorer','season_maestro','season_golden_glove')
   and a.season_id = any(array(select private.career_seasons(mem.pelada_id)))
  order by s.starts_on desc limit 200) t;
 return jsonb_build_object('visible', true, 'items', v_items);
end $$;

---------------------------------------------------------------------------------------------------
-- Retrospectiva: bloco season_awards (a versão guardada da V8.1 não muda)
---------------------------------------------------------------------------------------------------
alter function public.get_season_retrospective_official(uuid) rename to get_season_retrospective_official_pre87;
alter function public.get_season_retrospective_official_pre87(uuid) set schema private;
create function public.get_season_retrospective_official(p_season uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
 return private.get_season_retrospective_official_pre87(p_season)
  || jsonb_build_object('season_awards', private.season_awards_public(p_season));
end $$;

---------------------------------------------------------------------------------------------------
-- Permissões
---------------------------------------------------------------------------------------------------
revoke all on function private.v87_events_immutable(), private.v87_rules_version(), private.v87_award_type(text),
 private.v87_season_cutoff(uuid), private.v87_ref_at(uuid,timestamptz), private.v87_stat_result(uuid,text),
 private.glove_candidates(uuid,integer,integer), private.glove_pick(uuid,integer,integer), private.v87_glove_result(uuid),
 private.season_award_apply(uuid,text,text,text,uuid[],jsonb,jsonb), private.season_awards_sync(uuid),
 private.season_awards_sync_safe(uuid), private.season_awards_after_change(uuid,date), private.close_month(uuid,date),
 private.close_month_v86(uuid,date), private.after_rating_inputs_changed(uuid,uuid,text),
 private.after_rating_inputs_changed_pre87(uuid,uuid,text), private.process_season_awards(), private.run_scheduled_tasks(),
 private.run_scheduled_tasks_pre87(), private.notify_season_award_revoked(), private.v87_winner_entries(uuid,uuid[],jsonb), private.v87_named_ranking(jsonb),
 private.season_awards_public(uuid), private.get_player_career_summary_pre87(uuid),
 private.get_trophy_history_pre87(uuid,text,jsonb,integer), private.get_season_retrospective_official_pre87(uuid)
 from public, anon, authenticated;
revoke all on function public.get_season_awards(uuid), public.grant_golden_glove_exception(uuid,integer,integer,text),
 public.revoke_golden_glove_exception(uuid,text), public.get_player_season_titles(uuid), public.process_season_awards(),
 public.get_player_career_summary(uuid), public.get_trophy_history(uuid,text,jsonb,integer),
 public.get_season_retrospective_official(uuid) from public, anon;
grant execute on function public.get_season_awards(uuid), public.grant_golden_glove_exception(uuid,integer,integer,text),
 public.revoke_golden_glove_exception(uuid,text), public.get_player_season_titles(uuid),
 public.get_player_career_summary(uuid), public.get_trophy_history(uuid,text,jsonb,integer),
 public.get_season_retrospective_official(uuid) to authenticated;
revoke all on function public.process_season_awards() from authenticated;
grant execute on function public.process_season_awards() to service_role;
