-- Minuto 91 / 062: V8.5 — preparação, prévia, confirmação e composições oficiais versionadas.
--
-- Usa o motor exato da 061. Nada aqui lê OVR, nota, gol ou atributo. Motor V7.7 intocado.
--
-- Modelo (separação de estados, §3 do prompt):
--  preparação (draw_preparations, 1 aberta por pelada)  →  prévia (draw_previews, no máximo 1 ativa)
--  →  composição oficial (team_compositions, versionada)  →  [Fase 2] partida pré-cadastrada / súmula.
--  A composição NÃO é presença: a súmula define quem jogou (REV-58/75, Etapas 2/14).
--
-- Regras implementadas:
--  REV-05/21/24/25/31..35  participantes = integrantes ativos + convidados (nome obrigatório, posição opcional entre
--          as dez oficiais); capitães opcionais, exatamente dois, distintos, um por equipe, fixos e contados.
--  REV-07/32/42  cada rodada sorteada = draw_sample (índice uniforme seguro + decodificação); o índice e a entrada
--          ficam na prévia (auditável); a prévia não expõe semente para jogadores.
--  REV-08/38  nova prévia substitui a ativa de forma atômica; anteriores ficam 'replaced' (auditoria, não opção);
--          a composição oficial anterior continua valendo até uma confirmação válida.
--  REV-23/27/30/36/49/72  qualquer mudança na preparação incrementa a versão e invalida a prévia ativa; a prévia
--          guarda um retrato imutável; a confirmação revalida (versão, elegibilidade, posições) e recusa se mudou.
--  REV-19/20/39/40  concorrência otimista (expected_version) e idempotência por request_id; o resultado de qualquer
--          operação pode ser consultado depois (get_v85_operation) em vez de repetir a gravação.
--  REV-41  toda função revalida o papel no momento da chamada; a preparação fica para outro administrador.
--  REV-45  várias tentativas auditadas; limite temporário de 20 prévias por preparação em 10 minutos.
--  REV-46/47/48  resumo posicional (a×b por grupo, custo, ótimo inevitável) — sem força nem OVR; trilha completa só
--          em get_composition_history (staff).
--  REV-09..18/26/58/74  operações manuais atômicas sobre a composição: incluir (assistida: equipe menor → menor
--          quantidade no grupo → sorteio seguro), remover, substituir, transferir, trocar, capitães; em lote, tudo ou
--          nada; sem redistribuição automática; sem alerta de equilíbrio (Etapa 32 A); reversão = operação inversa.
--  REV-51/36A  histórico preservado por versão; jogadores leem só a versão vigente.
--  REV-71  mesma identidade por caminhos diferentes: mantém uma participação e informa (notice).
--  REV-73/LAC-04  convidado → cadastrado: troca explícita de identidade na preparação, com rastro, sem fundir históricos.
--  REV-79  descarte explícito; registros técnicos e composições anteriores preservados.
--  REV-80/Etapas 17/18  montagem manual e cópia de composição anterior viram prévia 'manual'/'copy' (nunca rotuladas
--          como sorteio otimizado), revalidadas e confirmadas pelo mesmo fluxo.
--  LAC-01  modo 'single' = UMA composição-base para N rodadas; 'independent' = uma composição por rodada. Ajustes na
--          partida (Fase 2) são locais e nunca alteram a base nem outras rodadas (Etapa 7).
--
-- Sorteio por OVR (039/040): public.create_team_draw passa a recusar novos sorteios (DRAW_ALGORITHM_SUPERSEDED).
-- Sorteios, escalações e leituras históricas continuam funcionando (get_team_draws, get_lineups, use_lineup_in_match).

---------------------------------------------------------------------------------------------------
-- Idempotência
---------------------------------------------------------------------------------------------------
create table private.v85_operations (
 request_id uuid primary key,
 pelada_id uuid not null,
 actor_user_id uuid,
 kind text not null,
 result jsonb not null,
 created_at timestamptz not null default now()
);

