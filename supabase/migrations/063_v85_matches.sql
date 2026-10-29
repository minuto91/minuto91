-- Minuto 91 / 063: V8.5 — partidas pré-cadastradas, escalação prevista local, confirmação coletiva de quem jogou,
-- súmula com salvamento versionado, revisão antes de finalizar, linha do tempo opcional, remarcação/cancelamento
-- ligados à previsão e lista inteligente de partidas.
--
-- Motor V7.7 intocado: nada aqui muda fórmula, voto, nota ou carta. A súmula oficial continua sendo
-- match_participants + match_events (write_match_sheet, 050); a votação continua aberta só por publish_match.
--
-- Precedência aplicada (decisão posterior substitui só o assunto incompatível):
--  * "Partida: data só até hoje" (decisão anterior) × Etapas 6/10/16 e REV-77 (pré-cadastro e remarcação para datas
--    futuras): RASCUNHO pode ter data futura (até 366 dias); PUBLICAR exige que a data já tenha chegado
--    (MATCH_IN_FUTURE). Nenhuma partida futura recebe resultado, voto ou estatística.
--
-- Estados (LAC-03): rascunho agendado → (participação confirmada) → publicada/votação → finalizada;
--  cancelada = mesma linha, preservada, sem estatística (REV-050/REV-76); remarcada = mesma linha, nova data,
--  histórico em match_schedule_events (REV-77). Publicada só muda pela anulação/correção oficial (REV-78).
--
-- Separação (REV-75, Etapas 2/6/14/28):
--  composição oficial (062)  →  escalação prevista da partida (match_planned_players, cópia local)
--  →  participação confirmada (match_participants)  →  súmula/resultado.
--  Prevista não é presença; editar a prevista não muda a composição, outras rodadas nem a súmula (Etapa 7).

---------------------------------------------------------------------------------------------------
-- Datas: rascunho futuro permitido; publicação só depois da data
---------------------------------------------------------------------------------------------------
create or replace function private.prepare_match(p_pelada uuid, p_played_at timestamptz,
 inout p_team_a text, inout p_team_b text, out p_season uuid)
language plpgsql security definer set search_path = '' as $$
begin
 if p_played_at is null
  or private.pelada_local_date(p_pelada,p_played_at) > private.pelada_today(p_pelada) + 366 then
  raise exception 'INVALID_MATCH_DATE'; end if;
 p_team_a := coalesce(nullif(btrim(p_team_a),''),'Time A');
 p_team_b := coalesce(nullif(btrim(p_team_b),''),'Time B');
 if length(p_team_a) > 40 or length(p_team_b) > 40 then raise exception 'INVALID_TEAM_NAME'; end if;
 if (p_team_a,p_team_b) is distinct from ('Time A','Time B') and not private.pelada_has_premium(p_pelada) then
  raise exception 'TEAM_NAMES_PREMIUM'; end if;
 p_season := private.season_for_date(p_pelada, private.pelada_local_date(p_pelada,p_played_at));
end $$;

create function private.block_future_publication() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if old.status = 'draft' and new.status in ('voting_open','finalizing','finalized')
   and private.pelada_local_date(new.pelada_id, new.played_at) > private.pelada_today(new.pelada_id) then
  raise exception 'MATCH_IN_FUTURE'; end if;
 if old.status = 'draft' and new.status in ('voting_open','finalizing','finalized')
   and exists(select 1 from public.match_planned_players where match_id=new.id) and old.participation_confirmed_at is null then
  raise exception 'PARTICIPATION_NOT_CONFIRMED'; end if; -- Etapa 2: pré-cadastrada exige confirmação coletiva
 return new;
end $$;

---------------------------------------------------------------------------------------------------
-- Colunas e tabelas
---------------------------------------------------------------------------------------------------
alter table public.matches
 add column composition_id uuid references public.team_compositions(id),
 add column composition_round integer,
 add column composition_version integer,
 add column draft_version integer not null default 1,
 add column participation_confirmed_at timestamptz,
 add column participation_confirmed_by uuid references public.profiles(id) on delete set null,
 add column planned_status text not null default 'none' check (planned_status in ('none','planned','needs_review','cleared'));
-- Etapa 6/11: nunca duas partidas para a mesma rodada da mesma composição (inclusive canceladas: remarca-se a mesma).
create unique index matches_one_per_composition_round on public.matches(composition_id, composition_round) where composition_id is not null;
grant select (composition_id, composition_round, composition_version, draft_version, participation_confirmed_at, planned_status)
 on public.matches to authenticated;

create trigger matches_block_future_publication before update of status on public.matches
 for each row execute function private.block_future_publication();

