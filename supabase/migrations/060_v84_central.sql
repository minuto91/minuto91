-- Minuto 91 / 060: V8.4 — Central do Jogador (E05, E13, E14). Incremental: nada é apagado ou reescrito.
--
-- E14 Notificações: feed único sobre a fila existente (notification_events, 022). Estado lido/não lido por usuário,
--  persistido no servidor (read_at). O feed só devolve o que a pessoa pode ver: o próprio usuário, evento já liberado
--  (não agendado para o futuro, não suprimido), dentro de 90 dias, sem a premiação privada Bola Murcha (política já
--  vigente em private.push_skip_reason) e de peladas em que ainda há vínculo (ativo ou ex-integrante com histórico).
--  Ler uma notificação NÃO resolve votação, convite, pagamento ou pendência: só marca read_at.
--  Retenção de 90 dias: private.purge_old_notifications() apaga SÓ a fila de avisos; dados esportivos, financeiros,
--  votos e trilhas de auditoria (private.audit_events) não são tocados.
-- E13 Personalização: layout da Central por usuário (ordem/ocultação dos blocos E04–E06 e ocultação do E08),
--  versionado (controle otimista de versão) e restaurável.
-- E05 Último Jogo: leitura oficial do último jogo DISPUTADO pelo jogador e PUBLICADO (status finalized), com as
--  estatísticas oficiais e a nota já publicada. Nada é calculado aqui: só leitura de linhas oficiais.

---------------------------------------------------------------------------------------------------
-- E14: leitura persistida
---------------------------------------------------------------------------------------------------

alter table public.notification_events add column if not exists read_at timestamptz;
create index if not exists notifications_unread
 on public.notification_events(user_id, created_at desc) where read_at is null and status in ('pending','sent');

-- Condição única de "visível no feed" (usada por todas as funções abaixo; um só lugar para a regra).
create function private.notification_visible(e public.notification_events) returns boolean
language sql stable security definer set search_path = '' as $$
 select e.user_id = auth.uid()
  and e.status in ('pending','sent')
  and e.scheduled_at <= now()
  and e.created_at > now() - interval '90 days'
  and e.event_type <> 'award_bola_murcha'
  and (e.pelada_id is null or exists(select 1 from public.pelada_memberships m
    where m.pelada_id = e.pelada_id and m.user_id = e.user_id and m.status in ('active','left')));
$$;

-- Há alguma não lida? (o sino mostra só um ponto: nunca um número)
create function public.has_unread_notifications() returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 return exists(select 1 from public.notification_events e
  where e.user_id = auth.uid() and e.read_at is null and private.notification_visible(e));
end $$;

-- Feed paginado (mais recentes primeiro). p_after = "next" da página anterior. O payload devolvido tem só chaves de
-- navegação (nunca dados de votação nem valores financeiros).
create function public.get_my_notifications(p_after jsonb default null, p_limit integer default 30) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_lim integer := private.page_limit(p_limit, 30, 50); a_at timestamptz; a_id uuid; v_items jsonb; v_next jsonb; v_n integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_after is not null then
  begin a_at := (p_after->>'at')::timestamptz; a_id := (p_after->>'id')::uuid;
  exception when others then raise exception 'INVALID_CURSOR'; end;
  if a_at is null or a_id is null then raise exception 'INVALID_CURSOR'; end if;
 end if;
 with page as (
  select e.id, e.event_type, e.pelada_id, p.name pelada_name, e.created_at, e.read_at,
   jsonb_strip_nulls(jsonb_build_object('pelada_id', e.payload->>'pelada_id', 'match_id', e.payload->>'match_id',
    'award_type', e.payload->>'award_type', 'period_month', e.payload->>'period_month')) payload
  from public.notification_events e left join public.peladas p on p.id = e.pelada_id
  where e.user_id = auth.uid() and private.notification_visible(e)
   and (a_id is null or (e.created_at, e.id) < (a_at, a_id))
  order by e.created_at desc, e.id desc limit v_lim + 1)
 select coalesce(jsonb_agg(to_jsonb(page) order by created_at desc, id desc), '[]'::jsonb), count(*) into v_items, v_n from page;
 if v_n > v_lim then
  v_items := (select jsonb_agg(x order by o) from jsonb_array_elements(v_items) with ordinality q(x, o) where o <= v_lim);
  v_next := jsonb_build_object('at', v_items->(v_lim-1)->'created_at', 'id', v_items->(v_lim-1)->'id');
 end if;
 return jsonb_build_object('items', v_items, 'next', v_next);
