-- Fluxo feliz: onboarding, criar pelada, convite, entrar, assistente, sucessão.
-- Rodar SOMENTE em banco local descartável. Tudo em transação com ROLLBACK.
\set ON_ERROR_STOP on
begin;
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('10000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
create function pg_temp.as_user(n int) returns void language plpgsql as
 $$ begin perform set_config('request.jwt.claim.sub', pg_temp.uid(n)::text, true); end $$;
create function pg_temp.expect_error(p_sql text, p_msg text) returns void language plpgsql as
 $$ begin
  begin execute p_sql; exception when others then
   if sqlerrm like '%'||p_msg||'%' then return; end if;
   raise exception 'erro inesperado "%" (esperado "%") em: %', sqlerrm, p_msg, p_sql;
  end;
  raise exception 'deveria falhar com "%": %', p_msg, p_sql;
 end $$;
create function pg_temp.assert(p_ok boolean, p_msg text) returns void language plpgsql as
 $$ begin if not coalesce(p_ok,false) then raise exception 'FALHOU: %', p_msg; end if; end $$;

insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-t'||n||'@example.invalid','',now(),now(),now() from generate_series(1,6) n;


-- ===== Onboarding =====
set local role authenticated;
select pg_temp.as_user(1);
select pg_temp.expect_error($q$select public.create_pelada('Pelada X','attacker')$q$,'ONBOARDING_REQUIRED');
select pg_temp.expect_error($q$select public.complete_onboarding('Alice',false,true)$q$,'ADULT_DECLARATION_REQUIRED');
select pg_temp.expect_error($q$select public.complete_onboarding('Alice',true,false)$q$,'TERMS_ACCEPTANCE_REQUIRED');
select public.complete_onboarding('Alice',true,true);
select pg_temp.as_user(2); select public.complete_onboarding('Bruno',true,true);
select pg_temp.as_user(3); select public.complete_onboarding('Carla',true,true);
select pg_temp.as_user(4); select public.complete_onboarding('Davi',true,true);
select pg_temp.as_user(5); select public.complete_onboarding('Edu',true,true);
reset role;
select pg_temp.assert((select adult_declared_at is not null and terms_accepted_at is not null
  from public.profiles where id=pg_temp.uid(1)),'carimbos de maioridade/termos gravados');
select pg_temp.assert((select adult_declared_at is null and terms_accepted_at is null
  from public.profiles where id=pg_temp.uid(6)),'usuario 6 sem onboarding');

-- ===== Criar pelada / convite / entrar =====
set local role authenticated;
select pg_temp.as_user(1);
select pg_temp.expect_error($q$select public.create_pelada('Pelada Teste','striker')$q$,'INVALID_POSITION');
select pg_temp.expect_error($q$select public.create_pelada('A','attacker')$q$,'INVALID_NAME');
select public.create_pelada('Pelada Teste','attacker','Sabado') as pelada_id \gset
select public.create_pelada('Pelada Isolada','goalkeeper') as isolated_id \gset
select public.create_pelada_invite(:'pelada_id'::uuid,24,50) as token \gset

select pg_temp.as_user(6);
select pg_temp.expect_error(format('select public.join_pelada(%L,%L)',:'token','defender'),'ONBOARDING_REQUIRED');
select public.complete_onboarding('Fabi',true,true);
select pg_temp.expect_error(format('select public.join_pelada(%L)',:'token'),'POSITION_REQUIRED');
select pg_temp.expect_error(format('select public.join_pelada(%L,%L)',:'token','striker'),'INVALID_POSITION');

select pg_temp.as_user(2); select public.join_pelada(:'token','defender') as m2 \gset
select pg_temp.as_user(3); select public.join_pelada(:'token','midfielder') as m3 \gset
select pg_temp.as_user(4); select public.join_pelada(:'token','goalkeeper') as m4 \gset
select pg_temp.as_user(5); select public.join_pelada(:'token','attacker') as m5 \gset
select pg_temp.as_user(6); select public.join_pelada(:'token','defender') as m6 \gset
-- Entrar de novo estando ativo e idempotente.
select public.join_pelada(:'token') as m6b \gset
reset role;
select pg_temp.assert(:'m6'=:'m6b','join idempotente');
select pg_temp.assert((select preferred_position from public.pelada_memberships where id=:'m4'::uuid)='goalkeeper','posicao gravada');
select pg_temp.assert((select count(*) from public.pelada_memberships where pelada_id=:'pelada_id'::uuid and status='active')=6,'6 ativos');
select pg_temp.assert((select count(*) from public.pelada_memberships where pelada_id=:'pelada_id'::uuid and role='admin' and status='active')=1,'um admin');

-- ===== Assistentes =====
set local role authenticated;
select pg_temp.as_user(2);
select pg_temp.expect_error(format('select public.set_assistant(%L,%L,true)',:'pelada_id',:'m3'),'ADMIN_REQUIRED');
select pg_temp.expect_error(format('select public.set_successor(%L,%L)',:'pelada_id',:'m3'),'ADMIN_REQUIRED');
select pg_temp.as_user(1);
select public.set_assistant(:'pelada_id'::uuid,:'m3'::uuid,true);
select public.set_assistant(:'pelada_id'::uuid,:'m4'::uuid,true);
reset role;
select pg_temp.assert((select assistant_since is not null from public.pelada_memberships where id=:'m3'::uuid),'assistant_since preenchido');
-- Limite gratuito = 1 quando o beta Premium esta fechado.
update private.app_config set value='false'::jsonb where key='premium_beta_open';
set local role authenticated; select pg_temp.as_user(1);
select pg_temp.expect_error(format('select public.set_assistant(%L,%L,true)',:'pelada_id',:'m5'),'ASSISTANT_LIMIT_REACHED');
reset role;
update private.app_config set value='true'::jsonb where key='premium_beta_open';
set local role authenticated; select pg_temp.as_user(1);
select public.set_assistant(:'pelada_id'::uuid,:'m5'::uuid,true);
select public.set_assistant(:'pelada_id'::uuid,:'m5'::uuid,false);
reset role;
select pg_temp.assert((select role='player' and assistant_since is null from public.pelada_memberships where id=:'m5'::uuid),'assistente removido');

-- Troca direta do admin (fora da RPC) e bloqueada ate para o dono do banco.
select pg_temp.expect_error(format('update public.pelada_memberships set role=%L where pelada_id=%L and role=%L','player',:'pelada_id','admin'),'ADMIN_TRANSITION_REQUIRES_RPC');
select pg_temp.expect_error(format('update public.pelada_memberships set role=%L where id=%L','admin',:'m2'),'ADMIN_TRANSITION_REQUIRES_RPC');

-- ===== Ordem de sucessao =====
-- Datas explicitas (now() e igual dentro de uma transacao).
update public.pelada_memberships set joined_at=now()-interval '10 days' where id=:'m2'::uuid;
update public.pelada_memberships set joined_at=now()-interval '9 days'  where id=:'m5'::uuid;
update public.pelada_memberships set joined_at=now()-interval '8 days'  where id=:'m6'::uuid;
update public.pelada_memberships set assistant_since=now()-interval '3 days' where id=:'m4'::uuid; -- mais antigo
update public.pelada_memberships set assistant_since=now()-interval '2 days' where id=:'m3'::uuid;

-- 1) Sucessor indicado vence assistente e jogador mais antigo.
set local role authenticated; select pg_temp.as_user(1);
select pg_temp.expect_error(format('select public.set_successor(%L,%L)',:'pelada_id',(select id from public.pelada_memberships where user_id=pg_temp.uid(1) and pelada_id=:'pelada_id'::uuid)),'INVALID_SUCCESSOR');
select public.set_successor(:'pelada_id'::uuid,:'m6'::uuid);
select public.leave_pelada(:'pelada_id'::uuid) as r1 \gset
reset role;
select pg_temp.assert((select role='admin' from public.pelada_memberships where id=:'m6'::uuid),'sucessor indicado virou admin');
select pg_temp.assert((:'r1'::jsonb->>'succession_source')='designated','origem designated');
select pg_temp.assert((select successor_membership_id is null from public.peladas where id=:'pelada_id'::uuid),'sucessor limpo');

