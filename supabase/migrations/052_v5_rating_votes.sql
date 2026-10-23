-- Minuto 91 / 052: V5 (Prompt Master v2.0, Etapas 10-15), votação pós-partida v2.
--
-- Ciclo: indisponível (partida não oficial) -> pronta (oficial, sem sessão) -> aberta (admin abre, 6 h)
-- -> aguardando publicação (prazo vencido; automático) -> publicada (admin confirma; idempotente).
-- - A súmula publicada vira partida oficial na hora (o fluxo antigo de cédula inteira deixa de abrir
--   sessões novas; sessões antigas ainda abertas terminam pelo caminho da 013).
-- - Quem vota e quem recebe nota: participantes da súmula com conta (private.match_voters), dos dois times.
--   Convidados e jogadores sem conta não votam nem recebem nota (D8). Ninguém vota em si mesmo.
-- - Cada nota (0 a 10, passos de 0,5) é salva sozinha (cast_rating_vote): no máximo uma nota ativa por
--   partida + eleitor + avaliado; reenviar substitui. O prazo é checado no servidor (clock_timestamp) na
--   mesma transação que grava, com a sessão travada: não existe voto tardio.
-- - Ordem fixa por eleitor (hash da sessão + eleitor + avaliado), pulados reaparecem uma vez, depois
--   ficam na revisão. Progresso guardado no servidor.
-- - Sigilo: notas e progresso ficam no schema private, sem SELECT para ninguém. O admin vê só agregados
--   (get_rating_vote_admin). Depois de publicada, o público vê só a nota final ou "avaliação insuficiente".
-- - Nota da partida (D3/D5): q = 0,5 média dos companheiros + 0,5 média dos adversários, só com pelo menos
--   uma nota de cada grupo. Sem nota fictícia.
-- - Craque e Bola Murcha (D4, mantidos): escolha opcional no fim; prêmio só com 3+ escolhas (decisão técnica,
--   herdando o mínimo de 3 da regra antiga).
-- - Correção da súmula com a votação v2 aberta ou aguardando publicação: atualiza gols/assistências mostrados, notifica quem já deu
--   nota aos jogadores alterados, não mexe nas notas. Entrada/saída de jogador ajusta a lista de eleitores.
-- Rollback: recriar open_voting_session (013), compute_match_results (013), correct_match_sheet (009),
-- push_skip_reason (045) e dropar as tabelas rating_vote_*.

create table public.rating_vote_sessions (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null,
 status text not null default 'open' check (status in ('open','awaiting_publication','published','cancelled')),
 opened_by uuid references public.profiles(id) on delete set null,
 opened_at timestamptz not null default now(),
 closes_at timestamptz not null,
 original_closes_at timestamptz not null,
 rules_version integer not null,
 bola_murcha_enabled boolean not null,
 published_by uuid references public.profiles(id) on delete set null,
 published_at timestamptz,
 created_at timestamptz not null default now(),
 foreign key (match_id, pelada_id) references public.matches(id, pelada_id),
 unique (match_id),
 unique (id, pelada_id)
);
create index rating_vote_sessions_open on public.rating_vote_sessions(closes_at) where status='open';

create table public.rating_vote_participants (
 session_id uuid not null,
 pelada_id uuid not null,
 membership_id uuid not null,
 participant_id uuid references public.match_participants(id) on delete set null,
 team text not null check (team in ('A','B')),
 primary key (session_id, membership_id),
 foreign key (session_id, pelada_id) references public.rating_vote_sessions(id, pelada_id) on delete cascade,
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id)
);

create table public.rating_vote_extensions (
 id uuid primary key default gen_random_uuid(),
 session_id uuid not null,
 pelada_id uuid not null,
 extended_by uuid references public.profiles(id) on delete set null,
 extended_at timestamptz not null default now(),
 previous_closes_at timestamptz not null,
 added_minutes integer not null check (added_minutes between 15 and 720),
 new_closes_at timestamptz not null,
 foreign key (session_id, pelada_id) references public.rating_vote_sessions(id, pelada_id) on delete cascade
);

create table private.rating_votes (
 session_id uuid not null references public.rating_vote_sessions(id) on delete cascade,
 voter_membership_id uuid not null,
 target_membership_id uuid not null,
 rating numeric(3,1) not null check (rating between 0 and 10 and rating*2 = floor(rating*2)),
 updated_at timestamptz not null default now(),
 primary key (session_id, voter_membership_id, target_membership_id),
 check (voter_membership_id <> target_membership_id)
);

create table private.rating_vote_progress (
 session_id uuid not null references public.rating_vote_sessions(id) on delete cascade,
 voter_membership_id uuid not null,
 sequence uuid[] not null,
 pos integer not null default 0,
 skipped_once uuid[] not null default '{}',
 second_pos integer not null default 0,
 skipped_twice uuid[] not null default '{}',
 reached_review_at timestamptz,
 primary key (session_id, voter_membership_id)
);