create table public.match_planned_players (
 match_id uuid not null references public.matches(id) on delete cascade,
 pid uuid not null,
 membership_id uuid references public.pelada_memberships(id),
 guest_id uuid references public.guests(id),
 position_code text,
 team text not null check (team in ('A','B')),
 is_captain boolean not null default false,
 primary key (match_id, pid),
 check ((membership_id is null) <> (guest_id is null))
);
alter table public.match_planned_players enable row level security;
revoke all on public.match_planned_players from anon, authenticated;

-- Etapa 25: linha do tempo opcional. Minuto só quando informado; ordem só a registrada; nunca inventada.
create table public.match_timeline (
 id uuid primary key default gen_random_uuid(),
 match_id uuid not null references public.matches(id) on delete cascade,
 seq integer not null,
 event_type text not null check (event_type in ('goal','assist','own_goal','unattributed_goal','yellow_card','second_yellow','red_card')),
 participant_id uuid references public.match_participants(id) on delete cascade,
 team text not null check (team in ('A','B')),
 minute integer check (minute is null or minute between 0 and 200),
 unique (match_id, seq)
);
alter table public.match_timeline enable row level security;
revoke all on public.match_timeline from anon, authenticated;

---------------------------------------------------------------------------------------------------
-- Auxiliares
---------------------------------------------------------------------------------------------------
create function private.v85_match_for_update(p_match uuid, p_expected integer) returns public.matches
language plpgsql security definer set search_path = '' as $$
declare v public.matches;
begin
 v := private.lock_match_draft(p_match);
 if p_expected is not null and p_expected <> v.draft_version then raise exception 'VERSION_CONFLICT'; end if;
 return v;
end $$;

create function private.v85_match_bump(p_match uuid) returns integer
language sql security definer set search_path = '' as $$
 update public.matches set draft_version=draft_version+1 where id=p_match returning draft_version;
$$;

-- Setor da súmula a partir do código (convidado sem posição → null: precisa ser informado na confirmação).
create function private.v85_sector(p_code text) returns text
language sql immutable set search_path = '' as $$
 select case when p_code is null then null else private.position_sector(p_code) end;
$$;

create function private.v85_planned_json(p_match uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_agg(jsonb_build_object('pid', p.pid, 'membership_id', p.membership_id, 'guest_id', p.guest_id,
   'guest', p.guest_id is not null, 'name', private.v85_name(p.membership_id, p.guest_id), 'team', p.team,
   'position', coalesce(private.v85_position(p.membership_id, null), p.position_code), 'captain', p.is_captain,
   'avatar_path', private.v85_avatar(p.membership_id),
   'eligible', private.v85_eligible(m.pelada_id, p.membership_id, p.guest_id))
  order by p.team, private.draw_group_order(private.draw_group_key(coalesce(private.v85_position(p.membership_id, null), p.position_code))),
   private.v85_name(p.membership_id, p.guest_id)), '[]'::jsonb)
 from public.match_planned_players p join public.matches m on m.id=p.match_id where p.match_id=p_match;
$$;

