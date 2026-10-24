-- Minuto 91 V7.7: migrações 053 a 057 em ordem. Colar no SQL Editor do projeto minuto91-dev e executar uma vez.

-- ===== 053_v77_vote_integrity.sql =====
-- Minuto 91 / 053: V7.7 (prompt mestre de 24/10/2026), bloco C - integridade da votação v2.
--
-- - Toda nota e toda escolha de Craque/Bola Murcha vira uma VERSÃO imutável (private.rating_vote_versions,
--   só INSERT; UPDATE e DELETE bloqueados por trigger). private.rating_votes / private.rating_vote_awards
--   continuam como projeção da última versão (o que é apurado) e nunca perdem linha: inelegibilidade
--   invalida logicamente (invalidated_at), elegibilidade restabelecida revalida.
-- - Escolha de prêmio em branco = versão com alvo nulo (o voto em branco é permitido, nunca forçado).
-- - O eleitor consulta o próprio histórico de versões (get_my_rating_vote_history), também depois da
--   publicação e mesmo tendo saído da pelada; só leitura depois do encerramento.
-- - Administração vê só progresso operacional (não iniciado / em andamento / revisão concluída) e
--   contagens. Média das notas, validade por jogador e qualquer resultado provisório saem do resumo.
-- - Publicação automática pelo servidor no fechamento (rating_vote_tick), idempotente, com novas
--   tentativas a cada execução do agendador e alerta à gestão depois de 3 falhas. O prazo original
--   (original_closes_at) nunca é alterado.
-- - Uma única prorrogação comum por votação (15 min a 12 h), só a gestão, avisando apenas pendentes.
-- - Ex-integrante que jogou a partida continua eleitor dela (acesso pontual à votação, sem reativar
--   a filiação nem liberar outras telas). Conta com exclusão pendente não vota.
-- - Sem quórum percentual: notas exigem ao menos um voto de cada grupo (D3/D5, inalterado); prêmios
--   exigem 3 escolhas válidas por prêmio, empate no 1º lugar = prêmio compartilhado.
-- Rollback: recriar as funções de 052 (cast/skip/set_awards/get_rating_vote/get_rating_vote_admin/
-- publish/extend/tick/get_my_pending), dropar private.rating_vote_versions e as colunas novas.

---------------------------------------------------------------------------------------------------
-- Estrutura
---------------------------------------------------------------------------------------------------
create table private.rating_vote_versions (
 id bigint generated always as identity primary key,
 session_id uuid not null references public.rating_vote_sessions(id),
 voter_membership_id uuid not null,
 kind text not null check (kind in ('rating','craque','bola_murcha','invalidated','revalidated')),
 target_membership_id uuid,
 rating numeric(3,1) check (rating is null or (rating between 0 and 10 and rating*2 = floor(rating*2))),
 reopening_id uuid,
 reason text,
 created_at timestamptz not null default clock_timestamp()
);
create index rating_vote_versions_voter on private.rating_vote_versions(session_id, voter_membership_id, id);
revoke all on private.rating_vote_versions from public, anon, authenticated;

alter table private.rating_votes add column invalidated_at timestamptz, add column invalid_reason text;
alter table private.rating_vote_awards add column invalidated_at timestamptz, add column invalid_reason text,
 add column updated_at timestamptz not null default now();
alter table private.rating_vote_awards alter column target_membership_id drop not null; -- em branco

alter table public.rating_vote_sessions add column published_sheet_version integer;
update public.rating_vote_sessions s set published_sheet_version=m.sheet_version
 from public.matches m where m.id=s.match_id and s.status='published' and s.published_sheet_version is null;

-- Histórico das notas atuais (antes desta migração não havia trilha): uma versão "legada" por nota.
insert into private.rating_vote_versions(session_id,voter_membership_id,kind,target_membership_id,rating,reason,created_at)
select session_id, voter_membership_id, 'rating', target_membership_id, rating, 'backfill_053', updated_at
from private.rating_votes order by updated_at;
insert into private.rating_vote_versions(session_id,voter_membership_id,kind,target_membership_id,reason)
select session_id, voter_membership_id, award_type, target_membership_id, 'backfill_053' from private.rating_vote_awards;

-- Votos e versões não se apagam nem se reescrevem. A única exceção é a anonimização da exclusão de conta
-- (055), que liga minuto91.vote_purge na própria transação.
create function private.protect_vote_history() returns trigger
language plpgsql set search_path = '' as $$
begin
 if coalesce(current_setting('minuto91.vote_purge', true),'') = 'on' then
  return case when tg_op='DELETE' then old else new end;
 end if;
 if tg_table_name = 'rating_vote_versions' then raise exception 'VOTE_HISTORY_IMMUTABLE'; end if;
 if tg_op = 'DELETE' then raise exception 'VOTE_DELETE_FORBIDDEN'; end if;
 return new;
end $$;
create trigger rating_vote_versions_immutable before update or delete on private.rating_vote_versions
 for each row execute function private.protect_vote_history();
create trigger rating_votes_no_delete before delete on private.rating_votes
 for each row execute function private.protect_vote_history();
create trigger rating_vote_awards_no_delete before delete on private.rating_vote_awards
 for each row execute function private.protect_vote_history();

---------------------------------------------------------------------------------------------------
-- Eleitorado: participantes com conta (ativos OU que saíram depois), sem exclusão pendente
---------------------------------------------------------------------------------------------------
create function private.account_blocked(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from private.account_deletion_requests r where r.user_id=p_user and r.status='pending');
$$;

create function private.rating_voters(p_match uuid) returns table(membership_id uuid, participant_id uuid)
language sql stable security definer set search_path = '' as $$
 select p.membership_id, p.id from public.match_participants p
 join public.pelada_memberships m on m.id=p.membership_id
 join public.profiles pr on pr.id=m.user_id
 where p.match_id=p_match and m.status in ('active','left')
  and pr.adult_declared_at is not null and pr.terms_accepted_at is not null
  and not private.account_blocked(m.user_id);
$$;

-- Membership do usuário logado que é eleitor da sessão (ativo ou ex-integrante). Nulo se não for.
create function private.rating_vote_my_voter(p_session uuid) returns uuid
language sql stable security definer set search_path = '' as $$
 select t.membership_id from public.rating_vote_participants t
 join public.pelada_memberships pm on pm.id=t.membership_id
 where t.session_id=p_session and pm.user_id=(select auth.uid()) and pm.status in ('active','left')
  and not private.account_blocked(pm.user_id)
 limit 1;
$$;

-- Votações em que eu (ex-integrante) ainda sou eleitor: acesso pontual, só à votação.
create function private.rating_vote_access(p_match uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.rating_vote_sessions s where s.match_id=p_match
  and private.rating_vote_my_voter(s.id) is not null);
$$;

-- Reabertura excepcional ativa (054 cria a tabela; aqui só a referência por id).
create function private.rating_vote_active_reopening(p_session uuid) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v uuid;
begin
 if to_regclass('private.rating_vote_reopenings') is null then return null; end if;
 execute 'select id from private.rating_vote_reopenings where session_id=$1 and closed_at is null order by opened_at desc limit 1'
  into v using p_session;
 return v;
end $$;

---------------------------------------------------------------------------------------------------
-- Progresso (mesma regra de 052, só com notas válidas)
---------------------------------------------------------------------------------------------------
create or replace function private.rating_vote_progress_row(p_session uuid, p_voter uuid) returns private.rating_vote_progress
language plpgsql security definer set search_path = '' as $$
declare v private.rating_vote_progress;
begin
 insert into private.rating_vote_progress(session_id, voter_membership_id, sequence)
 select p_session, p_voter, coalesce(array_agg(t.membership_id order by md5(p_session::text||p_voter::text||t.membership_id::text)),'{}')
 from public.rating_vote_participants t where t.session_id=p_session and t.membership_id<>p_voter
 on conflict do nothing;
 select * into v from private.rating_vote_progress where session_id=p_session and voter_membership_id=p_voter for update;
 v.sequence := array(select x from unnest(v.sequence) with ordinality u(x, o)
   where exists(select 1 from public.rating_vote_participants t where t.session_id=p_session and t.membership_id=u.x)
   order by o)
  || array(select t.membership_id from public.rating_vote_participants t where t.session_id=p_session
   and t.membership_id<>p_voter and not (t.membership_id = any(v.sequence))
   order by md5(p_session::text||p_voter::text||t.membership_id::text));
 v.pos := least(v.pos, cardinality(v.sequence));
 if v.pos >= cardinality(v.sequence) then
  while v.second_pos < cardinality(v.skipped_once) and (
    not exists(select 1 from public.rating_vote_participants t where t.session_id=p_session and t.membership_id=v.skipped_once[v.second_pos+1])
    or exists(select 1 from private.rating_votes r where r.session_id=p_session and r.voter_membership_id=p_voter
     and r.target_membership_id=v.skipped_once[v.second_pos+1] and r.invalidated_at is null)) loop
   v.second_pos := v.second_pos + 1;
  end loop;
  if v.second_pos >= cardinality(v.skipped_once) and v.reached_review_at is null then v.reached_review_at := now(); end if;
 end if;
 update private.rating_vote_progress set sequence=v.sequence, pos=v.pos, second_pos=v.second_pos,
  reached_review_at=v.reached_review_at where session_id=p_session and voter_membership_id=p_voter;
 return v;
end $$;

---------------------------------------------------------------------------------------------------
-- Leitura do eleitor
---------------------------------------------------------------------------------------------------
create or replace function public.get_rating_vote(p_match uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_s public.rating_vote_sessions; v_status text; v_me uuid; v_team text;
 v_p private.rating_vote_progress; v_phase text; v_current uuid; v_targets jsonb; v_staff boolean; v_awards jsonb;
 v_member boolean; v_suspension jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 v_member := private.is_active_member(v_m.pelada_id);
 if not v_member and not private.rating_vote_access(p_match) then raise exception 'MATCH_NOT_FOUND'; end if;
 v_staff := private.is_active_staff(v_m.pelada_id);
 select * into v_s from public.rating_vote_sessions where match_id=p_match;
 if not found then
  return jsonb_build_object('state', case when v_m.status = 'annulled' then 'suspended'
    when v_m.status <> 'finalized' then 'unavailable'
    when exists(select 1 from public.voting_sessions o where o.match_id=p_match and o.status='finalized') then 'legacy'
    else 'ready' end,
   'can_manage', v_staff, 'server_now', clock_timestamp());
 end if;
 -- Partida anulada: nada da votação (nem gols dos avaliados) aparece, para ninguém.
 if v_m.status = 'annulled' then
  return jsonb_build_object('state','suspended','session_id',v_s.id,'server_now',clock_timestamp(),'can_manage',v_staff);
 end if;
 v_status := private.rating_vote_effective_status(v_s);
 -- Votação interrompida por anulação e não retomada depois da restauração (054): aguarda a gestão.
 if v_status = 'cancelled' and to_regclass('private.rating_vote_suspensions') is not null then
  execute $q$select jsonb_build_object('previous_status', previous_status, 'divergent', divergent)
    from private.rating_vote_suspensions where session_id=$1 and resolved_at is null
    order by suspended_at desc limit 1$q$ into v_suspension using v_s.id;
  if v_suspension is not null then v_status := 'interrupted'; end if;
 end if;
 v_me := private.rating_vote_my_voter(v_s.id);
 select team into v_team from public.rating_vote_participants where session_id=v_s.id and membership_id=v_me;
 if v_team is not null and v_status = 'open' then
  v_p := private.rating_vote_progress_row(v_s.id, v_me);
 elsif v_team is not null then
  select * into v_p from private.rating_vote_progress where session_id=v_s.id and voter_membership_id=v_me;
 end if;
 if v_p.session_id is not null then
  if v_p.pos < cardinality(v_p.sequence) then v_phase := 'first'; v_current := v_p.sequence[v_p.pos+1];
  elsif v_p.second_pos < cardinality(v_p.skipped_once) then v_phase := 'second'; v_current := v_p.skipped_once[v_p.second_pos+1];
  else v_phase := 'review'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('membership_id',t.membership_id,'name',coalesce(pm.player_name,pr.display_name),
    'avatar_path',pr.avatar_path,'position',coalesce(mp.position_code, mp.primary_position),'team',t.team,
    'is_teammate',t.team=v_team,
    'goals',coalesce((select sum(quantity) from public.match_events e where e.participant_id=t.participant_id and e.event_type='goal'),0),
    'assists',coalesce((select sum(quantity) from public.match_events e where e.participant_id=t.participant_id and e.event_type='assist'),0),
    'my_rating',(select r.rating from private.rating_votes r where r.session_id=v_s.id and r.voter_membership_id=v_me
      and r.target_membership_id=t.membership_id and r.invalidated_at is null),
    'skipped', t.membership_id = any(v_p.skipped_once)) order by o), '[]'::jsonb)
  into v_targets
  from unnest(v_p.sequence) with ordinality u(x, o)
  join public.rating_vote_participants t on t.session_id=v_s.id and t.membership_id=u.x
  join public.pelada_memberships pm on pm.id=t.membership_id
  left join public.profiles pr on pr.id=pm.user_id
  left join public.match_participants mp on mp.id=t.participant_id;
  select jsonb_object_agg(award_type, target_membership_id) into v_awards from private.rating_vote_awards
  where session_id=v_s.id and voter_membership_id=v_me and invalidated_at is null and target_membership_id is not null;
 end if;
 return jsonb_build_object('state', v_status, 'session_id', v_s.id, 'opened_at', v_s.opened_at,
  'closes_at', v_s.closes_at, 'original_closes_at', v_s.original_closes_at, 'server_now', clock_timestamp(),
  'can_manage', v_staff and v_member,
  'is_voter', v_team is not null, 'is_former_member', v_team is not null and not v_member,
  'my_team', v_team, 'phase', v_phase, 'current', v_current,
  'targets', coalesce(v_targets,'[]'::jsonb),
  'rated', (select count(*) from jsonb_array_elements(coalesce(v_targets,'[]'::jsonb)) x where x->>'my_rating' is not null),
  'bola_murcha_enabled', v_s.bola_murcha_enabled, 'my_awards', coalesce(v_awards,'{}'::jsonb),
  'reopened', private.rating_vote_active_reopening(v_s.id) is not null,
  'interruption', v_suspension,
  'extension_used', exists(select 1 from public.rating_vote_extensions e where e.session_id=v_s.id),
  'published_at', v_s.published_at);
end $$;