end $$;

-- Marca uma como lida (idempotente: repetir devolve o mesmo read_at). Só a do próprio usuário.
create function public.mark_notification_read(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_at timestamptz;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 update public.notification_events set read_at = coalesce(read_at, now())
 where id = p_id and user_id = auth.uid() returning read_at into v_at;
 if v_at is null then raise exception 'NOTIFICATION_NOT_FOUND'; end if;
 return jsonb_build_object('id', p_id, 'read_at', v_at);
end $$;

-- Marca todas como lidas (idempotente: sem não lidas, devolve 0).
create function public.mark_all_notifications_read() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 with u as (update public.notification_events e set read_at = now()
  where e.user_id = auth.uid() and e.read_at is null and private.notification_visible(e) returning 1)
 select count(*) into v_n from u;
 return jsonb_build_object('marked', v_n);
end $$;

-- Retenção operacional de 90 dias (E14): só a fila de avisos.
create function private.purge_old_notifications() returns integer
language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
 with d as (delete from public.notification_events where created_at < now() - interval '90 days' returning 1)
 select count(*) into v_n from d;
 return v_n;
end $$;

do $cron$
begin
 if exists(select 1 from pg_extension where extname='pg_cron') then
  execute $q$select cron.schedule('minuto91-notification-retention', '17 4 * * *', 'select private.purge_old_notifications()')$q$;
 else
  raise notice 'pg_cron not enabled: schedule private.purge_old_notifications() daily';
 end if;
end $cron$;

---------------------------------------------------------------------------------------------------
-- E13: layout da Central (versionado)
---------------------------------------------------------------------------------------------------

create table public.user_central_layout (
 user_id uuid primary key references auth.users(id) on delete cascade,
 version integer not null default 1 check (version >= 1),
 block_order text[] not null,
 hidden_blocks text[] not null default '{}',
 updated_at timestamptz not null default now()
);
alter table public.user_central_layout enable row level security;
revoke all on public.user_central_layout from anon, authenticated;
grant select on public.user_central_layout to authenticated;
create policy user_central_layout_read_own on public.user_central_layout for select to authenticated
 using (user_id = (select auth.uid()));

-- Padrão: E04, E05, E06 nessa ordem, nada oculto. version 0 = nunca personalizado.
create function public.get_central_layout() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v public.user_central_layout;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v from public.user_central_layout where user_id = auth.uid();
 if not found then
  return jsonb_build_object('version', 0, 'order', jsonb_build_array('next_round','last_game','career_summary'),
   'hidden', '[]'::jsonb, 'is_default', true);
 end if;
 return jsonb_build_object('version', v.version, 'order', to_jsonb(v.block_order), 'hidden', to_jsonb(v.hidden_blocks), 'is_default', false);
end $$;

-- Só E04 (next_round), E05 (last_game) e E06 (career_summary) reordenam; E08 (my_peladas) só se oculta e fica sempre
-- por último. Os demais blocos não são configuráveis. p_expected_version: a versão que a tela leu (0 = padrão);
-- se mudou no servidor, LAYOUT_VERSION_CONFLICT (a tela recarrega, nada é sobrescrito em silêncio).
create function public.set_central_layout(p_order text[], p_hidden text[], p_expected_version integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_cur integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_order is null or p_hidden is null or p_expected_version is null or p_expected_version < 0 then raise exception 'INVALID_LAYOUT'; end if;
 if cardinality(p_order) <> 3 or not (p_order @> array['next_round','last_game','career_summary']) then raise exception 'INVALID_LAYOUT'; end if;
 if exists(select 1 from unnest(p_hidden) h where h not in ('next_round','last_game','career_summary','my_peladas')) then raise exception 'INVALID_LAYOUT'; end if;
 if cardinality(p_hidden) <> (select count(distinct h) from unnest(p_hidden) h) then raise exception 'INVALID_LAYOUT'; end if;
 select version into v_cur from public.user_central_layout where user_id = auth.uid() for update;
 if coalesce(v_cur, 0) <> p_expected_version then raise exception 'LAYOUT_VERSION_CONFLICT'; end if;
 insert into public.user_central_layout(user_id, version, block_order, hidden_blocks) values(auth.uid(), 1, p_order, p_hidden)
 on conflict (user_id) do update set version = public.user_central_layout.version + 1, block_order = excluded.block_order,
  hidden_blocks = excluded.hidden_blocks, updated_at = now();
 return public.get_central_layout();
end $$;

-- Restaurar padrão: remove a personalização (volta a version 0). Idempotente.
create function public.reset_central_layout() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 delete from public.user_central_layout where user_id = auth.uid();
 return public.get_central_layout();
end $$;

---------------------------------------------------------------------------------------------------
-- E05: último jogo disputado e publicado
---------------------------------------------------------------------------------------------------

-- Última partida em que o jogador FOI participante da súmula e que está oficialmente publicada (finalized; as
-- anuladas/canceladas/em votação/rascunho não entram). Números vêm de match_player_results (oficial); defesas
-- difíceis só existem para goleiro com registro confirmado (null = não registrado, 0 = zero real).
create function public.get_my_last_game(p_pelada uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_mem public.pelada_memberships; v_m public.matches; v_part public.match_participants; v_r public.match_player_results;
 v_sess text; v_legacy boolean; v_saves integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_mem from public.pelada_memberships where pelada_id = p_pelada and user_id = auth.uid() and status = 'active';
 if not found then raise exception 'PELADA_NOT_FOUND'; end if;
 select m.* into v_m from public.matches m join public.match_participants mp on mp.match_id = m.id and mp.membership_id = v_mem.id
 where m.pelada_id = p_pelada and m.status = 'finalized' order by m.played_at desc, m.id desc limit 1;
 if not found then return jsonb_build_object('game', null); end if;
 select * into v_part from public.match_participants where match_id = v_m.id and membership_id = v_mem.id;
 select * into v_r from public.match_player_results where match_id = v_m.id and membership_id = v_mem.id;
 select status into v_sess from public.rating_vote_sessions where match_id = v_m.id;
 v_legacy := exists(select 1 from public.voting_sessions where match_id = v_m.id and status = 'finalized');
 select hard_saves into v_saves from public.match_keeper_saves where match_id = v_m.id and participant_id = v_part.id;
 return jsonb_build_object('game', jsonb_build_object(
  'match_id', v_m.id, 'played_at', v_m.played_at, 'team_a_name', v_m.team_a_name, 'team_b_name', v_m.team_b_name,
  'team_a_score', v_m.team_a_score, 'team_b_score', v_m.team_b_score, 'my_team', v_part.team,
  'position', v_part.primary_position,
  'goals', v_r.goals, 'assists', v_r.assists, 'red_cards', v_r.red_cards,
  'hard_saves', v_saves,
  'final_rating', v_r.final_rating, 'has_valid_rating', coalesce(v_r.has_valid_rating, false),
  'rating_session_status', v_sess, 'legacy_finalized', v_legacy));
end $$;

---------------------------------------------------------------------------------------------------
-- Grants
---------------------------------------------------------------------------------------------------
revoke all on function private.notification_visible(public.notification_events), private.purge_old_notifications() from public, anon, authenticated;
revoke all on function public.has_unread_notifications(), public.get_my_notifications(jsonb,integer), public.mark_notification_read(uuid),
 public.mark_all_notifications_read(), public.get_central_layout(), public.set_central_layout(text[],text[],integer),
 public.reset_central_layout(), public.get_my_last_game(uuid) from public, anon;
grant execute on function public.has_unread_notifications(), public.get_my_notifications(jsonb,integer), public.mark_notification_read(uuid),
 public.mark_all_notifications_read(), public.get_central_layout(), public.set_central_layout(text[],text[],integer),
 public.reset_central_layout(), public.get_my_last_game(uuid) to authenticated;
