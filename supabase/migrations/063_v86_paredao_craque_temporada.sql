-- Minuto 91 / 063: V8.6 — Paredão do Mês (PM-01..PM-12) e Craque da Temporada (CT-01..CT-13, V01..V30, F01..F04).
-- Especificação normativa: docs/V8.6_DECISOES_COMPLETAS.md. Rastreabilidade: docs/V8.6_MATRIZ_RASTREABILIDADE.md.
--
-- Não altera as fórmulas globais de OVR/REF (051), nem as seis premiações anteriores. Acrescenta:
--  * awards.award_type 'monthly_goalkeeper' (Paredão do Mês) e 'season_craque' (Craque da Temporada);
--  * Paredão: calculado em private.close_month (embrulhado), PUBLICADO só após confirmação do admin (PM-08), com versões
--    auditáveis quando uma correção muda o resultado (PM-11). REF mensal = MESMA função de REF da 051 (rating_ref_match,
--    encolhimento ref_shrink, neutro ref_neutral, peso de recência 30 − partidas posteriores) aplicada só às partidas
--    do goleiro no mês (ADR V86-02);
--  * Craque da Temporada: candidatos, snapshot de eleitores, 1º/2º turno, prorrogação única, quórum ceil(N/2), desempate
--    esportivo, confirmação do admin, reinício por correção (V18/V25) e sinalização de retificação (V19).
-- FAIL-CLOSED (decisões pendentes, não inventadas): empate de OVR na formação de candidatos (G03) e empate remanescente
-- depois do critério 6 do desempate final (ordem dos atributos, F04=A) deixam o fluxo bloqueado, sem sorteio nem admin.
-- Rollback: dropar as funções/tabelas v86/paredao/craque, restaurar private.close_month (049), get_player_career_summary e
-- get_trophy_history (056), e a constraint de awards (049).

---------------------------------------------------------------------------------------------------
-- Ativação (PM-10 / CT-13: sem concessão retroativa)
---------------------------------------------------------------------------------------------------
create table private.v86_activation (
 feature text primary key check (feature in ('monthly_goalkeeper','season_craque')),
 activated_at timestamptz not null default now()
);
revoke all on private.v86_activation from public, anon, authenticated;
insert into private.v86_activation(feature) values ('monthly_goalkeeper'), ('season_craque');

---------------------------------------------------------------------------------------------------
-- awards: novos tipos
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
  'monthly_goalkeeper','season_craque'));
alter table public.awards drop constraint award_period;
alter table public.awards add constraint award_period check (
 (award_type = 'season_craque' and match_id is null and period_month is null)
 or (award_type <> 'season_craque' and (match_id is null) = (period_month is not null)));
create unique index one_active_season_craque on public.awards(season_id) where award_type = 'season_craque' and status = 'active';

---------------------------------------------------------------------------------------------------
-- Auxiliares
---------------------------------------------------------------------------------------------------
-- Posição oficial cadastrada num instante (histórico de position_changes; sem mudança, a atual).
create function private.v86_official_position(p_membership uuid, p_at timestamptz) returns text
language sql stable security definer set search_path = '' as $$
 select coalesce(
  (select c.to_position_code from public.position_changes c where c.membership_id = p_membership and c.changed_at < p_at
   order by c.changed_at desc, c.position_version desc limit 1),
  (select c.from_position_code from public.position_changes c where c.membership_id = p_membership and c.changed_at >= p_at
   order by c.changed_at, c.position_version limit 1),
  (select m.position_code from public.pelada_memberships m where m.id = p_membership));
$$;

-- Eventos de auditoria, imutáveis.
create table private.v86_events (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 subject text not null check (subject in ('monthly_goalkeeper','season_craque')),
 subject_id uuid not null,
 kind text not null,
 actor_user_id uuid,
 detail jsonb not null default '{}'::jsonb,
 occurred_at timestamptz not null default clock_timestamp()
);
create index idx_v86_events on private.v86_events(subject, subject_id, occurred_at);
revoke all on private.v86_events from public, anon, authenticated;
create function private.v86_events_immutable() returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'V86_EVENTS_IMMUTABLE'; end $$;
create trigger v86_events_immutable before update or delete on private.v86_events
for each row execute function private.v86_events_immutable();

---------------------------------------------------------------------------------------------------
-- PAREDÃO DO MÊS
---------------------------------------------------------------------------------------------------
create table private.monthly_goalkeeper_results (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 period_month date not null,
 version integer not null,
 season_id uuid,
 status text not null check (status in ('awaiting_admin','published','no_winner','superseded','cancelled')),
 winners uuid[] not null default '{}',
 ranking jsonb not null default '[]'::jsonb,
 rectifies uuid,
 computed_at timestamptz not null default now(),
 confirmed_by uuid,
 confirmed_at timestamptz,
 unique (pelada_id, period_month, version)
);
revoke all on private.monthly_goalkeeper_results from public, anon, authenticated;

-- REF mensal e métricas por goleiro. Só partidas finalizadas do mês em que a pessoa jogou no gol (posição da súmula).
create function private.paredao_ranking(p_pelada uuid, p_month date)
returns table(membership_id uuid, gk_matches integer, saves_matches integer, saves_total integer, avg_saves numeric,
 ref numeric, official_gol boolean)
