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
