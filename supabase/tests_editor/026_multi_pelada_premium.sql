-- Uma conta, vários papéis e Premium isolado por pelada (auditoria V3, Fase 4). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 026_multi_pelada_premium" = tudo certo, nada gravado
-- (o beta é desligado só dentro do teste e volta sozinho no rollback).
-- Cenário: o usuário 1 é admin e jogador das peladas A e B e só jogador da C (admin: usuário 2).
-- Só a A fica Premium (compra pela loja). Nada da A pode valer na B ou na C, nem o papel de admin.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('c2860000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.mem(p_pelada uuid, n int) returns uuid language sql as
 $$ select id from public.pelada_memberships where pelada_id=p_pelada and user_id=pg_temp.uid(n) $$;
create function pg_temp.premium(p uuid) returns boolean language sql as $$ select private.pelada_has_premium(p) $$;
-- O que o app recebe para a pelada p (como o usuário atual).
create function pg_temp.ent(p uuid) returns jsonb language sql as $$ select public.get_pelada_entitlement(p) $$;
-- Evento da loja como o webhook manda; volta ao papel authenticated no fim.
create function pg_temp.ev(p_id text, p_type text, n int, p_pelada uuid, p_tx text) returns text language plpgsql as
 $$ declare r text; begin
  execute 'reset role';
  perform set_config('role','service_role',true);
  r := public.apply_subscription_event(jsonb_build_object('id',p_id,'type',p_type,'app_user_id',pg_temp.uid(n)::text,
   'product_id','premium_mensal','original_transaction_id',p_tx,
   'expiration_at_ms',extract(epoch from now()+interval '30 days')*1000,
   'event_timestamp_ms',extract(epoch from now())*1000,
   'subscriber_attributes',jsonb_build_object('pelada_id',jsonb_build_object('value',p_pelada::text))));
  execute 'reset role';
  perform set_config('role','authenticated',true);
  return r;
 end $$;

do $test$
declare v_a uuid; v_b uuid; v_c uuid; v_tok text; r text;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-mp'||n||'@example.invalid','',now(),now(),now() from generate_series(1,5) n;
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
for i in 1..5 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;

-- A e B: admin 1, com 3, 4 e 5. C: admin 2, com 1. O 2 também joga na A.
perform pg_temp.as_user(1);
v_a := public.create_pelada('Pelada A','attacker');
v_b := public.create_pelada('Pelada B','defender');
perform pg_temp.as_user(2); v_c := public.create_pelada('Pelada C','midfielder');
perform pg_temp.as_user(1); v_tok := public.create_pelada_invite(v_a);
for i in 2..5 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,'defender'); end loop;
perform pg_temp.as_user(1); v_tok := public.create_pelada_invite(v_b);
for i in 3..5 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,'midfielder'); end loop;
perform pg_temp.as_user(2); v_tok := public.create_pelada_invite(v_c);
perform pg_temp.as_user(1); perform public.join_pelada(v_tok,'attacker');

-- ===== Uma conta, papéis diferentes por pelada =====
perform pg_temp.assert((select role from public.pelada_memberships where id=pg_temp.mem(v_a,1))='admin','1 admin na A');
perform pg_temp.assert((select role from public.pelada_memberships where id=pg_temp.mem(v_b,1))='admin','1 admin na B');
perform pg_temp.assert((select role from public.pelada_memberships where id=pg_temp.mem(v_c,1))='player','1 jogador na C');
perform pg_temp.assert((select count(*) from public.profiles where id=pg_temp.uid(1))=1,'uma conta só');
-- Ser admin da A e da B não dá nada na C.
perform pg_temp.expect_error(format('select public.update_pelada_settings(%L,240,false,null)',v_c),'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('select public.set_assistant(%L,%L,true)',v_c,pg_temp.mem(v_c,1)),'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_c),'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('select public.start_premium_trial(%L)',v_c),'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('select public.set_pelada_crest(%L,%L)',v_c,v_c::text||'/'||gen_random_uuid()::text||'.png'),'ADMIN_REQUIRED');
-- E ser admin da C não dá nada na A (onde o 2 é jogador).
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.update_pelada_settings(%L,240,false,null)',v_a),'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('select public.set_assistant(%L,%L,true)',v_a,pg_temp.mem(v_a,3)),'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_a),'ADMIN_REQUIRED');