language sql stable security definer set search_path = '' as $$
 with prm as (select (params->>'ref_neutral')::float8 neutral, (params->>'ref_shrink')::float8 shrink
  from private.rating_params_active()),
 gm as (
  select x.membership_id, ks.hard_saves sv,
   row_number() over (partition by x.membership_id order by m.played_at desc, m.id desc) - 1 later
  from public.matches m join public.match_participants x on x.match_id = m.id
  left join public.match_keeper_saves ks on ks.participant_id = x.id and ks.match_id = m.id
  where m.pelada_id = p_pelada and m.status = 'finalized' and x.membership_id is not null
   and x.primary_position = 'goalkeeper'
   and private.pelada_local_date(p_pelada, m.played_at) >= date_trunc('month', p_month)::date
   and private.pelada_local_date(p_pelada, m.played_at) < (date_trunc('month', p_month) + interval '1 month')::date),
 agg as (
  select g.membership_id, count(*)::int gk, count(g.sv)::int sm, coalesce(sum(g.sv), 0)::int st,
   sum(greatest(30 - g.later, 1)) filter (where g.sv is not null) sw,
   sum(greatest(30 - g.later, 1) * private.rating_ref_match(g.sv::float8)) filter (where g.sv is not null) swv
  from gm g group by g.membership_id)
 select a.membership_id, a.gk, a.sm, a.st,
  case when a.sm > 0 then round(a.st::numeric / a.sm, 6) end,
  round((case when a.sm = 0 then prm.neutral
   else prm.neutral + (a.sm::float8 / (a.sm + prm.shrink)) * (a.swv / a.sw - prm.neutral) end)::numeric, 6),
  private.v86_official_position(a.membership_id, (date_trunc('month', p_month) + interval '1 month')::timestamptz) = 'GOL'
 from agg a cross join prm;
$$;

-- PM-01..PM-06: GOL oficial, ≥2 partidas no gol, maior REF mensal, depois média de defesas difíceis, depois partidas; senão compartilhado.
create function private.paredao_winners(p_pelada uuid, p_month date) returns uuid[]
language sql stable security definer set search_path = '' as $$
 with e as (select * from private.paredao_ranking(p_pelada, p_month) where gk_matches >= 2 and official_gol)
 select coalesce((select array_agg(e.membership_id order by e.membership_id) from e
  where (e.ref, coalesce(e.avg_saves, -1), e.gk_matches) = (select e2.ref, coalesce(e2.avg_saves, -1), e2.gk_matches
   from e e2 order by e2.ref desc, coalesce(e2.avg_saves, -1) desc, e2.gk_matches desc limit 1)), '{}'::uuid[]);
$$;

create function private.paredao_after_close(p_pelada uuid, p_month date) returns void
language plpgsql security definer set search_path = '' as $$
declare v_start date := date_trunc('month', p_month)::date; v_end date; v_act timestamptz; v_season uuid; v_w uuid[];
 v_last private.monthly_goalkeeper_results; v_pub private.monthly_goalkeeper_results; v_rank jsonb; v_same boolean;
begin
 v_end := (v_start + interval '1 month')::date;
 select activated_at into v_act from private.v86_activation where feature = 'monthly_goalkeeper';
 if v_act is null or v_start < date_trunc('month', v_act)::date then return; end if;
 if private.pelada_today(p_pelada) < v_end then return; end if;
 if exists(select 1 from public.matches where pelada_id = p_pelada and status in ('voting_open','finalizing')
   and private.pelada_local_date(pelada_id, played_at) >= v_start and private.pelada_local_date(pelada_id, played_at) < v_end)
 then return; end if;

 -- close_month revogou os prêmios ativos do mês: o publicado continua valendo até o admin confirmar outra versão (PM-11).
 select * into v_pub from private.monthly_goalkeeper_results
 where pelada_id = p_pelada and period_month = v_start and status = 'published' order by version desc limit 1;
 if found then
  perform private.grant_month_award(p_pelada, v_pub.season_id, v_start, 'monthly_goalkeeper', v_pub.winners);
 end if;

 select r.season_id into v_season from private.month_results(p_pelada, v_start, v_end) r order by r.played_at desc limit 1;
 if v_season is null then return; end if;
 v_w := private.paredao_winners(p_pelada, v_start);
 select coalesce(jsonb_agg(to_jsonb(r) order by r.ref desc, r.membership_id), '[]'::jsonb) into v_rank
 from private.paredao_ranking(p_pelada, v_start) r;

 select * into v_last from private.monthly_goalkeeper_results
 where pelada_id = p_pelada and period_month = v_start order by version desc limit 1 for update;
 if not found then
  insert into private.monthly_goalkeeper_results(pelada_id, period_month, version, season_id, status, winners, ranking)
  values(p_pelada, v_start, 1, v_season, case when cardinality(v_w) = 0 then 'no_winner' else 'awaiting_admin' end, v_w, v_rank);
  return;
 end if;
 v_same := v_last.winners @> v_w and v_w @> v_last.winners;
 if v_last.status in ('awaiting_admin','no_winner') then
  if v_last.rectifies is not null and v_pub.id is not null and v_pub.winners @> v_w and v_w @> v_pub.winners then
   update private.monthly_goalkeeper_results set status = 'cancelled', winners = v_w, ranking = v_rank, computed_at = now()
   where id = v_last.id;
  else
   update private.monthly_goalkeeper_results set season_id = v_season, winners = v_w, ranking = v_rank, computed_at = now(),
    status = case when cardinality(v_w) = 0 and v_last.rectifies is null then 'no_winner' else 'awaiting_admin' end
   where id = v_last.id;
  end if;
  if not v_same then
   insert into private.v86_events(pelada_id, subject, subject_id, kind, detail)
   values(p_pelada, 'monthly_goalkeeper', v_last.id, 'recomputed', jsonb_build_object('month', v_start, 'winners', v_w));
  end if;
 elsif v_last.status = 'published' and not v_same then
  insert into private.monthly_goalkeeper_results(pelada_id, period_month, version, season_id, status, winners, ranking, rectifies)
  values(p_pelada, v_start, v_last.version + 1, v_season, 'awaiting_admin', v_w, v_rank, v_last.id);
  insert into private.v86_events(pelada_id, subject, subject_id, kind, detail)
  values(p_pelada, 'monthly_goalkeeper', v_last.id, 'rectification_proposed',
   jsonb_build_object('month', v_start, 'from', v_last.winners, 'to', v_w));
 end if;
end $$;

-- close_month (049) continua igual; o Paredão roda depois, no mesmo ponto de chamada.
alter function private.close_month(uuid, date) rename to close_month_v77;
create function private.close_month(p_pelada uuid, p_month date) returns void
language plpgsql security definer set search_path = '' as $$
begin
 perform private.close_month_v77(p_pelada, p_month);
 perform private.paredao_after_close(p_pelada, p_month);
end $$;

