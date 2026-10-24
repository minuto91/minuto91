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