-- 2) Sem sucessor: assistente mais antigo (m4, goleiro) antes do jogador mais antigo (m2).
set local role authenticated; select pg_temp.as_user(6);
select public.leave_pelada(:'pelada_id'::uuid) as r2 \gset
reset role;
select pg_temp.assert((select role='admin' and assistant_since is null from public.pelada_memberships where id=:'m4'::uuid),'assistente mais antigo assumiu');
select pg_temp.assert((:'r2'::jsonb->>'succession_source')='assistant','origem assistant');

-- 3) Sai o admin atual (m4): proximo assistente (m3).
set local role authenticated; select pg_temp.as_user(4);
select public.leave_pelada(:'pelada_id'::uuid);
reset role;
select pg_temp.assert((select role='admin' from public.pelada_memberships where id=:'m3'::uuid),'segundo assistente assumiu');

-- 4) Sai o admin (m3): sem assistentes, jogador ativo mais antigo (m2 - 10 dias).
set local role authenticated; select pg_temp.as_user(3);
select public.leave_pelada(:'pelada_id'::uuid) as r4 \gset
reset role;
select pg_temp.assert((select role='admin' from public.pelada_memberships where id=:'m2'::uuid),'jogador mais antigo assumiu');
select pg_temp.assert((:'r4'::jsonb->>'succession_source')='player','origem player');