create table private.rating_vote_awards (
 session_id uuid not null references public.rating_vote_sessions(id) on delete cascade,
 voter_membership_id uuid not null,
 award_type text not null check (award_type in ('craque','bola_murcha')),
 target_membership_id uuid not null,
 primary key (session_id, voter_membership_id, award_type),
 check (voter_membership_id <> target_membership_id)
);

create table private.rating_vote_results (
 session_id uuid not null references public.rating_vote_sessions(id) on delete cascade,
 membership_id uuid not null,
 q numeric(8,6) check (q between 0 and 10),
 teammate_votes integer not null,
 opponent_votes integer not null,
 primary key (session_id, membership_id)
);

revoke all on private.rating_votes, private.rating_vote_progress, private.rating_vote_awards,
 private.rating_vote_results from public, anon, authenticated;

alter table public.rating_vote_sessions enable row level security;
alter table public.rating_vote_participants enable row level security;
alter table public.rating_vote_extensions enable row level security;
revoke all on public.rating_vote_sessions, public.rating_vote_participants, public.rating_vote_extensions from anon,authenticated;
grant select on public.rating_vote_sessions, public.rating_vote_participants, public.rating_vote_extensions to authenticated;
create policy rv_sessions_read on public.rating_vote_sessions for select to authenticated
 using ((select private.is_active_member(pelada_id)));
create policy rv_participants_read on public.rating_vote_participants for select to authenticated
 using ((select private.is_active_member(pelada_id)));
create policy rv_extensions_read on public.rating_vote_extensions for select to authenticated
 using ((select private.is_active_staff(pelada_id)));

---------------------------------------------------------------------------------------------------
-- A súmula publicada vira oficial na hora (sem a cédula antiga)
---------------------------------------------------------------------------------------------------
create or replace function private.open_voting_session(p_match uuid, p_closes_at timestamptz,
 p_duration integer, p_fixed boolean) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
 perform private.finalize_match_without_voting(p_match);
 return null;
end $$;

-- Resultados da partida: sessão antiga (013) ou notas publicadas da v2.
alter function private.compute_match_results(uuid,uuid) rename to compute_match_results_v1;
create function private.compute_match_results(p_match uuid, p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if p_session is not null then
  perform private.compute_match_results_v1(p_match, p_session);
  return;
 end if;
 delete from public.match_player_results where match_id=p_match;
 insert into public.match_player_results(pelada_id,match_id,session_id,membership_id,numeric_rating_count,
  peer_rating,objective_rating,final_rating,has_valid_rating,goals,assists,red_cards,match_result,
  position_snapshot,formula_version)
 with m as (select * from public.matches where id=p_match),
 ev as (
  select participant_id,
   coalesce(sum(quantity) filter (where event_type='goal'),0)::int g,
   coalesce(sum(quantity) filter (where event_type='assist'),0)::int a,
   coalesce(sum(quantity) filter (where event_type in ('red_card','second_yellow')),0)::int rc
  from public.match_events where match_id=p_match and participant_id is not null group by participant_id),
 q as (
  select r.membership_id, r.q from private.rating_vote_results r
  join public.rating_vote_sessions s on s.id=r.session_id
  where s.match_id=p_match and s.status='published')
 select m.pelada_id, p_match, null, p.membership_id, 0,
  round(q.q,6),
  round(least(10, greatest(0, 5 + 2*coalesce(ev.g,0) + coalesce(ev.a,0)
   + case when (p.team='A' and m.team_a_score>m.team_b_score) or (p.team='B' and m.team_b_score>m.team_a_score) then 1
          when m.team_a_score=m.team_b_score then 0 else -1 end))::numeric,6),
  round(q.q,6), q.q is not null, coalesce(ev.g,0), coalesce(ev.a,0), coalesce(ev.rc,0),
  case when (p.team='A' and m.team_a_score>m.team_b_score) or (p.team='B' and m.team_b_score>m.team_a_score) then 'win'
       when m.team_a_score=m.team_b_score then 'draw' else 'loss' end,
  p.primary_position, 2
 from public.match_participants p cross join m
 left join ev on ev.participant_id=p.id
 left join q on q.membership_id=p.membership_id
 where p.match_id=p_match and p.membership_id is not null;
end $$;

---------------------------------------------------------------------------------------------------
-- Leitura e estado
---------------------------------------------------------------------------------------------------
create function private.rating_vote_effective_status(s public.rating_vote_sessions) returns text
language sql stable set search_path = '' as $$
 select case when s.status in ('published','cancelled') then s.status
  when clock_timestamp() >= s.closes_at then 'awaiting_publication' else 'open' end;
$$;

create function private.my_membership(p_pelada uuid) returns uuid
language sql stable security definer set search_path = '' as $$
 select id from public.pelada_memberships where pelada_id=p_pelada and user_id=(select auth.uid()) and status='active';
$$;

-- Garante a ordem fixa do eleitor e avança por cima de pulados já avaliados na segunda passada.
create function private.rating_vote_progress_row(p_session uuid, p_voter uuid) returns private.rating_vote_progress
language plpgsql security definer set search_path = '' as $$
declare v private.rating_vote_progress;
begin
 insert into private.rating_vote_progress(session_id, voter_membership_id, sequence)
 select p_session, p_voter, coalesce(array_agg(t.membership_id order by md5(p_session::text||p_voter::text||t.membership_id::text)),'{}')
 from public.rating_vote_participants t where t.session_id=p_session and t.membership_id<>p_voter
 on conflict do nothing;
 select * into v from private.rating_vote_progress where session_id=p_session and voter_membership_id=p_voter for update;
 -- Alvos que saíram da súmula são ignorados; os que entraram vão para o fim da sequência.
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
     and r.target_membership_id=v.skipped_once[v.second_pos+1])) loop
   v.second_pos := v.second_pos + 1;
  end loop;
  if v.second_pos >= cardinality(v.skipped_once) and v.reached_review_at is null then v.reached_review_at := now(); end if;
 end if;
 update private.rating_vote_progress set sequence=v.sequence, pos=v.pos, second_pos=v.second_pos,
  reached_review_at=v.reached_review_at where session_id=p_session and voter_membership_id=p_voter;
 return v;