-- Trava a sessão e valida o eleitor dentro do prazo (servidor é a autoridade).
create or replace function private.rating_vote_lock_voter(p_session uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_s public.rating_vote_sessions; v_me uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_s from public.rating_vote_sessions where id=p_session for share;
 if not found then raise exception 'SESSION_NOT_FOUND'; end if;
 v_me := private.rating_vote_my_voter(p_session);
 if v_me is null and not private.is_active_member(v_s.pelada_id) then raise exception 'SESSION_NOT_FOUND'; end if;
 if exists(select 1 from public.matches where id=v_s.match_id and status='annulled') then raise exception 'VOTING_SUSPENDED'; end if;
 if v_s.status <> 'open' or clock_timestamp() >= v_s.closes_at then raise exception 'VOTING_CLOSED'; end if;
 if v_me is null then raise exception 'NOT_ELIGIBLE_VOTER' using errcode='42501'; end if;
 return v_me;
end $$;

-- Nota: grava a versão e só então a projeção. Reenviar o mesmo valor (retry de rede) não cria versão nova.
create or replace function public.cast_rating_vote(p_session uuid, p_target uuid, p_rating numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_me uuid; v_p private.rating_vote_progress; v_match uuid; v_cur private.rating_votes;
begin
 v_me := private.rating_vote_lock_voter(p_session);
 if p_target = v_me then raise exception 'SELF_VOTE_NOT_ALLOWED'; end if;
 if not exists(select 1 from public.rating_vote_participants where session_id=p_session and membership_id=p_target) then
  raise exception 'TARGET_NOT_ELIGIBLE'; end if;
 if p_rating is null or p_rating < 0 or p_rating > 10 or p_rating*2 <> floor(p_rating*2) then raise exception 'INVALID_RATING'; end if;
 select * into v_cur from private.rating_votes where session_id=p_session and voter_membership_id=v_me
  and target_membership_id=p_target for update;
 if not found or v_cur.rating <> p_rating or v_cur.invalidated_at is not null then
  insert into private.rating_vote_versions(session_id,voter_membership_id,kind,target_membership_id,rating,reopening_id)
  values(p_session, v_me, 'rating', p_target, p_rating, private.rating_vote_active_reopening(p_session));
  insert into private.rating_votes(session_id, voter_membership_id, target_membership_id, rating)
  values(p_session, v_me, p_target, p_rating)
  on conflict (session_id, voter_membership_id, target_membership_id) do update
   set rating=excluded.rating, updated_at=now(), invalidated_at=null, invalid_reason=null;
 end if;
 v_p := private.rating_vote_progress_row(p_session, v_me);
 if v_p.pos < cardinality(v_p.sequence) and v_p.sequence[v_p.pos+1] = p_target then
  update private.rating_vote_progress set pos=pos+1 where session_id=p_session and voter_membership_id=v_me;
 elsif v_p.pos >= cardinality(v_p.sequence) and v_p.second_pos < cardinality(v_p.skipped_once)
   and v_p.skipped_once[v_p.second_pos+1] = p_target then
  update private.rating_vote_progress set second_pos=second_pos+1 where session_id=p_session and voter_membership_id=v_me;
 end if;
 select match_id into v_match from public.rating_vote_sessions where id=p_session;
 return public.get_rating_vote(v_match);
end $$;

-- Craque e Bola Murcha (opcionais). null = em branco. Cada mudança vira versão; nada é apagado.
create or replace function public.set_rating_vote_awards(p_session uuid, p_craque uuid, p_bola_murcha uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid; v_s public.rating_vote_sessions; a record; v_cur private.rating_vote_awards;
begin
 v_me := private.rating_vote_lock_voter(p_session);
 select * into v_s from public.rating_vote_sessions where id=p_session;
 if p_craque = v_me or p_bola_murcha = v_me then raise exception 'SELF_VOTE_NOT_ALLOWED'; end if;
 if p_bola_murcha is not null and not v_s.bola_murcha_enabled then raise exception 'BOLA_MURCHA_DISABLED'; end if;
 if (p_craque is not null and not exists(select 1 from public.rating_vote_participants where session_id=p_session and membership_id=p_craque))
  or (p_bola_murcha is not null and not exists(select 1 from public.rating_vote_participants where session_id=p_session and membership_id=p_bola_murcha)) then
  raise exception 'TARGET_NOT_ELIGIBLE'; end if;
 for a in select * from (values ('craque', p_craque), ('bola_murcha', p_bola_murcha)) x(t, target) loop
  select * into v_cur from private.rating_vote_awards where session_id=p_session and voter_membership_id=v_me
   and award_type=a.t for update;
  if not found and a.target is null then continue; end if; -- nunca escolheu e continua em branco
  if found and v_cur.target_membership_id is not distinct from a.target and v_cur.invalidated_at is null then continue; end if;
  insert into private.rating_vote_versions(session_id,voter_membership_id,kind,target_membership_id,reopening_id)
  values(p_session, v_me, a.t, a.target, private.rating_vote_active_reopening(p_session));
  insert into private.rating_vote_awards(session_id, voter_membership_id, award_type, target_membership_id)
  values(p_session, v_me, a.t, a.target)
  on conflict (session_id, voter_membership_id, award_type) do update
   set target_membership_id=excluded.target_membership_id, updated_at=now(), invalidated_at=null, invalid_reason=null;
 end loop;
end $$;

-- Meu histórico de versões numa partida (só as minhas; também depois de publicada e como ex-integrante).
create function public.get_my_rating_vote_history(p_match uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_s public.rating_vote_sessions; v_me uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_s from public.rating_vote_sessions where match_id=p_match;
 if not found then raise exception 'SESSION_NOT_FOUND'; end if;
 select t.membership_id into v_me from public.rating_vote_participants t
 join public.pelada_memberships pm on pm.id=t.membership_id
 where t.session_id=v_s.id and pm.user_id=auth.uid();
 if v_me is null then
  -- Quem saiu da lista de eleitores por correção ainda vê o que registrou.
  select v.voter_membership_id into v_me from private.rating_vote_versions v
  join public.pelada_memberships pm on pm.id=v.voter_membership_id
  where v.session_id=v_s.id and pm.user_id=auth.uid() limit 1;
 end if;
 if v_me is null then raise exception 'NOT_ELIGIBLE_VOTER' using errcode='42501'; end if;
 return jsonb_build_object('session_id', v_s.id,
  'read_only', v_s.status <> 'open' or clock_timestamp() >= v_s.closes_at,
  'versions', coalesce((select jsonb_agg(jsonb_build_object('kind', v.kind, 'target_membership_id', v.target_membership_id,
     'target_name', (select coalesce(pm.player_name,'Jogador') from public.pelada_memberships pm where pm.id=v.target_membership_id),
     'rating', v.rating, 'at', v.created_at, 'during_reopening', v.reopening_id is not null,
     'current', case when v.kind='rating' then exists(select 1 from private.rating_votes r where r.session_id=v.session_id
        and r.voter_membership_id=v.voter_membership_id and r.target_membership_id=v.target_membership_id
        and r.invalidated_at is null and r.rating=v.rating)
        and v.id = (select max(v2.id) from private.rating_vote_versions v2 where v2.session_id=v.session_id
         and v2.voter_membership_id=v.voter_membership_id and v2.target_membership_id=v.target_membership_id and v2.kind='rating')
      when v.kind in ('craque','bola_murcha') then v.id = (select max(v2.id) from private.rating_vote_versions v2
         where v2.session_id=v.session_id and v2.voter_membership_id=v.voter_membership_id and v2.kind=v.kind)
        and exists(select 1 from private.rating_vote_awards w where w.session_id=v.session_id
         and w.voter_membership_id=v.voter_membership_id and w.award_type=v.kind and w.invalidated_at is null)
      else false end) order by v.id)
   from private.rating_vote_versions v where v.session_id=v_s.id and v.voter_membership_id=v_me
    and v.kind in ('rating','craque','bola_murcha')), '[]'::jsonb));
end $$;

---------------------------------------------------------------------------------------------------
-- Gestão: só progresso operacional, nunca conteúdo
---------------------------------------------------------------------------------------------------
create or replace function public.get_rating_vote_admin(p_session uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s public.rating_vote_sessions; v_n int; v_voters jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_s from public.rating_vote_sessions where id=p_session;
 if not found or not private.is_active_staff(v_s.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select count(*) into v_n from public.rating_vote_participants where session_id=p_session;
 select coalesce(jsonb_agg(jsonb_build_object('membership_id',t.membership_id,'name',coalesce(pm.player_name,pr.display_name),
   'team',t.team,
   'progress', case when g.reached_review_at is not null then 'complete'
     when g.session_id is not null then 'in_progress' else 'not_started' end)
   order by coalesce(pm.player_name,pr.display_name)), '[]'::jsonb)
 into v_voters
 from public.rating_vote_participants t join public.pelada_memberships pm on pm.id=t.membership_id
 left join public.profiles pr on pr.id=pm.user_id
 left join private.rating_vote_progress g on g.session_id=t.session_id and g.voter_membership_id=t.membership_id
 where t.session_id=p_session;
 return jsonb_build_object('session_id',p_session,'state',private.rating_vote_effective_status(v_s),
  'opened_at',v_s.opened_at,'closes_at',v_s.closes_at,'original_closes_at',v_s.original_closes_at,
  'server_now',clock_timestamp(),
  'participants',v_n,
  'voters_complete',(select count(*) from jsonb_array_elements(v_voters) x where x->>'progress'='complete'),
  'voters_in_progress',(select count(*) from jsonb_array_elements(v_voters) x where x->>'progress'='in_progress'),
  'voters_not_started',(select count(*) from jsonb_array_elements(v_voters) x where x->>'progress'='not_started'),
  'voters',v_voters,
  'extension_used', exists(select 1 from public.rating_vote_extensions e where e.session_id=p_session),
  'extensions',(select coalesce(jsonb_agg(jsonb_build_object('at',e.extended_at,'added_minutes',e.added_minutes,
    'new_closes_at',e.new_closes_at) order by e.extended_at),'[]'::jsonb) from public.rating_vote_extensions e where e.session_id=p_session),
  'published_at',v_s.published_at);
end $$;

---------------------------------------------------------------------------------------------------
-- Prorrogação comum: uma por votação, avisa só pendentes
---------------------------------------------------------------------------------------------------
create or replace function public.extend_rating_vote(p_session uuid, p_minutes integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s public.rating_vote_sessions; v_new timestamptz; v_ext uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_s from public.rating_vote_sessions where id=p_session for update;
 if not found or not private.is_active_staff(v_s.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 if exists(select 1 from public.matches where id=v_s.match_id and status='annulled') then raise exception 'VOTING_SUSPENDED'; end if;
 if v_s.status <> 'open' or clock_timestamp() >= v_s.closes_at then raise exception 'VOTING_CLOSED'; end if;
 if p_minutes is null or p_minutes not between 15 and 720 then raise exception 'INVALID_EXTENSION'; end if;
 if exists(select 1 from public.rating_vote_extensions where session_id=p_session) then raise exception 'EXTENSION_ALREADY_USED'; end if;
 v_new := v_s.closes_at + make_interval(mins => p_minutes);
 update public.rating_vote_sessions set closes_at=v_new where id=p_session;
 insert into public.rating_vote_extensions(session_id,pelada_id,extended_by,previous_closes_at,added_minutes,new_closes_at)
 values(p_session,v_s.pelada_id,auth.uid(),v_s.closes_at,p_minutes,v_new) returning id into v_ext;
 perform private.notify(pm.user_id, v_s.pelada_id, 'voting_extended', 'essential', 'rvext:'||v_ext||':'||pm.user_id,
  jsonb_build_object('pelada_id',v_s.pelada_id,'match_id',v_s.match_id,'closes_at',v_new))
 from public.rating_vote_participants t join public.pelada_memberships pm on pm.id=t.membership_id
 where t.session_id=p_session and pm.user_id is not null and pm.status in ('active','left')
  and not exists(select 1 from private.rating_vote_progress g where g.session_id=p_session
   and g.voter_membership_id=t.membership_id and g.reached_review_at is not null);
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_s.pelada_id,auth.uid(),'rating_vote_extended',jsonb_build_object('session_id',p_session,
  'previous_closes_at',v_s.closes_at,'added_minutes',p_minutes,'new_closes_at',v_new));
 return public.get_rating_vote(v_s.match_id);
end $$;

---------------------------------------------------------------------------------------------------
-- Publicação: núcleo idempotente (servidor ou gestão)
---------------------------------------------------------------------------------------------------
create function private.publish_rating_vote_core(p_session uuid, p_actor uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_s public.rating_vote_sessions; v_m public.matches; t text;
begin
 select * into v_s from public.rating_vote_sessions where id=p_session;
 if not found then raise exception 'SESSION_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_s.pelada_id for update;
 select * into v_s from public.rating_vote_sessions where id=p_session for update;
 if v_s.status = 'published' then return false; end if; -- idempotente
 if v_s.status = 'cancelled' then raise exception 'SESSION_CANCELLED'; end if;
 if clock_timestamp() < v_s.closes_at then raise exception 'VOTING_STILL_OPEN'; end if;
 select * into v_m from public.matches where id=v_s.match_id for update;
 if v_m.status <> 'finalized' then raise exception 'VOTING_SUSPENDED'; end if;

 -- Resultado da sessão: uma vez por sessão (retry não duplica; a restauração não passa por aqui).
 insert into private.rating_vote_results(session_id, membership_id, q, teammate_votes, opponent_votes)
 select p_session, t2.membership_id,
  case when count(r.*) filter (where vt.team=t2.team) > 0 and count(r.*) filter (where vt.team<>t2.team) > 0 then
   0.5*avg(r.rating) filter (where vt.team=t2.team) + 0.5*avg(r.rating) filter (where vt.team<>t2.team) end,
  count(r.*) filter (where vt.team=t2.team), count(r.*) filter (where vt.team<>t2.team)
 from public.rating_vote_participants t2
 left join private.rating_votes r on r.session_id=p_session and r.target_membership_id=t2.membership_id and r.invalidated_at is null
 left join public.rating_vote_participants vt on vt.session_id=p_session and vt.membership_id=r.voter_membership_id
 where t2.session_id=p_session
 group by t2.membership_id, t2.team
 on conflict (session_id, membership_id) do nothing;

 -- Craque / Bola Murcha: apuração independente, 3+ escolhas válidas por prêmio, empate = compartilhado.
 foreach t in array case when v_s.bola_murcha_enabled then array['craque','bola_murcha'] else array['craque'] end loop
  if (select count(*) from private.rating_vote_awards w join public.rating_vote_participants vt
      on vt.session_id=w.session_id and vt.membership_id=w.voter_membership_id
      where w.session_id=p_session and w.award_type=t and w.invalidated_at is null and w.target_membership_id is not null
       and exists(select 1 from public.rating_vote_participants x where x.session_id=p_session and x.membership_id=w.target_membership_id)) >= 3
     and not exists(select 1 from public.awards a where a.match_id=v_s.match_id and a.status='active'
      and a.award_type=case t when 'craque' then 'match_craque' else 'bola_murcha' end) then
   insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count,is_shared)
   with votes as (select w.target_membership_id m, count(*)::int c from private.rating_vote_awards w
     join public.rating_vote_participants vt on vt.session_id=w.session_id and vt.membership_id=w.voter_membership_id
     where w.session_id=p_session and w.award_type=t and w.invalidated_at is null and w.target_membership_id is not null
      and exists(select 1 from public.rating_vote_participants x where x.session_id=p_session and x.membership_id=w.target_membership_id)
     group by w.target_membership_id),
   top as (select * from votes where c=(select max(c) from votes))
   select v_s.pelada_id, v_s.match_id, v_m.season_id, top.m,
    case t when 'craque' then 'match_craque' else 'bola_murcha' end, top.c, (select count(*) from top) > 1
   from top on conflict do nothing;
  end if;
 end loop;

 update public.rating_vote_sessions set status='published', published_by=p_actor, published_at=now(),
  published_sheet_version=v_m.sheet_version where id=p_session;
 if to_regclass('private.rating_vote_reopenings') is not null then
  execute 'update private.rating_vote_reopenings set closed_at=now() where session_id=$1 and closed_at is null' using p_session;
 end if;
 perform private.compute_match_results(v_s.match_id, null);
 perform set_config('minuto91.rating_event', 'votes_published', true);
 perform private.after_match_finalized(v_s.match_id);
 perform set_config('minuto91.rating_event', '', true);
 perform private.notify(pm.user_id, v_s.pelada_id, 'result_published', 'essential', 'rvpub:'||p_session||':'||pm.user_id,
  jsonb_build_object('pelada_id',v_s.pelada_id,'match_id',v_s.match_id))
 from public.rating_vote_participants t2 join public.pelada_memberships pm on pm.id=t2.membership_id
 where t2.session_id=p_session and pm.user_id is not null and pm.status='active';
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_s.pelada_id,p_actor,'rating_vote_published',jsonb_build_object('session_id',p_session,'match_id',v_s.match_id,
  'automatic', p_actor is null,
  'valid_players',(select count(*) from private.rating_vote_results where session_id=p_session and q is not null),
  'insufficient_players',(select count(*) from private.rating_vote_results where session_id=p_session and q is null)));
 -- Contas já excluídas definitivamente: o voto individual não tem mais fundamento de retenção.
 perform set_config('minuto91.vote_purge','on',true);
 delete from private.rating_vote_versions v using public.pelada_memberships pm
  where v.session_id=p_session and pm.id=v.voter_membership_id and pm.user_id is null;
 delete from private.rating_votes v using public.pelada_memberships pm
  where v.session_id=p_session and pm.id=v.voter_membership_id and pm.user_id is null;
 delete from private.rating_vote_awards v using public.pelada_memberships pm
  where v.session_id=p_session and pm.id=v.voter_membership_id and pm.user_id is null;
 delete from private.rating_vote_progress v using public.pelada_memberships pm
  where v.session_id=p_session and pm.id=v.voter_membership_id and pm.user_id is null;
 perform set_config('minuto91.vote_purge','',true);
 return true;
end $$;

create or replace function public.publish_rating_vote(p_session uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s public.rating_vote_sessions;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_s from public.rating_vote_sessions where id=p_session;
 if not found then raise exception 'SESSION_NOT_FOUND'; end if;
 if not private.is_active_staff(v_s.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 perform private.publish_rating_vote_core(p_session, auth.uid());
 return public.get_rating_vote(v_s.match_id);
end $$;

---------------------------------------------------------------------------------------------------
-- Agendador: fecha, publica sozinho (com novas tentativas) e lembra pendentes
---------------------------------------------------------------------------------------------------
create or replace function private.rating_vote_tick() returns void
language plpgsql security definer set search_path = '' as $$
declare r record; v_fail int;
begin
 update public.rating_vote_sessions set status='awaiting_publication'
 where status='open' and closes_at <= clock_timestamp();
 for r in select s.id, s.pelada_id, s.match_id from public.rating_vote_sessions s
   join public.matches m on m.id=s.match_id and m.status='finalized'
   where s.status='awaiting_publication' order by s.closes_at loop
  perform private.run_job('publish_rating_vote', r.id, 'select private.publish_rating_vote_core($1, null)');
  select count(*) into v_fail from private.background_jobs where job_type='publish_rating_vote' and entity_id=r.id and status='failed';
  if v_fail >= 3 then
   -- Falha persistente: a gestão é avisada uma vez (o servidor continua tentando).
   perform private.notify(pm.user_id, r.pelada_id, 'rating_vote_publish_failed', 'essential', 'rvfail:'||r.id||':'||pm.user_id,
    jsonb_build_object('pelada_id',r.pelada_id,'match_id',r.match_id))
   from public.pelada_memberships pm where pm.pelada_id=r.pelada_id and pm.status='active'
    and pm.role in ('admin','assistant') and pm.user_id is not null;
  end if;
 end loop;
 -- Lembretes só para quem ainda não chegou à revisão, só com a sessão aberta, sempre pelo prazo vigente.
 perform private.notify(pm.user_id, s.pelada_id, 'voting_closing_soon', 'essential',
  case when clock_timestamp() >= s.closes_at - interval '1 hour'
   then 'rv2:'||s.id||':'||extract(epoch from s.closes_at)::bigint||':'||pm.user_id
   else 'rv1:'||s.id||':'||pm.user_id end,
  jsonb_build_object('pelada_id',s.pelada_id,'match_id',s.match_id,'closes_at',s.closes_at))
 from public.rating_vote_sessions s join public.rating_vote_participants t on t.session_id=s.id
 join public.pelada_memberships pm on pm.id=t.membership_id and pm.status in ('active','left') and pm.user_id is not null
 join public.matches m on m.id=s.match_id and m.status='finalized'
 where s.status='open' and s.closes_at > clock_timestamp()
  and not private.account_blocked(pm.user_id)
  and (clock_timestamp() >= s.closes_at - interval '1 hour' or clock_timestamp() >= s.opened_at + interval '2 hours')
  and not exists(select 1 from private.rating_vote_progress g where g.session_id=s.id
   and g.voter_membership_id=t.membership_id and g.reached_review_at is not null);
end $$;

-- Central: votações abertas em que eu voto (inclusive como ex-integrante) e ainda não cheguei à revisão.
create or replace function public.get_my_pending_rating_votes() returns jsonb
language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_agg(jsonb_build_object('match_id', s.match_id, 'session_id', s.id, 'pelada_id', s.pelada_id,
   'pelada_name', p.name, 'closes_at', s.closes_at, 'team_a_name', m.team_a_name, 'team_b_name', m.team_b_name,
   'team_a_score', m.team_a_score, 'team_b_score', m.team_b_score, 'played_at', m.played_at,
   'rated', (select count(*) from private.rating_votes r where r.session_id = s.id and r.voter_membership_id = t.membership_id
     and r.invalidated_at is null),
   'total', (select count(*) - 1 from public.rating_vote_participants x where x.session_id = s.id),
   'started', g.session_id is not null, 'former_member', pm.status <> 'active') order by s.closes_at), '[]'::jsonb)
 from public.rating_vote_sessions s
 join public.rating_vote_participants t on t.session_id = s.id
 join public.pelada_memberships pm on pm.id = t.membership_id and pm.user_id = (select auth.uid()) and pm.status in ('active','left')
 join public.peladas p on p.id = s.pelada_id join public.matches m on m.id = s.match_id and m.status='finalized'
 left join private.rating_vote_progress g on g.session_id = s.id and g.voter_membership_id = t.membership_id
 where s.status = 'open' and s.closes_at > clock_timestamp() and (g.reached_review_at is null)
  and not private.account_blocked((select auth.uid()));
$$;

-- Push: avisos de votação chegam ao ex-integrante eleitor; os demais continuam exigindo filiação ativa.
create or replace function private.push_skip_reason(p_id uuid) returns text
language sql stable security definer set search_path = '' as $$
 select case
  when e.attempt_count >= 5 then 'MAX_ATTEMPTS'
  when e.created_at < now() - interval '24 hours' then 'STALE'
  when e.event_type = 'award_bola_murcha' then 'POLICY'
  when e.pelada_id is not null and not exists(select 1 from public.pelada_memberships m
    where m.pelada_id=e.pelada_id and m.user_id=e.user_id and m.status='active')
   and not (e.event_type in ('voting_opened','voting_closing_soon','sheet_corrected','voting_extended','voting_reopened')
    and exists(select 1 from public.rating_vote_sessions s join public.rating_vote_participants t on t.session_id=s.id
     join public.pelada_memberships m on m.id=t.membership_id
     where s.match_id=private.try_uuid(e.payload->>'match_id') and m.user_id=e.user_id and m.status='left'))
   then 'NO_ACCESS'
  when e.event_type <> 'account_transferred' and exists(select 1 from public.notification_preferences p
    where p.user_id=e.user_id and ((e.category='essential' and not p.essential) or (e.category='engagement' and not p.engagement)
     or (p.categories ->> private.notification_category(e.event_type)) = 'false'))
   then 'OPTED_OUT'
  when e.event_type in ('voting_opened','voting_closing_soon','sheet_corrected','voting_restarted','voting_extended','voting_reopened')
   and not exists(select 1 from public.voting_sessions v where v.match_id=private.try_uuid(e.payload->>'match_id')
    and v.status='open')
   and not exists(select 1 from public.rating_vote_sessions v where v.match_id=private.try_uuid(e.payload->>'match_id')
    and v.status='open' and v.closes_at > now()) then 'VOTING_CLOSED'
  when not exists(select 1 from public.push_devices d where d.user_id=e.user_id) then 'NO_DEVICE'
 end
 from public.notification_events e where e.id=p_id;
$$;

create or replace function private.notification_category(p_event text) returns text
language sql immutable set search_path = '' as $$
 select case
  when p_event in ('voting_opened','voting_restarted','sheet_corrected','voting_extended','voting_reopened') then 'match_voting'
  when p_event = 'voting_closing_soon' then 'voting_reminder'
  when p_event in ('result_published','match_annulled','match_restored') then 'results'
  when p_event like 'award\_%' or p_event in ('sticker_unlocked','season_review') then 'awards'
  when p_event in ('admin_succession','role_changed','successor_designated','subscription_changed',
   'rating_vote_publish_failed') then 'pelada'
  when p_event = 'account_transferred' then 'account'
  else 'other' end;
$$;

-- Abertura: o eleitorado usa a mesma regra (ativos e quem já saiu, sem exclusão pendente).
create or replace function public.open_rating_vote(p_match uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_m public.matches; v_id uuid; v_close timestamptz := now() + interval '6 hours';
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_pelada for update;
 if not private.is_active_staff(v_pelada) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match for update;
 if v_m.status <> 'finalized' then raise exception 'MATCH_NOT_OFFICIAL'; end if;
 if exists(select 1 from public.rating_vote_sessions where match_id=p_match) then raise exception 'VOTING_ALREADY_OPENED'; end if;
 if exists(select 1 from public.voting_sessions o where o.match_id=p_match and o.status='finalized') then
  raise exception 'MATCH_HAS_LEGACY_VOTING'; end if;
 insert into public.rating_vote_sessions(pelada_id,match_id,opened_by,closes_at,original_closes_at,rules_version,bola_murcha_enabled)
 values(v_pelada,p_match,auth.uid(),v_close,v_close,2,
  coalesce((select bola_murcha_enabled from public.pelada_settings where pelada_id=v_pelada),true)
   and private.pelada_has_premium(v_pelada))
 returning id into v_id;
 insert into public.rating_vote_participants(session_id,pelada_id,membership_id,participant_id,team)
 select v_id, v_pelada, v.membership_id, v.participant_id, p.team
 from private.rating_voters(p_match) v join public.match_participants p on p.id=v.participant_id;
 perform private.notify(pm.user_id, v_pelada, 'voting_opened', 'essential', 'rvopen:'||v_id||':'||pm.user_id,
  jsonb_build_object('pelada_id',v_pelada,'match_id',p_match))
 from public.rating_vote_participants t join public.pelada_memberships pm on pm.id=t.membership_id
 where t.session_id=v_id and pm.user_id is not null;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_pelada,auth.uid(),'rating_vote_opened',jsonb_build_object('match_id',p_match,'session_id',v_id,
  'closes_at',v_close,'rules_version',2,'participants',(select count(*) from public.rating_vote_participants where session_id=v_id)));
 return public.get_rating_vote(p_match);
end $$;

revoke all on function private.protect_vote_history(), private.account_blocked(uuid), private.rating_voters(uuid),
 private.rating_vote_my_voter(uuid), private.rating_vote_access(uuid), private.rating_vote_active_reopening(uuid),
 private.publish_rating_vote_core(uuid,uuid) from public, anon, authenticated;
revoke all on function public.get_my_rating_vote_history(uuid) from public, anon;
grant execute on function public.get_my_rating_vote_history(uuid) to authenticated;

-- ===== 054_v77_annulment_restoration.sql =====
-- Minuto 91 / 054: V7.7, blocos D e E - anulação e restauração de partidas, votação em partida anulada.
--
-- Substitui a regra antiga de 020 (só até 7 dias, sem restauração):
-- - Anulação pela administração a qualquer tempo, com categoria, justificativa, prévia e confirmação reforçada
--   (a prévia traz um preview_token; se o estado mudou, a operação recusa com PREVIEW_OUTDATED e o app mostra
--   a prévia nova para confirmar de novo).
-- - Restauração excepcional, com justificativa, prévia e confirmação. Anular/restaurar quantas vezes for preciso:
--   cada operação é um evento imutável (private.match_status_events) com request_id (retry do mesmo pedido não
--   repete a operação). Cada anulação abre um CICLO (cycle_id = id do evento de anulação).
-- - Efeitos esportivos: a partida anulada sai de gols, assistências, cartões, notas, OVR, rankings, Seleção,
--   troféus, figurinhas e agregados, inclusive em meses e temporadas já fechados; ao restaurar, os dados válidos
--   voltam (os mesmos prêmios, reativados, sem duplicar). Fechamentos financeiros não são tocados.
-- - A partida anulada continua no histórico. Para jogadores: só data, equipes, rodada, status e linha do tempo
--   resumida. Placar (colunas public_team_*_score), eventos, súmulas versionadas, notas, prêmios, Seleção e
--   destaques ficam ocultos também no banco (privilégio de coluna + políticas RESTRICTIVE + RPCs).
-- - match_annulments deixa de ser legível pelo app (descrição e autor vazavam para todos os membros). A linha do
--   tempo pública sai de get_match_status_history (sem descrição e sem autor, também para ex-integrantes que
--   jogaram a partida); os detalhes, de get_match_status_history_admin (só administração).
-- - Notificação: uma coletiva por operação concluída (match_annulled / match_restored) para os integrantes
--   atuais, com chave de deduplicação pelo id da operação; nada por OVR/troféu/figurinha recalculado. Sai do
--   mesmo INSERT de auditoria da operação (mesma transação): operação revertida não notifica.
-- - Votação: a anulação preserva sessão e votos e guarda o estado anterior (aberta, aguardando publicação,
--   publicada). Na restauração, a publicação original volta sozinha (sem novo voto, sem segunda publicação, sem
--   duplicar resultados e prêmios) se a súmula for compatível; se não, fica suspensa até correção legítima.
--   Votação interrompida antes de publicar não reabre sozinha: a administração retoma (prazo original ainda
--   não venceu), publica os votos preservados ou reabre por 1 a 24 h, no máximo uma reabertura por ciclo.
-- - correct_match_sheet: votos de quem deixa de ser elegível são invalidados (não apagados) e revalidados se a
--   elegibilidade voltar; correção excepcional depois da publicação só sem mudar eleitorado/avaliados.
-- Rollback: restaurar annul_match/preview (020), correct_match_sheet (052), notify_from_audit (022),
-- get_match_lineup (042), get_my_home (037), a política annulments_read e o trigger rating_vote_on_annul;
-- dropar as tabelas e colunas novas. Eventos de restauração não têm volta automática (registrar à parte).

---------------------------------------------------------------------------------------------------
-- Estrutura
---------------------------------------------------------------------------------------------------
create table private.match_status_events (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null references public.matches(id),
 kind text not null check (kind in ('annulment','restoration')),
 cycle_id uuid not null,
 request_id uuid not null unique,
 reason_category text check (reason_category is null or reason_category in
  ('sheet_error','duplicate_match','match_not_played','other','restoration')),
 description text not null check (length(btrim(description)) between 10 and 1000),
 actor_user_id uuid,
 preview_token text not null,
 effects jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default clock_timestamp()
);
create index match_status_events_match on private.match_status_events(match_id, created_at);
revoke all on private.match_status_events from public, anon, authenticated;

create function private.status_events_immutable() returns trigger
language plpgsql set search_path = '' as $$
begin
 raise exception 'STATUS_EVENT_IMMUTABLE';
end $$;
create trigger match_status_events_immutable before update or delete on private.match_status_events
 for each row execute function private.status_events_immutable();

-- Estado anterior da votação em cada ciclo.
create table private.rating_vote_suspensions (
 id uuid primary key default gen_random_uuid(),
 session_id uuid not null references public.rating_vote_sessions(id),
 cycle_id uuid not null,
 previous_status text not null check (previous_status in ('open','awaiting_publication','published')),
 previous_closes_at timestamptz not null,
 suspended_at timestamptz not null default clock_timestamp(),
 restored_at timestamptz,
 divergent boolean not null default false,
 resolved_at timestamptz,
 resolution text check (resolution is null or resolution in
  ('publication_restored','resumed','published','reopened','superseded')),
 resolved_by uuid,
 unique (session_id, cycle_id)
);
create unique index one_open_suspension on private.rating_vote_suspensions(session_id) where resolved_at is null;
revoke all on private.rating_vote_suspensions from public, anon, authenticated;

create table private.rating_vote_reopenings (
 id uuid primary key default gen_random_uuid(),
 session_id uuid not null references public.rating_vote_sessions(id),
 cycle_id uuid not null unique, -- no máximo uma reabertura excepcional por ciclo
 suspension_id uuid not null references private.rating_vote_suspensions(id),
 opened_by uuid not null,
 reason text not null,
 opened_at timestamptz not null default clock_timestamp(),
 closes_at timestamptz not null,
 closed_at timestamptz
);
revoke all on private.rating_vote_reopenings from public, anon, authenticated;

-- Anulações repetidas da mesma partida (antes: uma por partida).
alter table public.match_annulments drop constraint if exists match_annulments_match_id_key;
alter table public.match_annulments add column status_event_id uuid;
drop policy if exists annulments_read on public.match_annulments;
revoke all on public.match_annulments from authenticated;

-- A anulação deixa de cancelar a sessão às cegas: annul_match guarda o estado anterior.
drop trigger if exists rating_vote_on_annul on public.matches;

-- Backfill: anulações antigas viram eventos (o ciclo é o próprio evento) e as sessões já canceladas por elas
-- ganham o registro do estado anterior que dá para recuperar (publicada, se havia publicação).
insert into private.match_status_events(id,pelada_id,match_id,kind,cycle_id,request_id,reason_category,description,
 actor_user_id,preview_token,effects,created_at)
select a.id, a.pelada_id, a.match_id, 'annulment', a.id, a.id, a.reason_category, a.description, a.annulled_by,
 'backfill_054', jsonb_build_object('backfill', true), a.created_at
from public.match_annulments a;
update public.match_annulments set status_event_id=id where status_event_id is null;
insert into private.rating_vote_suspensions(session_id,cycle_id,previous_status,previous_closes_at,suspended_at)
select s.id, a.id, case when s.published_at is not null then 'published' else 'awaiting_publication' end,
 s.closes_at, a.created_at
from public.rating_vote_sessions s join public.match_annulments a on a.match_id=s.match_id
join public.matches m on m.id=s.match_id and m.status='annulled'
where s.status='cancelled';

---------------------------------------------------------------------------------------------------
-- Dados de partida anulada ocultos no banco
---------------------------------------------------------------------------------------------------
create function private.match_detail_visible(p_match uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select coalesce((select m.status <> 'annulled' or private.is_active_admin(m.pelada_id)
  from public.matches m where m.id=p_match), true);
$$;
revoke all on function private.match_detail_visible(uuid) from public, anon;
grant execute on function private.match_detail_visible(uuid) to authenticated;

create policy events_hidden_when_annulled on public.match_events as restrictive for select to authenticated
 using ((select private.match_detail_visible(match_id)));
create policy versions_hidden_when_annulled on public.match_versions as restrictive for select to authenticated
 using ((select private.match_detail_visible(match_id)));
create policy results_hidden_when_annulled on public.match_player_results as restrictive for select to authenticated
 using ((select private.match_detail_visible(match_id)));
create policy saves_hidden_when_annulled on public.match_keeper_saves as restrictive for select to authenticated
 using ((select private.match_detail_visible(match_id)));
create policy highlights_hidden_when_annulled on public.highlights as restrictive for select to authenticated
 using ((select private.match_detail_visible(match_id)));
create policy selections_hidden_when_annulled on public.round_selections as restrictive for select to authenticated
 using ((select private.match_detail_visible(match_id)));
create policy awards_hidden_when_annulled on public.awards as restrictive for select to authenticated
 using (match_id is null or (select private.match_detail_visible(match_id)));
create policy snapshots_hidden_when_annulled on public.card_snapshots as restrictive for select to authenticated
 using ((select private.match_detail_visible(match_id)));
create policy rating_history_hidden_when_annulled on public.player_rating_history as restrictive for select to authenticated
 using (match_id is null or (select private.match_detail_visible(match_id)));

-- Placar: o app lê public_team_*_score (nulo quando anulada); o placar original fica só para o servidor.
alter table public.matches
 add column public_team_a_score integer generated always as (case when status='annulled' then null else team_a_score end) stored,
 add column public_team_b_score integer generated always as (case when status='annulled' then null else team_b_score end) stored;
do $$
declare v_cols text;
begin
 select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into v_cols
 from information_schema.columns where table_schema='public' and table_name='matches'
  and column_name not in ('team_a_score','team_b_score');
 execute 'revoke select on public.matches from authenticated';
 execute format('grant select (%s) on public.matches to authenticated', v_cols);
end $$;

-- Escalação pós-jogo: sem placar quando anulada (equipes continuam visíveis).
alter function public.get_match_lineup(uuid) rename to get_match_lineup_v42;
alter function public.get_match_lineup_v42(uuid) set schema private;
create function public.get_match_lineup(p_match uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := private.get_match_lineup_v42(p_match);
begin
 if v->>'status' = 'annulled' then
  v := v || jsonb_build_object('team_a_score', null, 'team_b_score', null);
 end if;
 return v;
end $$;
revoke all on function private.get_match_lineup_v42(uuid) from public, anon, authenticated;
revoke all on function public.get_match_lineup(uuid) from public, anon;
grant execute on function public.get_match_lineup(uuid) to authenticated;

-- Início antigo: o placar da última partida some quando ela foi anulada.
create or replace function public.get_my_home() returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object(
  'peladas', coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'role',pm.role,
     'last',(select jsonb_build_object('id',m.id,'played_at',m.played_at,'status',m.status,'team_a_name',m.team_a_name,
        'team_b_name',m.team_b_name,'team_a_score',m.public_team_a_score,'team_b_score',m.public_team_b_score)
       from public.matches m where m.pelada_id=p.id and m.status<>'draft' order by m.played_at desc, m.id desc limit 1),
     'drafts',case when pm.role in ('admin','assistant')
       then (select count(*) from public.matches m where m.pelada_id=p.id and m.status='draft') else 0 end)
    order by p.name)
   from public.pelada_memberships pm join public.peladas p on p.id=pm.pelada_id
   where pm.user_id=(select auth.uid()) and pm.status='active'), '[]'::jsonb),
  'pending', coalesce((select jsonb_agg(jsonb_build_object('match_id',s.match_id,'pelada_id',s.pelada_id,
     'pelada_name',p.name,'closes_at',s.closes_at,'team_a_name',m.team_a_name,'team_b_name',m.team_b_name,
     'team_a_score',m.public_team_a_score,'team_b_score',m.public_team_b_score) order by s.closes_at)
   from public.voting_sessions s join public.voting_eligible_members e on e.session_id=s.id
   join public.pelada_memberships pm on pm.id=e.membership_id and pm.user_id=(select auth.uid()) and pm.status='active'
   join public.peladas p on p.id=s.pelada_id join public.matches m on m.id=s.match_id
   where s.status='open' and s.closes_at > now()
    and not exists(select 1 from public.vote_receipts r where r.session_id=s.id and r.membership_id=e.membership_id)), '[]'::jsonb),
  'server_time', now());
$$;

---------------------------------------------------------------------------------------------------
-- Notificações: uma coletiva por operação; efeitos retroativos em silêncio
---------------------------------------------------------------------------------------------------
create function private.quiet_effects() returns boolean
language sql stable set search_path = '' as $$
 select coalesce(current_setting('minuto91.quiet_effects', true),'') = 'on';
$$;

create or replace function private.notify_from_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_match uuid := (new.metadata->>'match_id')::uuid; v_session uuid; u uuid; v_payload jsonb; v_op text;
begin
 v_payload := jsonb_build_object('pelada_id',new.pelada_id,'match_id',v_match);
 if new.event_type in ('match_published','match_sheet_corrected','voting_restarted') then
  v_session := coalesce((new.metadata->>'new_session_id')::uuid, (new.metadata->>'session_id')::uuid,
   (select id from public.voting_sessions where match_id=v_match and status='open'));
  if v_session is not null then
   for u in select * from private.session_users(v_session) loop
    perform private.notify(u,new.pelada_id,
     case new.event_type when 'match_published' then 'voting_opened' when 'voting_restarted' then 'voting_restarted'
      else 'sheet_corrected' end,'essential',new.event_type||':'||new.id||':'||u,v_payload);
   end loop;
  end if;
 elsif new.event_type = 'match_finalized' then
  for u in select * from private.pelada_users(new.pelada_id) loop
   perform private.notify(u,new.pelada_id,'result_published','essential',new.event_type||':'||v_match||':'||u,v_payload);
  end loop;
 elsif new.event_type in ('match_annulled','match_restored') then
  -- Chave pela operação: anulações sucessivas avisam de novo; retry da mesma operação não duplica.
  v_op := coalesce(new.metadata->>'operation_id', new.metadata->>'annulment_id', new.id::text);
  for u in select * from private.pelada_users(new.pelada_id) loop
   perform private.notify(u,new.pelada_id,new.event_type,'essential',new.event_type||':'||v_op||':'||u,
    v_payload || jsonb_build_object('operation_id', v_op));
  end loop;
 elsif new.event_type in ('admin_succeeded','pelada_without_eligible_admin') then
  for u in select * from private.pelada_users(new.pelada_id) loop
   perform private.notify(u,new.pelada_id,'admin_succession','essential',new.event_type||':'||new.id||':'||u,
    jsonb_build_object('pelada_id',new.pelada_id));
  end loop;
 elsif new.event_type='subscription_event' then
  perform private.notify(m.user_id,new.pelada_id,'subscription_changed','essential','subscription:'||new.id,
   jsonb_build_object('pelada_id',new.pelada_id,'result',new.metadata->>'result'))
  from public.pelada_memberships m where m.pelada_id=new.pelada_id and m.role='admin' and m.status='active';
 end if;
 return new;
end $$;

create or replace function private.notify_from_award() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.status='active' and not private.quiet_effects() then
  perform private.notify(m.user_id,new.pelada_id,'award_'||new.award_type,'engagement','award:'||new.id,
   jsonb_build_object('pelada_id',new.pelada_id,'match_id',new.match_id,'award_type',new.award_type,
    'period_month',new.period_month))
  from public.pelada_memberships m where m.id=new.membership_id and m.status='active';
 end if;
 return new;
end $$;

create or replace function private.notify_from_sticker() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.event_type in ('unlocked','reactivated') and not private.quiet_effects() then
  perform private.notify(m.user_id,new.pelada_id,'sticker_unlocked','engagement','sticker:'||new.id,
   jsonb_build_object('pelada_id',new.pelada_id,'sticker_definition_id',new.sticker_definition_id))
  from public.pelada_memberships m where m.id=new.membership_id and m.status='active';
 end if;
 return new;
end $$;

---------------------------------------------------------------------------------------------------
-- Prévia e efeitos
---------------------------------------------------------------------------------------------------
create or replace function private.lock_annullable_match(p_match uuid) returns public.matches
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_m public.matches;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_pelada for update;
 if not private.is_active_admin(v_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match for update;
 return v_m;
end $$;

-- Votação compatível com a súmula atual? (mesma versão publicada e todo eleitor ainda no mesmo time)
create function private.rating_vote_sheet_compatible(p_session uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select s.published_sheet_version is not distinct from m.sheet_version
  and not exists(select 1 from public.rating_vote_participants t where t.session_id=s.id
   and not exists(select 1 from public.match_participants p where p.match_id=s.match_id
    and p.membership_id=t.membership_id and p.team=t.team))
 from public.rating_vote_sessions s join public.matches m on m.id=s.match_id where s.id=p_session;
$$;

create function private.match_status_preview(p_m public.matches, p_kind text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s public.rating_vote_sessions; v_sus private.rating_vote_suspensions; v_vote text; v_conflicts text[] := '{}';
 v_body jsonb; v_last uuid; v_month date;
begin
 select * into v_s from public.rating_vote_sessions where match_id=p_m.id;
 if found then
  select * into v_sus from private.rating_vote_suspensions where session_id=v_s.id and resolved_at is null;
  if p_kind = 'annulment' then
   v_vote := case private.rating_vote_effective_status(v_s)
    when 'open' then 'suspend_open' when 'awaiting_publication' then 'suspend_awaiting'
    when 'published' then 'suspend_published' else 'keep_suspended' end;
   if v_vote = 'suspend_open' then v_conflicts := array_append(v_conflicts, 'voting_in_progress'); end if;
  else
   v_vote := case when v_sus.id is null then 'none'
    when v_sus.previous_status = 'published' and private.rating_vote_sheet_compatible(v_s.id) then 'restore_publication'
    when v_sus.previous_status = 'published' then 'publication_suspended'
    else 'admin_decision' end;
   if v_vote = 'publication_suspended' then v_conflicts := array_append(v_conflicts, 'sheet_divergent'); end if;
   if v_vote = 'admin_decision' then v_conflicts := array_append(v_conflicts, 'voting_needs_decision'); end if;
  end if;
 else
  v_vote := 'none';
 end if;
 select id into v_last from private.match_status_events where match_id=p_m.id order by created_at desc, id desc limit 1;
 v_month := date_trunc('month', private.pelada_local_date(p_m.pelada_id, p_m.played_at))::date;
 v_body := jsonb_build_object(
  'kind', p_kind,
  'status', p_m.status,
  'players_affected', (select count(*) from public.match_player_results where match_id=p_m.id),
  'goals', (select coalesce(sum(goals),0) from public.match_player_results where match_id=p_m.id),
  'assists', (select coalesce(sum(assists),0) from public.match_player_results where match_id=p_m.id),
  'cards', (select coalesce(sum(quantity),0) from public.match_events where match_id=p_m.id
    and event_type in ('yellow_card','second_yellow','red_card')),
  'ratings', (select count(*) from public.match_player_results where match_id=p_m.id and has_valid_rating),
  'awards', (select count(*) from public.awards where match_id=p_m.id
    and status = case when p_kind='annulment' then 'active' else 'revoked' end
    and award_type <> 'match_garcom'),
  'has_round_selection', exists(select 1 from public.round_selections where match_id=p_m.id),
  'month', v_month,
  'month_closed', exists(select 1 from public.monthly_closures where pelada_id=p_m.pelada_id and period_month=v_month),
  'season_closed', exists(select 1 from public.seasons where id=p_m.season_id and ends_on < private.pelada_today(p_m.pelada_id)),
  'finance_unchanged', true,
  'voting', v_vote,
  'conflicts', to_jsonb(v_conflicts),
  'cycles', (select count(*) from private.match_status_events where match_id=p_m.id and kind='annulment'));
 return v_body || jsonb_build_object('preview_token',
  md5(v_body::text || coalesce(v_last::text,'') || p_m.sheet_version::text || coalesce(v_s.status,'') || coalesce(v_s.closes_at::text,'')));
end $$;

create or replace function public.preview_match_annulment(p_match uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches;
begin
 v_m := private.lock_annullable_match(p_match);
 return private.match_status_preview(v_m, 'annulment') || jsonb_build_object('can_annul', v_m.status='finalized');
end $$;

create function public.preview_match_restoration(p_match uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches;
begin
 v_m := private.lock_annullable_match(p_match);
 return private.match_status_preview(v_m, 'restoration') || jsonb_build_object('can_restore', v_m.status='annulled');
end $$;

-- Recalcula tudo que depende da partida (anulação e restauração usam o mesmo caminho), em silêncio.
create function private.apply_match_status_effects(p_m public.matches, p_event text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_latest uuid; v_mem uuid;
begin
 perform set_config('minuto91.quiet_effects', 'on', true);
 perform set_config('minuto91.rating_event', p_event, true);
 update public.highlights set expires_at=now() where match_id=p_m.id and expires_at is null;
 select id into v_latest from public.matches where pelada_id=p_m.pelada_id and status='finalized'
 order by finalized_at desc, id desc limit 1;
 if v_latest is not null and not exists(select 1 from public.highlights
   where pelada_id=p_m.pelada_id and expires_at is null and match_id=v_latest) then
  perform private.refresh_highlights(v_latest);
 end if;
 perform private.recompute_stats(p_m.pelada_id, p_m.season_id);
 perform private.recompute_cards(p_m.season_id, null);
 perform private.close_month(p_m.pelada_id, private.pelada_local_date(p_m.pelada_id, p_m.played_at));
 for v_mem in select membership_id from public.player_career_stats where pelada_id=p_m.pelada_id
   union select membership_id from public.player_sticker_progress where pelada_id=p_m.pelada_id loop
  perform private.reconcile_sticker_unlocks(v_mem);
 end loop;
 perform set_config('minuto91.rating_event', '', true);
 perform set_config('minuto91.quiet_effects', '', true);
end $$;

---------------------------------------------------------------------------------------------------
-- Anular
---------------------------------------------------------------------------------------------------
drop function if exists public.annul_match(uuid,text,text,boolean);
create function public.annul_match(p_match uuid, p_reason_category text, p_description text,
 p_confirm boolean, p_preview_token text, p_request_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_desc text := nullif(btrim(p_description),''); v_prev jsonb; v_ev uuid := gen_random_uuid();
 v_done private.match_status_events; v_s public.rating_vote_sessions; v_old private.rating_vote_suspensions;
 v_prev_status text; v_awards uuid[]; v_sel uuid[];
begin
 if p_request_id is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
 v_m := private.lock_annullable_match(p_match);
 select * into v_done from private.match_status_events where request_id=p_request_id;
 if found then
  if v_done.match_id <> p_match or v_done.kind <> 'annulment' then raise exception 'REQUEST_ID_REUSED'; end if;
  return jsonb_build_object('annulled',true,'already_processed',true,'operation_id',v_done.id);
 end if;
 if v_m.status='annulled' then raise exception 'MATCH_ALREADY_ANNULLED'; end if;
 if v_m.status <> 'finalized' then raise exception 'MATCH_NOT_FINALIZED'; end if;
 if p_reason_category is null or p_reason_category not in ('sheet_error','duplicate_match','match_not_played','other') then
  raise exception 'INVALID_REASON_CATEGORY'; end if;
 if v_desc is null or length(v_desc) not between 10 and 1000 then raise exception 'DESCRIPTION_REQUIRED'; end if;
 if p_confirm is distinct from true then raise exception 'CONFIRMATION_REQUIRED'; end if;
 v_prev := private.match_status_preview(v_m, 'annulment');
 if p_preview_token is distinct from v_prev->>'preview_token' then raise exception 'PREVIEW_OUTDATED'; end if;

 -- Votação: preserva sessão e votos, guarda o estado anterior e suspende.
 select * into v_s from public.rating_vote_sessions where match_id=p_match for update;
 if found then
  select * into v_old from private.rating_vote_suspensions where session_id=v_s.id and resolved_at is null for update;
  v_prev_status := case when v_old.id is not null then v_old.previous_status
   else private.rating_vote_effective_status(v_s) end;
  if v_old.id is not null then
   update private.rating_vote_suspensions set resolved_at=now(), resolution='superseded' where id=v_old.id;
  end if;
  if v_prev_status in ('open','awaiting_publication','published') then
   insert into private.rating_vote_suspensions(session_id,cycle_id,previous_status,previous_closes_at)
   values(v_s.id, v_ev, v_prev_status, coalesce(v_old.previous_closes_at, v_s.closes_at));
  end if;
  update private.rating_vote_reopenings set closed_at=now() where session_id=v_s.id and closed_at is null;
  update public.rating_vote_sessions set status='cancelled' where id=v_s.id and status<>'cancelled';
 end if;

 update public.matches set status='annulled' where id=p_match;
 select coalesce(array_agg(id),'{}') into v_awards from public.awards where match_id=p_match and status='active';
 update public.awards set status='revoked', revoked_at=now() where id = any(v_awards);
 select coalesce(array_agg(id),'{}') into v_sel from public.round_selections where match_id=p_match and status='published';
 update public.round_selections set status='revoked' where id = any(v_sel);

 insert into private.match_status_events(id,pelada_id,match_id,kind,cycle_id,request_id,reason_category,description,
  actor_user_id,preview_token,effects)
 values(v_ev,v_m.pelada_id,p_match,'annulment',v_ev,p_request_id,p_reason_category,v_desc,auth.uid(),
  v_prev->>'preview_token', jsonb_build_object('awards_revoked',to_jsonb(v_awards),'selections_revoked',to_jsonb(v_sel),
   'voting_previous_status',v_prev_status,'preview',v_prev - 'preview_token'));
 insert into public.match_annulments(pelada_id,match_id,reason_category,description,annulled_by,status_event_id)
 values(v_m.pelada_id,p_match,p_reason_category,v_desc,auth.uid(),v_ev);

 perform private.apply_match_status_effects(v_m, 'annulment');

 -- Por último (depois de tudo consistente): auditoria -> notificação coletiva na mesma transação.
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),'match_annulled',jsonb_build_object('match_id',p_match,
  'operation_id',v_ev,'annulment_id',v_ev,'reason_category',p_reason_category));
 return jsonb_build_object('annulled',true,'already_processed',false,'operation_id',v_ev,'annulment_id',v_ev);
end $$;

---------------------------------------------------------------------------------------------------
-- Restaurar
---------------------------------------------------------------------------------------------------
create function public.restore_match(p_match uuid, p_justification text, p_confirm boolean,
 p_preview_token text, p_request_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_desc text := nullif(btrim(p_justification),''); v_prev jsonb; v_ev uuid := gen_random_uuid();
 v_done private.match_status_events; v_cycle private.match_status_events; v_s public.rating_vote_sessions;
 v_sus private.rating_vote_suspensions; v_vote text := 'none'; v_awards uuid[]; v_sel uuid[];
begin
 if p_request_id is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
 v_m := private.lock_annullable_match(p_match);
 select * into v_done from private.match_status_events where request_id=p_request_id;
 if found then
  if v_done.match_id <> p_match or v_done.kind <> 'restoration' then raise exception 'REQUEST_ID_REUSED'; end if;
  return jsonb_build_object('restored',true,'already_processed',true,'operation_id',v_done.id);
 end if;
 if v_m.status <> 'annulled' then raise exception 'MATCH_NOT_ANNULLED'; end if;
 if v_desc is null or length(v_desc) not between 10 and 1000 then raise exception 'DESCRIPTION_REQUIRED'; end if;
 if p_confirm is distinct from true then raise exception 'CONFIRMATION_REQUIRED'; end if;
 v_prev := private.match_status_preview(v_m, 'restoration');
 if p_preview_token is distinct from v_prev->>'preview_token' then raise exception 'PREVIEW_OUTDATED'; end if;
 select * into v_cycle from private.match_status_events where match_id=p_match and kind='annulment'
 order by created_at desc, id desc limit 1;

 update public.matches set status='finalized' where id=p_match;
 select * into v_m from public.matches where id=p_match;

 -- Os mesmos prêmios e a mesma Seleção revogados por esta anulação voltam (sem novas linhas).
 select coalesce(array_agg(x::uuid),'{}') into v_awards
 from jsonb_array_elements_text(coalesce(v_cycle.effects->'awards_revoked','[]'::jsonb)) x;
 select coalesce(array_agg(x::uuid),'{}') into v_sel
 from jsonb_array_elements_text(coalesce(v_cycle.effects->'selections_revoked','[]'::jsonb)) x;
 update public.round_selections set status='published' where id = any(v_sel) and status='revoked';

 select * into v_s from public.rating_vote_sessions where match_id=p_match for update;
 if found then
  select * into v_sus from private.rating_vote_suspensions where session_id=v_s.id and resolved_at is null for update;
  if v_sus.id is not null then
   update private.rating_vote_suspensions set restored_at=now() where id=v_sus.id;
   if v_sus.previous_status = 'published' and private.rating_vote_sheet_compatible(v_s.id) then
    -- Publicação original de volta: mesmos resultados, mesmos prêmios, sem novo voto.
    update public.rating_vote_sessions set status='published' where id=v_s.id;
    update private.rating_vote_suspensions set resolved_at=now(), resolution='publication_restored', resolved_by=auth.uid()
    where id=v_sus.id;
    v_vote := 'publication_restored';
   elsif v_sus.previous_status = 'published' then
    update private.rating_vote_suspensions set divergent=true where id=v_sus.id;
    v_vote := 'publication_suspended';
   else
    v_vote := 'admin_decision';
   end if;
  end if;
 end if;

 -- Prêmios da votação só voltam com a publicação; os demais (objetivos) voltam sempre.
 update public.awards a set status='active', revoked_at=null
 where a.id = any(v_awards) and a.status='revoked'
  and (a.award_type not in ('match_craque','bola_murcha') or v_vote in ('publication_restored','none'))
  and a.award_type <> 'match_garcom'
  and not exists(select 1 from public.awards b where b.status='active' and b.award_type=a.award_type
   and b.membership_id=a.membership_id and b.match_id=a.match_id);

 if v_s.id is not null then perform private.compute_match_results(p_match, null); end if;

 insert into private.match_status_events(id,pelada_id,match_id,kind,cycle_id,request_id,reason_category,description,
  actor_user_id,preview_token,effects)
 values(v_ev,v_m.pelada_id,p_match,'restoration',coalesce(v_cycle.id, v_ev),p_request_id,'restoration',v_desc,auth.uid(),
  v_prev->>'preview_token', jsonb_build_object('voting',v_vote,'preview',v_prev - 'preview_token'));

 perform private.apply_match_status_effects(v_m, 'recompute');
 perform set_config('minuto91.quiet_effects', 'on', true);
 perform private.compute_round_selection(p_match) where not exists(select 1 from public.round_selections where match_id=p_match);
 perform private.after_selection_updated(p_match);
 perform set_config('minuto91.quiet_effects', '', true);

 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),'match_restored',jsonb_build_object('match_id',p_match,'operation_id',v_ev,
  'cycle_id',v_cycle.id,'voting',v_vote));
 return jsonb_build_object('restored',true,'already_processed',false,'operation_id',v_ev,'voting',v_vote);
end $$;

---------------------------------------------------------------------------------------------------
-- Votação interrompida: decisão da administração depois da restauração
---------------------------------------------------------------------------------------------------
-- p_mode: 'resume' (prazo original ainda não venceu), 'publish' (publicar os votos preservados),
-- 'reopen' (reabrir por p_hours de 1 a 24, uma vez por ciclo) ou 'restore_publication' (publicada e
-- divergente, depois de a súmula voltar a ser compatível).
create function public.reactivate_rating_vote(p_session uuid, p_mode text, p_hours integer, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s public.rating_vote_sessions; v_sus private.rating_vote_suspensions; v_reason text := nullif(btrim(p_reason),'');
 v_close timestamptz; v_reopen uuid; v_cycle private.match_status_events;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_s from public.rating_vote_sessions where id=p_session;
 if not found then raise exception 'SESSION_NOT_FOUND'; end if;
 perform private.lock_annullable_match(v_s.match_id);
 select * into v_s from public.rating_vote_sessions where id=p_session for update;
 if (select status from public.matches where id=v_s.match_id) <> 'finalized' then raise exception 'VOTING_SUSPENDED'; end if;
 select * into v_sus from private.rating_vote_suspensions where session_id=p_session and resolved_at is null for update;
 if not found or v_sus.restored_at is null then raise exception 'NOTHING_TO_REACTIVATE'; end if;
 if v_reason is null or length(v_reason) not between 3 and 500 then raise exception 'REASON_REQUIRED'; end if;
 select * into v_cycle from private.match_status_events where id=v_sus.cycle_id;

 if p_mode = 'restore_publication' then
  if v_sus.previous_status <> 'published' then raise exception 'INVALID_MODE'; end if;
  if not private.rating_vote_sheet_compatible(p_session) then raise exception 'SHEET_DIVERGENT'; end if;
  update public.rating_vote_sessions set status='published' where id=p_session;
  update public.awards a set status='active', revoked_at=null
  where a.id in (select x::uuid from jsonb_array_elements_text(coalesce(v_cycle.effects->'awards_revoked','[]'::jsonb)) x)
   and a.status='revoked' and a.award_type in ('match_craque','bola_murcha')
   and not exists(select 1 from public.awards b where b.status='active' and b.award_type=a.award_type
    and b.membership_id=a.membership_id and b.match_id=a.match_id);
  perform private.compute_match_results(v_s.match_id, null);
  perform set_config('minuto91.quiet_effects', 'on', true);
  perform set_config('minuto91.rating_event', 'recompute', true);
  perform private.after_match_finalized(v_s.match_id);
  perform set_config('minuto91.rating_event', '', true);
  perform set_config('minuto91.quiet_effects', '', true);
  update private.rating_vote_suspensions set resolved_at=now(), resolution='publication_restored', resolved_by=auth.uid()
  where id=v_sus.id;
 elsif v_sus.previous_status = 'published' then
  raise exception 'INVALID_MODE';
 elsif p_mode = 'resume' then
  if v_sus.previous_closes_at <= clock_timestamp() then raise exception 'ORIGINAL_DEADLINE_PASSED'; end if;
  update public.rating_vote_sessions set status='open', closes_at=v_sus.previous_closes_at where id=p_session;
  update private.rating_vote_suspensions set resolved_at=now(), resolution='resumed', resolved_by=auth.uid() where id=v_sus.id;
 elsif p_mode = 'publish' then
  if v_sus.previous_closes_at > clock_timestamp() then raise exception 'ORIGINAL_DEADLINE_NOT_PASSED'; end if;
  update public.rating_vote_sessions set status='awaiting_publication', closes_at=v_sus.previous_closes_at where id=p_session;
  update private.rating_vote_suspensions set resolved_at=now(), resolution='published', resolved_by=auth.uid() where id=v_sus.id;
  perform private.publish_rating_vote_core(p_session, auth.uid());
 elsif p_mode = 'reopen' then
  if v_sus.previous_closes_at > clock_timestamp() then raise exception 'ORIGINAL_DEADLINE_NOT_PASSED'; end if;
  if p_hours is null or p_hours not between 1 and 24 then raise exception 'INVALID_REOPEN_HOURS'; end if;
  if exists(select 1 from private.rating_vote_reopenings where cycle_id=v_sus.cycle_id) then
   raise exception 'REOPEN_ALREADY_USED'; end if;
  v_close := clock_timestamp() + make_interval(hours => p_hours);
  insert into private.rating_vote_reopenings(session_id,cycle_id,suspension_id,opened_by,reason,closes_at)
  values(p_session,v_sus.cycle_id,v_sus.id,auth.uid(),v_reason,v_close) returning id into v_reopen;
  -- O prazo original fica registrado (original_closes_at e a suspensão); a prorrogação comum não é tocada.
  update public.rating_vote_sessions set status='open', closes_at=v_close where id=p_session;
  update private.rating_vote_suspensions set resolved_at=now(), resolution='reopened', resolved_by=auth.uid() where id=v_sus.id;
  perform private.notify(pm.user_id, v_s.pelada_id, 'voting_reopened', 'essential', 'rvreopen:'||v_reopen||':'||pm.user_id,
   jsonb_build_object('pelada_id',v_s.pelada_id,'match_id',v_s.match_id,'closes_at',v_close))
  from public.rating_vote_participants t join public.pelada_memberships pm on pm.id=t.membership_id
  where t.session_id=p_session and pm.user_id is not null and pm.status in ('active','left')
   and not private.account_blocked(pm.user_id);
 else
  raise exception 'INVALID_MODE';
 end if;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_s.pelada_id,auth.uid(),'rating_vote_reactivated',jsonb_build_object('session_id',p_session,'match_id',v_s.match_id,
  'mode',p_mode,'cycle_id',v_sus.cycle_id,'reopening_id',v_reopen,'closes_at',v_close,'reason',v_reason));
 return public.get_rating_vote(v_s.match_id);
end $$;

---------------------------------------------------------------------------------------------------
-- Linha do tempo: resumida para jogadores, detalhada só para a administração
---------------------------------------------------------------------------------------------------
create function private.can_read_match_history(p_match uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.matches m where m.id=p_match and m.status <> 'draft' and (
  private.is_active_member(m.pelada_id)
  or exists(select 1 from public.match_participants p join public.pelada_memberships pm on pm.id=p.membership_id
   where p.match_id=m.id and pm.user_id=(select auth.uid()) and pm.status='left')));
$$;

create function public.get_match_status_history(p_match uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_m public.matches;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.can_read_match_history(p_match) then raise exception 'MATCH_NOT_FOUND'; end if;
 select * into v_m from public.matches where id=p_match;
 return jsonb_build_object('match_id', v_m.id, 'status', v_m.status, 'played_at', v_m.played_at,
  'team_a_name', v_m.team_a_name, 'team_b_name', v_m.team_b_name,
  'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.created_at,
     'reason_category', case when e.kind='annulment' then e.reason_category end) order by e.created_at, e.id)
   from private.match_status_events e where e.match_id=p_match), '[]'::jsonb));
end $$;

create function public.get_match_status_history_admin(p_match uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_m public.matches;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match;
 if not found or not private.is_active_admin(v_m.pelada_id) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 return jsonb_build_object('match_id', v_m.id, 'status', v_m.status,
  'team_a_score', v_m.team_a_score, 'team_b_score', v_m.team_b_score,
  'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'cycle_id', e.cycle_id, 'at', e.created_at,
     'reason_category', e.reason_category, 'description', e.description,
     'actor_name', (select pr.display_name from public.profiles pr where pr.id=e.actor_user_id),
     'effects', e.effects) order by e.created_at, e.id)
   from private.match_status_events e where e.match_id=p_match), '[]'::jsonb),
  'voting', (select jsonb_build_object('session_id', s.id, 'status', s.status,
     'original_closes_at', s.original_closes_at, 'closes_at', s.closes_at,
     'suspension', (select jsonb_build_object('previous_status', x.previous_status, 'previous_closes_at', x.previous_closes_at,
        'restored_at', x.restored_at, 'divergent', x.divergent, 'cycle_id', x.cycle_id,
        'reopen_used', exists(select 1 from private.rating_vote_reopenings r where r.cycle_id=x.cycle_id))
       from private.rating_vote_suspensions x where x.session_id=s.id and x.resolved_at is null),
     'reopenings', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'cycle_id', r.cycle_id, 'opened_at', r.opened_at,
        'closes_at', r.closes_at, 'closed_at', r.closed_at, 'reason', r.reason,
        'votes', (select count(*) from private.rating_vote_versions v where v.reopening_id=r.id))
        order by r.opened_at), '[]'::jsonb) from private.rating_vote_reopenings r where r.session_id=s.id))
   from public.rating_vote_sessions s where s.match_id=p_match));