create function private.v85_replay(p_request uuid, p_kind text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v private.v85_operations;
begin
 if p_request is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
 select * into v from private.v85_operations where request_id=p_request;
 if not found then return null; end if;
 if v.kind <> p_kind or v.actor_user_id is distinct from auth.uid() then raise exception 'REQUEST_ID_CONFLICT'; end if;
 return v.result || jsonb_build_object('replayed', true);
end $$;

create function private.v85_done(p_request uuid, p_pelada uuid, p_kind text, p_result jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
 insert into private.v85_operations(request_id,pelada_id,actor_user_id,kind,result)
 values(p_request,p_pelada,auth.uid(),p_kind,p_result);
 return p_result;
end $$;

-- REV-20/40: depois de perder a conexão, o app consulta o resultado real em vez de repetir.
create function public.get_v85_operation(p_request uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v private.v85_operations;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v from private.v85_operations where request_id=p_request and actor_user_id=auth.uid();
 if not found then return jsonb_build_object('found', false); end if;
 return jsonb_build_object('found', true, 'kind', v.kind, 'result', v.result, 'created_at', v.created_at);
end $$;

---------------------------------------------------------------------------------------------------
-- Tabelas
---------------------------------------------------------------------------------------------------
create table public.draw_preparations (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 mode text not null default 'single' check (mode in ('single','independent')),
 rounds_total integer not null default 1 check (rounds_total between 1 and 12),
 round_dates timestamptz[] check (round_dates is null or cardinality(round_dates) between 1 and 12),
 captains_enabled boolean not null default false,
 status text not null default 'open' check (status in ('open','confirmed','discarded')),
 version integer not null default 1,
 source_composition_id uuid,
 created_by uuid references public.profiles(id) on delete set null,
 updated_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 closed_at timestamptz
);
create unique index draw_preparations_one_open on public.draw_preparations(pelada_id) where status='open';

create table public.draw_prep_participants (
 prep_id uuid not null references public.draw_preparations(id) on delete cascade,
 pid uuid not null, -- identidade: membership_id ou guest_id
 membership_id uuid references public.pelada_memberships(id),
 guest_id uuid references public.guests(id),
 position_code text check (position_code is null or position_code in ('GOL','ZAG','LD','LE','VOL','MEI','CA','PD','PE','ATA')),
 captain_team text check (captain_team in ('A','B')),
 added_at timestamptz not null default now(),
 primary key (prep_id, pid),
 check ((membership_id is null) <> (guest_id is null)),
 check (pid = coalesce(membership_id, guest_id))
);
create unique index draw_prep_one_captain_per_team on public.draw_prep_participants(prep_id, captain_team) where captain_team is not null;

create table public.draw_previews (
 id uuid primary key default gen_random_uuid(),
 prep_id uuid not null references public.draw_preparations(id) on delete cascade,
 prep_version integer not null,
 source text not null check (source in ('draw','manual','copy')),
 status text not null default 'active' check (status in ('active','replaced','invalidated','confirmed','discarded')),
 algorithm_version integer not null default 3,
 snapshot jsonb not null,  -- [{pid, membership_id, guest_id, position_key, group, captain_team}] (sem nomes)
 rounds jsonb not null,    -- [{round, cost, count, rank, sizes}]
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now()
);
create unique index draw_previews_one_active on public.draw_previews(prep_id) where status='active';

create table public.draw_preview_players (
 preview_id uuid not null references public.draw_previews(id) on delete cascade,
 round_number integer not null check (round_number between 1 and 12),
 pid uuid not null,
 team text not null check (team in ('A','B')),
 primary key (preview_id, round_number, pid)
);

create table public.team_compositions (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 prep_id uuid references public.draw_preparations(id),
 preview_id uuid references public.draw_previews(id),
 source text not null check (source in ('draw','manual','copy')),
 mode text not null check (mode in ('single','independent')),
 round_number integer not null default 1,
 rounds_total integer not null default 1,
 round_date timestamptz,
 label text not null check (length(btrim(label)) between 1 and 60),
 team_a_name text not null default 'Time A' check (length(btrim(team_a_name)) between 1 and 40),
 team_b_name text not null default 'Time B' check (length(btrim(team_b_name)) between 1 and 40),
 captains_enabled boolean not null default false,
 status text not null default 'active' check (status in ('active','replaced','cancelled')),
 version integer not null default 1,
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index team_compositions_by_pelada on public.team_compositions(pelada_id, status, created_at desc);

create table public.team_composition_members (
 composition_id uuid not null references public.team_compositions(id) on delete cascade,
 pid uuid not null,
 membership_id uuid references public.pelada_memberships(id),
 guest_id uuid references public.guests(id),
 position_code text,
 team text not null check (team in ('A','B')),
 is_captain boolean not null default false,
 version_from integer not null,
 version_to integer, -- null = vigente
 check ((membership_id is null) <> (guest_id is null)),
 check (version_to is null or version_to > version_from)
);
create unique index composition_members_current on public.team_composition_members(composition_id, pid) where version_to is null;
create index composition_members_by_comp on public.team_composition_members(composition_id, version_from);

create table private.team_composition_ops (
 id uuid primary key default gen_random_uuid(),
 composition_id uuid not null references public.team_compositions(id) on delete cascade,
 version integer not null,
 op_type text not null,
 payload jsonb not null,
 actor_user_id uuid,
 request_id uuid,
 created_at timestamptz not null default now()
);
create index composition_ops_by_comp on private.team_composition_ops(composition_id, version);

-- REV-73: convidados com posição opcional e vínculo de substituição por cadastro (sem fundir históricos).
alter table public.guests add column position_code text
 check (position_code is null or position_code in ('GOL','ZAG','LD','LE','VOL','MEI','CA','PD','PE','ATA'));

alter table public.draw_preparations enable row level security;
alter table public.draw_prep_participants enable row level security;
alter table public.draw_previews enable row level security;
alter table public.draw_preview_players enable row level security;
alter table public.team_compositions enable row level security;
alter table public.team_composition_members enable row level security;
revoke all on public.draw_preparations, public.draw_prep_participants, public.draw_previews, public.draw_preview_players,
 public.team_compositions, public.team_composition_members from anon, authenticated;
revoke all on private.v85_operations, private.team_composition_ops from public, anon, authenticated;

---------------------------------------------------------------------------------------------------
-- Auxiliares
---------------------------------------------------------------------------------------------------

-- Posição considerada: integrante = posição atual (código ou setor legado); convidado = a da preparação.
create function private.v85_position(p_membership uuid, p_guest_pos text) returns text
language sql stable security definer set search_path = '' as $$
 select case when p_membership is null then p_guest_pos
  else (select coalesce(m.position_code, m.preferred_position) from public.pelada_memberships m where m.id=p_membership) end;
$$;

create function private.v85_name(p_membership uuid, p_guest uuid) returns text
language sql stable security definer set search_path = '' as $$
 select coalesce((select player_name from public.pelada_memberships where id=p_membership),
  (select display_name from public.guests where id=p_guest), 'Jogador');
$$;

create function private.v85_avatar(p_membership uuid) returns text
language sql stable security definer set search_path = '' as $$
 -- LAC-05: foto só de integrante com conta, sem bloqueio; convidado/sem foto → avatar neutro no app (REV-69).
 select case when m.user_id is not null and not private.blocked_either_way(m.user_id)
  then (select p.avatar_path from public.profiles p where p.id=m.user_id) end
 from public.pelada_memberships m where m.id=p_membership;
$$;

-- Elegível: integrante ativo da pelada, ou convidado da pelada.
create function private.v85_eligible(p_pelada uuid, p_membership uuid, p_guest uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select case when p_membership is not null then exists(select 1 from public.pelada_memberships
   where id=p_membership and pelada_id=p_pelada and status='active')
  else exists(select 1 from public.guests where id=p_guest and pelada_id=p_pelada) end;
$$;

create function private.v85_prep_for_update(p_prep uuid, p_expected integer) returns public.draw_preparations
language plpgsql security definer set search_path = '' as $$
declare v public.draw_preparations;
begin
 select * into v from public.draw_preparations where id=p_prep;
 if not found then raise exception 'PREP_NOT_FOUND'; end if;
 perform private.require_draw_staff(v.pelada_id);
 select * into v from public.draw_preparations where id=p_prep for update;
 if v.status <> 'open' then raise exception 'PREP_CLOSED'; end if;
 if p_expected is null or p_expected <> v.version then raise exception 'VERSION_CONFLICT'; end if;
 return v;
end $$;

-- Toda mudança relevante: nova versão e prévia ativa invalidada (REV-36).
create function private.v85_prep_touch(p_prep uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare v integer;
begin
 update public.draw_previews set status='invalidated' where prep_id=p_prep and status='active';
 update public.draw_preparations set version=version+1, updated_at=now(), updated_by=auth.uid()
 where id=p_prep returning version into v;
 return v;
end $$;

-- Motivos que impedem confirmar/usar (REV-23/27/72), lidos ao vivo.
create function private.v85_prep_problems(p_prep uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_agg(jsonb_build_object('pid', x.pid, 'problem', x.problem)), '[]'::jsonb) from (
  select p.pid, 'INELIGIBLE' problem from public.draw_prep_participants p join public.draw_preparations d on d.id=p.prep_id
  where p.prep_id=p_prep and not private.v85_eligible(d.pelada_id, p.membership_id, p.guest_id)) x;
$$;

create function private.v85_summary(p_group text[], p_team text[]) returns jsonb
language sql immutable set search_path = '' as $$
 select jsonb_build_object('cost', private.draw_cost(p_group, p_team),
  'size_a', (select count(*) from unnest(p_team) t where t='A'), 'size_b', (select count(*) from unnest(p_team) t where t='B'),
  'by_group', (select coalesce(jsonb_agg(jsonb_build_object('group', g, 'a', a, 'b', b) order by private.draw_group_order(g)), '[]'::jsonb)
   from (select g, count(*) filter (where t='A') a, count(*) filter (where t='B') b from unnest(p_group, p_team) x(g,t) group by g) q));
$$;

---------------------------------------------------------------------------------------------------
-- Leitura da preparação (staff)
---------------------------------------------------------------------------------------------------
create function private.v85_preview_json(p_preview uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('id', v.id, 'prep_version', v.prep_version, 'source', v.source, 'status', v.status,
  'created_at', v.created_at,
  'stale', v.prep_version <> d.version or exists(
    select 1 from jsonb_array_elements(v.snapshot) s
    where (s->>'membership_id') is not null
      and (private.v85_position((s->>'membership_id')::uuid, null) is distinct from s->>'position'
        or not private.v85_eligible(d.pelada_id, (s->>'membership_id')::uuid, null))),
  'rounds', (select jsonb_agg(jsonb_build_object('round', r.round_number,
     'optimal', case when v.source='draw' then (select jsonb_build_object('cost', (x->>'cost')::int, 'count', x->>'count')
        from jsonb_array_elements(v.rounds) x where (x->>'round')::int = r.round_number) end,
     'summary', private.v85_summary(
        array(select s->>'group' from jsonb_array_elements(v.snapshot) s join public.draw_preview_players q
              on q.pid=(s->>'pid')::uuid and q.preview_id=v.id and q.round_number=r.round_number order by s->>'pid'),
        array(select q.team from jsonb_array_elements(v.snapshot) s join public.draw_preview_players q
              on q.pid=(s->>'pid')::uuid and q.preview_id=v.id and q.round_number=r.round_number order by s->>'pid')),
     'players', (select jsonb_agg(jsonb_build_object('pid', q.pid, 'team', q.team,
        'name', private.v85_name((s->>'membership_id')::uuid, (s->>'guest_id')::uuid),
        'guest', (s->>'guest_id') is not null, 'position', s->>'position', 'group', s->>'group',
        'captain', (s->>'captain_team') is not null) order by q.team, private.draw_group_order(s->>'group'),
        private.v85_name((s->>'membership_id')::uuid, (s->>'guest_id')::uuid))
       from public.draw_preview_players q join jsonb_array_elements(v.snapshot) s on (s->>'pid')::uuid=q.pid
       where q.preview_id=v.id and q.round_number=r.round_number)) order by r.round_number)
   from (select distinct round_number from public.draw_preview_players where preview_id=v.id) r))
 from public.draw_previews v join public.draw_preparations d on d.id=v.prep_id where v.id=p_preview;
$$;

create function private.v85_prep_json(p_prep uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('id', d.id, 'pelada_id', d.pelada_id, 'mode', d.mode, 'rounds_total', d.rounds_total,
  'round_dates', to_jsonb(d.round_dates), 'captains_enabled', d.captains_enabled, 'status', d.status, 'version', d.version,
  'updated_at', d.updated_at, 'source_composition_id', d.source_composition_id,
  'problems', private.v85_prep_problems(d.id),
  'participants', coalesce((select jsonb_agg(jsonb_build_object('pid', p.pid, 'membership_id', p.membership_id,
     'guest_id', p.guest_id, 'guest', p.guest_id is not null, 'name', private.v85_name(p.membership_id, p.guest_id),
     'position', private.v85_position(p.membership_id, p.position_code),
     'group', private.draw_group_key(private.v85_position(p.membership_id, p.position_code)),
     'captain_team', p.captain_team, 'avatar_path', private.v85_avatar(p.membership_id),
     'eligible', private.v85_eligible(d.pelada_id, p.membership_id, p.guest_id))
    order by private.draw_group_order(private.draw_group_key(private.v85_position(p.membership_id, p.position_code))),
     private.v85_name(p.membership_id, p.guest_id), p.pid)
   from public.draw_prep_participants p where p.prep_id=d.id), '[]'::jsonb),
  'preview', (select private.v85_preview_json(v.id) from public.draw_previews v where v.prep_id=d.id and v.status='active'))
 from public.draw_preparations d where d.id=p_prep;
$$;

create function public.get_draw_preparation(p_pelada uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.is_active_staff(p_pelada) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 return (select private.v85_prep_json(id) from public.draw_preparations where pelada_id=p_pelada and status='open');
end $$;

---------------------------------------------------------------------------------------------------
-- Edição da preparação
---------------------------------------------------------------------------------------------------

-- Abre (ou devolve a aberta: REV-37 recuperação).
create function public.open_draw_preparation(p_pelada uuid, p_mode text default 'single', p_rounds integer default 1) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
 perform private.require_draw_staff(p_pelada);
 select id into v from public.draw_preparations where pelada_id=p_pelada and status='open';
 if found then return private.v85_prep_json(v); end if;
 if p_mode is null or p_mode not in ('single','independent') then raise exception 'DRAW_INVALID_MODE'; end if;
 if p_rounds is null or p_rounds not between 1 and 12 then raise exception 'DRAW_INVALID_ROUNDS'; end if;
 insert into public.draw_preparations(pelada_id,mode,rounds_total,created_by,updated_by)
 values(p_pelada,p_mode,p_rounds,auth.uid(),auth.uid()) returning id into v;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'draw_prep_opened',jsonb_build_object('prep_id',v));
 return private.v85_prep_json(v);
end $$;

-- Configuração: modo, rodadas, datas das rodadas (Etapa 10, não consecutivas) e capitães ligados/desligados.
create function public.set_draw_preparation_options(p_prep uuid, p_expected integer, p_mode text, p_rounds integer,
 p_round_dates timestamptz[] default null, p_captains boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.draw_preparations;
begin
 v := private.v85_prep_for_update(p_prep, p_expected);
 if p_mode is null or p_mode not in ('single','independent') then raise exception 'DRAW_INVALID_MODE'; end if;
 if p_rounds is null or p_rounds not between 1 and 12 then raise exception 'DRAW_INVALID_ROUNDS'; end if;
 if p_round_dates is not null and (cardinality(p_round_dates) <> p_rounds
   or (select count(distinct x) from unnest(p_round_dates) x) <> p_rounds or array_position(p_round_dates, null) is not null) then
  raise exception 'DRAW_INVALID_ROUND_DATES'; end if;
 update public.draw_preparations set mode=p_mode, rounds_total=p_rounds,
  round_dates=(select array_agg(x order by x) from unnest(p_round_dates) x), captains_enabled=coalesce(p_captains,false)
 where id=p_prep;
 if not coalesce(p_captains,false) then update public.draw_prep_participants set captain_team=null where prep_id=p_prep; end if;
 perform private.v85_prep_touch(p_prep);
 return private.v85_prep_json(p_prep);
end $$;

-- Define a lista de integrantes (Etapa 9: "Último sorteio/Todos/Limpar" resolvem no app para esta lista).
-- REV-71: ids repetidos são reduzidos a um e informados. Convidados existentes na preparação são mantidos.
create function public.set_draw_members(p_prep uuid, p_expected integer, p_members uuid[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.draw_preparations; v_dups integer; v_list uuid[];
begin
 v := private.v85_prep_for_update(p_prep, p_expected);
 v_list := array(select distinct x from unnest(coalesce(p_members,'{}')) x where x is not null);
 v_dups := coalesce(cardinality(p_members),0) - cardinality(v_list);
 if (select count(*) from public.pelada_memberships where id=any(v_list) and pelada_id=v.pelada_id and status='active')
   <> cardinality(v_list) then raise exception 'DRAW_INVALID_PLAYER'; end if;
 if cardinality(v_list) + (select count(*) from public.draw_prep_participants where prep_id=p_prep and guest_id is not null) > 100 then
  raise exception 'DRAW_TOO_MANY_PLAYERS'; end if;
 delete from public.draw_prep_participants where prep_id=p_prep and membership_id is not null and not (membership_id = any(v_list));
 insert into public.draw_prep_participants(prep_id,pid,membership_id)
 select p_prep, x, x from unnest(v_list) x on conflict (prep_id,pid) do nothing;
 perform private.v85_prep_touch(p_prep);
 return private.v85_prep_json(p_prep) || jsonb_build_object('notice', case when v_dups > 0 then 'DUPLICATES_MERGED' end);
end $$;

-- REV-24/30: convidado novo (nome obrigatório, posição opcional) ou existente da pelada.
create function public.add_draw_guest(p_prep uuid, p_expected integer, p_guest uuid, p_name text, p_position text,
 p_adult_declared boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.draw_preparations; v_g uuid := p_guest; v_pos text := nullif(btrim(coalesce(p_position,'')),'');
begin
 v := private.v85_prep_for_update(p_prep, p_expected);
 if v_pos is not null and not (v_pos = any(private.position_codes())) then raise exception 'INVALID_POSITION'; end if;
 if (select count(*) from public.draw_prep_participants where prep_id=p_prep) >= 100 then raise exception 'DRAW_TOO_MANY_PLAYERS'; end if;
 if v_g is null then
  if length(btrim(coalesce(p_name,''))) not between 1 and 80 then raise exception 'GUEST_NAME_REQUIRED'; end if;
  if not coalesce(p_adult_declared,false) then raise exception 'GUEST_ADULT_DECLARATION_REQUIRED'; end if;
  insert into public.guests(pelada_id,display_name,adult_declared_at,created_by,position_code)
  values(v.pelada_id,btrim(p_name),now(),auth.uid(),v_pos) returning id into v_g;
 elsif not exists(select 1 from public.guests where id=v_g and pelada_id=v.pelada_id) then raise exception 'GUEST_NOT_FOUND';
 end if;
 if exists(select 1 from public.draw_prep_participants where prep_id=p_prep and pid=v_g) then
  update public.draw_prep_participants set position_code=v_pos where prep_id=p_prep and pid=v_g; -- REV-30
 else
  insert into public.draw_prep_participants(prep_id,pid,guest_id,position_code) values(p_prep,v_g,v_g,v_pos);
 end if;
 perform private.v85_prep_touch(p_prep);
 return private.v85_prep_json(p_prep) || jsonb_build_object('guest_id', v_g);
end $$;

create function public.remove_draw_participant(p_prep uuid, p_expected integer, p_pid uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.draw_preparations;
begin
 v := private.v85_prep_for_update(p_prep, p_expected);
 delete from public.draw_prep_participants where prep_id=p_prep and pid=p_pid;
 if not found then raise exception 'DRAW_INVALID_PLAYER'; end if;
 perform private.v85_prep_touch(p_prep);
 return private.v85_prep_json(p_prep);
end $$;

-- REV-21/25: capitães (integrante ou convidado), um por equipe, distintos. null limpa a equipe.
create function public.set_draw_captains(p_prep uuid, p_expected integer, p_captain_a uuid, p_captain_b uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.draw_preparations;
begin
 v := private.v85_prep_for_update(p_prep, p_expected);
 if not v.captains_enabled then raise exception 'CAPTAINS_DISABLED'; end if;
 if p_captain_a is not null and p_captain_a = p_captain_b then raise exception 'CAPTAINS_MUST_DIFFER'; end if;
 if (p_captain_a is not null and not exists(select 1 from public.draw_prep_participants where prep_id=p_prep and pid=p_captain_a))
  or (p_captain_b is not null and not exists(select 1 from public.draw_prep_participants where prep_id=p_prep and pid=p_captain_b)) then
  raise exception 'DRAW_INVALID_PLAYER'; end if;
 update public.draw_prep_participants set captain_team=null where prep_id=p_prep;
 update public.draw_prep_participants set captain_team='A' where prep_id=p_prep and pid=p_captain_a;
 update public.draw_prep_participants set captain_team='B' where prep_id=p_prep and pid=p_captain_b;
 perform private.v85_prep_touch(p_prep);
 return private.v85_prep_json(p_prep);
end $$;

-- REV-73/LAC-04: convidado passa a ser o integrante cadastrado nesta preparação (troca explícita, com rastro).
-- Não altera partidas anteriores nem funde estatísticas do convidado.
create function public.replace_draw_guest_with_member(p_prep uuid, p_expected integer, p_guest uuid, p_membership uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.draw_preparations; v_cap text;
begin
 v := private.v85_prep_for_update(p_prep, p_expected);
 select captain_team into v_cap from public.draw_prep_participants where prep_id=p_prep and guest_id=p_guest;
 if not found then raise exception 'GUEST_NOT_FOUND'; end if;
 if not private.v85_eligible(v.pelada_id, p_membership, null) then raise exception 'DRAW_INVALID_PLAYER'; end if;
 delete from public.draw_prep_participants where prep_id=p_prep and guest_id=p_guest;
 delete from public.draw_prep_participants where prep_id=p_prep and membership_id=p_membership; -- REV-71
 insert into public.draw_prep_participants(prep_id,pid,membership_id,captain_team) values(p_prep,p_membership,p_membership,v_cap);
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
 values(v.pelada_id,auth.uid(),p_membership,'draw_guest_replaced_by_member',jsonb_build_object('prep_id',p_prep,'guest_id',p_guest));
 perform private.v85_prep_touch(p_prep);
 return private.v85_prep_json(p_prep);
end $$;

-- REV-79: descarte explícito.
create function public.discard_draw_preparation(p_prep uuid, p_expected integer, p_confirm boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.draw_preparations;
begin
 if not coalesce(p_confirm,false) then raise exception 'CONFIRMATION_REQUIRED'; end if;
 v := private.v85_prep_for_update(p_prep, p_expected);
 update public.draw_previews set status='discarded' where prep_id=p_prep and status='active';
 update public.draw_preparations set status='discarded', closed_at=now(), updated_by=auth.uid(), version=version+1 where id=p_prep;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v.pelada_id,auth.uid(),'draw_prep_discarded',jsonb_build_object('prep_id',p_prep));
end $$;

---------------------------------------------------------------------------------------------------
-- Prévia
---------------------------------------------------------------------------------------------------

-- Retrato imutável dos participantes (REV-72) em ordem estável (grupo, pid).
create function private.v85_snapshot(p_prep uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_agg(x order by private.draw_group_order(x->>'group'), x->>'pid'), '[]'::jsonb) from (
  select jsonb_build_object('pid', p.pid, 'membership_id', p.membership_id, 'guest_id', p.guest_id,
   'position', private.v85_position(p.membership_id, p.position_code),
   'group', private.draw_group_key(private.v85_position(p.membership_id, p.position_code)),
   'captain_team', case when d.captains_enabled then p.captain_team end) x
  from public.draw_prep_participants p join public.draw_preparations d on d.id=p.prep_id where p.prep_id=p_prep) q;
$$;

create function private.v85_check_prep_ready(p_prep uuid) returns public.draw_preparations
language plpgsql security definer set search_path = '' as $$
declare v public.draw_preparations; n integer;
begin
 select * into v from public.draw_preparations where id=p_prep;
 select count(*) into n from public.draw_prep_participants where prep_id=p_prep;
 if n < 2 then raise exception 'DRAW_TOO_FEW_PLAYERS'; end if; -- REV-35
 if n > 100 then raise exception 'DRAW_TOO_MANY_PLAYERS'; end if;
 if jsonb_array_length(private.v85_prep_problems(p_prep)) > 0 then raise exception 'DRAW_PARTICIPANT_INELIGIBLE'; end if; -- REV-27
 if v.captains_enabled and (select count(*) from public.draw_prep_participants where prep_id=p_prep and captain_team is not null) <> 2 then
  raise exception 'CAPTAINS_REQUIRED'; end if; -- REV-21: exatamente dois quando ativados
 return v;
end $$;

-- Sorteio exato: cria a nova prévia ativa (substitui a anterior, REV-38). Limite: 20 em 10 min (REV-45).
create function public.generate_draw_preview(p_prep uuid, p_expected integer, p_request uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.draw_preparations; v_snap jsonb; v_id uuid; r integer; v_res jsonb; v_rounds jsonb := '[]'::jsonb;
 v_groups text[]; v_fixed text[]; v_pids uuid[]; v_replay jsonb; v_out jsonb;
begin
 v_replay := private.v85_replay(p_request, 'draw_preview'); if v_replay is not null then return v_replay; end if;
 v := private.v85_prep_for_update(p_prep, p_expected);
 v := private.v85_check_prep_ready(p_prep);
 if (select count(*) from public.draw_previews where prep_id=p_prep and source='draw' and created_at > now() - interval '10 minutes') >= 20 then
  raise exception 'DRAW_RATE_LIMITED'; end if;
 v_snap := private.v85_snapshot(p_prep);
 v_groups := array(select s->>'group' from jsonb_array_elements(v_snap) with ordinality s(s,i) order by i);
 v_fixed := array(select s->>'captain_team' from jsonb_array_elements(v_snap) with ordinality s(s,i) order by i);
 v_pids := array(select (s->>'pid')::uuid from jsonb_array_elements(v_snap) with ordinality s(s,i) order by i);
 update public.draw_previews set status='replaced' where prep_id=p_prep and status='active';
 insert into public.draw_previews(prep_id,prep_version,source,snapshot,rounds,created_by)
 values(p_prep,v.version,'draw',v_snap,'[]',auth.uid()) returning id into v_id;
 for r in 1..case when v.mode='single' then 1 else v.rounds_total end loop
  v_res := private.draw_sample(v_groups, v_fixed);
  insert into public.draw_preview_players(preview_id,round_number,pid,team)
  select v_id, r, v_pids[i], v_res->'teams'->>(i-1) from generate_subscripts(v_pids,1) i;
  v_rounds := v_rounds || jsonb_build_object('round', r, 'cost', v_res->'cost', 'count', v_res->'count',
   'rank', v_res->'rank', 'sizes', v_res->'sizes');
 end loop;
 update public.draw_previews set rounds=v_rounds where id=v_id;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v.pelada_id,auth.uid(),'draw_preview_generated',jsonb_build_object('prep_id',p_prep,'preview_id',v_id,
  'algorithm_version',3,'rounds',v_rounds,'players',cardinality(v_pids)));
 v_out := private.v85_prep_json(p_prep);
 return private.v85_done(p_request, v.pelada_id, 'draw_preview', v_out);
end $$;

-- Montagem manual (Etapa 17) ou ajuste interativo da prévia (Etapa 12): times definidos pelo administrador.
-- p_assign: [{"round":1,"pid":uuid,"team":"A"}] cobrindo todos os participantes em cada rodada.
create function public.save_manual_preview(p_prep uuid, p_expected integer, p_assign jsonb, p_request uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.draw_preparations; v_snap jsonb; v_id uuid; v_replay jsonb; n integer; r integer; v_out jsonb; v_src text;
begin
 v_replay := private.v85_replay(p_request, 'manual_preview'); if v_replay is not null then return v_replay; end if;
 v := private.v85_prep_for_update(p_prep, p_expected);
 v := private.v85_check_prep_ready(p_prep);
 v_snap := private.v85_snapshot(p_prep); n := jsonb_array_length(v_snap);
 if jsonb_typeof(p_assign) <> 'array' then raise exception 'LINEUP_INVALID'; end if;
 for r in 1..case when v.mode='single' then 1 else v.rounds_total end loop
  if (select count(distinct (a->>'pid')) from jsonb_array_elements(p_assign) a where (a->>'round')::int=r) <> n
   or (select count(*) from jsonb_array_elements(p_assign) a where (a->>'round')::int=r) <> n
   or exists(select 1 from jsonb_array_elements(p_assign) a where (a->>'round')::int=r and (a->>'team') not in ('A','B'))
   or exists(select 1 from jsonb_array_elements(v_snap) s where not exists(select 1 from jsonb_array_elements(p_assign) a
       where (a->>'round')::int=r and a->>'pid'=s->>'pid'))
   or exists(select 1 from jsonb_array_elements(v_snap) s join jsonb_array_elements(p_assign) a
       on a->>'pid'=s->>'pid' and (a->>'round')::int=r where (s->>'captain_team') is not null and s->>'captain_team' <> a->>'team')
   or not exists(select 1 from jsonb_array_elements(p_assign) a where (a->>'round')::int=r and a->>'team'='A')
   or not exists(select 1 from jsonb_array_elements(p_assign) a where (a->>'round')::int=r and a->>'team'='B') then
   raise exception 'LINEUP_INVALID'; end if;
 end loop;
 if exists(select 1 from jsonb_array_elements(p_assign) a where (a->>'round')::int not between 1 and
   case when v.mode='single' then 1 else v.rounds_total end) then raise exception 'LINEUP_INVALID'; end if;
 v_src := case when v.source_composition_id is not null then 'copy' else 'manual' end;
 update public.draw_previews set status='replaced' where prep_id=p_prep and status='active';
 insert into public.draw_previews(prep_id,prep_version,source,snapshot,rounds,created_by)
 values(p_prep,v.version,v_src,v_snap,'[]',auth.uid()) returning id into v_id;
 insert into public.draw_preview_players(preview_id,round_number,pid,team)
 select v_id, (a->>'round')::int, (a->>'pid')::uuid, a->>'team' from jsonb_array_elements(p_assign) a;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v.pelada_id,auth.uid(),'draw_preview_manual',jsonb_build_object('prep_id',p_prep,'preview_id',v_id,'source',v_src));
 v_out := private.v85_prep_json(p_prep);
 return private.v85_done(p_request, v.pelada_id, 'manual_preview', v_out);
end $$;

---------------------------------------------------------------------------------------------------
-- Confirmação → composição oficial
---------------------------------------------------------------------------------------------------
create function public.confirm_draw_preview(p_preview uuid, p_expected integer, p_team_a_name text, p_team_b_name text,
 p_request uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_p public.draw_previews; v public.draw_preparations; v_replay jsonb; r integer; v_c uuid; v_ids uuid[] := '{}';
 v_a text := coalesce(nullif(btrim(p_team_a_name),''),'Time A'); v_b text := coalesce(nullif(btrim(p_team_b_name),''),'Time B');
 v_out jsonb; v_rounds integer;
begin
 v_replay := private.v85_replay(p_request, 'draw_confirm'); if v_replay is not null then return v_replay; end if;
 select * into v_p from public.draw_previews where id=p_preview;
 if not found then raise exception 'PREVIEW_NOT_FOUND'; end if;
 v := private.v85_prep_for_update(v_p.prep_id, p_expected);
 select * into v_p from public.draw_previews where id=p_preview for update;
 if v_p.status <> 'active' or v_p.prep_version <> v.version then raise exception 'DRAW_STALE'; end if; -- REV-36/49/72
 if (private.v85_preview_json(p_preview)->>'stale')::boolean then raise exception 'DRAW_STALE'; end if; -- REV-23
 perform private.v85_check_prep_ready(v.id);
 if length(v_a) > 40 or length(v_b) > 40 then raise exception 'INVALID_TEAM_NAME'; end if;
 v_rounds := case when v.mode='single' then 1 else v.rounds_total end;
 for r in 1..v_rounds loop
  insert into public.team_compositions(pelada_id,prep_id,preview_id,source,mode,round_number,rounds_total,round_date,label,
   team_a_name,team_b_name,captains_enabled,created_by)
  values(v.pelada_id,v.id,p_preview,v_p.source,v.mode,r,case when v.mode='single' then v.rounds_total else 1 end,
   case when v.mode='independent' then v.round_dates[r] end,
   case when v.mode='single' then case when v.rounds_total=1 then 'Rodada única' else 'Base · '||v.rounds_total||' rodadas' end
        else 'Rodada '||r||' de '||v.rounds_total end,
   v_a,v_b,v.captains_enabled,auth.uid()) returning id into v_c;
  insert into public.team_composition_members(composition_id,pid,membership_id,guest_id,position_code,team,is_captain,version_from)
  select v_c, q.pid, (s->>'membership_id')::uuid, (s->>'guest_id')::uuid, s->>'position', q.team,
   (s->>'captain_team') is not null, 1
  from public.draw_preview_players q join jsonb_array_elements(v_p.snapshot) s on (s->>'pid')::uuid=q.pid
  where q.preview_id=p_preview and q.round_number=r;
  insert into private.team_composition_ops(composition_id,version,op_type,payload,actor_user_id,request_id)
  values(v_c,1,'created',jsonb_build_object('source',v_p.source,'preview_id',p_preview,
   'optimal',(select x from jsonb_array_elements(v_p.rounds) x where (x->>'round')::int=r)),auth.uid(),p_request);
  v_ids := v_ids || v_c;
 end loop;
 update public.draw_previews set status='confirmed' where id=p_preview;
 update public.draw_preparations set status='confirmed', closed_at=now(), updated_by=auth.uid(), version=version+1 where id=v.id;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v.pelada_id,auth.uid(),'draw_confirmed',jsonb_build_object('prep_id',v.id,'preview_id',p_preview,'compositions',to_jsonb(v_ids)));
 -- REV-55: sucesso só aqui, depois da gravação; o app oferece as duas imagens desta versão.
 v_out := jsonb_build_object('compositions', (select jsonb_agg(private.v85_composition_json(x, true)) from unnest(v_ids) x));
 return private.v85_done(p_request, v.pelada_id, 'draw_confirm', v_out);
end $$;

---------------------------------------------------------------------------------------------------
-- Composição oficial: leitura
---------------------------------------------------------------------------------------------------
create function private.v85_composition_json(p_comp uuid, p_staff boolean) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('id', c.id, 'pelada_id', c.pelada_id, 'source', c.source, 'mode', c.mode,
  'round_number', c.round_number, 'rounds_total', c.rounds_total, 'round_date', c.round_date, 'label', c.label,
  'team_a_name', c.team_a_name, 'team_b_name', c.team_b_name, 'captains_enabled', c.captains_enabled,
  'status', c.status, 'version', c.version, 'updated_at', c.updated_at,
  'members', coalesce((select jsonb_agg(jsonb_build_object('pid', m.pid, 'membership_id', m.membership_id,
     'guest', m.guest_id is not null, 'name', private.v85_name(m.membership_id, m.guest_id),
     'position', m.position_code, 'group', private.draw_group_key(m.position_code), 'team', m.team,
     'captain', m.is_captain, 'avatar_path', private.v85_avatar(m.membership_id),
     'eligible', private.v85_eligible(c.pelada_id, m.membership_id, m.guest_id))
    order by m.team, private.draw_group_order(private.draw_group_key(m.position_code)), private.v85_name(m.membership_id, m.guest_id), m.pid)
   from public.team_composition_members m where m.composition_id=c.id and m.version_to is null), '[]'::jsonb),
  'summary', case when p_staff then private.v85_summary(
    array(select private.draw_group_key(m.position_code) from public.team_composition_members m where m.composition_id=c.id and m.version_to is null order by m.pid),
    array(select m.team from public.team_composition_members m where m.composition_id=c.id and m.version_to is null order by m.pid)) end)
 from public.team_compositions c where c.id=p_comp;
$$;

-- Integrantes: só composições ativas e só a versão vigente (Etapa 36 A).
create function public.get_team_compositions(p_pelada uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_staff boolean;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.is_active_member(p_pelada) then raise exception 'PELADA_NOT_FOUND'; end if;
 v_staff := private.is_active_staff(p_pelada);
 return coalesce((select jsonb_agg(private.v85_composition_json(c.id, v_staff) order by c.created_at desc, c.round_number)
  from public.team_compositions c where c.pelada_id=p_pelada and c.status='active'), '[]'::jsonb);
end $$;

-- REV-48/51: trilha completa (staff): versões, operações e o sorteio original.
create function public.get_composition_history(p_comp uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v public.team_compositions;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v from public.team_compositions where id=p_comp;
 if not found or not private.is_active_staff(v.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 return jsonb_build_object('composition_id', v.id, 'current_version', v.version,
  'operations', (select jsonb_agg(jsonb_build_object('version', o.version, 'op_type', o.op_type, 'payload', o.payload,
     'created_at', o.created_at, 'actor_name', (select display_name from public.profiles where id=o.actor_user_id)) order by o.version, o.created_at)
   from private.team_composition_ops o where o.composition_id=v.id),
  'versions', (select jsonb_agg(jsonb_build_object('version', g, 'members', (select jsonb_agg(jsonb_build_object('pid', m.pid,
      'name', private.v85_name(m.membership_id, m.guest_id), 'team', m.team, 'captain', m.is_captain) order by m.team, m.pid)
     from public.team_composition_members m where m.composition_id=v.id and m.version_from <= g and (m.version_to is null or m.version_to > g)))
    order by g) from generate_series(1, v.version) g));
end $$;

---------------------------------------------------------------------------------------------------
-- Composição oficial: operações manuais (atômicas, em lote)
---------------------------------------------------------------------------------------------------
-- p_ops: lista de operações aplicadas em ordem, tudo ou nada; uma única nova versão.
--  {"op":"add","membership_id"|"guest_id":uuid,"team":"A"|"B"|null}   (null = inclusão assistida REV-10/11)
--  {"op":"remove","pid":uuid}
--  {"op":"substitute","out":uuid,"membership_id"|"guest_id":uuid,"team":null|"A"|"B"} (padrão: mesma equipe)
--  {"op":"transfer","pid":uuid}           (vai para a outra equipe, mesmo desequilibrando — REV-15)
--  {"op":"swap","a":uuid,"b":uuid}        (um de cada equipe — REV-16)
--  {"op":"captains","a":uuid|null,"b":uuid|null} (REV-26: substituir no mesmo time ou desativar os dois)
create function public.apply_composition_ops(p_comp uuid, p_expected integer, p_ops jsonb, p_request uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.team_compositions; v_replay jsonb; e jsonb; v_new integer; v_pid uuid; v_mem uuid; v_guest uuid; v_team text;
 v_pos text; v_grp text; ca integer; cb integer; ga integer; gb integer; v_cur text; v_b text; v_notices jsonb := '[]'::jsonb;
 v_out jsonb; i integer := 0;
begin
 v_replay := private.v85_replay(p_request, 'composition_ops'); if v_replay is not null then return v_replay; end if;
 select * into v from public.team_compositions where id=p_comp;
 if not found then raise exception 'COMPOSITION_NOT_FOUND'; end if;
 perform private.require_draw_staff(v.pelada_id);
 select * into v from public.team_compositions where id=p_comp for update;
 if v.status <> 'active' then raise exception 'COMPOSITION_NOT_ACTIVE'; end if;
 if p_expected is null or p_expected <> v.version then raise exception 'VERSION_CONFLICT'; end if;
 if jsonb_typeof(p_ops) <> 'array' or jsonb_array_length(p_ops) = 0 or jsonb_array_length(p_ops) > 100 then raise exception 'INVALID_VALUE'; end if;
 v_new := v.version + 1;

 -- Trabalho numa tabela temporária com o estado vigente; grava o resultado no fim.
 create temp table if not exists v85_work(pid uuid primary key, membership_id uuid, guest_id uuid, position_code text,
  team text, is_captain boolean) on commit drop;
 delete from pg_temp.v85_work;
 insert into pg_temp.v85_work select pid, membership_id, guest_id, position_code, team, is_captain
 from public.team_composition_members where composition_id=p_comp and version_to is null;

 for e in select * from jsonb_array_elements(p_ops) loop
  i := i + 1;
  if e->>'op' in ('add','substitute') then
   v_mem := private.try_uuid(e->>'membership_id'); v_guest := private.try_uuid(e->>'guest_id');
   if (v_mem is null) = (v_guest is null) or not private.v85_eligible(v.pelada_id, v_mem, v_guest) then raise exception 'DRAW_INVALID_PLAYER'; end if;
   v_pid := coalesce(v_mem, v_guest);
   v_pos := private.v85_position(v_mem, (select position_code from public.guests where id=v_guest));
   v_grp := private.draw_group_key(v_pos);
   if e->>'op' = 'substitute' then
    select team into v_cur from pg_temp.v85_work where pid=private.try_uuid(e->>'out');
    if not found then raise exception 'DRAW_INVALID_PLAYER'; end if;
    if (select is_captain from pg_temp.v85_work where pid=private.try_uuid(e->>'out')) then raise exception 'CAPTAIN_REPLACE_FIRST'; end if;
    delete from pg_temp.v85_work where pid=private.try_uuid(e->>'out');
    v_team := coalesce(e->>'team', v_cur); -- REV-13: mesmo time por padrão
   else
    v_team := e->>'team';
   end if;
   if exists(select 1 from pg_temp.v85_work where pid=v_pid) then -- REV-71
    v_notices := v_notices || jsonb_build_object('op', i, 'notice', 'ALREADY_IN_COMPOSITION', 'pid', v_pid); continue;
   end if;
   if (select count(*) from pg_temp.v85_work) >= 100 then raise exception 'DRAW_TOO_MANY_PLAYERS'; end if;
   if v_team is null then -- REV-10: menor equipe → menor quantidade no grupo → sorteio seguro
    select count(*) filter (where team='A'), count(*) filter (where team='B') into ca, cb from pg_temp.v85_work;
    select count(*) filter (where team='A'), count(*) filter (where team='B') into ga, gb from pg_temp.v85_work
     where private.draw_group_key(position_code)=v_grp;
    v_team := case when ca < cb then 'A' when cb < ca then 'B' when ga < gb then 'A' when gb < ga then 'B'
     when private.secure_below(2)=0 then 'A' else 'B' end;
   elsif v_team not in ('A','B') then raise exception 'INVALID_VALUE'; end if;
   insert into pg_temp.v85_work values(v_pid, v_mem, v_guest, v_pos, v_team, false);
  elsif e->>'op' = 'remove' then
   v_pid := private.try_uuid(e->>'pid');
   if (select is_captain from pg_temp.v85_work where pid=v_pid) then raise exception 'CAPTAIN_REPLACE_FIRST'; end if;
   delete from pg_temp.v85_work where pid=v_pid; -- REV-12/58: sem redistribuição
   if not found then raise exception 'DRAW_INVALID_PLAYER'; end if;
  elsif e->>'op' = 'transfer' then
   update pg_temp.v85_work set team=case team when 'A' then 'B' else 'A' end where pid=private.try_uuid(e->>'pid') and not is_captain;
   if not found then raise exception 'DRAW_INVALID_PLAYER'; end if;
  elsif e->>'op' = 'swap' then
   select team into v_cur from pg_temp.v85_work where pid=private.try_uuid(e->>'a') and not is_captain;
   select team into v_b from pg_temp.v85_work where pid=private.try_uuid(e->>'b') and not is_captain;
   if v_cur is null or v_b is null or v_cur = v_b then raise exception 'SWAP_INVALID'; end if;
   update pg_temp.v85_work set team=case when pid=private.try_uuid(e->>'a') then v_b else v_cur end
   where pid in (private.try_uuid(e->>'a'), private.try_uuid(e->>'b'));
  elsif e->>'op' = 'captains' then
   if not v.captains_enabled and (e->>'a' is not null or e->>'b' is not null) then raise exception 'CAPTAINS_DISABLED'; end if;
   update pg_temp.v85_work set is_captain=false;
   if e->>'a' is null and e->>'b' is null then
    update public.team_compositions set captains_enabled=false where id=p_comp; v.captains_enabled := false;
   else
    if e->>'a' is null or e->>'b' is null or e->>'a' = e->>'b' then raise exception 'CAPTAINS_REQUIRED'; end if;
    update pg_temp.v85_work set is_captain=true where (pid=private.try_uuid(e->>'a') and team='A') or (pid=private.try_uuid(e->>'b') and team='B');
    if (select count(*) from pg_temp.v85_work where is_captain) <> 2 then raise exception 'CAPTAINS_REQUIRED'; end if;
   end if;
  else raise exception 'INVALID_OPERATION';
  end if;
 end loop;

 if (select count(*) from pg_temp.v85_work where team='A') = 0 or (select count(*) from pg_temp.v85_work where team='B') = 0 then
  raise exception 'COMPOSITION_TEAM_EMPTY'; end if; -- formação mínima (validação permitida pela Etapa 32 A)
 if v.captains_enabled and (select count(*) from pg_temp.v85_work where is_captain) <> 2 then raise exception 'CAPTAINS_REQUIRED'; end if;

 -- Fecha as linhas que mudaram e abre as novas (histórico por versão).
 update public.team_composition_members m set version_to=v_new
 where m.composition_id=p_comp and m.version_to is null and not exists(
  select 1 from pg_temp.v85_work w where w.pid=m.pid and w.team=m.team and w.is_captain=m.is_captain);
 insert into public.team_composition_members(composition_id,pid,membership_id,guest_id,position_code,team,is_captain,version_from)
 select p_comp, w.pid, w.membership_id, w.guest_id, w.position_code, w.team, w.is_captain, v_new from pg_temp.v85_work w
 where not exists(select 1 from public.team_composition_members m where m.composition_id=p_comp and m.version_to is null and m.pid=w.pid);
 update public.team_compositions set version=v_new, updated_at=now() where id=p_comp;
 insert into private.team_composition_ops(composition_id,version,op_type,payload,actor_user_id,request_id)
 values(p_comp,v_new,'manual_ops',jsonb_build_object('ops',p_ops,'notices',v_notices),auth.uid(),p_request);
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v.pelada_id,auth.uid(),'composition_changed',jsonb_build_object('composition_id',p_comp,'version',v_new));
 v_out := private.v85_composition_json(p_comp, true) || jsonb_build_object('notices', v_notices);
 return private.v85_done(p_request, v.pelada_id, 'composition_ops', v_out);
end $$;

-- REV-80/Etapa 18: copia a composição como ponto de partida (abre preparação; times entram como prévia 'copy'
-- quando o administrador salvar com save_manual_preview). Nunca é apresentada como novo sorteio.
create function public.copy_composition_to_preparation(p_comp uuid, p_mode text default 'single', p_rounds integer default 1) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.team_compositions; v_prep uuid;
begin
 select * into v from public.team_compositions where id=p_comp;
 if not found then raise exception 'COMPOSITION_NOT_FOUND'; end if;
 perform private.require_draw_staff(v.pelada_id);
 if exists(select 1 from public.draw_preparations where pelada_id=v.pelada_id and status='open') then raise exception 'PREP_ALREADY_OPEN'; end if;
 if p_mode not in ('single','independent') then raise exception 'DRAW_INVALID_MODE'; end if;
 if p_rounds is null or p_rounds not between 1 and 12 then raise exception 'DRAW_INVALID_ROUNDS'; end if;
 insert into public.draw_preparations(pelada_id,mode,rounds_total,captains_enabled,source_composition_id,created_by,updated_by)
 values(v.pelada_id,p_mode,p_rounds,v.captains_enabled,p_comp,auth.uid(),auth.uid()) returning id into v_prep;
 -- Só quem ainda é elegível entra (revalidação); posição atual, não a antiga.
 insert into public.draw_prep_participants(prep_id,pid,membership_id,guest_id,position_code,captain_team)
 select v_prep, m.pid, m.membership_id, m.guest_id, case when m.guest_id is not null then m.position_code end,
  case when m.is_captain and v.captains_enabled then m.team end
 from public.team_composition_members m where m.composition_id=p_comp and m.version_to is null
  and private.v85_eligible(v.pelada_id, m.membership_id, m.guest_id);
 return private.v85_prep_json(v_prep) || jsonb_build_object('suggested', (select jsonb_agg(jsonb_build_object('pid', m.pid, 'team', m.team))
  from public.team_composition_members m join public.draw_prep_participants p on p.prep_id=v_prep and p.pid=m.pid
  where m.composition_id=p_comp and m.version_to is null));
end $$;

---------------------------------------------------------------------------------------------------
-- Sorteio antigo por OVR: encerrado para novos sorteios (REV-31). Histórico intacto.
---------------------------------------------------------------------------------------------------
create or replace function public.create_team_draw(p_pelada uuid, p_members uuid[], p_mode text, p_rounds integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
 raise exception 'DRAW_ALGORITHM_SUPERSEDED';
end $$;

---------------------------------------------------------------------------------------------------
-- Permissões
---------------------------------------------------------------------------------------------------
revoke all on function private.v85_replay(uuid,text), private.v85_done(uuid,uuid,text,jsonb), private.v85_position(uuid,text),
 private.v85_name(uuid,uuid), private.v85_avatar(uuid), private.v85_eligible(uuid,uuid,uuid),
 private.v85_prep_for_update(uuid,integer), private.v85_prep_touch(uuid), private.v85_prep_problems(uuid),
 private.v85_summary(text[],text[]), private.v85_prep_json(uuid), private.v85_preview_json(uuid), private.v85_snapshot(uuid),
 private.v85_check_prep_ready(uuid), private.v85_composition_json(uuid,boolean) from public, anon, authenticated;

revoke all on function public.get_v85_operation(uuid), public.get_draw_preparation(uuid), public.open_draw_preparation(uuid,text,integer),
 public.set_draw_preparation_options(uuid,integer,text,integer,timestamptz[],boolean), public.set_draw_members(uuid,integer,uuid[]),
 public.add_draw_guest(uuid,integer,uuid,text,text,boolean), public.remove_draw_participant(uuid,integer,uuid),
 public.set_draw_captains(uuid,integer,uuid,uuid), public.replace_draw_guest_with_member(uuid,integer,uuid,uuid),
 public.discard_draw_preparation(uuid,integer,boolean), public.generate_draw_preview(uuid,integer,uuid),
 public.save_manual_preview(uuid,integer,jsonb,uuid), public.confirm_draw_preview(uuid,integer,text,text,uuid),
 public.get_team_compositions(uuid), public.get_composition_history(uuid), public.apply_composition_ops(uuid,integer,jsonb,uuid),
 public.copy_composition_to_preparation(uuid,text,integer) from public, anon;
grant execute on function public.get_v85_operation(uuid), public.get_draw_preparation(uuid), public.open_draw_preparation(uuid,text,integer),
 public.set_draw_preparation_options(uuid,integer,text,integer,timestamptz[],boolean), public.set_draw_members(uuid,integer,uuid[]),
 public.add_draw_guest(uuid,integer,uuid,text,text,boolean), public.remove_draw_participant(uuid,integer,uuid),
 public.set_draw_captains(uuid,integer,uuid,uuid), public.replace_draw_guest_with_member(uuid,integer,uuid,uuid),
 public.discard_draw_preparation(uuid,integer,boolean), public.generate_draw_preview(uuid,integer,uuid),
 public.save_manual_preview(uuid,integer,jsonb,uuid), public.confirm_draw_preview(uuid,integer,text,text,uuid),
 public.get_team_compositions(uuid), public.get_composition_history(uuid), public.apply_composition_ops(uuid,integer,jsonb,uuid),
 public.copy_composition_to_preparation(uuid,text,integer) to authenticated;