-- Admin confirma a publicação (PM-08) ou a retificação (PM-11).
create function public.confirm_monthly_goalkeeper(p_pelada uuid, p_month date) returns void
language plpgsql security definer set search_path = '' as $$
declare v_start date := date_trunc('month', p_month)::date; v_r private.monthly_goalkeeper_results;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 if not private.is_active_member(p_pelada) then raise exception 'PELADA_NOT_FOUND'; end if;
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode = '42501'; end if;
 perform 1 from public.peladas where id = p_pelada for update;
 select * into v_r from private.monthly_goalkeeper_results
 where pelada_id = p_pelada and period_month = v_start order by version desc limit 1 for update;
 if not found or v_r.status <> 'awaiting_admin' then raise exception 'NOTHING_TO_CONFIRM'; end if;
 if v_r.rectifies is not null then
  update public.awards set status = 'revoked', revoked_at = now()
  where pelada_id = p_pelada and award_type = 'monthly_goalkeeper' and period_month = v_start and status = 'active';
  update private.monthly_goalkeeper_results set status = 'superseded' where id = v_r.rectifies;
 end if;
 update private.monthly_goalkeeper_results set status = 'published', confirmed_by = auth.uid(), confirmed_at = now()
 where id = v_r.id;
 perform private.grant_month_award(p_pelada, v_r.season_id, v_start, 'monthly_goalkeeper', v_r.winners);
 insert into private.v86_events(pelada_id, subject, subject_id, kind, actor_user_id, detail)
 values(p_pelada, 'monthly_goalkeeper', v_r.id, 'published', auth.uid(),
  jsonb_build_object('month', v_start, 'winners', v_r.winners, 'rectification', v_r.rectifies is not null));
 insert into private.audit_events(pelada_id, actor_user_id, event_type, metadata)
 values(p_pelada, auth.uid(), 'monthly_goalkeeper_published', jsonb_build_object('month', v_start, 'version', v_r.version));
end $$;