-- ===== Sem beta, ninguém é Premium =====
perform pg_temp.assert(not pg_temp.premium(v_a) and not pg_temp.premium(v_b) and not pg_temp.premium(v_c),'sem beta: todas grátis');

-- ===== A assina pela loja =====
perform pg_temp.as_user(1); perform public.start_premium_purchase(v_a);
r := pg_temp.ev('mp-1','INITIAL_PURCHASE',1,v_a,'tx-a');
perform pg_temp.assert(r='activated','compra da A ativada: '||r);
perform pg_temp.assert(pg_temp.premium(v_a),'A Premium');
perform pg_temp.assert(not pg_temp.premium(v_b),'B continua grátis (mesmo admin)');
perform pg_temp.assert(not pg_temp.premium(v_c),'C continua grátis (mesmo jogador)');
perform pg_temp.as_user(1);
perform pg_temp.assert((pg_temp.ent(v_a)->>'is_premium')::boolean,'app: A Premium');
perform pg_temp.assert(not (pg_temp.ent(v_b)->>'is_premium')::boolean,'app: B grátis');
perform pg_temp.assert(not (pg_temp.ent(v_c)->>'is_premium')::boolean and not (pg_temp.ent(v_c)->>'is_admin')::boolean,'app: C grátis e sem admin');

-- ===== Benefícios só na A =====
-- Nomes dos times.
perform public.create_match(v_a, now(), 'Azul', 'Branco');
perform pg_temp.expect_error(format('select public.create_match(%L,%L,''Azul'',''Branco'')',v_b,now()),'TEAM_NAMES_PREMIUM');
-- Bola Murcha desligável.
perform public.update_pelada_settings(v_a,240,false,null);
perform pg_temp.expect_error(format('select public.update_pelada_settings(%L,240,false,null)',v_b),'PREMIUM_REQUIRED');
-- Assistentes: 3 na A, 1 na B.
perform public.set_assistant(v_a,pg_temp.mem(v_a,3),true);
perform public.set_assistant(v_a,pg_temp.mem(v_a,4),true);
perform public.set_assistant(v_a,pg_temp.mem(v_a,5),true);
perform public.set_assistant(v_b,pg_temp.mem(v_b,3),true);
perform pg_temp.expect_error(format('select public.set_assistant(%L,%L,true)',v_b,pg_temp.mem(v_b,4)),'ASSISTANT_LIMIT_REACHED');
-- Temporada personalizada.
perform pg_temp.expect_error(format('select public.customize_season(%L,''keep_current'',''Temporada B'',null,%L,true)',
 v_b,(current_date+60)),'PREMIUM_REQUIRED');

-- ===== A compra da A não migra para a B =====
-- Uma conta da loja = uma assinatura com período pago.
perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_b),'BUYER_ALREADY_SUBSCRIBED');
-- Renovação da A chegando com o atributo apontando para a B (atributo antigo ou forjado no aparelho).
r := pg_temp.ev('mp-2','RENEWAL',1,v_b,'tx-a');
perform pg_temp.assert(r='activated','renovação aplicada: '||r);
perform pg_temp.assert(not pg_temp.premium(v_b),'atributo da B não liberou a B');
perform pg_temp.assert((select count(*) from public.subscription_purchasers where pelada_id=v_b)=0,'nenhuma compra registrada na B');
perform pg_temp.assert(pg_temp.premium(v_a),'A segue Premium');

-- ===== Teste grátis da B vale só para a B =====
perform pg_temp.as_user(1); perform public.start_premium_trial(v_b);
perform pg_temp.assert(pg_temp.premium(v_b),'B em teste grátis');
perform pg_temp.assert(not pg_temp.premium(v_c),'C continua grátis');
-- O teste é por pessoa: o mesmo admin não ganha outro para a C (nem é admin dela).
perform pg_temp.as_user(2);
perform pg_temp.assert(not (pg_temp.ent(v_c)->>'is_premium')::boolean,'app do admin da C: grátis');

-- ===== Expiração da A não mexe na B =====
r := pg_temp.ev('mp-3','EXPIRATION',1,v_a,'tx-a');
perform pg_temp.assert(r='expired','A expirou: '||r);
perform pg_temp.assert(not pg_temp.premium(v_a),'A voltou ao grátis');
perform pg_temp.assert(pg_temp.premium(v_b),'B segue no teste grátis');

  raise exception 'PASS: 026_multi_pelada_premium (rollback proposital - nada foi gravado)';
end
$test$;