end $$;

---------------------------------------------------------------------------------------------------
-- Correção da súmula
---------------------------------------------------------------------------------------------------
-- Invalida (sem apagar) os votos de/para quem não está mais na lista e revalida os que voltaram.
create function private.rating_vote_sync_eligibility(p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 with inv as (
  update private.rating_votes r set invalidated_at=now(), invalid_reason='ineligible'
  where r.session_id=p_session and r.invalidated_at is null and (
   not exists(select 1 from public.rating_vote_participants t where t.session_id=p_session and t.membership_id=r.voter_membership_id)
   or not exists(select 1 from public.rating_vote_participants t where t.session_id=p_session and t.membership_id=r.target_membership_id))
  returning r.voter_membership_id, r.target_membership_id)
 insert into private.rating_vote_versions(session_id,voter_membership_id,kind,target_membership_id,reason)
 select p_session, voter_membership_id, 'invalidated', target_membership_id, 'ineligible' from inv;
 with rev as (
  update private.rating_votes r set invalidated_at=null, invalid_reason=null
  where r.session_id=p_session and r.invalid_reason='ineligible'
   and exists(select 1 from public.rating_vote_participants t where t.session_id=p_session and t.membership_id=r.voter_membership_id)
   and exists(select 1 from public.rating_vote_participants t where t.session_id=p_session and t.membership_id=r.target_membership_id)
  returning r.voter_membership_id, r.target_membership_id)
 insert into private.rating_vote_versions(session_id,voter_membership_id,kind,target_membership_id,reason)
 select p_session, voter_membership_id, 'revalidated', target_membership_id, 'eligible_again' from rev;
 update private.rating_vote_awards w set invalidated_at=now(), invalid_reason='ineligible'
 where w.session_id=p_session and w.invalidated_at is null and (
  not exists(select 1 from public.rating_vote_participants t where t.session_id=p_session and t.membership_id=w.voter_membership_id)
  or (w.target_membership_id is not null and not exists(select 1 from public.rating_vote_participants t
   where t.session_id=p_session and t.membership_id=w.target_membership_id)));
 update private.rating_vote_awards w set invalidated_at=null, invalid_reason=null
 where w.session_id=p_session and w.invalid_reason='ineligible'
  and exists(select 1 from public.rating_vote_participants t where t.session_id=p_session and t.membership_id=w.voter_membership_id)
  and (w.target_membership_id is null or exists(select 1 from public.rating_vote_participants t
   where t.session_id=p_session and t.membership_id=w.target_membership_id));
end $$;

create or replace function public.correct_match_sheet(p_match uuid, p_participants jsonb, p_events jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_m public.matches; v_reason text := nullif(btrim(p_reason),'');
 v_before jsonb; v_after jsonb; v_old uuid[]; v_changed boolean; v_r jsonb; v_version int;
 v_s public.rating_vote_sessions; v_stats_before jsonb; v_changed_players uuid[]; v_exceptional boolean := false;
 v_sus private.rating_vote_suspensions; v_teams_before jsonb; v_teams_after jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_pelada for update;
 if not private.is_active_staff(v_pelada) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match for update;
 if v_m.status='draft' then raise exception 'MATCH_IS_DRAFT'; end if;
 if v_m.status='annulled' then raise exception 'MATCH_ANNULLED'; end if;
 if v_m.status='finalized' then
  select * into v_s from public.rating_vote_sessions where match_id=p_match for update;
  if not found then raise exception 'SHEET_LOCKED'; end if;
  select * into v_sus from private.rating_vote_suspensions where session_id=v_s.id and resolved_at is null;
  if v_s.status in ('open','awaiting_publication') then
   null;
  elsif v_s.status = 'published' or (v_sus.id is not null and v_sus.previous_status='published') then
   -- Fluxo excepcional: só a administração e só sem mudar eleitorado nem avaliados.
   if not private.is_active_admin(v_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
   v_exceptional := true;
  else
   raise exception 'SHEET_LOCKED';
  end if;
 elsif v_m.status <> 'voting_open' then raise exception 'SHEET_LOCKED';
 end if;
 if v_reason is null or length(v_reason) not between 3 and 500 then raise exception 'REASON_REQUIRED'; end if;

 v_before := private.sheet_snapshot(p_match);
 if not exists(select 1 from public.match_versions where match_id=p_match and version_number=v_m.sheet_version) then
  insert into public.match_versions(pelada_id,match_id,version_number,snapshot)
  values(v_pelada,p_match,v_m.sheet_version,v_before);
 end if;
 v_old := private.sheet_voter_memberships(p_match);
 select coalesce(jsonb_object_agg(p.membership_id::text, jsonb_build_array(
   coalesce((select sum(quantity) from public.match_events e where e.participant_id=p.id and e.event_type='goal'),0),
   coalesce((select sum(quantity) from public.match_events e where e.participant_id=p.id and e.event_type='assist'),0))),'{}')
 into v_stats_before from public.match_participants p where p.match_id=p_match and p.membership_id is not null;
 select coalesce(jsonb_object_agg(p.membership_id::text, p.team),'{}') into v_teams_before
 from public.match_participants p where p.match_id=p_match and p.membership_id is not null;

 v_r := private.write_match_sheet(v_m, p_participants, p_events);
 v_after := private.sheet_snapshot(p_match);
 if v_after = v_before then raise exception 'NO_CHANGES'; end if;
 v_changed := v_old is distinct from private.sheet_voter_memberships(p_match);
 select coalesce(jsonb_object_agg(p.membership_id::text, p.team),'{}') into v_teams_after
 from public.match_participants p where p.match_id=p_match and p.membership_id is not null;
 if v_exceptional and v_teams_after is distinct from v_teams_before then
  raise exception 'CORRECTION_CHANGES_ELECTORATE';
 end if;

 update public.matches set sheet_version=sheet_version+1 where id=p_match returning sheet_version into v_version;
 insert into public.match_versions(pelada_id,match_id,version_number,changed_by,change_reason,snapshot,eligible_voters_changed)
 values(v_pelada,p_match,v_version,auth.uid(),v_reason,v_after,v_changed);
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_pelada,auth.uid(),'match_sheet_corrected',jsonb_build_object(
  'match_id',p_match,'sheet_version',v_version,'eligible_voters_changed',v_changed,'exceptional',v_exceptional,
  'before_version',v_version-1,'after_version',v_version));

 if v_m.status='voting_open' then
  perform private.on_sheet_corrected(p_match, v_changed);
 else
  if v_exceptional then
   -- Mesmo eleitorado: só religa os participantes recriados e registra a versão compatível.
   update public.rating_vote_participants t set participant_id=p.id
   from public.match_participants p where t.session_id=v_s.id and p.match_id=p_match and p.membership_id=t.membership_id;
   update public.rating_vote_sessions set published_sheet_version=v_version where id=v_s.id;
  else
   delete from public.rating_vote_participants t where t.session_id=v_s.id
    and not exists(select 1 from private.rating_voters(p_match) v where v.membership_id=t.membership_id);
   insert into public.rating_vote_participants(session_id,pelada_id,membership_id,participant_id,team)
   select v_s.id, v_pelada, v.membership_id, v.participant_id, p.team
   from private.rating_voters(p_match) v join public.match_participants p on p.id=v.participant_id
   on conflict (session_id, membership_id) do update set team=excluded.team, participant_id=excluded.participant_id;
   perform private.rating_vote_sync_eligibility(v_s.id);
   select coalesce(array_agg(p.membership_id),'{}') into v_changed_players
   from public.match_participants p where p.match_id=p_match and p.membership_id is not null
    and (v_stats_before->(p.membership_id::text)) is distinct from jsonb_build_array(
     coalesce((select sum(quantity) from public.match_events e where e.participant_id=p.id and e.event_type='goal'),0),
     coalesce((select sum(quantity) from public.match_events e where e.participant_id=p.id and e.event_type='assist'),0));
   if v_s.status='open' and clock_timestamp() < v_s.closes_at then
    perform private.notify(pm.user_id, v_pelada, 'sheet_corrected', 'essential',
     'rvfix:'||v_s.id||':'||v_version||':'||pm.user_id, jsonb_build_object('pelada_id',v_pelada,'match_id',p_match))
    from (select distinct r.voter_membership_id m from private.rating_votes r
      where r.session_id=v_s.id and r.invalidated_at is null and r.target_membership_id = any(v_changed_players)) a
    join public.pelada_memberships pm on pm.id=a.m where pm.user_id is not null;
   end if;
  end if;
  perform private.compute_match_results(p_match, null);
  perform set_config('minuto91.rating_event', 'sheet_corrected', true);
  perform private.after_match_finalized(p_match);
  perform set_config('minuto91.rating_event', '', true);
 end if;
 return v_r || jsonb_build_object('sheet_version',v_version,'eligible_voters_changed',v_changed)
  || case when v_exceptional then jsonb_build_object('exceptional',true) else '{}'::jsonb end;
end $$;

revoke all on function private.status_events_immutable(), private.quiet_effects(), private.rating_vote_sheet_compatible(uuid),
 private.match_status_preview(public.matches,text), private.apply_match_status_effects(public.matches,text),
 private.can_read_match_history(uuid), private.rating_vote_sync_eligibility(uuid) from public, anon, authenticated;
revoke all on function public.preview_match_restoration(uuid), public.annul_match(uuid,text,text,boolean,text,uuid),
 public.restore_match(uuid,text,boolean,text,uuid), public.reactivate_rating_vote(uuid,text,integer,text),
 public.get_match_status_history(uuid), public.get_match_status_history_admin(uuid) from public, anon;
grant execute on function public.preview_match_restoration(uuid), public.annul_match(uuid,text,text,boolean,text,uuid),
 public.restore_match(uuid,text,boolean,text,uuid), public.reactivate_rating_vote(uuid,text,integer,text),
 public.get_match_status_history(uuid), public.get_match_status_history_admin(uuid) to authenticated;

-- ===== 055_v77_account_deletion.sql =====
-- Minuto 91 / 055: V7.7, bloco F - exclusão de conta e recuperação.
--
-- - Durante os 30 dias de exclusão reversível a vaga do jogador em cada pelada fica RESERVADA e conta no limite
--   de 100 (private.pelada_seat_count). Cancelar dentro do prazo devolve as participações no mesmo registro
--   (sem associação duplicada). Se uma pelada antiga já estava cheia antes desta regra (legado), a participação
--   volta como "saiu" com o nome de volta, e a resposta diz quais peladas não puderam ser recuperadas (nada de
--   recuperação parcial silenciosa).
-- - Exclusão definitiva idempotente em etapas com checkpoint: votos individuais sem fundamento de retenção
--   (sessões já publicadas) -> dados pessoais e anonimização das participações -> conta de login. A solicitação
--   só vira 'completed' quando TODAS as etapas terminaram. Falha na etapa de login: fica 'pending', com código
--   do erro (sem dados pessoais), nova tentativa com espera crescente (5 min x 2^n, até 6 h) e alerta depois de
--   5 tentativas (private.account_purge_alerts). A conta segue bloqueada para uso normal até o fim.
-- - Resultados esportivos oficiais ficam (como "Aposentado", sem vínculo com a pessoa).
-- - Etapa externa (Supabase Auth): se o banco não puder apagar auth.users, a Edge Function account-purge
--   apaga pela API administrativa e chama complete_account_purge_auth (service_role).
-- Rollback: restaurar request_account_deletion/cancel_account_deletion/purge_account (036), join_pelada (004),
-- run_scheduled_tasks (036) e get_account_status (021); dropar as colunas novas.

alter table private.account_deletion_requests
 add column attempts integer not null default 0,
 add column next_attempt_at timestamptz,
 add column last_error_code text,
 add column checkpoints jsonb not null default '{}'::jsonb,
 add column alerted_at timestamptz;

-- Legado: solicitações marcadas 'completed' com falha no login voltam a pendentes (a conta de login ainda existe).
update private.account_deletion_requests r set status='pending', last_error_code=r.error_code,
 checkpoints=jsonb_build_object('votes',true,'personal',true)
where r.status='completed' and r.error_code='AUTH_DELETE_FAILED'
 and exists(select 1 from auth.users u where u.id=r.user_id)
 and not exists(select 1 from private.account_deletion_requests x where x.user_id=r.user_id and x.status='pending');

-- Vagas ocupadas: ativos + reservados por exclusão pendente.
create function private.pelada_seat_count(p_pelada uuid) returns integer
language sql stable security definer set search_path = '' as $$
 select count(*)::int from public.pelada_memberships m
 where m.pelada_id=p_pelada and (m.status='active' or (m.status='retired' and m.user_id is not null
  and exists(select 1 from private.account_deletion_requests r where r.user_id=m.user_id and r.status='pending')));
$$;

create or replace function public.join_pelada(p_invite_token text, p_position text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_inv private.pelada_invites%rowtype; v_membership uuid; v_name text;
 v_existing public.pelada_memberships%rowtype;
begin
 if v_user is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform private.require_onboarded();
 if p_invite_token is null or p_invite_token !~ '^[0-9a-f]{64}$' then
  raise exception 'INVALID_INVITE'; end if;
 if p_position is not null and not private.valid_position(p_position) then raise exception 'INVALID_POSITION'; end if;
 select * into v_inv from private.pelada_invites
 where token_hash=encode(extensions.digest(p_invite_token,'sha256'),'hex') for update;
 if not found or v_inv.revoked_at is not null or v_inv.expires_at<=now() or v_inv.uses>=v_inv.max_uses then
  raise exception 'INVALID_OR_EXPIRED_INVITE'; end if;
 perform 1 from public.peladas where id=v_inv.pelada_id and status='active' for update;
 if not found then raise exception 'PELADA_NOT_ACTIVE'; end if;
 select display_name into v_name from public.profiles where id=v_user;
 if v_name is null then raise exception 'PROFILE_REQUIRED'; end if;
 select * into v_existing from public.pelada_memberships
 where pelada_id=v_inv.pelada_id and user_id=v_user for update;
 if found and v_existing.status='active' then return v_existing.id; end if;
 if found and v_existing.status in ('suspended','retired') then raise exception 'MEMBERSHIP_NOT_REJOINABLE'; end if;
 if private.pelada_seat_count(v_inv.pelada_id) >= 100 then raise exception 'PELADA_FULL'; end if;
 if v_existing.id is not null then
  update public.pelada_memberships set status='active', role='player', assistant_since=null,
   player_name=v_name, preferred_position=coalesce(p_position, preferred_position)
  where id=v_existing.id returning id into v_membership;
 else
  if p_position is null then raise exception 'POSITION_REQUIRED'; end if;
  insert into public.pelada_memberships(pelada_id,user_id,player_name,preferred_position)
  values(v_inv.pelada_id,v_user,v_name,p_position) returning id into v_membership;
 end if;
 update private.pelada_invites set uses=uses+1 where id=v_inv.id;
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type)
 values(v_inv.pelada_id,v_user,v_membership,case when v_existing.id is not null then 'member_rejoined' else 'member_joined' end);
 return v_membership;
end $$;

create or replace function public.cancel_account_deletion() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_req private.account_deletion_requests; s jsonb; v_restored integer := 0;
 v_blocked jsonb := '[]'::jsonb; v_active integer;
begin
 if v_user is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_req from private.account_deletion_requests where user_id=v_user and status='pending' for update;
 if not found or v_req.purge_after <= now() then raise exception 'NO_PENDING_DELETION'; end if;
 for s in select * from jsonb_array_elements(v_req.memberships_snapshot) order by value->>'pelada_id' loop
  perform 1 from public.peladas where id=(s->>'pelada_id')::uuid for update;
  if coalesce(s->>'status','active') = 'active' then
   -- A vaga estava reservada: só os outros ativos contam. Excesso só existe em dado legado.
   select count(*) into v_active from public.pelada_memberships x
   where x.pelada_id=(s->>'pelada_id')::uuid and x.status='active' and x.id <> (s->>'membership_id')::uuid;
   if v_active < 100 then
    update public.pelada_memberships set status='active', role='player', assistant_since=null,
     player_name=s->>'player_name'
    where id=(s->>'membership_id')::uuid and user_id=v_user and status='retired';
    if found then v_restored := v_restored + 1; end if;
   else
    update public.pelada_memberships set status='left', player_name=s->>'player_name'
    where id=(s->>'membership_id')::uuid and user_id=v_user and status='retired';
    v_blocked := v_blocked || jsonb_build_object('pelada_id', s->>'pelada_id', 'reason', 'PELADA_FULL_LEGACY');
   end if;
  else
   update public.pelada_memberships set player_name=s->>'player_name'
   where id=(s->>'membership_id')::uuid and user_id=v_user and status=s->>'status';
  end if;
 end loop;
 update private.account_deletion_requests set status='cancelled', processed_at=now(), memberships_snapshot='[]'
 where id=v_req.id;
 insert into private.audit_events(actor_user_id,event_type,metadata)
 values(v_user,'account_deletion_cancelled',jsonb_build_object('request_id',v_req.id,'restored',v_restored,
  'not_restored',jsonb_array_length(v_blocked)));
 return jsonb_build_object('restored_memberships',v_restored,'not_restored',v_blocked);
end $$;

-- Exclusão definitiva em etapas. Chamada pelo agendador; reentrante (cada etapa tem checkpoint).
create or replace function private.purge_account(p_request uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_req private.account_deletion_requests; v_state text; v_wait interval;
begin
 select * into v_req from private.account_deletion_requests where id=p_request and status='pending' for update;
 if not found or v_req.purge_after > now() then return; end if;

 -- 1. Votos individuais de sessões já publicadas: o resultado oficial fica; a escolha individual sai.
 if not coalesce((v_req.checkpoints->>'votes')::boolean, false) then
  perform set_config('minuto91.vote_purge','on',true);
  delete from private.rating_vote_versions v using public.pelada_memberships pm, public.rating_vote_sessions s
   where pm.id=v.voter_membership_id and pm.user_id=v_req.user_id and s.id=v.session_id and (s.status='published'
    or exists(select 1 from private.rating_vote_suspensions x where x.session_id=s.id and x.resolved_at is null
     and x.previous_status='published'));
  delete from private.rating_votes v using public.pelada_memberships pm, public.rating_vote_sessions s
   where pm.id=v.voter_membership_id and pm.user_id=v_req.user_id and s.id=v.session_id and (s.status='published'
    or exists(select 1 from private.rating_vote_suspensions x where x.session_id=s.id and x.resolved_at is null
     and x.previous_status='published'));
  delete from private.rating_vote_awards v using public.pelada_memberships pm, public.rating_vote_sessions s
   where pm.id=v.voter_membership_id and pm.user_id=v_req.user_id and s.id=v.session_id and (s.status='published'
    or exists(select 1 from private.rating_vote_suspensions x where x.session_id=s.id and x.resolved_at is null
     and x.previous_status='published'));
  delete from private.rating_vote_progress v using public.pelada_memberships pm
   where pm.id=v.voter_membership_id and pm.user_id=v_req.user_id;
  perform set_config('minuto91.vote_purge','',true);
  v_req.checkpoints := v_req.checkpoints || '{"votes":true}';
  update private.account_deletion_requests set checkpoints=v_req.checkpoints where id=p_request;
 end if;

 -- 2. Dados pessoais e vínculo das participações (o registro esportivo fica como "Aposentado").
 if not coalesce((v_req.checkpoints->>'personal')::boolean, false) then
  update public.pelada_memberships set player_name='Aposentado',
   status=case when status='active' then 'retired' else status end, user_id=null
  where user_id=v_req.user_id;
  update public.content_reports set reporter_user_id=null where reporter_user_id=v_req.user_id;
  delete from public.user_blocks where blocker_user_id=v_req.user_id or blocked_user_id=v_req.user_id;
  delete from public.push_devices where user_id=v_req.user_id;
  delete from public.notification_events where user_id=v_req.user_id;
  delete from public.profiles where id=v_req.user_id;
  v_req.checkpoints := v_req.checkpoints || '{"personal":true}';
  update private.account_deletion_requests set checkpoints=v_req.checkpoints, memberships_snapshot='[]' where id=p_request;
 end if;

 -- 3. Conta de login. Falha não conclui: tenta de novo depois.
 begin
  delete from auth.users where id=v_req.user_id;
 exception when others then
  get stacked diagnostics v_state = returned_sqlstate;
  v_wait := least(interval '6 hours', make_interval(mins => 5 * (2 ^ least(v_req.attempts, 7))::int));
  update private.account_deletion_requests set attempts=attempts+1, last_error_code='AUTH_DELETE_FAILED:'||v_state,
   error_code='AUTH_DELETE_FAILED', next_attempt_at=now()+v_wait,
   alerted_at=case when attempts+1 >= 5 and alerted_at is null then now() else alerted_at end
  where id=p_request;
  if v_req.attempts + 1 = 5 then
   insert into private.audit_events(event_type,metadata)
   values('account_purge_stuck',jsonb_build_object('request_id',p_request,'error_code','AUTH_DELETE_FAILED:'||v_state));
  end if;
  return;
 end;
 perform private.finish_account_purge(p_request);
end $$;

create function private.finish_account_purge(p_request uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 update private.account_deletion_requests set status='completed', processed_at=now(), error_code=null, last_error_code=null,
  next_attempt_at=null, memberships_snapshot='[]', checkpoints=checkpoints || '{"auth":true}'
 where id=p_request and status='pending';
 if found then
  insert into private.audit_events(event_type,metadata) values('account_purged',jsonb_build_object('request_id',p_request));
 end if;
end $$;

-- Etapa externa (Edge Function account-purge, service_role): lista o que espera a API de Auth e confirma.
create function public.list_pending_auth_purges(p_limit integer default 20) returns table(request_id uuid, user_id uuid)
language sql stable security definer set search_path = '' as $$
 select r.id, r.user_id from private.account_deletion_requests r
 where r.status='pending' and r.purge_after <= now() and coalesce((r.checkpoints->>'personal')::boolean,false)
  and r.error_code='AUTH_DELETE_FAILED'
 order by r.requested_at limit greatest(1, least(coalesce(p_limit,20), 100));
$$;

create function public.complete_account_purge_auth(p_request uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_req private.account_deletion_requests;
begin
 select * into v_req from private.account_deletion_requests where id=p_request and status='pending' for update;
 if not found then return false; end if;
 if not coalesce((v_req.checkpoints->>'personal')::boolean,false) then raise exception 'PURGE_STEPS_PENDING'; end if;
 if exists(select 1 from auth.users where id=v_req.user_id) then raise exception 'AUTH_USER_STILL_EXISTS'; end if;
 perform private.finish_account_purge(p_request);
 return true;
end $$;

create view private.account_purge_alerts as
 select id request_id, requested_at, purge_after, attempts, last_error_code, next_attempt_at, alerted_at, checkpoints
 from private.account_deletion_requests
 where status='pending' and purge_after <= now() and (attempts >= 5 or purge_after < now() - interval '1 day');

create or replace function public.get_account_status() returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('deletion_pending', r.id is not null, 'purge_after', r.purge_after,
  'state', case when r.id is null then 'active' when r.purge_after > now() then 'recoverable' else 'finalizing' end,
  'can_recover', r.id is not null and r.purge_after > now())
 from (select 1) one left join private.account_deletion_requests r
  on r.user_id=(select auth.uid()) and r.status='pending';
$$;

-- Agendador (036) com a espera entre tentativas da exclusão.
create or replace function private.run_scheduled_tasks() returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
 for r in select id from public.voting_sessions where status='open' and closes_at <= now() loop
  perform private.run_job('finalize_voting', r.id, 'select private.finalize_session($1)');
 end loop;
 perform private.notify(m.user_id, v.pelada_id, 'voting_closing_soon', 'essential',
  'closing:'||v.id||':'||m.user_id, jsonb_build_object('pelada_id',v.pelada_id,'match_id',v.match_id))
 from public.voting_sessions v join public.voting_eligible_members e on e.session_id=v.id
 join public.pelada_memberships m on m.id=e.membership_id and m.status='active' and m.user_id is not null
 where v.status='open' and v.closes_at > now() and v.closes_at <= now() + interval '1 hour'
  and not exists(select 1 from public.vote_receipts r2 where r2.session_id=v.id and r2.membership_id=e.membership_id);
 for r in select distinct m.pelada_id from public.matches m where m.status='finalized'
   and not exists(select 1 from public.monthly_closures c where c.pelada_id=m.pelada_id
    and c.period_month=date_trunc('month', private.pelada_local_date(m.pelada_id, m.played_at))::date) loop
  perform private.run_job('close_months', r.pelada_id, 'select private.close_pending_months($1, null)');
 end loop;
 for r in select id from private.account_deletion_requests where status='pending' and purge_after <= now()
   and coalesce(next_attempt_at, '-infinity'::timestamptz) <= now() loop
  perform private.run_job('purge_account', r.id, 'select private.purge_account($1)');
 end loop;
 for r in select s.id from public.seasons s where s.ends_on < private.pelada_today(s.pelada_id)
   and not exists(select 1 from private.season_cleanups c where c.season_id=s.id) loop
  perform private.run_job('cleanup_season', r.id, 'select private.cleanup_season($1)');
 end loop;
 perform private.run_job('reconcile_store_events', null, 'select private.reconcile_store_events()');
 delete from private.background_jobs where completed_at < now() - interval '90 days';
end $$;

revoke all on function private.pelada_seat_count(uuid), private.finish_account_purge(uuid) from public, anon, authenticated;
revoke all on private.account_purge_alerts from public, anon, authenticated;
revoke all on function public.list_pending_auth_purges(integer), public.complete_account_purge_auth(uuid) from public, anon, authenticated;
grant execute on function public.list_pending_auth_purges(integer), public.complete_account_purge_auth(uuid) to service_role;

-- ===== 056_v77_selection_awards.sql =====
-- Minuto 91 / 056: V7.7, bloco B e itens de prêmios.
--
-- Seleção da Rodada (algorithm_version 2):
-- - 4-3-3 (1 goleiro, 4 defensores, 3 meias, 3 atacantes). Publica só com pelo menos 11 jogadores com nota
--   oficial válida, entre eles quem possa ocupar o gol (posição principal ou secundária confirmada).
-- - Posição secundária CONFIRMADA vale tanto quanto a principal. Fora delas não há adaptação (vaga sem
--   candidato fica vazia, decisão anterior mantida).
-- - Escolha GLOBAL: a combinação de jogadores e vagas que preenche mais vagas e, entre essas, tem a maior soma de
--   notas oficiais internas (sem arredondar), sem repetir jogador. Empates exatos: prevalece a ordem
--   determinística nota, quantidade de notas válidas, nota dos votos, id (a mesma de 016). A administração não
--   escolhe manualmente.
-- Posição secundária: o jogador indica (fica pendente) e a administração confirma ou recusa; a administração
-- também pode definir direto. Entra na súmula como retrato da partida (match_participants.secondary_position),
-- só se confirmada. Não altera o motor de OVR (que usa só a principal).
-- Prêmios:
-- - Garçom da Partida (match_garcom, V4.6) excluído por completo: não é mais concedido e os troféus históricos
--   ficam revogados (a linha fica para auditoria, mas não aparece nem conta em lugar nenhum).
-- - Prêmios do mês recalculados (correções, anulação, restauração): o mesmo vencedor reaproveita o registro
--   (revogado e reativado na mesma transação), sem duplicar e sem novo aviso; quem perde fica revogado
--   (histórico preservado). Empates continuam compartilhados.
-- Rollback: recriar compute_round_selection (016), grant_month_award (015), after_cards_updated e
-- grant_match_garcom (049); reativar os match_garcom revogados por esta migração (audit 'garcom_match_removed').

---------------------------------------------------------------------------------------------------
-- Posição secundária
---------------------------------------------------------------------------------------------------
alter table public.pelada_memberships
 add column secondary_position text check (secondary_position is null or secondary_position in ('goalkeeper','defender','midfielder','attacker')),
 add column secondary_status text check (secondary_status is null or secondary_status in ('pending','confirmed')),
 add column secondary_decided_by uuid,
 add column secondary_decided_at timestamptz,
 add constraint memberships_secondary_differs check (secondary_position is null or secondary_position <> preferred_position),
 add constraint memberships_secondary_status check ((secondary_position is null) = (secondary_status is null));

alter table public.match_participants
 add column secondary_position text check (secondary_position is null or secondary_position in ('goalkeeper','defender','midfielder','attacker'));

create function private.snapshot_secondary_position() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.membership_id is not null and (tg_op='INSERT' or new.membership_id is distinct from old.membership_id) then
  select case when m.secondary_status='confirmed' then m.secondary_position end into new.secondary_position
  from public.pelada_memberships m where m.id=new.membership_id;
 end if;
 if new.secondary_position = new.primary_position then new.secondary_position := null; end if;
 return new;
end $$;
create trigger participants_secondary_snapshot before insert or update of membership_id, primary_position
 on public.match_participants for each row execute function private.snapshot_secondary_position();

-- Jogador: indica (ou limpa) a secundária; fica pendente até a administração confirmar.
create function public.request_secondary_position(p_pelada uuid, p_position text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.pelada_memberships;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.pelada_memberships where pelada_id=p_pelada and user_id=auth.uid() and status='active' for update;
 if not found then raise exception 'ACTIVE_MEMBERSHIP_REQUIRED'; end if;
 if p_position is not null and p_position not in ('goalkeeper','defender','midfielder','attacker') then
  raise exception 'INVALID_POSITION'; end if;
 if p_position = v_m.preferred_position then raise exception 'SECONDARY_EQUALS_PRIMARY'; end if;
 if p_position is not distinct from v_m.secondary_position then return; end if;
 update public.pelada_memberships set secondary_position=p_position,
  secondary_status=case when p_position is null then null else 'pending' end,
  secondary_decided_by=null, secondary_decided_at=null where id=v_m.id;
 if p_position is not null then
  perform private.notify(a.user_id, p_pelada, 'position_change_requested', 'essential', 'secreq:'||v_m.id||':'||p_position||':'||a.user_id,
   jsonb_build_object('pelada_id',p_pelada,'membership_id',v_m.id,'secondary',true))
  from public.pelada_memberships a where a.pelada_id=p_pelada and a.status='active' and a.role='admin' and a.user_id is not null;
 end if;
end $$;

-- Administração: confirma/recusa o pedido ou define direto (p_position nulo limpa).
create function public.decide_secondary_position(p_membership uuid, p_position text, p_confirm boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.pelada_memberships;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.pelada_memberships where id=p_membership for update;
 if not found or not private.is_active_admin(v_m.pelada_id) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if p_position is not null and p_position not in ('goalkeeper','defender','midfielder','attacker') then
  raise exception 'INVALID_POSITION'; end if;
 if p_position = v_m.preferred_position then raise exception 'SECONDARY_EQUALS_PRIMARY'; end if;
 if p_confirm and p_position is not null then
  update public.pelada_memberships set secondary_position=p_position, secondary_status='confirmed',
   secondary_decided_by=auth.uid(), secondary_decided_at=now() where id=v_m.id;
 else
  update public.pelada_memberships set secondary_position=null, secondary_status=null,
   secondary_decided_by=auth.uid(), secondary_decided_at=now() where id=v_m.id;
 end if;
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),v_m.id,'secondary_position_decided',jsonb_build_object('position',
  case when p_confirm then p_position end,'requested',v_m.secondary_position));
end $$;

-- A posição principal mudou para o mesmo setor da secundária: a secundária deixa de existir.
create function private.clear_secondary_on_primary() returns trigger
language plpgsql set search_path = '' as $$
begin
 if new.secondary_position is not null and new.secondary_position = new.preferred_position then
  new.secondary_position := null; new.secondary_status := null;
 end if;
 return new;
end $$;
create trigger memberships_clear_secondary before update of preferred_position on public.pelada_memberships
 for each row execute function private.clear_secondary_on_primary();

---------------------------------------------------------------------------------------------------
-- Seleção da Rodada v2: otimização global
---------------------------------------------------------------------------------------------------
create or replace function private.compute_round_selection(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c_min_eligible constant integer := 11; v_pelada uuid; v_sel uuid;
 v_ids uuid[]; v_pri text[]; v_sec text[]; v_rat numeric[]; v_n int; i int; st int; g int; d int; m int; a int;
 v_fill int[]; v_sum numeric[]; v_choice int[]; nf int; ns numeric; bf int; bs numeric; bc int; opt int; slot text;
 v_cap int[] := array[1,4,3,3]; v_states int := 160; v_slot text; v_rank int := 0;
 v_secs text[] := array['goalkeeper','defender','midfielder','attacker'];
begin
 select pelada_id into v_pelada from public.matches where id=p_match and status='finalized';
 if v_pelada is null then
  delete from public.round_selections where match_id=p_match and status='published';
  return;
 end if;
 delete from public.round_selections where match_id=p_match;
 select array_agg(r.membership_id order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id),
  array_agg(r.position_snapshot order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id),
  array_agg(p.secondary_position order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id),
  array_agg(r.final_rating order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id)
 into v_ids, v_pri, v_sec, v_rat
 from public.match_player_results r
 left join public.match_participants p on p.match_id=r.match_id and p.membership_id=r.membership_id
 where r.match_id=p_match and r.has_valid_rating and r.final_rating is not null;
 v_n := coalesce(cardinality(v_ids), 0);
 if v_n < c_min_eligible then return; end if;
 if not coalesce('goalkeeper' = any(v_pri) or 'goalkeeper' = any(v_sec), false) then return; end if;

 -- Programação dinâmica de trás para frente: estado = vagas usadas (g,d,m,a) = g*80 + d*16 + m*4 + a.
 -- dp[i][estado] = melhor (vagas preenchidas, soma) usando os jogadores i..n. Escolha: 0 fora, 1 principal,
 -- 2 secundária. Em empate exato vale a ordem: principal, secundária, fora (o jogador mais bem colocado entra).
 v_fill := array_fill(0, array[(v_n+1)*v_states]);
 v_sum := array_fill(0::numeric, array[(v_n+1)*v_states]);
 v_choice := array_fill(0, array[(v_n+1)*v_states]);
 for i in reverse v_n..1 loop
  for st in 0..v_states-1 loop
   g := st / 80; d := (st / 16) % 5; m := (st / 4) % 4; a := st % 4;
   bf := v_fill[i*v_states + st + 1]; bs := v_sum[i*v_states + st + 1]; bc := 0;
   for opt in reverse 2..1 loop
    slot := case opt when 1 then v_pri[i] else v_sec[i] end;
    if slot is null then continue; end if;
    nf := -1;
    if slot='goalkeeper' and g < 1 then nf := (g+1)*80 + d*16 + m*4 + a;
    elsif slot='defender' and d < 4 then nf := g*80 + (d+1)*16 + m*4 + a;
    elsif slot='midfielder' and m < 3 then nf := g*80 + d*16 + (m+1)*4 + a;
    elsif slot='attacker' and a < 3 then nf := g*80 + d*16 + m*4 + a + 1;
    end if;
    if nf < 0 then continue; end if;
    if v_fill[i*v_states + nf + 1] + 1 > bf or (v_fill[i*v_states + nf + 1] + 1 = bf and v_sum[i*v_states + nf + 1] + v_rat[i] >= bs) then
     bf := v_fill[i*v_states + nf + 1] + 1; bs := v_sum[i*v_states + nf + 1] + v_rat[i]; bc := opt;
    end if;
   end loop;
   v_fill[(i-1)*v_states + st + 1] := bf; v_sum[(i-1)*v_states + st + 1] := bs; v_choice[(i-1)*v_states + st + 1] := bc;
  end loop;
 end loop;

 insert into public.round_selections(pelada_id,match_id,algorithm_version) values(v_pelada,p_match,2) returning id into v_sel;
 st := 0;
 for i in 1..v_n loop
  opt := v_choice[(i-1)*v_states + st + 1];
  if opt = 0 then continue; end if;
  v_slot := case opt when 1 then v_pri[i] else v_sec[i] end;
  g := st / 80; d := (st / 16) % 5; m := (st / 4) % 4; a := st % 4;
  st := case v_slot when 'goalkeeper' then (g+1)*80 + d*16 + m*4 + a when 'defender' then g*80 + (d+1)*16 + m*4 + a
   when 'midfielder' then g*80 + d*16 + (m+1)*4 + a else g*80 + d*16 + m*4 + a + 1 end;
  v_rank := v_rank + 1;
  insert into public.round_selection_players(selection_id,membership_id,official_position,slot_position,final_rating,rank_order)
  values(v_sel, v_ids[i], v_pri[i], v_slot, v_rat[i], v_rank);
 end loop;
end $$;

---------------------------------------------------------------------------------------------------
-- Garçom da Partida: fora
---------------------------------------------------------------------------------------------------
create or replace function private.grant_match_garcom(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 null; -- V7.7: prêmio excluído
end $$;

create or replace function private.after_cards_updated(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid;
begin
 select pelada_id into v_pelada from public.matches where id=p_match;
 perform private.refresh_highlights(p_match);
 perform private.close_pending_months(v_pelada, p_match);
 perform private.after_rankings_updated(p_match);
end $$;

with g as (
 update public.awards set status='revoked', revoked_at=now() where award_type='match_garcom' and status='active' returning id)
insert into private.audit_events(event_type,metadata)
select 'garcom_match_removed', jsonb_build_object('awards', count(*)) from g;

---------------------------------------------------------------------------------------------------
-- Prêmios do mês sem duplicar nem reavisar
---------------------------------------------------------------------------------------------------
create or replace function private.grant_month_award(p_pelada uuid, p_season uuid, p_month date, p_type text,
 p_winners uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare w uuid; v_w uuid[];
begin
 -- RN-106 (021): aposentado não recebe prêmio novo.
 select coalesce(array_agg(m.id),'{}') into v_w from public.pelada_memberships m where m.id = any(p_winners) and m.status<>'retired';
 foreach w in array v_w loop
  update public.awards set status='active', revoked_at=null, is_shared=cardinality(v_w) > 1, season_id=p_season
  where id = (select id from public.awards where pelada_id=p_pelada and award_type=p_type and membership_id=w
   and period_month=p_month and status='revoked' and revoked_at=now() order by created_at desc limit 1);
  if not found and not exists(select 1 from public.awards where pelada_id=p_pelada and award_type=p_type
    and membership_id=w and period_month=p_month and status='active') then
   insert into public.awards(pelada_id,season_id,membership_id,award_type,period_month,is_shared)
   values(p_pelada, p_season, w, p_type, p_month, cardinality(v_w) > 1);
  end if;
 end loop;
end $$;

revoke all on function private.snapshot_secondary_position(), private.clear_secondary_on_primary() from public, anon, authenticated;
revoke all on function public.request_secondary_position(uuid,text), public.decide_secondary_position(uuid,text,boolean) from public, anon;
grant execute on function public.request_secondary_position(uuid,text), public.decide_secondary_position(uuid,text,boolean) to authenticated;

-- Sala de Troféus sem Garçom da Partida (os demais troféus e regras de 049 ficam iguais).
alter function public.get_player_career_summary(uuid) rename to get_player_career_summary_v46;
alter function public.get_player_career_summary_v46(uuid) set schema private;
create function public.get_player_career_summary(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := private.get_player_career_summary_v46(p_user);
begin
 if not coalesce((v->>'visible')::boolean, false) then return v; end if;
 return v || jsonb_build_object('trophies', (v->'trophies') - 'match_garcom',
  'peladas', coalesce((select jsonb_agg(e || jsonb_build_object('trophies', (e->'trophies') - 'match_garcom') order by o)
   from jsonb_array_elements(v->'peladas') with ordinality q(e, o)), '[]'::jsonb));
end $$;

alter function public.get_trophy_history(uuid,text,jsonb,integer) rename to get_trophy_history_v46;
alter function public.get_trophy_history_v46(uuid,text,jsonb,integer) set schema private;
create function public.get_trophy_history(p_user uuid, p_type text, p_after jsonb default null, p_limit integer default 20)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 if p_type = 'match_garcom' then raise exception 'INVALID_TROPHY'; end if;
 return private.get_trophy_history_v46(p_user, p_type, p_after, p_limit);
end $$;

revoke all on function private.get_player_career_summary_v46(uuid), private.get_trophy_history_v46(uuid,text,jsonb,integer)
 from public, anon, authenticated;
revoke all on function public.get_player_career_summary(uuid), public.get_trophy_history(uuid,text,jsonb,integer) from public, anon;
grant execute on function public.get_player_career_summary(uuid), public.get_trophy_history(uuid,text,jsonb,integer) to authenticated;

-- ===== 057_v77_legal_versions.sql =====
-- Minuto 91 / 057: V7.7 - versões das minutas legais alinhadas às regras novas (Termos 1.2, Política 1.3; texto em
-- app/src/lib/legalText.ts). Quem já aceitou a versão anterior é convidado a aceitar de novo no próximo acesso.
-- [VALIDAR COM ADVOGADO] antes de aplicar em produção.
-- Rollback: update private.app_config set value='{"terms":"1.1","privacy":"1.2"}' where key='legal_versions'.
update private.app_config set value='{"terms":"1.2","privacy":"1.3"}'::jsonb where key='legal_versions';