-- Admin vê proposta pendente e ranking; os demais só veem o resultado publicado.
create function public.get_monthly_goalkeeper(p_pelada uuid, p_month date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_start date := date_trunc('month', p_month)::date; v_admin boolean; v_pub private.monthly_goalkeeper_results;
 v_last private.monthly_goalkeeper_results;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 if not private.is_active_member(p_pelada) then raise exception 'PELADA_NOT_FOUND'; end if;
 v_admin := private.is_active_admin(p_pelada);
 select * into v_pub from private.monthly_goalkeeper_results
 where pelada_id = p_pelada and period_month = v_start and status = 'published' order by version desc limit 1;
 select * into v_last from private.monthly_goalkeeper_results
 where pelada_id = p_pelada and period_month = v_start order by version desc limit 1;
 return jsonb_build_object('month', v_start,
  'published', case when v_pub.id is null then null else jsonb_build_object('winners', v_pub.winners, 'is_shared', cardinality(v_pub.winners) > 1) end,
  'pending', case when v_admin and v_last.status = 'awaiting_admin'
   then jsonb_build_object('winners', v_last.winners, 'ranking', v_last.ranking, 'rectification', v_last.rectifies is not null) end,
  'no_winner', coalesce(v_last.status = 'no_winner', false));
end $$;

---------------------------------------------------------------------------------------------------
-- CRAQUE DA TEMPORADA
---------------------------------------------------------------------------------------------------
create table private.season_craque_polls (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 season_id uuid not null references public.seasons(id),
 cycle integer not null default 1,
 status text not null check (status in ('awaiting_open','round1','round2','awaiting_admin','published','no_winner','tie_blocked','cancelled')),
 no_winner_reason text check (no_winner_reason in ('sem_candidatos','candidato_unico','sem_quorum')),
 candidates jsonb not null default '[]'::jsonb,
 r1_opens_at timestamptz, r1_closes_at timestamptz, r1_extended boolean not null default false,
 r2_opens_at timestamptz, r2_closes_at timestamptz, r2_extended boolean not null default false,
 r2_finalists uuid[],
 r1_tally jsonb, r2_tally jsonb,
 winner_membership_id uuid,
 decided_by text check (decided_by in ('votes','tiebreak')),
 tiebreak_trace jsonb,
 rectification_pending boolean not null default false,
 opened_by uuid, published_by uuid, published_at timestamptz,
 created_at timestamptz not null default now(),
 unique (season_id, cycle)
);
create unique index one_live_season_craque_poll on private.season_craque_polls(season_id) where status <> 'cancelled';
create table private.season_craque_electors (
 poll_id uuid not null references private.season_craque_polls(id) on delete cascade,
 round integer not null check (round in (1, 2)),
 membership_id uuid not null,
 primary key (poll_id, round, membership_id)
);
-- Voto secreto (V08): nenhuma função devolve o par eleitor→candidato; só o próprio voto do eleitor e totais após o encerramento.
create table private.season_craque_ballots (
 poll_id uuid not null references private.season_craque_polls(id) on delete cascade,
 round integer not null check (round in (1, 2)),
 voter_membership_id uuid not null,
 candidate_membership_id uuid not null,
 updated_at timestamptz not null default now(),
 primary key (poll_id, round, voter_membership_id)
);
revoke all on private.season_craque_polls, private.season_craque_electors, private.season_craque_ballots
 from public, anon, authenticated;

-- Métrica de desempate de uma pessoa na temporada.
create function private.craque_metric(p_season uuid, p_membership uuid, p_step text) returns numeric
language sql stable security definer set search_path = '' as $$
 select case p_step
  when 'ovr' then coalesce((select c.overall from public.player_cards c where c.season_id = p_season and c.membership_id = p_membership), -1)
  when 'craque_partida' then (select count(*) from public.awards a where a.season_id = p_season and a.membership_id = p_membership
   and a.award_type = 'match_craque' and a.status = 'active')
  when 'partidas' then (select count(*) from public.match_participants x join public.matches m on m.id = x.match_id
   where m.season_id = p_season and m.status = 'finalized' and x.membership_id = p_membership)
  when 'rei_mes' then (select count(*) from public.awards a where a.season_id = p_season and a.membership_id = p_membership
   and a.award_type = 'monthly_king' and a.status = 'active')
  when 'gols' then coalesce((select sum(r.goals) from public.match_player_results r join public.matches m on m.id = r.match_id
   where m.season_id = p_season and m.status = 'finalized' and r.membership_id = p_membership), 0)
  when 'garcom_mes' then (select count(*) from public.awards a where a.season_id = p_season and a.membership_id = p_membership
   and a.award_type = 'monthly_garcom' and a.status = 'active')
 end;
$$;

-- Seção D: OVR → Craques da Partida → partidas → Reis do Mês → gols → Garçons do Mês. Se ainda empatar, o passo 7
-- (atributos oficiais, ordem NÃO aprovada — F04=A) não existe: bloqueia (fail-closed); o admin só decide depois dele.
create function private.craque_tiebreak(p_season uuid, p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_rem uuid[] := p_ids; v_trace jsonb := '[]'::jsonb; v_step text; v_new uuid[];
begin
 foreach v_step in array array['ovr','craque_partida','partidas','rei_mes','gols','garcom_mes'] loop
  exit when cardinality(v_rem) <= 1;
  select array_agg(t.id) into v_new from (
   select s.id, s.val, max(s.val) over () mx from (
    select u.id, private.craque_metric(p_season, u.id, v_step) val from unnest(v_rem) u(id)) s) t
  where t.val = t.mx;
  v_rem := v_new;
  v_trace := v_trace || jsonb_build_array(jsonb_build_object('step', v_step, 'remaining', v_rem));
 end loop;
 if cardinality(v_rem) = 1 then
  return jsonb_build_object('winner', v_rem[1], 'blocked', false, 'trace', v_trace);
 end if;
 return jsonb_build_object('winner', null, 'blocked', true, 'blocked_reason', 'F04_ATTRIBUTE_ORDER_PENDING',
  'remaining', to_jsonb(v_rem), 'trace', v_trace);
end $$;

-- Maior grupo empatado pela chave do modo. 'ovr'/'sub': ≥50% das partidas elegíveis e OVR publicado (CT-06, CT-09).
-- 'goals' (≥1 gol) e 'craque' (≥1 Craque da Partida): sem 50%, mas com OVR publicado (CT-07, CT-08). Chave: contagem, depois OVR (CT-03/04).
create function private.craque_top_group(p_season uuid, p_mode text, p_excl uuid[]) returns uuid[]
language sql stable security definer set search_path = '' as $$
 with tot as (select count(*)::int n from public.matches where season_id = p_season and status = 'finalized'),
 b as (
  select c.membership_id, c.overall ovr,
   (select count(*) from public.match_participants x join public.matches m on m.id = x.match_id
    where m.season_id = p_season and m.status = 'finalized' and x.membership_id = c.membership_id)::int played,
   coalesce((select sum(r.goals) from public.match_player_results r join public.matches m on m.id = r.match_id
    where m.season_id = p_season and m.status = 'finalized' and r.membership_id = c.membership_id), 0)::int goals,
   (select count(*) from public.awards a where a.season_id = p_season and a.membership_id = c.membership_id
    and a.award_type = 'match_craque' and a.status = 'active')::int craques
  from public.player_cards c where c.season_id = p_season and not c.is_provisional),
 f as (
  select b.membership_id, b.ovr,
   case p_mode when 'goals' then b.goals when 'craque' then b.craques else 0 end k1
  from b cross join tot
  where not (b.membership_id = any(p_excl))
   and case p_mode when 'goals' then b.goals >= 1 when 'craque' then b.craques >= 1
        else tot.n > 0 and b.played * 2 >= tot.n end)
 select (select array_agg(f.membership_id order by f.membership_id) from f
  where (f.k1, f.ovr) = (select f2.k1, f2.ovr from f f2 order by f2.k1 desc, f2.ovr desc limit 1));
$$;

-- Candidatos (CT-02, CT-05). Devolve {blocked, candidates:[{membership_id, slot, ovr, substitute}]}.
-- G03: empate completo (contagem + OVR) na vaga bloqueia (pendente de decisão); vaga sem elegível fica vazia (G04).
create function private.craque_candidate_set(p_season uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_sel uuid[] := '{}'; v_out jsonb := '[]'::jsonb; v_g uuid[]; v_slot text; v_mode text; v_h uuid; v_sub boolean;
begin
 foreach v_slot in array array['ovr','goals','craque'] loop
  v_g := private.craque_top_group(p_season, case v_slot when 'ovr' then 'ovr' else v_slot end, '{}');
  v_sub := false;
  if v_g is not null and cardinality(v_g) > 1 then
   return jsonb_build_object('blocked', 'G03_TIE_UNRESOLVED', 'slot', v_slot, 'candidates', '[]'::jsonb);
  end if;
  v_h := v_g[1];
  if v_h is not null and v_h = any(v_sel) then
   v_g := private.craque_top_group(p_season, 'sub', v_sel);
   if v_g is not null and cardinality(v_g) > 1 then
    return jsonb_build_object('blocked', 'G03_TIE_UNRESOLVED', 'slot', v_slot || '_substitute', 'candidates', '[]'::jsonb);
   end if;
   v_h := v_g[1]; v_sub := true;
  end if;
  if v_h is not null then
   v_sel := v_sel || v_h;
   v_out := v_out || jsonb_build_array(jsonb_build_object('membership_id', v_h, 'slot', v_slot, 'substitute', v_sub,
    'ovr', (select c.overall from public.player_cards c where c.season_id = p_season and c.membership_id = v_h)));
  end if;
 end loop;
 return jsonb_build_object('blocked', null, 'candidates', v_out);
end $$;

create function private.craque_log(p_pelada uuid, p_poll uuid, p_kind text, p_detail jsonb default '{}'::jsonb, p_actor uuid default null)
returns void language sql security definer set search_path = '' as $$
 insert into private.v86_events(pelada_id, subject, subject_id, kind, actor_user_id, detail)
 values(p_pelada, 'season_craque', p_poll, p_kind, p_actor, p_detail);
$$;

-- Correção que muda candidatos: antes da publicação, invalida a apuração e reinicia (V18/V25); depois dela, sinaliza
-- retificação auditável (V19) sem alterar nada em silêncio. Política da retificação (G10) pendente.
create function private.craque_recheck(p_poll uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare p private.season_craque_polls; v_set jsonb; v_now uuid[]; v_old uuid[];
begin
 select * into p from private.season_craque_polls where id = p_poll for update;
 if not found or p.status in ('awaiting_open','cancelled') then return; end if;
 v_set := private.craque_candidate_set(p.season_id);
 if v_set->>'blocked' is not null then return; end if;
 select coalesce(array_agg((e->>'membership_id')::uuid order by (e->>'membership_id')), '{}') into v_now
 from jsonb_array_elements(v_set->'candidates') e;
 select coalesce(array_agg((e->>'membership_id')::uuid order by (e->>'membership_id')), '{}') into v_old
 from jsonb_array_elements(p.candidates) e;
 if v_now = v_old then return; end if;
 if p.status = 'published' then
  if not p.rectification_pending then
   update private.season_craque_polls set rectification_pending = true where id = p.id;
   perform private.craque_log(p.pelada_id, p.id, 'rectification_required', jsonb_build_object('candidates_now', v_now));
  end if;
  return;
 end if;
 update private.season_craque_polls set status = 'cancelled' where id = p.id;
 delete from private.season_craque_ballots where poll_id = p.id;
 perform private.craque_log(p.pelada_id, p.id, 'restarted_by_correction',
  jsonb_build_object('from_status', p.status, 'candidates_before', v_old, 'candidates_now', v_now));
 insert into private.season_craque_polls(pelada_id, season_id, cycle, status)
 values(p.pelada_id, p.season_id, p.cycle + 1, 'awaiting_open');
end $$;

-- Avança relógio: encerra turnos vencidos, prorroga uma vez, aplica quórum, apura e desempata. Idempotente.
create function private.craque_advance(p_poll uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare p private.season_craque_polls; v_round integer; v_n integer; v_q integer; v_votes integer; v_loop integer := 0;
 v_leaders uuid[]; v_tally jsonb; v_pool uuid[]; v_tb jsonb; v_e2 integer;
begin
 loop
  v_loop := v_loop + 1;
  exit when v_loop > 8;
  select * into p from private.season_craque_polls where id = p_poll for update;
  if p.status = 'round1' and now() >= p.r1_closes_at then v_round := 1;
  elsif p.status = 'round2' and now() >= p.r2_closes_at then v_round := 2;
  else exit; end if;

  select count(*)::int into v_n from private.season_craque_electors where poll_id = p.id and round = v_round;
  v_q := ceil(v_n / 2.0)::int; -- V14
  select count(*)::int into v_votes from private.season_craque_ballots where poll_id = p.id and round = v_round;
  if v_votes < greatest(v_q, 1) then -- V09/V26: sem quórum (ou sem votos válidos)
   if v_round = 1 and not p.r1_extended then -- V15
    update private.season_craque_polls set r1_extended = true, r1_closes_at = r1_closes_at + interval '24 hours' where id = p.id;
    perform private.craque_log(p.pelada_id, p.id, 'round1_extended', jsonb_build_object('electors', v_n, 'quorum', v_q));
   elsif v_round = 2 and not p.r2_extended then -- V22
    update private.season_craque_polls set r2_extended = true, r2_closes_at = r2_closes_at + interval '24 hours' where id = p.id;
    perform private.craque_log(p.pelada_id, p.id, 'round2_extended', jsonb_build_object('electors', v_n, 'quorum', v_q));
   else
    update private.season_craque_polls set status = 'no_winner', no_winner_reason = 'sem_quorum' where id = p.id;
    perform private.craque_log(p.pelada_id, p.id, 'no_winner_quorum', jsonb_build_object('round', v_round, 'electors', v_n, 'quorum', v_q));
   end if;
   continue;
  end if;

  if v_round = 1 then
   select coalesce(array_agg((e->>'membership_id')::uuid), '{}') into v_pool from jsonb_array_elements(p.candidates) e;
  else v_pool := p.r2_finalists; end if;
  select jsonb_object_agg(u.id::text, (select count(*) from private.season_craque_ballots b
    where b.poll_id = p.id and b.round = v_round and b.candidate_membership_id = u.id)) into v_tally
  from unnest(v_pool) u(id);
  select array_agg(u.id order by u.id) into v_leaders from unnest(v_pool) u(id)
  where (v_tally->>(u.id::text))::int = (select max(x::int) from jsonb_each_text(v_tally) t(k, x));

  if v_round = 1 then update private.season_craque_polls set r1_tally = v_tally where id = p.id;
  else update private.season_craque_polls set r2_tally = v_tally where id = p.id; end if;

  if cardinality(v_leaders) = 1 then
   update private.season_craque_polls set status = 'awaiting_admin', winner_membership_id = v_leaders[1], decided_by = 'votes' where id = p.id;
   perform private.craque_log(p.pelada_id, p.id, 'round_closed_winner', jsonb_build_object('round', v_round));
  elsif v_round = 1 then -- V04: 2º turno só entre os empatados
   select count(*)::int into v_e2 from private.season_craque_electors e1
   where e1.poll_id = p.id and e1.round = 1 and not (e1.membership_id = any(v_leaders));
   update private.season_craque_polls set r2_finalists = v_leaders where id = p.id;
   if v_e2 = 0 then -- V29: ninguém habilitado: critérios de desempate direto
    v_tb := private.craque_tiebreak(p.season_id, v_leaders);
    perform private.craque_apply_tiebreak(p.id, v_tb);
   else
    insert into private.season_craque_electors(poll_id, round, membership_id)
    select p.id, 2, e1.membership_id from private.season_craque_electors e1
    where e1.poll_id = p.id and e1.round = 1 and not (e1.membership_id = any(v_leaders)); -- V16/V17
    update private.season_craque_polls set status = 'round2', r2_opens_at = p.r1_closes_at,
     r2_closes_at = p.r1_closes_at + interval '24 hours' where id = p.id; -- V11
    perform private.craque_log(p.pelada_id, p.id, 'round2_started', jsonb_build_object('finalists', v_leaders, 'electors', v_e2));
   end if;
  else
   v_tb := private.craque_tiebreak(p.season_id, v_leaders);
   perform private.craque_apply_tiebreak(p.id, v_tb);
  end if;
 end loop;
end $$;

create function private.craque_apply_tiebreak(p_poll uuid, p_tb jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare p private.season_craque_polls;
begin
 select * into p from private.season_craque_polls where id = p_poll;
 if (p_tb->>'blocked')::boolean then
  update private.season_craque_polls set status = 'tie_blocked', tiebreak_trace = p_tb where id = p.id;
  perform private.craque_log(p.pelada_id, p.id, 'tie_blocked', p_tb);
 else
  update private.season_craque_polls set status = 'awaiting_admin', winner_membership_id = (p_tb->>'winner')::uuid,
   decided_by = 'tiebreak', tiebreak_trace = p_tb where id = p.id;
  perform private.craque_log(p.pelada_id, p.id, 'tiebreak_decided', p_tb);
 end if;
end $$;

-- Recheck + avanço para a enquete viva da temporada.
create function private.craque_sync(p_season uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
 select id into v_id from private.season_craque_polls where season_id = p_season and status <> 'cancelled' for update;
 if v_id is null then return null; end if;
 perform private.craque_recheck(v_id);
 select id into v_id from private.season_craque_polls where season_id = p_season and status <> 'cancelled';
 perform private.craque_advance(v_id);
 return v_id;
end $$;

create function private.craque_season_ready(p_season uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare s public.seasons; v_act timestamptz;
begin
 select * into s from public.seasons where id = p_season;
 if not found then return 'SEASON_NOT_FOUND'; end if;
 select activated_at into v_act from private.v86_activation where feature = 'season_craque';
 if v_act is null or s.ends_on < v_act::date then return 'BEFORE_ACTIVATION'; end if; -- CT-13
 if s.lifecycle <> 'normal' or s.status <> 'closed' then return 'SEASON_NOT_CLOSED';
 elsif not coalesce((private.season_consolidation(p_season)->>'ready')::boolean, false) then return 'SEASON_NOT_CONSOLIDATED';
 end if;
 return null;
end $$;

-- V05: o admin abre a votação depois do encerramento oficial. Congela candidatos e eleitores (V17).
create function public.open_season_craque_poll(p_season uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seasons; v_why text; v_set jsonb; p private.season_craque_polls; v_n integer; v_has boolean;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 select * into s from public.seasons where id = p_season;
 if not found or not private.is_active_member(s.pelada_id) then raise exception 'SEASON_NOT_FOUND'; end if;
 if not private.is_active_admin(s.pelada_id) then raise exception 'ADMIN_REQUIRED' using errcode = '42501'; end if;
 perform 1 from public.peladas where id = s.pelada_id for update;
 perform private.craque_sync(p_season);
 v_why := private.craque_season_ready(p_season);
 if v_why is not null then raise exception '%', v_why; end if;
 select * into p from private.season_craque_polls where season_id = p_season and status <> 'cancelled';
 v_has := found;
 if v_has and p.status <> 'awaiting_open' then raise exception 'POLL_ALREADY_EXISTS'; end if;
 v_set := private.craque_candidate_set(p_season);
 if v_set->>'blocked' is not null then raise exception 'CANDIDATE_TIE_UNRESOLVED'; end if; -- G03 pendente
 v_n := jsonb_array_length(v_set->'candidates');
 if not v_has then
  insert into private.season_craque_polls(pelada_id, season_id, cycle, status)
  values(s.pelada_id, p_season, coalesce((select max(cycle) from private.season_craque_polls where season_id = p_season), 0) + 1, 'awaiting_open')
  returning * into p;
 end if;
 if v_n < 2 then -- CT-11/CT-12
  update private.season_craque_polls set status = 'no_winner', candidates = v_set->'candidates', opened_by = auth.uid(),
   no_winner_reason = case when v_n = 1 then 'candidato_unico' else 'sem_candidatos' end where id = p.id;
  perform private.craque_log(s.pelada_id, p.id, 'no_winner_candidates', jsonb_build_object('candidates', v_n), auth.uid());
  return jsonb_build_object('status', 'no_winner');
 end if;
 update private.season_craque_polls set status = 'round1', candidates = v_set->'candidates', opened_by = auth.uid(),
  r1_opens_at = now(), r1_closes_at = now() + interval '72 hours' where id = p.id; -- V06
 -- V01/V17: quem disputou ao menos uma partida na temporada e ainda pode votar (membro ativo com conta).
 insert into private.season_craque_electors(poll_id, round, membership_id)
 select distinct p.id, 1, x.membership_id
 from public.match_participants x join public.matches m on m.id = x.match_id
 join public.pelada_memberships pm on pm.id = x.membership_id
 where m.season_id = p_season and m.status = 'finalized' and x.membership_id is not null
  and pm.status = 'active' and pm.user_id is not null;
 perform private.craque_log(s.pelada_id, p.id, 'round1_opened', jsonb_build_object('candidates', v_set->'candidates'), auth.uid());
 insert into private.audit_events(pelada_id, actor_user_id, event_type, metadata)
 values(s.pelada_id, auth.uid(), 'season_craque_opened', jsonb_build_object('season_id', p_season, 'poll_id', p.id));
 return jsonb_build_object('status', 'round1');
end $$;

create function public.cast_season_craque_vote(p_season uuid, p_candidate uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.seasons; v_mem uuid; p private.season_craque_polls; v_round integer; v_pool uuid[];
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 select * into s from public.seasons where id = p_season;
 if not found or not private.is_active_member(s.pelada_id) then raise exception 'SEASON_NOT_FOUND'; end if;
 select id into v_mem from public.pelada_memberships where pelada_id = s.pelada_id and user_id = auth.uid() and status = 'active';
 perform private.craque_sync(p_season);
 select * into p from private.season_craque_polls where season_id = p_season and status <> 'cancelled' for update;
 if not found or p.status not in ('round1','round2') then raise exception 'VOTING_NOT_OPEN'; end if;
 v_round := case p.status when 'round1' then 1 else 2 end;
 if not exists(select 1 from private.season_craque_electors where poll_id = p.id and round = v_round and membership_id = v_mem)
 then raise exception 'NOT_ELIGIBLE_VOTER'; end if;
 if v_round = 1 then
  select array_agg((e->>'membership_id')::uuid) into v_pool from jsonb_array_elements(p.candidates) e;
 else v_pool := p.r2_finalists; end if;
 if p_candidate is null or not (p_candidate = any(v_pool)) then raise exception 'INVALID_CANDIDATE'; end if;
 -- V02: não vota em si; V24/V30: exceção só no 1º turno com exatamente 2 candidatos.
 if p_candidate = v_mem and not (v_round = 1 and cardinality(v_pool) = 2) then raise exception 'SELF_VOTE_NOT_ALLOWED'; end if;
 insert into private.season_craque_ballots(poll_id, round, voter_membership_id, candidate_membership_id)
 values(p.id, v_round, v_mem, p_candidate)
 on conflict (poll_id, round, voter_membership_id) do update set candidate_membership_id = excluded.candidate_membership_id,
  updated_at = now(); -- V07: voto substituível até o encerramento
end $$;

-- V13: o admin confirma a publicação; nada é publicado sozinho.
create function public.confirm_season_craque(p_season uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.seasons; p private.season_craque_polls;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 select * into s from public.seasons where id = p_season;
 if not found or not private.is_active_member(s.pelada_id) then raise exception 'SEASON_NOT_FOUND'; end if;
 if not private.is_active_admin(s.pelada_id) then raise exception 'ADMIN_REQUIRED' using errcode = '42501'; end if;
 perform private.craque_sync(p_season);
 select * into p from private.season_craque_polls where season_id = p_season and status <> 'cancelled' for update;
 if not found or p.status <> 'awaiting_admin' then raise exception 'NOTHING_TO_CONFIRM'; end if;
 update private.season_craque_polls set status = 'published', published_by = auth.uid(), published_at = now() where id = p.id;
 insert into public.awards(pelada_id, season_id, membership_id, award_type, is_shared)
 values(s.pelada_id, p_season, p.winner_membership_id, 'season_craque', false);
 perform private.craque_log(s.pelada_id, p.id, 'published', jsonb_build_object('winner', p.winner_membership_id, 'decided_by', p.decided_by), auth.uid());
 insert into private.audit_events(pelada_id, actor_user_id, event_type, metadata)
 values(s.pelada_id, auth.uid(), 'season_craque_published', jsonb_build_object('season_id', p_season, 'poll_id', p.id));
end $$;

-- Estado para a tela. Sem parciais (V10); o próprio voto só para o próprio eleitor; totais só depois do encerramento
-- (admin ao confirmar, todos após publicar).
create function public.get_season_craque(p_season uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seasons; v_admin boolean; v_mem uuid; p private.season_craque_polls; v_round integer; v_cand jsonb;
 v_set jsonb; v_why text; v_show boolean; v_my uuid; v_pool uuid[];
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 select * into s from public.seasons where id = p_season;
 if not found or not private.is_active_member(s.pelada_id) then raise exception 'SEASON_NOT_FOUND'; end if;
 v_admin := private.is_active_admin(s.pelada_id);
 select id into v_mem from public.pelada_memberships where pelada_id = s.pelada_id and user_id = auth.uid() and status = 'active';
 perform private.craque_sync(p_season);
 select * into p from private.season_craque_polls where season_id = p_season and status <> 'cancelled';
 if not found or p.status = 'awaiting_open' then
  v_why := private.craque_season_ready(p_season);
  if v_admin and v_why is null then v_set := private.craque_candidate_set(p_season); end if;
  return jsonb_build_object('season_id', p_season, 'status', coalesce(p.status, 'not_started'), 'is_admin', v_admin,
   'can_open', v_admin and v_why is null and coalesce(v_set->>'blocked', '') = '',
   'not_ready_reason', v_why, 'blocked', v_set->>'blocked',
   'preview_candidates', case when v_admin then v_set->'candidates' end, 'cycle', p.cycle);
 end if;
 v_round := case p.status when 'round1' then 1 when 'round2' then 2 end;
 v_show := p.status = 'published' or (v_admin and p.status in ('awaiting_admin','tie_blocked','no_winner'));
 if v_round is not null then
  select ballots.candidate_membership_id into v_my from private.season_craque_ballots ballots
  where ballots.poll_id = p.id and ballots.round = v_round and ballots.voter_membership_id = v_mem;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('membership_id', (e->>'membership_id')::uuid, 'slot', e->>'slot',
   'substitute', (e->>'substitute')::boolean, 'ovr', e->'ovr',
   'name', (select pr.display_name from public.pelada_memberships pm join public.profiles pr on pr.id = pm.user_id
            where pm.id = (e->>'membership_id')::uuid),
   'finalist', p.r2_finalists is not null and (e->>'membership_id')::uuid = any(p.r2_finalists))), '[]'::jsonb)
 into v_cand from jsonb_array_elements(p.candidates) e;
 return jsonb_build_object('season_id', p_season, 'poll_id', p.id, 'cycle', p.cycle, 'status', p.status, 'is_admin', v_admin,
  'round', v_round, 'candidates', v_cand,
  'opens_at', case v_round when 1 then p.r1_opens_at when 2 then p.r2_opens_at end,
  'closes_at', case v_round when 1 then p.r1_closes_at when 2 then p.r2_closes_at end,
  'extended', case v_round when 1 then p.r1_extended when 2 then p.r2_extended end,
  'i_am_elector', v_round is not null and exists(select 1 from private.season_craque_electors el
    where el.poll_id = p.id and el.round = v_round and el.membership_id = v_mem),
  'my_vote', v_my, 'my_membership_id', v_mem,
  'no_winner_reason', p.no_winner_reason, 'rectification_pending', p.rectification_pending,
  'winner_membership_id', case when v_show or p.status = 'published' then p.winner_membership_id end,
  'decided_by', case when v_show then p.decided_by end,
  'tally1', case when v_show then p.r1_tally end, 'tally2', case when v_show then p.r2_tally end,
  'tiebreak', case when v_admin then p.tiebreak_trace end,
  'events', case when v_admin then coalesce((select jsonb_agg(jsonb_build_object('kind', ev.kind, 'at', ev.occurred_at)
    order by ev.occurred_at) from private.v86_events ev where ev.subject = 'season_craque' and ev.subject_id in
    (select id from private.season_craque_polls where season_id = p_season)), '[]'::jsonb) end);
end $$;

-- Para o agendador (pg_cron/Edge): encerra turnos vencidos sem depender de alguém abrir o app.
create function public.process_season_craque_polls() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0;
begin
 for r in select season_id from private.season_craque_polls where status in ('round1','round2') loop
  perform private.craque_sync(r.season_id); n := n + 1;
 end loop;
 return n;
end $$;

---------------------------------------------------------------------------------------------------
-- Sala de Troféus: acrescenta os dois troféus novos (os demais ficam como na 056)
---------------------------------------------------------------------------------------------------
alter function public.get_player_career_summary(uuid) rename to get_player_career_summary_pre86;
alter function public.get_player_career_summary_pre86(uuid) set schema private;
create function public.get_player_career_summary(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := private.get_player_career_summary_pre86(p_user); v_p jsonb;
begin
 if not coalesce((v->>'visible')::boolean, false) then return v; end if;
 select coalesce(jsonb_agg(e || jsonb_build_object('trophies', (e->'trophies') || jsonb_build_object(
   'monthly_goalkeeper', c.g, 'season_craque', c.s)) order by o), '[]'::jsonb)
 into v_p
 from jsonb_array_elements(v->'peladas') with ordinality q(e, o)
 cross join lateral (
  select count(*) filter (where a.award_type = 'monthly_goalkeeper')::int g, count(*) filter (where a.award_type = 'season_craque')::int s
  from public.awards a
  where a.membership_id = (e->>'membership_id')::uuid and a.status = 'active'
   and a.award_type in ('monthly_goalkeeper','season_craque')
   and a.season_id = any(array(select private.career_seasons((e->>'pelada_id')::uuid)))) c;
 return v || jsonb_build_object('peladas', v_p, 'trophies', (v->'trophies') || jsonb_build_object(
  'monthly_goalkeeper', (select coalesce(sum((e->'trophies'->>'monthly_goalkeeper')::int), 0) from jsonb_array_elements(v_p) e),
  'season_craque', (select coalesce(sum((e->'trophies'->>'season_craque')::int), 0) from jsonb_array_elements(v_p) e)));
end $$;

alter function public.get_trophy_history(uuid,text,jsonb,integer) rename to get_trophy_history_pre86;
alter function public.get_trophy_history_pre86(uuid,text,jsonb,integer) set schema private;
create function public.get_trophy_history(p_user uuid, p_type text, p_after jsonb default null, p_limit integer default 20)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_level text; v_items jsonb;
begin
 if p_type is null or p_type not in ('monthly_goalkeeper','season_craque') then
  return private.get_trophy_history_pre86(p_user, p_type, p_after, p_limit);
 end if;
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 select career_visibility into v_level from public.profiles where id = p_user;
 if not found or not private.can_view_global(p_user, v_level) then return jsonb_build_object('visible', false); end if;
 -- Poucos por jogador (um por mês/temporada): lista única, sem paginação.
 select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'match_id', null, 'period_month', t.period_month,
   'is_shared', t.is_shared, 'pelada_id', t.pelada_id, 'pelada_name', t.pname, 'season_name', t.sname,
   'at', t.sort_at) order by t.sort_at desc, t.id desc), '[]'::jsonb)
 into v_items
 from (select a.id, a.period_month, a.is_shared, a.pelada_id, p.name pname, s.name sname,
   coalesce(a.period_month::timestamp at time zone 'UTC', a.created_at) sort_at
  from public.pelada_memberships mem join public.awards a on a.membership_id = mem.id
  join public.peladas p on p.id = mem.pelada_id join public.seasons s on s.id = a.season_id
  where mem.user_id = p_user and mem.status in ('active','left') and a.status = 'active' and a.award_type = p_type
   and a.season_id = any(array(select private.career_seasons(mem.pelada_id)))
  order by 7 desc, 1 desc limit 50) t;
 return jsonb_build_object('visible', true, 'items', v_items, 'next', null);
end $$;

---------------------------------------------------------------------------------------------------
-- Permissões
---------------------------------------------------------------------------------------------------
revoke all on function private.v86_official_position(uuid,timestamptz), private.v86_events_immutable(),
 private.paredao_ranking(uuid,date), private.paredao_winners(uuid,date), private.paredao_after_close(uuid,date),
 private.close_month(uuid,date), private.close_month_v77(uuid,date), private.craque_metric(uuid,uuid,text),
 private.craque_tiebreak(uuid,uuid[]), private.craque_top_group(uuid,text,uuid[]), private.craque_candidate_set(uuid),
 private.craque_log(uuid,uuid,text,jsonb,uuid), private.craque_recheck(uuid), private.craque_advance(uuid),
 private.craque_apply_tiebreak(uuid,jsonb), private.craque_sync(uuid), private.craque_season_ready(uuid),
 private.get_player_career_summary_pre86(uuid), private.get_trophy_history_pre86(uuid,text,jsonb,integer)
 from public, anon, authenticated;
revoke all on function public.confirm_monthly_goalkeeper(uuid,date), public.get_monthly_goalkeeper(uuid,date),
 public.open_season_craque_poll(uuid), public.cast_season_craque_vote(uuid,uuid), public.confirm_season_craque(uuid),
 public.get_season_craque(uuid), public.process_season_craque_polls(), public.get_player_career_summary(uuid),
 public.get_trophy_history(uuid,text,jsonb,integer) from public, anon;
grant execute on function public.confirm_monthly_goalkeeper(uuid,date), public.get_monthly_goalkeeper(uuid,date),
 public.open_season_craque_poll(uuid), public.cast_season_craque_vote(uuid,uuid), public.confirm_season_craque(uuid),
 public.get_season_craque(uuid), public.get_player_career_summary(uuid),
 public.get_trophy_history(uuid,text,jsonb,integer) to authenticated;
revoke all on function public.process_season_craque_polls() from authenticated;
grant execute on function public.process_season_craque_polls() to service_role;
