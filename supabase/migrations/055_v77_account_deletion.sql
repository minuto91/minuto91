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
