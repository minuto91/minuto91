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

do $test$
declare
  v_isolated_id text;
  v_m2 text;
  v_m3 text;
  v_m4 text;
  v_m5 text;
  v_m6 text;
  v_m6b text;
  v_m6r text;
  v_pelada_id text;
  v_r1 text;
  v_r2 text;
  v_r4 text;
  v_r5 text;
  v_token text;
  v_token2 text;
  v_token3 text;
begin
-- Fluxo feliz: onboarding, criar pelada, convite, entrar, assistente, sucessão.





insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-t'||n||'@example.invalid','',now(),now(),now() from generate_series(1,6) n;


-- ===== Onboarding =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error($q$select public.create_pelada('Pelada X','attacker')$q$,'ONBOARDING_REQUIRED');
perform pg_temp.expect_error($q$select public.complete_onboarding('Alice',false,true)$q$,'ADULT_DECLARATION_REQUIRED');
perform pg_temp.expect_error($q$select public.complete_onboarding('Alice',true,false)$q$,'TERMS_ACCEPTANCE_REQUIRED');
perform public.complete_onboarding('Alice',true,true);
perform pg_temp.as_user(2); perform public.complete_onboarding('Bruno',true,true);
perform pg_temp.as_user(3); perform public.complete_onboarding('Carla',true,true);
perform pg_temp.as_user(4); perform public.complete_onboarding('Davi',true,true);
perform pg_temp.as_user(5); perform public.complete_onboarding('Edu',true,true);
execute 'reset role';
perform pg_temp.assert((select adult_declared_at is not null and terms_accepted_at is not null
  from public.profiles where id=pg_temp.uid(1)),'carimbos de maioridade/termos gravados');
perform pg_temp.assert((select adult_declared_at is null and terms_accepted_at is null
  from public.profiles where id=pg_temp.uid(6)),'usuario 6 sem onboarding');

-- ===== Criar pelada / convite / entrar =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error($q$select public.create_pelada('Pelada Teste','striker')$q$,'INVALID_POSITION');
perform pg_temp.expect_error($q$select public.create_pelada('A','attacker')$q$,'INVALID_NAME');
v_pelada_id := public.create_pelada('Pelada Teste','attacker','Sabado');
v_isolated_id := public.create_pelada('Pelada Isolada','goalkeeper');
v_token := public.create_pelada_invite(v_pelada_id::uuid,24,50);

perform pg_temp.as_user(6);
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)',v_token,'defender'),'ONBOARDING_REQUIRED');
perform public.complete_onboarding('Fabi',true,true);
perform pg_temp.expect_error(format('select public.join_pelada(%L)',v_token),'POSITION_REQUIRED');
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)',v_token,'striker'),'INVALID_POSITION');

perform pg_temp.as_user(2); v_m2 := public.join_pelada(v_token,'defender');
perform pg_temp.as_user(3); v_m3 := public.join_pelada(v_token,'midfielder');
perform pg_temp.as_user(4); v_m4 := public.join_pelada(v_token,'goalkeeper');
perform pg_temp.as_user(5); v_m5 := public.join_pelada(v_token,'attacker');
perform pg_temp.as_user(6); v_m6 := public.join_pelada(v_token,'defender');
-- Entrar de novo estando ativo e idempotente.
v_m6b := public.join_pelada(v_token);
execute 'reset role';
perform pg_temp.assert(v_m6=v_m6b,'join idempotente');
perform pg_temp.assert((select preferred_position from public.pelada_memberships where id=v_m4::uuid)='goalkeeper','posicao gravada');
perform pg_temp.assert((select count(*) from public.pelada_memberships where pelada_id=v_pelada_id::uuid and status='active')=6,'6 ativos');
perform pg_temp.assert((select count(*) from public.pelada_memberships where pelada_id=v_pelada_id::uuid and role='admin' and status='active')=1,'um admin');

-- ===== Assistentes =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.set_assistant(%L,%L,true)',v_pelada_id,v_m3),'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('select public.set_successor(%L,%L)',v_pelada_id,v_m3),'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
perform public.set_assistant(v_pelada_id::uuid,v_m3::uuid,true);
perform public.set_assistant(v_pelada_id::uuid,v_m4::uuid,true);
execute 'reset role';
perform pg_temp.assert((select assistant_since is not null from public.pelada_memberships where id=v_m3::uuid),'assistant_since preenchido');
-- Limite gratuito = 1 quando o beta Premium esta fechado.
update private.app_config set value='false'::jsonb where key='premium_beta_open';
set local role authenticated; perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.set_assistant(%L,%L,true)',v_pelada_id,v_m5),'ASSISTANT_LIMIT_REACHED');
execute 'reset role';
update private.app_config set value='true'::jsonb where key='premium_beta_open';
set local role authenticated; perform pg_temp.as_user(1);
perform public.set_assistant(v_pelada_id::uuid,v_m5::uuid,true);
perform public.set_assistant(v_pelada_id::uuid,v_m5::uuid,false);
execute 'reset role';
perform pg_temp.assert((select role='player' and assistant_since is null from public.pelada_memberships where id=v_m5::uuid),'assistente removido');

-- Troca direta do admin (fora da RPC) e bloqueada ate para o dono do banco.
perform pg_temp.expect_error(format('update public.pelada_memberships set role=%L where pelada_id=%L and role=%L','player',v_pelada_id,'admin'),'ADMIN_TRANSITION_REQUIRES_RPC');
perform pg_temp.expect_error(format('update public.pelada_memberships set role=%L where id=%L','admin',v_m2),'ADMIN_TRANSITION_REQUIRES_RPC');

