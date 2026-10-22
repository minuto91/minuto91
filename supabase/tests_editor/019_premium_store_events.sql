-- Vínculo compra↔pelada e eventos da loja fora de ordem (migração 026). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 019_premium_store_events" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('c2600000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Evento da loja como o webhook manda (minuto = ordem do evento na loja).
create function pg_temp.ev(p_id text, p_type text, n int, p_exp timestamptz, p_minute int, p_extra jsonb default '{}')
returns text language plpgsql as
 $$ declare r text; begin
  perform set_config('role','service_role',true);
  r := public.apply_subscription_event(jsonb_build_object('id',p_id,'type',p_type,'app_user_id',pg_temp.uid(n)::text,
   'product_id','premium_mensal','expiration_at_ms',extract(epoch from p_exp)*1000,
   'event_timestamp_ms',extract(epoch from now()-interval '1 day'+p_minute*interval '1 minute')*1000) || p_extra);
  execute 'reset role';
  return r;
 end $$;
create function pg_temp.premium(p uuid) returns boolean language sql as $$ select private.pelada_has_premium(p) $$;

do $test$
declare v_p1 uuid; v_p2 uuid; v_p4 uuid; v_p5 uuid; v_tok text; v_b1 uuid; v_b2 uuid; v_b4 uuid;
 v_until timestamptz := date_trunc('second', now()+interval '30 days');
 v_tx jsonb := '{"original_transaction_id":"tx-p1"}';
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-se'||n||'@example.invalid','',now(),now(),now() from generate_series(1,4) n;
perform set_config('role','authenticated',true);
for i in 1..4 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_p1 := public.create_pelada('Pelada Paga','attacker');
v_p2 := public.create_pelada('Outra do Admin','attacker');
v_tok := public.create_pelada_invite(v_p1);
perform pg_temp.as_user(2); perform public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(3); perform public.join_pelada(v_tok,'midfielder');
perform pg_temp.as_user(1); perform public.set_assistant(v_p1,pg_temp.mem(v_p1,3),true);

-- ===== Beta: nenhuma compra pode começar (sem cobrança real) =====
perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_p1),'PREMIUM_BETA_ACTIVE');
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);

-- ===== Só o admin, e não pelo papel anon =====
perform pg_temp.as_user(2); perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_p1),'ADMIN_REQUIRED');
perform pg_temp.as_user(3); perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_p1),'ADMIN_REQUIRED');
perform pg_temp.as_user(4); perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_p1),'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('select public.apply_subscription_event(%L)','{"id":"x","type":"RENEWAL"}'),'permission denied');
perform set_config('role','anon',true);
perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_p1),'permission denied');
perform set_config('role','authenticated',true);

-- ===== Uma compra pendente por comprador: a última pelada escolhida vale =====
perform pg_temp.as_user(1);
v_b2 := public.start_premium_purchase(v_p2);
v_b1 := public.start_premium_purchase(v_p1);
execute 'reset role';
perform pg_temp.assert((select status='expired' from public.subscription_purchasers where id=v_b2),'pendente da outra pelada fechada');
perform pg_temp.assert(pg_temp.ev('se-1','INITIAL_PURCHASE',1,v_until,10,v_tx)='activated','compra ativada');
perform pg_temp.assert(pg_temp.premium(v_p1) and not pg_temp.premium(v_p2),'Premium só na pelada escolhida');
perform pg_temp.assert(pg_temp.ev('se-1','INITIAL_PURCHASE',1,v_until,10,v_tx)='duplicate','evento repetido');
perform set_config('role','authenticated',true);
perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_p2),'BUYER_ALREADY_SUBSCRIBED');
perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_p1),'ALREADY_SUBSCRIBED');
execute 'reset role';

-- ===== Fora de ordem: expiração antiga chega depois da renovação =====
perform pg_temp.assert(pg_temp.ev('se-2','RENEWAL',1,v_until+interval '30 days',40,v_tx)='activated','renovação');
perform pg_temp.assert(pg_temp.ev('se-3','EXPIRATION',1,v_until,30,v_tx)='stale','expiração antiga ignorada');
perform pg_temp.assert(pg_temp.premium(v_p1)
 and (select status='active' from public.subscription_purchasers where id=v_b1),'continua Premium');