-- ===== Reentrada: mesmo registro, joined_at preservado =====
set local role authenticated; select pg_temp.as_user(2);
select public.create_pelada_invite(:'pelada_id'::uuid) as token2 \gset
select pg_temp.as_user(6); select public.join_pelada(:'token2') as m6r \gset
reset role;
select pg_temp.assert(:'m6r'=:'m6','reentrada reativa o mesmo registro');
select pg_temp.assert((select joined_at < now()-interval '7 days' and role='player' and assistant_since is null
  from public.pelada_memberships where id=:'m6'::uuid),'joined_at mantido, papel resetado');
select pg_temp.assert((select count(*) from public.pelada_memberships where pelada_id=:'pelada_id'::uuid and user_id=pg_temp.uid(6))=1,'sem registro duplicado');

-- ===== Convites: revogado e expirado =====
set local role authenticated; select pg_temp.as_user(2);
select public.revoke_pelada_invites(:'pelada_id'::uuid);
select pg_temp.as_user(3);
select pg_temp.expect_error(format('select public.join_pelada(%L,%L)',:'token2','midfielder'),'INVALID_OR_EXPIRED_INVITE');
select pg_temp.as_user(2);
select public.create_pelada_invite(:'pelada_id'::uuid,1,1) as token3 \gset
reset role;
update private.pelada_invites set expires_at=now()-interval '1 minute' where pelada_id=:'pelada_id'::uuid and revoked_at is null;
set local role authenticated; select pg_temp.as_user(3);
select pg_temp.expect_error(format('select public.join_pelada(%L,%L)',:'token3','midfielder'),'INVALID_OR_EXPIRED_INVITE');

-- ===== Isolamento RLS =====
select pg_temp.as_user(2);
select pg_temp.assert(not exists(select 1 from public.peladas where id=:'isolated_id'::uuid),'RLS: pelada alheia invisivel');
select pg_temp.assert(not exists(select 1 from public.pelada_settings where pelada_id=:'isolated_id'::uuid),'RLS: settings alheios invisiveis');
reset role;

-- ===== Admin sozinho sai: pelada restrita =====
select pg_temp.assert((select status from public.peladas where id=:'isolated_id'::uuid)='active','pelada isolada ativa');
set local role authenticated; select pg_temp.as_user(1);
select public.leave_pelada(:'isolated_id'::uuid) as r5 \gset
reset role;
select pg_temp.assert((:'r5'::jsonb->>'pelada_restricted')::boolean,'pelada restrita sem elegivel');
select pg_temp.assert((select status from public.peladas where id=:'isolated_id'::uuid)='restricted','status restricted');

rollback;
\echo 'PASS: smoke (onboarding, convites, assistentes, sucessao, reentrada, RLS)'