-- ===== Ordem de sucessao =====
-- Datas explicitas (now() e igual dentro de uma transacao).
update public.pelada_memberships set joined_at=now()-interval '10 days' where id=v_m2::uuid;
update public.pelada_memberships set joined_at=now()-interval '9 days'  where id=v_m5::uuid;
update public.pelada_memberships set joined_at=now()-interval '8 days'  where id=v_m6::uuid;
update public.pelada_memberships set assistant_since=now()-interval '3 days' where id=v_m4::uuid; -- mais antigo
update public.pelada_memberships set assistant_since=now()-interval '2 days' where id=v_m3::uuid;

-- 1) Sucessor indicado vence assistente e jogador mais antigo.
set local role authenticated; perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.set_successor(%L,%L)',v_pelada_id,(select id from public.pelada_memberships where user_id=pg_temp.uid(1) and pelada_id=v_pelada_id::uuid)),'INVALID_SUCCESSOR');
perform public.set_successor(v_pelada_id::uuid,v_m6::uuid);
v_r1 := public.leave_pelada(v_pelada_id::uuid);
execute 'reset role';
perform pg_temp.assert((select role='admin' from public.pelada_memberships where id=v_m6::uuid),'sucessor indicado virou admin');
perform pg_temp.assert((v_r1::jsonb->>'succession_source')='designated','origem designated');
perform pg_temp.assert((select successor_membership_id is null from public.peladas where id=v_pelada_id::uuid),'sucessor limpo');

-- 2) Sem sucessor: assistente mais antigo (m4, goleiro) antes do jogador mais antigo (m2).
set local role authenticated; perform pg_temp.as_user(6);
v_r2 := public.leave_pelada(v_pelada_id::uuid);
execute 'reset role';
perform pg_temp.assert((select role='admin' and assistant_since is null from public.pelada_memberships where id=v_m4::uuid),'assistente mais antigo assumiu');
perform pg_temp.assert((v_r2::jsonb->>'succession_source')='assistant','origem assistant');

-- 3) Sai o admin atual (m4): proximo assistente (m3).
set local role authenticated; perform pg_temp.as_user(4);
perform public.leave_pelada(v_pelada_id::uuid);
execute 'reset role';
perform pg_temp.assert((select role='admin' from public.pelada_memberships where id=v_m3::uuid),'segundo assistente assumiu');

-- 4) Sai o admin (m3): sem assistentes, jogador ativo mais antigo (m2 - 10 dias).
set local role authenticated; perform pg_temp.as_user(3);
v_r4 := public.leave_pelada(v_pelada_id::uuid);
execute 'reset role';
perform pg_temp.assert((select role='admin' from public.pelada_memberships where id=v_m2::uuid),'jogador mais antigo assumiu');
perform pg_temp.assert((v_r4::jsonb->>'succession_source')='player','origem player');

-- ===== Reentrada: mesmo registro, joined_at preservado =====
set local role authenticated; perform pg_temp.as_user(2);
v_token2 := public.create_pelada_invite(v_pelada_id::uuid);
perform pg_temp.as_user(6); v_m6r := public.join_pelada(v_token2);
execute 'reset role';
perform pg_temp.assert(v_m6r=v_m6,'reentrada reativa o mesmo registro');
perform pg_temp.assert((select joined_at < now()-interval '7 days' and role='player' and assistant_since is null
  from public.pelada_memberships where id=v_m6::uuid),'joined_at mantido, papel resetado');
perform pg_temp.assert((select count(*) from public.pelada_memberships where pelada_id=v_pelada_id::uuid and user_id=pg_temp.uid(6))=1,'sem registro duplicado');

-- ===== Convites: revogado e expirado =====
set local role authenticated; perform pg_temp.as_user(2);
perform public.revoke_pelada_invites(v_pelada_id::uuid);
perform pg_temp.as_user(3);
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)',v_token2,'midfielder'),'INVALID_OR_EXPIRED_INVITE');
perform pg_temp.as_user(2);
v_token3 := public.create_pelada_invite(v_pelada_id::uuid,1,1);
execute 'reset role';
update private.pelada_invites set expires_at=now()-interval '1 minute' where pelada_id=v_pelada_id::uuid and revoked_at is null;
set local role authenticated; perform pg_temp.as_user(3);
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)',v_token3,'midfielder'),'INVALID_OR_EXPIRED_INVITE');

-- ===== Isolamento RLS =====
perform pg_temp.as_user(2);
perform pg_temp.assert(not exists(select 1 from public.peladas where id=v_isolated_id::uuid),'RLS: pelada alheia invisivel');
perform pg_temp.assert(not exists(select 1 from public.pelada_settings where pelada_id=v_isolated_id::uuid),'RLS: settings alheios invisiveis');
execute 'reset role';

-- ===== Admin sozinho sai: pelada restrita =====
perform pg_temp.assert((select status from public.peladas where id=v_isolated_id::uuid)='active','pelada isolada ativa');
set local role authenticated; perform pg_temp.as_user(1);
v_r5 := public.leave_pelada(v_isolated_id::uuid);
execute 'reset role';
perform pg_temp.assert((v_r5::jsonb->>'pelada_restricted')::boolean,'pelada restrita sem elegivel');
perform pg_temp.assert((select status from public.peladas where id=v_isolated_id::uuid)='restricted','status restricted');


  raise exception 'PASS: 001_smoke (rollback proposital - nada foi gravado)';
end
$test$;