---------------------------------------------------------------------------------------------------
-- Pré-cadastro e atualização (Etapas 6, 10, 11, 16)
---------------------------------------------------------------------------------------------------
-- p_items: [{"composition_id": uuid, "round": n (1..rounds_total), "played_at": timestamptz}]
-- p_update: false = só cria; true = atualiza partidas já existentes ainda em rascunho (com confirmação no app).
-- p_reinforced: obrigatório para atualizar rascunho que já tem participação confirmada ou eventos (revisão reforçada).
-- Publicadas, canceladas e finalizadas nunca são tocadas (PROTECTED). Não registra presença nem abre votação.
create function public.pre_register_matches(p_pelada uuid, p_items jsonb, p_update boolean, p_reinforced boolean, p_request uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_replay jsonb; e jsonb; v_c public.team_compositions; v_round integer; v_at timestamptz; v_m public.matches;
 v_id uuid; v_out jsonb := '[]'::jsonb; v_season uuid; v_a text; v_b text; v_seen text[] := '{}'; v_res jsonb;
begin
 v_replay := private.v85_replay(p_request, 'pre_register'); if v_replay is not null then return v_replay; end if;
 perform private.require_draw_staff(p_pelada);
 if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 12 then raise exception 'INVALID_VALUE'; end if;
 for e in select * from jsonb_array_elements(p_items) loop
  select * into v_c from public.team_compositions where id=private.try_uuid(e->>'composition_id') and pelada_id=p_pelada for update;
  if not found or v_c.status <> 'active' then raise exception 'COMPOSITION_NOT_ACTIVE'; end if;
  v_round := coalesce((e->>'round')::int, 1); v_at := (e->>'played_at')::timestamptz;
  if v_round not between 1 and v_c.rounds_total then raise exception 'DRAW_INVALID_ROUNDS'; end if;
  if (v_c.id::text||':'||v_round) = any(v_seen) then raise exception 'DUPLICATE_ROUND'; end if;
  v_seen := v_seen || (v_c.id::text||':'||v_round);
  select * into v_m from public.matches where composition_id=v_c.id and composition_round=v_round for update;
  if found then
   if v_m.status <> 'draft' then v_out := v_out || jsonb_build_object('match_id', v_m.id, 'round', v_round, 'result', 'PROTECTED', 'status', v_m.status); continue; end if;
   if not coalesce(p_update,false) then v_out := v_out || jsonb_build_object('match_id', v_m.id, 'round', v_round, 'result', 'EXISTS'); continue; end if;
   if (v_m.participation_confirmed_at is not null or exists(select 1 from public.match_events where match_id=v_m.id))
     and not coalesce(p_reinforced,false) then
    v_out := v_out || jsonb_build_object('match_id', v_m.id, 'round', v_round, 'result', 'NEEDS_REINFORCED_REVIEW'); continue;
   end if;
   select * into v_a, v_b, v_season from private.prepare_match(p_pelada, coalesce(v_at, v_m.played_at), v_c.team_a_name, v_c.team_b_name);
   update public.matches set played_at=coalesce(v_at, played_at), season_id=v_season, team_a_name=v_a, team_b_name=v_b,
    composition_version=v_c.version, planned_status='planned', draft_version=draft_version+1 where id=v_m.id;
   delete from public.match_planned_players where match_id=v_m.id;
   v_id := v_m.id;
   v_res := jsonb_build_object('match_id', v_id, 'round', v_round, 'result', 'UPDATED');
  else
   if v_at is null then raise exception 'INVALID_MATCH_DATE'; end if;
   select * into v_a, v_b, v_season from private.prepare_match(p_pelada, v_at, v_c.team_a_name, v_c.team_b_name);
   insert into public.matches(pelada_id,season_id,played_at,team_a_name,team_b_name,created_by,composition_id,composition_round,
    composition_version,planned_status)
   values(p_pelada,v_season,v_at,v_a,v_b,auth.uid(),v_c.id,v_round,v_c.version,'planned') returning id into v_id;
   insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
   values(p_pelada,auth.uid(),'match_created',jsonb_build_object('match_id',v_id,'composition_id',v_c.id,'round',v_round));
   v_res := jsonb_build_object('match_id', v_id, 'round', v_round, 'result', 'CREATED');
  end if;
  -- Cópia local da composição vigente (só quem ainda é elegível; os demais ficam informados).
  insert into public.match_planned_players(match_id,pid,membership_id,guest_id,position_code,team,is_captain)
  select v_id, c.pid, c.membership_id, c.guest_id, c.position_code, c.team, c.is_captain
  from public.team_composition_members c where c.composition_id=v_c.id and c.version_to is null
   and private.v85_eligible(p_pelada, c.membership_id, c.guest_id);
  v_out := v_out || (v_res || jsonb_build_object('skipped_ineligible', (select count(*) from public.team_composition_members c
   where c.composition_id=v_c.id and c.version_to is null and not private.v85_eligible(p_pelada, c.membership_id, c.guest_id))));
 end loop;
 return private.v85_done(p_request, p_pelada, 'pre_register', jsonb_build_object('items', v_out));
end $$;

---------------------------------------------------------------------------------------------------
-- Escalação prevista da partida: ajustes locais (Etapas 7, 19, 31)
---------------------------------------------------------------------------------------------------
-- p_ops: add {membership_id|guest_id, team}, remove {pid}, transfer {pid}, substitute {out, membership_id|guest_id}.
-- Não altera a composição oficial, outras rodadas, presença nem estatística. Substituição: escolha humana.
create function public.adjust_match_planned(p_match uuid, p_expected integer, p_ops jsonb, p_request uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.matches; v_replay jsonb; e jsonb; v_mem uuid; v_guest uuid; v_pid uuid; v_team text; v_notices jsonb := '[]'::jsonb;
 v_out jsonb; i integer := 0;
begin
 v_replay := private.v85_replay(p_request, 'match_planned'); if v_replay is not null then return v_replay; end if;
 v := private.v85_match_for_update(p_match, p_expected);
 if jsonb_typeof(p_ops) <> 'array' or jsonb_array_length(p_ops) = 0 or jsonb_array_length(p_ops) > 100 then raise exception 'INVALID_VALUE'; end if;
 for e in select * from jsonb_array_elements(p_ops) loop
  i := i + 1;
  if e->>'op' in ('add','substitute') then
   v_mem := private.try_uuid(e->>'membership_id'); v_guest := private.try_uuid(e->>'guest_id');
   if (v_mem is null) = (v_guest is null) or not private.v85_eligible(v.pelada_id, v_mem, v_guest) then raise exception 'DRAW_INVALID_PLAYER'; end if;
   v_pid := coalesce(v_mem, v_guest);
   if e->>'op' = 'substitute' then
    delete from public.match_planned_players where match_id=p_match and pid=private.try_uuid(e->>'out') returning team into v_team;
    if not found then raise exception 'DRAW_INVALID_PLAYER'; end if;
    v_team := coalesce(e->>'team', v_team);
   else v_team := e->>'team'; end if;
   if v_team is null or v_team not in ('A','B') then raise exception 'INVALID_TEAM'; end if;
   if exists(select 1 from public.match_planned_players where match_id=p_match and pid=v_pid) then
    v_notices := v_notices || jsonb_build_object('op', i, 'notice', 'ALREADY_IN_MATCH', 'pid', v_pid); continue; end if;
   insert into public.match_planned_players(match_id,pid,membership_id,guest_id,position_code,team)
   values(p_match,v_pid,v_mem,v_guest,(select position_code from public.guests where id=v_guest),v_team);
  elsif e->>'op' = 'remove' then
   delete from public.match_planned_players where match_id=p_match and pid=private.try_uuid(e->>'pid');
   if not found then raise exception 'DRAW_INVALID_PLAYER'; end if;
  elsif e->>'op' = 'transfer' then
   update public.match_planned_players set team=case team when 'A' then 'B' else 'A' end
   where match_id=p_match and pid=private.try_uuid(e->>'pid');
   if not found then raise exception 'DRAW_INVALID_PLAYER'; end if;
  else raise exception 'INVALID_OPERATION'; end if;
 end loop;
 update public.matches set planned_status='planned' where id=p_match and planned_status in ('none','needs_review','cleared');
 perform private.v85_match_bump(p_match);
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v.pelada_id,auth.uid(),'match_planned_adjusted',jsonb_build_object('match_id',p_match,'ops',p_ops));
 v_out := jsonb_build_object('match_id', p_match, 'draft_version', (select draft_version from public.matches where id=p_match),
  'planned', private.v85_planned_json(p_match), 'notices', v_notices);
 return private.v85_done(p_request, v.pelada_id, 'match_planned', v_out);
end $$;

-- Etapa 31: candidatos para substituir (elegíveis, fora da partida), mesma posição primeiro. Nunca escolhe sozinho.
create function public.get_substitution_candidates(p_match uuid, p_out uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v public.matches; v_grp text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v from public.matches where id=p_match;
 if not found or not private.is_active_staff(v.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select private.draw_group_key(coalesce(private.v85_position(membership_id, null), position_code)) into v_grp
 from public.match_planned_players where match_id=p_match and pid=p_out;
 return coalesce((select jsonb_agg(jsonb_build_object('membership_id', m.id, 'name', m.player_name,
   'position', coalesce(m.position_code, m.preferred_position),
   'same_position', private.draw_group_key(coalesce(m.position_code, m.preferred_position)) = v_grp)
  order by private.draw_group_key(coalesce(m.position_code, m.preferred_position)) = v_grp desc, m.player_name)
  from public.pelada_memberships m where m.pelada_id=v.pelada_id and m.status='active'
   and not exists(select 1 from public.match_planned_players p where p.match_id=p_match and p.membership_id=m.id)
   and not exists(select 1 from public.match_participants p where p.match_id=p_match and p.membership_id=m.id)), '[]'::jsonb);
end $$;

---------------------------------------------------------------------------------------------------
-- Confirmação coletiva de quem jogou (Etapas 2, 14)
---------------------------------------------------------------------------------------------------
-- p_present: [{"membership_id"|"guest_id": uuid, "team": "A"|"B", "position": código (obrigatório p/ convidado sem posição)}]
-- Grava a participação real (match_participants) preservando eventos de quem continua; quem não entrou não conta.
-- Não publica e não abre votação.
create function public.confirm_match_participation(p_match uuid, p_expected integer, p_present jsonb, p_request uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.matches; v_replay jsonb; e jsonb; v_parts jsonb := '[]'::jsonb; v_events jsonb; v_pos text; v_mem uuid; v_guest uuid;
 v_out jsonb; v_r jsonb;
begin
 v_replay := private.v85_replay(p_request, 'participation'); if v_replay is not null then return v_replay; end if;
 v := private.v85_match_for_update(p_match, p_expected);
 if jsonb_typeof(p_present) <> 'array' or jsonb_array_length(p_present) < 2 or jsonb_array_length(p_present) > 100 then raise exception 'TEAMS_INCOMPLETE'; end if;
 for e in select * from jsonb_array_elements(p_present) loop
  v_mem := private.try_uuid(e->>'membership_id'); v_guest := private.try_uuid(e->>'guest_id');
  if v_guest is not null then
   v_pos := coalesce(nullif(e->>'position',''), (select position_code from public.match_planned_players where match_id=p_match and guest_id=v_guest),
    (select position_code from public.guests where id=v_guest),
    (select primary_position from public.match_participants where match_id=p_match and guest_id=v_guest));
   if v_pos is null then raise exception 'GUEST_POSITION_REQUIRED'; end if; -- não se inventa posição (REV-02)
   v_parts := v_parts || jsonb_build_object('guest_id', v_guest, 'team', e->>'team', 'position', v_pos);
  else
   v_parts := v_parts || jsonb_build_object('membership_id', v_mem, 'team', e->>'team');
  end if;
 end loop;
 -- Eventos de quem saiu impediriam a gravação: a súmula pede correção explícita (Etapa 20), nunca apaga em silêncio.
 if exists(select 1 from public.match_events ev join public.match_participants p on p.id=ev.participant_id
   where ev.match_id=p_match and not exists(select 1 from jsonb_array_elements(v_parts) x
    where private.try_uuid(x->>'membership_id') is not distinct from p.membership_id and private.try_uuid(x->>'guest_id') is not distinct from p.guest_id
      and (x->>'team') = p.team)) then
  raise exception 'EVENTS_REFERENCE_REMOVED_PLAYER'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('membership_id', p.membership_id, 'guest_id', p.guest_id, 'team', ev.team,
   'type', ev.event_type, 'quantity', ev.quantity)), '[]'::jsonb) into v_events
 from public.match_events ev left join public.match_participants p on p.id=ev.participant_id where ev.match_id=p_match;
 v_r := private.write_match_sheet(v, v_parts, v_events);
 if not exists(select 1 from public.match_participants where match_id=p_match and team='A')
  or not exists(select 1 from public.match_participants where match_id=p_match and team='B') then raise exception 'TEAMS_INCOMPLETE'; end if;
 update public.matches set participation_confirmed_at=now(), participation_confirmed_by=auth.uid() where id=p_match;
 perform private.v85_match_bump(p_match);
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v.pelada_id,auth.uid(),'match_participation_confirmed',jsonb_build_object('match_id',p_match,'count',jsonb_array_length(v_parts)));
 v_out := v_r || jsonb_build_object('match_id', p_match, 'draft_version', (select draft_version from public.matches where id=p_match),
  'participants', jsonb_array_length(v_parts));
 return private.v85_done(p_request, v.pelada_id, 'participation', v_out);
end $$;

---------------------------------------------------------------------------------------------------
-- Súmula: salvamento versionado e recuperável (Etapa 21) e revisão (Etapa 15)
---------------------------------------------------------------------------------------------------
-- Mesmo formato de save_match_sheet; recusa versão antiga (VERSION_CONFLICT) e repete com segurança (request_id).
-- Salvar não finaliza nem publica.
create function public.save_match_sheet_v85(p_match uuid, p_expected integer, p_participants jsonb, p_events jsonb, p_request uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.matches; v_replay jsonb; v_r jsonb;
begin
 v_replay := private.v85_replay(p_request, 'sheet_save'); if v_replay is not null then return v_replay; end if;
 v := private.v85_match_for_update(p_match, p_expected);
 v_r := private.write_match_sheet(v, p_participants, p_events);
 -- Timeline guarda só o que ainda existe na súmula.
 delete from public.match_timeline t where t.match_id=p_match and t.participant_id is not null
  and not exists(select 1 from public.match_participants p where p.id=t.participant_id);
 v_r := v_r || jsonb_build_object('draft_version', private.v85_match_bump(p_match), 'saved_at', now());
 return private.v85_done(p_request, v.pelada_id, 'sheet_save', v_r);
end $$;

-- Revisão compacta: erros bloqueiam; avisos não. Finalizar (publicar) continua sendo publish_match.
create function public.get_match_sheet_review(p_match uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v public.matches; v_err jsonb := '[]'::jsonb; v_warn jsonb := '[]'::jsonb; v_un integer; v_na integer; v_nb integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v from public.matches where id=p_match;
 if not found or not private.is_active_staff(v.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select count(*) filter (where team='A'), count(*) filter (where team='B') into v_na, v_nb from public.match_participants where match_id=p_match;
 if v.status <> 'draft' then v_err := v_err || '"MATCH_NOT_DRAFT"'::jsonb; end if;
 if v_na = 0 or v_nb = 0 then v_err := v_err || '"TEAMS_INCOMPLETE"'::jsonb; end if;
 if private.pelada_local_date(v.pelada_id, v.played_at) > private.pelada_today(v.pelada_id) then v_err := v_err || '"MATCH_IN_FUTURE"'::jsonb; end if;
 if exists(select 1 from public.match_planned_players where match_id=p_match) and v.participation_confirmed_at is null then
  v_err := v_err || '"PARTICIPATION_NOT_CONFIRMED"'::jsonb; end if;
 if exists(select 1 from public.match_participants p where p.match_id=p_match and p.membership_id is not null
   and not exists(select 1 from public.pelada_memberships m where m.id=p.membership_id and m.status='active')) then
  v_err := v_err || '"PARTICIPANT_INELIGIBLE"'::jsonb; end if;
 select coalesce(sum(quantity),0) into v_un from public.match_events where match_id=p_match and event_type='unattributed_goal';
 if v_un > 0 then v_warn := v_warn || jsonb_build_object('code','UNATTRIBUTED_GOALS','count',v_un); end if;
 if v.team_a_score + v.team_b_score > 0 and not exists(select 1 from public.match_events where match_id=p_match and event_type='assist') then
  v_warn := v_warn || '{"code":"NO_ASSISTS"}'::jsonb; end if;
 if abs(v_na - v_nb) > 1 then v_warn := v_warn || jsonb_build_object('code','TEAM_SIZES_DIFFER','a',v_na,'b',v_nb); end if; -- informativo
 return jsonb_build_object('match_id', p_match, 'draft_version', v.draft_version, 'team_a_score', v.team_a_score,
  'team_b_score', v.team_b_score, 'participants_a', v_na, 'participants_b', v_nb,
  'blocking', v_err, 'warnings', v_warn, 'can_publish', jsonb_array_length(v_err) = 0);
end $$;

-- Etapa 25: linha do tempo opcional (substitui a lista inteira da partida em rascunho).
-- p_items: [{"type", "membership_id"|"guest_id"|null, "team" (só sem autor), "minute"|null}] na ordem registrada.
-- Cada item precisa caber nas quantidades da súmula (não cria estatística).
create function public.set_match_timeline(p_match uuid, p_expected integer, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.matches; e jsonb; v_part public.match_participants; i integer := 0; v_team text;
begin
 v := private.v85_match_for_update(p_match, p_expected);
 if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 300 then raise exception 'INVALID_VALUE'; end if;
 delete from public.match_timeline where match_id=p_match;
 for e in select * from jsonb_array_elements(p_items) loop
  i := i + 1; v_part := null;
  if e->>'membership_id' is not null or e->>'guest_id' is not null then
   select * into v_part from public.match_participants where match_id=p_match
    and (membership_id=private.try_uuid(e->>'membership_id') or guest_id=private.try_uuid(e->>'guest_id'));
   if not found then raise exception 'EVENT_PARTICIPANT_NOT_IN_MATCH'; end if;
  end if;
  v_team := case when e->>'type'='own_goal' and v_part.id is not null then case v_part.team when 'A' then 'B' else 'A' end
   else coalesce(v_part.team, e->>'team') end;
  insert into public.match_timeline(match_id,seq,event_type,participant_id,team,minute)
  values(p_match,i,e->>'type',v_part.id,v_team,(e->>'minute')::int);
 end loop;
 if exists(select 1 from (select event_type, participant_id, team, count(*) n from public.match_timeline where match_id=p_match
    group by 1,2,3) t where t.n > coalesce((select sum(quantity) from public.match_events ev where ev.match_id=p_match
    and ev.event_type=t.event_type and ev.participant_id is not distinct from t.participant_id and ev.team=t.team),0)) then
  raise exception 'TIMELINE_EXCEEDS_SHEET'; end if;
 return jsonb_build_object('draft_version', private.v85_match_bump(p_match), 'items', i);
end $$;

---------------------------------------------------------------------------------------------------
-- Remarcação com previsão (Etapa 30, REV-77) e leitura da partida
---------------------------------------------------------------------------------------------------
-- p_planned: 'keep' (mantém), 'review' (mantém e marca para revisão), 'clear' (limpa a prevista).
-- Mesma linha, mesmo sorteio e mesma identidade da rodada; participantes revalidados na resposta.
create function public.reschedule_match_v85(p_match uuid, p_played_at timestamptz, p_planned text, p_request uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.matches; v_replay jsonb; v_out jsonb;
begin
 v_replay := private.v85_replay(p_request, 'reschedule'); if v_replay is not null then return v_replay; end if;
 if p_planned is null or p_planned not in ('keep','review','clear') then raise exception 'INVALID_VALUE'; end if;
 perform public.reschedule_match(p_match, p_played_at);
 select * into v from public.matches where id=p_match;
 if p_planned = 'clear' then delete from public.match_planned_players where match_id=p_match;
  update public.matches set planned_status='cleared' where id=p_match;
 elsif p_planned = 'review' or exists(select 1 from public.match_planned_players p where p.match_id=p_match
   and not private.v85_eligible(v.pelada_id, p.membership_id, p.guest_id)) then
  update public.matches set planned_status='needs_review' where id=p_match and exists(select 1 from public.match_planned_players where match_id=p_match);
 end if;
 perform private.v85_match_bump(p_match);
 v_out := jsonb_build_object('match_id', p_match, 'played_at', p_played_at,
  'planned_status', (select planned_status from public.matches where id=p_match),
  'ineligible', (select coalesce(jsonb_agg(p.pid), '[]'::jsonb) from public.match_planned_players p
   where p.match_id=p_match and not private.v85_eligible(v.pelada_id, p.membership_id, p.guest_id)));
 return private.v85_done(p_request, v.pelada_id, 'reschedule', v_out);
end $$;

-- Detalhe da partida para a administração e para jogadores (Etapas 24, 28, 36 A).
create function public.get_match_detail_v85(p_match uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v public.matches; v_staff boolean;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v from public.matches where id=p_match;
 if not found or not private.is_active_member(v.pelada_id) then raise exception 'MATCH_NOT_FOUND'; end if;
 v_staff := private.is_active_staff(v.pelada_id);
 if not v_staff and v.status = 'draft' and v.composition_id is null then raise exception 'MATCH_NOT_FOUND'; end if;
 return jsonb_build_object('id', v.id, 'pelada_id', v.pelada_id, 'status', v.status, 'played_at', v.played_at,
  'originally_scheduled_at', v.originally_scheduled_at, 'team_a_name', v.team_a_name, 'team_b_name', v.team_b_name,
  'draft_version', case when v_staff then v.draft_version end, 'planned_status', v.planned_status,
  'participation_confirmed', v.participation_confirmed_at is not null,
  -- Placar e súmula só depois de publicada (rascunho é interno da administração).
  'team_a_score', case when v.status not in ('draft','cancelled') or v_staff then v.team_a_score end,
  'team_b_score', case when v.status not in ('draft','cancelled') or v_staff then v.team_b_score end,
  -- Previsto ≠ participação (Etapa 28): só em rascunho, nunca em cancelada (REV-76).
  'planned', case when v.status='draft' then private.v85_planned_json(v.id) end,
  'timeline', case when v.status not in ('draft','cancelled') or v_staff then (select coalesce(jsonb_agg(jsonb_build_object(
     'seq', t.seq, 'type', t.event_type, 'team', t.team, 'minute', t.minute,
     'name', case when t.participant_id is not null then (select private.v85_name(p.membership_id, p.guest_id) from public.match_participants p where p.id=t.participant_id) end)
    order by t.seq), '[]'::jsonb) from public.match_timeline t where t.match_id=v.id) end,
  'cancel_reason', case when v.status='cancelled' then v.cancel_reason end);
end $$;

---------------------------------------------------------------------------------------------------
-- Lista inteligente de partidas (Etapas 8, 22, 23)
---------------------------------------------------------------------------------------------------
-- Cronológica (mais recente primeiro), com status, pendência e próxima ação; filtros discretos; paginação por cursor.
-- p_filters: {"q": texto (rodada/data dd/mm), "from": date, "to": date, "season_id": uuid, "status": [..]}
create function public.get_pelada_matches_v85(p_pelada uuid, p_filters jsonb default '{}', p_cursor text default null,
 p_limit integer default 30) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_staff boolean; v_rows jsonb; v_at timestamptz; v_id uuid; v_lim integer := least(greatest(coalesce(p_limit,30),1),100);
 v_status text[]; v_q text := nullif(btrim(coalesce(p_filters->>'q','')),'');
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.is_active_member(p_pelada) then raise exception 'PELADA_NOT_FOUND'; end if;
 v_staff := private.is_active_staff(p_pelada);
 if p_cursor is not null then
  v_at := split_part(p_cursor,'|',1)::timestamptz; v_id := split_part(p_cursor,'|',2)::uuid;
 end if;
 v_status := case when jsonb_typeof(p_filters->'status')='array' then array(select jsonb_array_elements_text(p_filters->'status')) end;
 select coalesce(jsonb_agg(r order by (r->>'played_at')::timestamptz desc, r->>'id' desc), '[]'::jsonb) into v_rows from (
  select jsonb_build_object('id', m.id, 'played_at', m.played_at, 'status', m.status,
   'team_a_name', m.team_a_name, 'team_b_name', m.team_b_name,
   'team_a_score', case when m.status not in ('draft','cancelled') or v_staff then m.team_a_score end,
   'team_b_score', case when m.status not in ('draft','cancelled') or v_staff then m.team_b_score end,
   'rescheduled', m.originally_scheduled_at is not null and m.status <> 'cancelled',
   'round_label', (select c.label from public.team_compositions c where c.id=m.composition_id),
   'pending', case when not v_staff then null
     when m.status='draft' and m.planned_status='needs_review' then 'REVIEW_PLANNED'
     when m.status='draft' and private.pelada_local_date(m.pelada_id,m.played_at) > private.pelada_today(m.pelada_id) then 'SCHEDULED'
     when m.status='draft' and exists(select 1 from public.match_planned_players p where p.match_id=m.id) and m.participation_confirmed_at is null then 'CONFIRM_PARTICIPATION'
     when m.status='draft' then 'FINISH_SHEET'
     when m.status='voting_open' then 'VOTING' end,
   'next_action', case when not v_staff then null
     when m.status='draft' and private.pelada_local_date(m.pelada_id,m.played_at) > private.pelada_today(m.pelada_id) then 'EDIT_PLANNED'
     when m.status='draft' and exists(select 1 from public.match_planned_players p where p.match_id=m.id) and m.participation_confirmed_at is null then 'CONFIRM_PARTICIPATION'
     when m.status='draft' then 'RESUME_SHEET'
     else 'VIEW' end) r
  from public.matches m
  where m.pelada_id=p_pelada
   -- Rascunho manual: só administração (regra anterior). Rodada pré-cadastrada: todos veem (Próxima Rodada, Etapa 28),
   -- sem placar nem súmula.
   and (v_staff or m.status <> 'draft' or m.composition_id is not null)
   and (v_status is null or m.status = any(v_status))
   and (p_filters->>'season_id' is null or m.season_id=private.try_uuid(p_filters->>'season_id'))
   and (p_filters->>'from' is null or private.pelada_local_date(m.pelada_id,m.played_at) >= (p_filters->>'from')::date)
   and (p_filters->>'to' is null or private.pelada_local_date(m.pelada_id,m.played_at) <= (p_filters->>'to')::date)
   and (v_q is null or to_char(private.pelada_local_date(m.pelada_id,m.played_at),'DD/MM/YYYY') like '%'||v_q||'%'
     or exists(select 1 from public.team_compositions c where c.id=m.composition_id and c.label ilike '%'||v_q||'%'))
   and (v_at is null or (m.played_at, m.id) < (v_at, v_id))
  order by m.played_at desc, m.id desc limit v_lim) q;
 return jsonb_build_object('items', v_rows, 'next_cursor', case when jsonb_array_length(v_rows) = v_lim then
  (v_rows->-1->>'played_at')||'|'||(v_rows->-1->>'id') end);
end $$;

---------------------------------------------------------------------------------------------------
-- Permissões
---------------------------------------------------------------------------------------------------
revoke all on function private.block_future_publication(), private.v85_match_for_update(uuid,integer), private.v85_match_bump(uuid),
 private.v85_sector(text), private.v85_planned_json(uuid) from public, anon, authenticated;
revoke all on function public.pre_register_matches(uuid,jsonb,boolean,boolean,uuid), public.adjust_match_planned(uuid,integer,jsonb,uuid),
 public.get_substitution_candidates(uuid,uuid), public.confirm_match_participation(uuid,integer,jsonb,uuid),
 public.save_match_sheet_v85(uuid,integer,jsonb,jsonb,uuid), public.get_match_sheet_review(uuid),
 public.set_match_timeline(uuid,integer,jsonb), public.reschedule_match_v85(uuid,timestamptz,text,uuid),
 public.get_match_detail_v85(uuid), public.get_pelada_matches_v85(uuid,jsonb,text,integer) from public, anon;
grant execute on function public.pre_register_matches(uuid,jsonb,boolean,boolean,uuid), public.adjust_match_planned(uuid,integer,jsonb,uuid),
 public.get_substitution_candidates(uuid,uuid), public.confirm_match_participation(uuid,integer,jsonb,uuid),
 public.save_match_sheet_v85(uuid,integer,jsonb,jsonb,uuid), public.get_match_sheet_review(uuid),
 public.set_match_timeline(uuid,integer,jsonb), public.reschedule_match_v85(uuid,timestamptz,text,uuid),
 public.get_match_detail_v85(uuid), public.get_pelada_matches_v85(uuid,jsonb,text,integer) to authenticated;