perform pg_temp.assert((select premium_until=v_until+interval '30 days' from public.pelada_entitlements where pelada_id=v_p1),'período renovado');
perform pg_temp.assert(pg_temp.ev('se-4','BILLING_ISSUE',1,v_until,45,v_tx)='billing_issue','problema de cobrança registrado');
perform pg_temp.assert(pg_temp.premium(v_p1),'cobrança pendente não tira o Premium (carência da loja)');

-- ===== Troca de admin: a assinatura continua na pelada =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1); perform public.leave_pelada(v_p1);
perform pg_temp.as_user(3);
perform pg_temp.assert(private.is_active_admin(v_p1),'assistente virou admin');
perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_p1),'ALREADY_SUBSCRIBED');
execute 'reset role';
perform pg_temp.assert(pg_temp.ev('se-5','RENEWAL',1,v_until+interval '60 days',70,v_tx)='activated','renovação do comprador antigo');
perform pg_temp.assert(pg_temp.ev('se-6','TRANSFER',1,null,80,jsonb_build_object(
 'app_user_id',null,'transferred_from',jsonb_build_array(pg_temp.uid(1)),'transferred_to',jsonb_build_array(pg_temp.uid(2))))='transfer_kept',
 'restaurar em conta que não é admin não muda o comprador');
perform pg_temp.assert(pg_temp.ev('se-7','TRANSFER',1,null,90,jsonb_build_object(
 'app_user_id',null,'transferred_from',jsonb_build_array(pg_temp.uid(1)),'transferred_to',jsonb_build_array(pg_temp.uid(3))))='transferred',
 'restaurar na conta do novo admin');
perform pg_temp.assert((select buyer_user_id=pg_temp.uid(3) from public.subscription_purchasers where id=v_b1),'comprador = novo admin');

-- ===== Reembolso, expiração e reativação =====
perform pg_temp.assert(pg_temp.ev('se-8','CANCELLATION',3,now()-interval '1 minute',100,
 v_tx || '{"cancel_reason":"CUSTOMER_SUPPORT"}')='refunded','reembolso');
perform pg_temp.assert(not pg_temp.premium(v_p1),'reembolso encerra o Premium');
perform pg_temp.assert(pg_temp.ev('se-9','EXPIRATION',3,now()-interval '1 minute',110,v_tx)='expired','expirou');
perform pg_temp.assert(not pg_temp.premium(v_p1)
 and (select status='expired' and plan='free' from public.pelada_entitlements where pelada_id=v_p1),'plano grátis');
perform pg_temp.assert(pg_temp.ev('se-10','RENEWAL',3,v_until,120,v_tx)='activated','reativação depois de expirar');
perform pg_temp.assert(pg_temp.premium(v_p1)
 and (select status='active' from public.subscription_purchasers where id=v_b1),'Premium de volta');

-- ===== Evento sem compra registrada pode ser reprocessado =====
perform pg_temp.assert(pg_temp.ev('se-11','INITIAL_PURCHASE',4,v_until,130)='unmatched','sem compra registrada');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(4);
v_p4 := public.create_pelada('Pelada do 4','attacker');
v_b4 := public.start_premium_purchase(v_p4);
execute 'reset role';
perform pg_temp.assert(pg_temp.ev('se-11','INITIAL_PURCHASE',4,v_until,130)='activated','reenvio processado');
perform pg_temp.assert(pg_temp.premium(v_p4),'Premium após reenvio');

-- ===== Cancelado mas ainda pago: não pode comprar para outra pelada =====
perform pg_temp.assert(pg_temp.ev('se-12','CANCELLATION',4,v_until,140)='cancelled','renovação desligada');
perform pg_temp.assert(pg_temp.premium(v_p4),'mês pago continua');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(4);
v_p5 := public.create_pelada('Segunda do 4','attacker');
perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_p5),'BUYER_ALREADY_SUBSCRIBED');
perform pg_temp.as_user(2);
perform pg_temp.assert((select count(*)=0 from public.subscription_purchasers),'jogador não vê compras de outros');
execute 'reset role';

-- ===== Atributo pelada_id de uma pelada que o comprador não registrou não vale =====
perform pg_temp.assert(pg_temp.ev('se-13','INITIAL_PURCHASE',2,v_until,150,
 jsonb_build_object('subscriber_attributes',jsonb_build_object('pelada_id',jsonb_build_object('value',v_p1))))='unmatched',
 'atributo forjado não liga compra');
perform pg_temp.assert((select count(*)=13 from private.subscription_events where event_id like 'se-%'),'13 eventos registrados');

  raise exception 'PASS: 019_premium_store_events (rollback proposital - nada foi gravado)';
end
$test$;