end $$;

-- Estado da votação de uma partida para quem está logado. Para o eleitor, a sequência e as próprias notas.
create function public.get_rating_vote(p_match uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_s public.rating_vote_sessions; v_status text; v_me uuid; v_team text;
 v_p private.rating_vote_progress; v_phase text; v_current uuid; v_targets jsonb; v_staff boolean; v_awards jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match;
 if not found or not private.is_active_member(v_m.pelada_id) then raise exception 'MATCH_NOT_FOUND'; end if;
 v_staff := private.is_active_staff(v_m.pelada_id);
 select * into v_s from public.rating_vote_sessions where match_id=p_match;
 if not found then
  return jsonb_build_object('state', case when v_m.status <> 'finalized' then 'unavailable'
    when exists(select 1 from public.voting_sessions o where o.match_id=p_match and o.status='finalized') then 'legacy'
    else 'ready' end,
   'can_manage', v_staff, 'server_now', clock_timestamp());
 end if;
 v_status := private.rating_vote_effective_status(v_s);
 v_me := private.my_membership(v_m.pelada_id);
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
  select coalesce(jsonb_agg(jsonb_build_object('membership_id',t.membership_id,'name',pr.display_name,
    'avatar_path',pr.avatar_path,'position',coalesce(mp.position_code, mp.primary_position),'team',t.team,
    'is_teammate',t.team=v_team,
    'goals',coalesce((select sum(quantity) from public.match_events e where e.participant_id=t.participant_id and e.event_type='goal'),0),
    'assists',coalesce((select sum(quantity) from public.match_events e where e.participant_id=t.participant_id and e.event_type='assist'),0),
    'my_rating',(select r.rating from private.rating_votes r where r.session_id=v_s.id and r.voter_membership_id=v_me
      and r.target_membership_id=t.membership_id),
    'skipped', t.membership_id = any(v_p.skipped_once)) order by o), '[]'::jsonb)
  into v_targets
  from unnest(v_p.sequence) with ordinality u(x, o)
  join public.rating_vote_participants t on t.session_id=v_s.id and t.membership_id=u.x
  join public.pelada_memberships pm on pm.id=t.membership_id
  left join public.profiles pr on pr.id=pm.user_id
  left join public.match_participants mp on mp.id=t.participant_id;
  select jsonb_object_agg(award_type, target_membership_id) into v_awards from private.rating_vote_awards
  where session_id=v_s.id and voter_membership_id=v_me;
 end if;
 return jsonb_build_object('state', v_status, 'session_id', v_s.id, 'opened_at', v_s.opened_at,
  'closes_at', v_s.closes_at, 'server_now', clock_timestamp(), 'can_manage', v_staff,
  'is_voter', v_team is not null, 'my_team', v_team, 'phase', v_phase, 'current', v_current,
  'targets', coalesce(v_targets,'[]'::jsonb),
  'rated', (select count(*) from jsonb_array_elements(coalesce(v_targets,'[]'::jsonb)) x where x->>'my_rating' is not null),
  'bola_murcha_enabled', v_s.bola_murcha_enabled, 'my_awards', coalesce(v_awards,'{}'::jsonb),
  'published_at', v_s.published_at);
end $$;

-- Trava a sessão e valida o eleitor dentro do prazo (servidor é a autoridade).
create function private.rating_vote_lock_voter(p_session uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_s public.rating_vote_sessions; v_me uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_s from public.rating_vote_sessions where id=p_session for share;
 if not found or not private.is_active_member(v_s.pelada_id) then raise exception 'SESSION_NOT_FOUND'; end if;
 if v_s.status <> 'open' or clock_timestamp() >= v_s.closes_at then raise exception 'VOTING_CLOSED'; end if;
 v_me := private.my_membership(v_s.pelada_id);
 if v_me is null or not exists(select 1 from public.rating_vote_participants where session_id=p_session and membership_id=v_me) then
  raise exception 'NOT_ELIGIBLE_VOTER' using errcode='42501'; end if;
 return v_me;
end $$;

create function public.cast_rating_vote(p_session uuid, p_target uuid, p_rating numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_me uuid; v_p private.rating_vote_progress; v_match uuid;
begin
 v_me := private.rating_vote_lock_voter(p_session);
 if p_target = v_me then raise exception 'SELF_VOTE_NOT_ALLOWED'; end if;
 if not exists(select 1 from public.rating_vote_participants where session_id=p_session and membership_id=p_target) then
  raise exception 'TARGET_NOT_ELIGIBLE'; end if;
 if p_rating is null or p_rating < 0 or p_rating > 10 or p_rating*2 <> floor(p_rating*2) then raise exception 'INVALID_RATING'; end if;
 insert into private.rating_votes(session_id, voter_membership_id, target_membership_id, rating)
 values(p_session, v_me, p_target, p_rating)
 on conflict (session_id, voter_membership_id, target_membership_id) do update set rating=excluded.rating, updated_at=now();
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

create function public.skip_rating_vote(p_session uuid, p_target uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_me uuid; v_p private.rating_vote_progress; v_match uuid;
begin
 v_me := private.rating_vote_lock_voter(p_session);
 v_p := private.rating_vote_progress_row(p_session, v_me);
 if v_p.pos < cardinality(v_p.sequence) and v_p.sequence[v_p.pos+1] = p_target then
  update private.rating_vote_progress set pos=pos+1,
   skipped_once=case when p_target = any(skipped_once) then skipped_once else skipped_once || p_target end
  where session_id=p_session and voter_membership_id=v_me;
 elsif v_p.pos >= cardinality(v_p.sequence) and v_p.second_pos < cardinality(v_p.skipped_once)
   and v_p.skipped_once[v_p.second_pos+1] = p_target then
  update private.rating_vote_progress set second_pos=second_pos+1,
   skipped_twice=case when p_target = any(skipped_twice) then skipped_twice else skipped_twice || p_target end
  where session_id=p_session and voter_membership_id=v_me;
 end if;
 perform private.rating_vote_progress_row(p_session, v_me);
 select match_id into v_match from public.rating_vote_sessions where id=p_session;
 return public.get_rating_vote(v_match);
end $$;

-- Craque e Bola Murcha (opcionais). null apaga a escolha.
create function public.set_rating_vote_awards(p_session uuid, p_craque uuid, p_bola_murcha uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_me uuid; v_s public.rating_vote_sessions;
begin
 v_me := private.rating_vote_lock_voter(p_session);
 select * into v_s from public.rating_vote_sessions where id=p_session;
 if p_craque = v_me or p_bola_murcha = v_me then raise exception 'SELF_VOTE_NOT_ALLOWED'; end if;
 if p_bola_murcha is not null and not v_s.bola_murcha_enabled then raise exception 'BOLA_MURCHA_DISABLED'; end if;
 if (p_craque is not null and not exists(select 1 from public.rating_vote_participants where session_id=p_session and membership_id=p_craque))
  or (p_bola_murcha is not null and not exists(select 1 from public.rating_vote_participants where session_id=p_session and membership_id=p_bola_murcha)) then
  raise exception 'TARGET_NOT_ELIGIBLE'; end if;
 delete from private.rating_vote_awards where session_id=p_session and voter_membership_id=v_me;
 insert into private.rating_vote_awards(session_id, voter_membership_id, award_type, target_membership_id)
 select p_session, v_me, t, x from (values ('craque', p_craque), ('bola_murcha', p_bola_murcha)) a(t, x) where x is not null;
end $$;

---------------------------------------------------------------------------------------------------
-- Administração
---------------------------------------------------------------------------------------------------
create function public.open_rating_vote(p_match uuid) returns jsonb
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
 values(v_pelada,p_match,auth.uid(),v_close,v_close,1,
  coalesce((select bola_murcha_enabled from public.pelada_settings where pelada_id=v_pelada),true)
   and private.pelada_has_premium(v_pelada))
 returning id into v_id;
 insert into public.rating_vote_participants(session_id,pelada_id,membership_id,participant_id,team)
 select v_id, v_pelada, v.membership_id, v.participant_id, p.team
 from private.match_voters(p_match) v join public.match_participants p on p.id=v.participant_id;
 perform private.notify(pm.user_id, v_pelada, 'voting_opened', 'essential', 'rvopen:'||v_id||':'||pm.user_id,
  jsonb_build_object('pelada_id',v_pelada,'match_id',p_match))
 from public.rating_vote_participants t join public.pelada_memberships pm on pm.id=t.membership_id
 where t.session_id=v_id and pm.user_id is not null;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_pelada,auth.uid(),'rating_vote_opened',jsonb_build_object('match_id',p_match,'session_id',v_id,
  'closes_at',v_close,'rules_version',1,'participants',(select count(*) from public.rating_vote_participants where session_id=v_id)));
 return public.get_rating_vote(p_match);
end $$;

create function public.extend_rating_vote(p_session uuid, p_minutes integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s public.rating_vote_sessions; v_new timestamptz;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_s from public.rating_vote_sessions where id=p_session for update;
 if not found or not private.is_active_staff(v_s.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 if v_s.status <> 'open' or clock_timestamp() >= v_s.closes_at then raise exception 'VOTING_CLOSED'; end if;
 if p_minutes is null or p_minutes not between 15 and 720 then raise exception 'INVALID_EXTENSION'; end if;
 v_new := v_s.closes_at + make_interval(mins => p_minutes);
 update public.rating_vote_sessions set closes_at=v_new where id=p_session;
 insert into public.rating_vote_extensions(session_id,pelada_id,extended_by,previous_closes_at,added_minutes,new_closes_at)
 values(p_session,v_s.pelada_id,auth.uid(),v_s.closes_at,p_minutes,v_new);
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_s.pelada_id,auth.uid(),'rating_vote_extended',jsonb_build_object('session_id',p_session,
  'previous_closes_at',v_s.closes_at,'added_minutes',p_minutes,'new_closes_at',v_new));
 return public.get_rating_vote(v_s.match_id);
end $$;

-- Só agregados: nunca quem deu qual nota.
create function public.get_rating_vote_admin(p_session uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s public.rating_vote_sessions; v_n int; v_players jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_s from public.rating_vote_sessions where id=p_session;
 if not found or not private.is_active_staff(v_s.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select count(*) into v_n from public.rating_vote_participants where session_id=p_session;
 select coalesce(jsonb_agg(jsonb_build_object('membership_id',t.membership_id,'name',pr.display_name,'team',t.team,
   'valid', exists(select 1 from private.rating_votes r join public.rating_vote_participants vt
      on vt.session_id=r.session_id and vt.membership_id=r.voter_membership_id
     where r.session_id=p_session and r.target_membership_id=t.membership_id and vt.team=t.team)
    and exists(select 1 from private.rating_votes r join public.rating_vote_participants vt
      on vt.session_id=r.session_id and vt.membership_id=r.voter_membership_id
     where r.session_id=p_session and r.target_membership_id=t.membership_id and vt.team<>t.team))
   order by pr.display_name), '[]'::jsonb)
 into v_players
 from public.rating_vote_participants t join public.pelada_memberships pm on pm.id=t.membership_id
 left join public.profiles pr on pr.id=pm.user_id where t.session_id=p_session;
 return jsonb_build_object('session_id',p_session,'state',private.rating_vote_effective_status(v_s),
  'opened_at',v_s.opened_at,'closes_at',v_s.closes_at,'server_now',clock_timestamp(),
  'participants',v_n,
  'voters_participated',(select count(distinct voter_membership_id) from private.rating_votes where session_id=p_session),
  'votes',(select count(*) from private.rating_votes where session_id=p_session),
  'coverage',case when v_n > 1 then round((select count(*) from private.rating_votes where session_id=p_session)::numeric/(v_n*(v_n-1)),4) else 0 end,
  'players_valid',(select count(*) from jsonb_array_elements(v_players) x where (x->>'valid')::boolean),
  'players_insufficient',(select count(*) from jsonb_array_elements(v_players) x where not (x->>'valid')::boolean),
  'average_rating',(select round(avg(rating),2) from private.rating_votes where session_id=p_session),
  'players',v_players,
  'extensions',(select coalesce(jsonb_agg(jsonb_build_object('at',e.extended_at,'added_minutes',e.added_minutes,
    'new_closes_at',e.new_closes_at) order by e.extended_at),'[]'::jsonb) from public.rating_vote_extensions e where e.session_id=p_session),
  'published_at',v_s.published_at);
end $$;

create function public.publish_rating_vote(p_session uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_s public.rating_vote_sessions; v_m public.matches; t text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.rating_vote_sessions where id=p_session;
 if not found then raise exception 'SESSION_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_pelada for update;
 if not private.is_active_staff(v_pelada) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select * into v_s from public.rating_vote_sessions where id=p_session for update;
 if v_s.status = 'published' then return public.get_rating_vote(v_s.match_id); end if; -- idempotente
 if v_s.status = 'cancelled' then raise exception 'SESSION_CANCELLED'; end if;
 if clock_timestamp() < v_s.closes_at then raise exception 'VOTING_STILL_OPEN'; end if;
 select * into v_m from public.matches where id=v_s.match_id for update;

 insert into private.rating_vote_results(session_id, membership_id, q, teammate_votes, opponent_votes)
 select p_session, t2.membership_id,
  case when count(*) filter (where vt.team=t2.team) > 0 and count(*) filter (where vt.team<>t2.team) > 0 then
   0.5*avg(r.rating) filter (where vt.team=t2.team) + 0.5*avg(r.rating) filter (where vt.team<>t2.team) end,
  count(r.*) filter (where vt.team=t2.team), count(r.*) filter (where vt.team<>t2.team)
 from public.rating_vote_participants t2
 left join private.rating_votes r on r.session_id=p_session and r.target_membership_id=t2.membership_id
 left join public.rating_vote_participants vt on vt.session_id=p_session and vt.membership_id=r.voter_membership_id
 where t2.session_id=p_session
 group by t2.membership_id, t2.team;

 -- Craque / Bola Murcha (3+ escolhas; empate dividido).
 foreach t in array case when v_s.bola_murcha_enabled then array['craque','bola_murcha'] else array['craque'] end loop
  if (select count(*) from private.rating_vote_awards where session_id=p_session and award_type=t) >= 3 then
   insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count,is_shared)
   with votes as (select target_membership_id m, count(*)::int c from private.rating_vote_awards
     where session_id=p_session and award_type=t group by target_membership_id),
   top as (select * from votes where c=(select max(c) from votes))
   select v_s.pelada_id, v_s.match_id, v_m.season_id, top.m,
    case t when 'craque' then 'match_craque' else 'bola_murcha' end, top.c, (select count(*) from top) > 1
   from top on conflict do nothing;
  end if;
 end loop;

 update public.rating_vote_sessions set status='published', published_by=auth.uid(), published_at=now() where id=p_session;
 perform private.compute_match_results(v_s.match_id, null);
 perform set_config('minuto91.rating_event', 'votes_published', true);
 perform private.after_match_finalized(v_s.match_id);
 perform set_config('minuto91.rating_event', '', true);
 perform private.notify(pm.user_id, v_s.pelada_id, 'result_published', 'essential', 'rvpub:'||p_session||':'||pm.user_id,
  jsonb_build_object('pelada_id',v_s.pelada_id,'match_id',v_s.match_id))
 from public.rating_vote_participants t2 join public.pelada_memberships pm on pm.id=t2.membership_id
 where t2.session_id=p_session and pm.user_id is not null;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_s.pelada_id,auth.uid(),'rating_vote_published',jsonb_build_object('session_id',p_session,'match_id',v_s.match_id,
  'valid_players',(select count(*) from private.rating_vote_results where session_id=p_session and q is not null),
  'insufficient_players',(select count(*) from private.rating_vote_results where session_id=p_session and q is null)));
 return public.get_rating_vote(v_s.match_id);
end $$;

-- Anulação cancela a votação v2 da partida.
create function private.rating_vote_on_annul() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.status='annulled' and old.status is distinct from 'annulled' then
  update public.rating_vote_sessions set status='cancelled' where match_id=new.id and status<>'cancelled';
 end if;
 return new;
end $$;
create trigger rating_vote_on_annul after update of status on public.matches
 for each row execute function private.rating_vote_on_annul();

---------------------------------------------------------------------------------------------------
-- Correção da súmula durante a votação v2 (Etapa 15)
---------------------------------------------------------------------------------------------------
create or replace function public.correct_match_sheet(p_match uuid, p_participants jsonb, p_events jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_m public.matches; v_reason text := nullif(btrim(p_reason),'');
 v_before jsonb; v_after jsonb; v_old uuid[]; v_changed boolean; v_r jsonb; v_version int;
 v_s public.rating_vote_sessions; v_stats_before jsonb; v_changed_players uuid[];
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_pelada for update;
 if not private.is_active_staff(v_pelada) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match for update;
 if v_m.status='draft' then raise exception 'MATCH_IS_DRAFT'; end if;
 if v_m.status='finalized' then
  -- Oficial: corrigível só com a votação v2 aberta ou aguardando publicação (antes de abrir, o admin abre e corrige).
  select * into v_s from public.rating_vote_sessions where match_id=p_match for update;
  if not found or v_s.status not in ('open','awaiting_publication') then raise exception 'SHEET_LOCKED'; end if;
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

 v_r := private.write_match_sheet(v_m, p_participants, p_events);
 v_after := private.sheet_snapshot(p_match);
 if v_after = v_before then raise exception 'NO_CHANGES'; end if;
 v_changed := v_old is distinct from private.sheet_voter_memberships(p_match);

 update public.matches set sheet_version=sheet_version+1 where id=p_match returning sheet_version into v_version;
 insert into public.match_versions(pelada_id,match_id,version_number,changed_by,change_reason,snapshot,eligible_voters_changed)
 values(v_pelada,p_match,v_version,auth.uid(),v_reason,v_after,v_changed);
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_pelada,auth.uid(),'match_sheet_corrected',jsonb_build_object(
  'match_id',p_match,'sheet_version',v_version,'eligible_voters_changed',v_changed));

 if v_m.status='voting_open' then
  perform private.on_sheet_corrected(p_match, v_changed);
 else
  if v_s.id is not null then
   -- Lista de eleitores acompanha a súmula; notas de/para quem saiu deixam de existir.
   delete from public.rating_vote_participants t where t.session_id=v_s.id
    and not exists(select 1 from private.match_voters(p_match) v where v.membership_id=t.membership_id);
   delete from private.rating_votes r where r.session_id=v_s.id and (
    not exists(select 1 from public.rating_vote_participants t where t.session_id=v_s.id and t.membership_id=r.voter_membership_id)
    or not exists(select 1 from public.rating_vote_participants t where t.session_id=v_s.id and t.membership_id=r.target_membership_id));
   delete from private.rating_vote_awards r where r.session_id=v_s.id and (
    not exists(select 1 from public.rating_vote_participants t where t.session_id=v_s.id and t.membership_id=r.voter_membership_id)
    or not exists(select 1 from public.rating_vote_participants t where t.session_id=v_s.id and t.membership_id=r.target_membership_id));
   delete from private.rating_vote_progress g where g.session_id=v_s.id
    and not exists(select 1 from public.rating_vote_participants t where t.session_id=v_s.id and t.membership_id=g.voter_membership_id);
   insert into public.rating_vote_participants(session_id,pelada_id,membership_id,participant_id,team)
   select v_s.id, v_pelada, v.membership_id, v.participant_id, p.team
   from private.match_voters(p_match) v join public.match_participants p on p.id=v.participant_id
   on conflict (session_id, membership_id) do update set team=excluded.team, participant_id=excluded.participant_id;
   -- Quem já deu nota a um jogador cujos gols/assistências mudaram é avisado (sem revelar a nota).
   select coalesce(array_agg(p.membership_id),'{}') into v_changed_players
   from public.match_participants p where p.match_id=p_match and p.membership_id is not null
    and (v_stats_before->(p.membership_id::text)) is distinct from jsonb_build_array(
     coalesce((select sum(quantity) from public.match_events e where e.participant_id=p.id and e.event_type='goal'),0),
     coalesce((select sum(quantity) from public.match_events e where e.participant_id=p.id and e.event_type='assist'),0));
   if v_s.status='open' and clock_timestamp() < v_s.closes_at then
    perform private.notify(pm.user_id, v_pelada, 'sheet_corrected', 'essential',
     'rvfix:'||v_s.id||':'||v_version||':'||pm.user_id, jsonb_build_object('pelada_id',v_pelada,'match_id',p_match))
    from (select distinct r.voter_membership_id m from private.rating_votes r
      where r.session_id=v_s.id and r.target_membership_id = any(v_changed_players)) a
    join public.pelada_memberships pm on pm.id=a.m where pm.user_id is not null;
   end if;
  end if;
  perform private.compute_match_results(p_match, null);
  perform set_config('minuto91.rating_event', 'sheet_corrected', true);
  perform private.after_match_finalized(p_match);
  perform set_config('minuto91.rating_event', '', true);
 end if;
 return v_r || jsonb_build_object('sheet_version',v_version,'eligible_voters_changed',v_changed);
end $$;

---------------------------------------------------------------------------------------------------
-- Encerramento automático e lembretes (agendador)
---------------------------------------------------------------------------------------------------
create function private.rating_vote_tick() returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
 for r in update public.rating_vote_sessions set status='awaiting_publication'
   where status='open' and closes_at <= clock_timestamp() returning id, pelada_id, match_id loop
  perform private.notify(pm.user_id, r.pelada_id, 'rating_vote_awaiting_publication', 'essential',
   'rvwait:'||r.id||':'||pm.user_id, jsonb_build_object('pelada_id',r.pelada_id,'match_id',r.match_id))
  from public.pelada_memberships pm where pm.pelada_id=r.pelada_id and pm.status='active'
   and pm.role in ('admin','assistant') and pm.user_id is not null;
 end loop;
 -- Lembretes só para quem ainda não chegou à revisão, só com a sessão aberta, sempre pelo prazo vigente.
 perform private.notify(pm.user_id, s.pelada_id, 'voting_closing_soon', 'essential',
  case when clock_timestamp() >= s.closes_at - interval '1 hour'
   then 'rv2:'||s.id||':'||extract(epoch from s.closes_at)::bigint||':'||pm.user_id
   else 'rv1:'||s.id||':'||pm.user_id end,
  jsonb_build_object('pelada_id',s.pelada_id,'match_id',s.match_id,'closes_at',s.closes_at))
 from public.rating_vote_sessions s join public.rating_vote_participants t on t.session_id=s.id
 join public.pelada_memberships pm on pm.id=t.membership_id and pm.status='active' and pm.user_id is not null
 where s.status='open' and s.closes_at > clock_timestamp()
  and (clock_timestamp() >= s.closes_at - interval '1 hour' or clock_timestamp() >= s.opened_at + interval '2 hours')
  and not exists(select 1 from private.rating_vote_progress g where g.session_id=s.id
   and g.voter_membership_id=t.membership_id and g.reached_review_at is not null);
end $$;

do $do$
begin
 if exists(select 1 from pg_extension where extname='pg_cron') then
  execute $q$select cron.schedule('minuto91-rating-votes', '*/5 * * * *', 'select private.rating_vote_tick()')$q$;
 else
  raise notice 'pg_cron not enabled: schedule private.rating_vote_tick() every 5 minutes';
 end if;
end $do$;

-- Push: notificações da votação v2 também caem quando a sessão não está mais aberta.
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
    and v.status='open')
   and not exists(select 1 from public.rating_vote_sessions v where v.match_id=private.try_uuid(e.payload->>'match_id')
    and v.status='open' and v.closes_at > now()) then 'VOTING_CLOSED'
  when not exists(select 1 from public.push_devices d where d.user_id=e.user_id) then 'NO_DEVICE'
 end
 from public.notification_events e where e.id=p_id;
$$;

revoke all on function private.compute_match_results_v1(uuid,uuid), private.rating_vote_effective_status(public.rating_vote_sessions),
 private.my_membership(uuid), private.rating_vote_progress_row(uuid,uuid), private.rating_vote_lock_voter(uuid),
 private.rating_vote_on_annul(), private.rating_vote_tick() from public,anon,authenticated;
revoke all on function public.get_rating_vote(uuid), public.cast_rating_vote(uuid,uuid,numeric),
 public.skip_rating_vote(uuid,uuid), public.set_rating_vote_awards(uuid,uuid,uuid), public.open_rating_vote(uuid),
 public.extend_rating_vote(uuid,integer), public.get_rating_vote_admin(uuid), public.publish_rating_vote(uuid) from public,anon;
grant execute on function public.get_rating_vote(uuid), public.cast_rating_vote(uuid,uuid,numeric),
 public.skip_rating_vote(uuid,uuid), public.set_rating_vote_awards(uuid,uuid,uuid), public.open_rating_vote(uuid),
 public.extend_rating_vote(uuid,integer), public.get_rating_vote_admin(uuid), public.publish_rating_vote(uuid) to authenticated;

-- Central do Jogador: votações v2 abertas em que eu voto e ainda não cheguei à revisão.
create function public.get_my_pending_rating_votes() returns jsonb
language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_agg(jsonb_build_object('match_id', s.match_id, 'session_id', s.id, 'pelada_id', s.pelada_id,
   'pelada_name', p.name, 'closes_at', s.closes_at, 'team_a_name', m.team_a_name, 'team_b_name', m.team_b_name,
   'team_a_score', m.team_a_score, 'team_b_score', m.team_b_score, 'played_at', m.played_at,
   'rated', (select count(*) from private.rating_votes r where r.session_id = s.id and r.voter_membership_id = t.membership_id),
   'total', (select count(*) - 1 from public.rating_vote_participants x where x.session_id = s.id),
   'started', g.session_id is not null) order by s.closes_at), '[]'::jsonb)
 from public.rating_vote_sessions s
 join public.rating_vote_participants t on t.session_id = s.id
 join public.pelada_memberships pm on pm.id = t.membership_id and pm.user_id = (select auth.uid()) and pm.status = 'active'
 join public.peladas p on p.id = s.pelada_id join public.matches m on m.id = s.match_id
 left join private.rating_vote_progress g on g.session_id = s.id and g.voter_membership_id = t.membership_id
 where s.status = 'open' and s.closes_at > clock_timestamp() and (g.reached_review_at is null);
$$;
revoke all on function public.get_my_pending_rating_votes() from public, anon;
grant execute on function public.get_my_pending_rating_votes() to authenticated;
