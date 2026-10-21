-- Premium, teste grátis e eventos da loja (migração 019). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 012_premium" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('c0000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.event(p_id text, p_type text, n int, p_exp timestamptz) returns text language plpgsql as
 $$ declare r text; begin
  perform set_config('role','service_role',true);
  r := public.apply_subscription_event(jsonb_build_object('id',p_id,'type',p_type,'app_user_id',pg_temp.uid(n)::text,
   'product_id','premium_mensal','original_transaction_id','tx-'||n,'expiration_at_ms',extract(epoch from p_exp)*1000));
  execute 'reset role';
  return r;
 end $$;

do $test$
declare v_p1 uuid; v_p2 uuid; v_p3 uuid; v_p5 uuid; v_tok text; v_e jsonb; v_buy uuid; v_until timestamptz;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-pr'||n||'@example.invalid','',now(),now(),now() from generate_series(1,6) n;
perform set_config('role','authenticated',true);
for i in 1..6 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_p1 := public.create_pelada('Pelada Premium','attacker');
v_tok := public.create_pelada_invite(v_p1);
for i in 2..4 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,'defender'); end loop;
perform pg_temp.as_user(6); perform public.join_pelada(v_tok,'midfielder');
perform pg_temp.as_user(5); v_p2 := public.create_pelada('Pelada do Comprador','attacker');
v_p5 := public.create_pelada('Segunda do Comprador','attacker');

-- ===== Beta ligado: tudo Premium, sem teste nem compra =====
perform pg_temp.as_user(1);
v_e := public.get_pelada_entitlement(v_p1);
perform pg_temp.assert((v_e->>'is_premium')::boolean and v_e->>'source'='beta' and not (v_e->>'trial_available')::boolean,'beta = Premium');
perform pg_temp.expect_error(format('select public.start_premium_trial(%L)',v_p1),'PREMIUM_BETA_ACTIVE');
perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_p1),'PREMIUM_BETA_ACTIVE');
for i in 2..4 loop perform public.set_assistant(v_p1,pg_temp.mem(v_p1,i),true); end loop; -- 3 assistentes (Premium)
perform pg_temp.as_user(6);
perform pg_temp.expect_error(format('select public.get_pelada_entitlement(%L)',v_p5),'PELADA_NOT_FOUND');
execute 'reset role';
-- Antiguidade dos assistentes: 2, depois 3, depois 4.
for i in 2..4 loop
 update public.pelada_memberships set assistant_since=now()-((5-i)||' days')::interval where id=pg_temp.mem(v_p1,i);
end loop;
insert into public.player_career_stats(pelada_id,membership_id,matches_played) values(v_p1,pg_temp.mem(v_p1,6),3);

-- ===== Fim do beta, sem Premium =====
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_e := public.get_pelada_entitlement(v_p1);
perform pg_temp.assert(not (v_e->>'is_premium')::boolean and (v_e->>'trial_available')::boolean,'grátis, teste disponível');
-- RN-096: só o assistente mais antigo mantém os poderes.
perform pg_temp.as_user(2); perform public.create_match(v_p1,now());
perform pg_temp.as_user(3); perform pg_temp.expect_error(format('select public.create_match(%L,%L)',v_p1,now()),'STAFF_REQUIRED');
perform pg_temp.as_user(4); perform pg_temp.expect_error(format('select public.create_match(%L,%L)',v_p1,now()),'STAFF_REQUIRED');
perform pg_temp.as_user(6);
perform pg_temp.assert((select count(*)=0 from public.player_career_stats where pelada_id=v_p1),'carreira é Premium');

-- ===== Teste grátis (botão do admin) =====
perform pg_temp.expect_error(format('select public.start_premium_trial(%L)',v_p1),'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
perform public.start_premium_trial(v_p1);
v_e := public.get_pelada_entitlement(v_p1);
perform pg_temp.assert((v_e->>'is_premium')::boolean and v_e->>'source'='trial'
  and (v_e->>'trial_ends_at')::timestamptz=now()+interval '30 days','30 dias de teste');
perform pg_temp.expect_error(format('select public.start_premium_trial(%L)',v_p1),'TRIAL_ALREADY_USED');
v_p3 := public.create_pelada('Outra do Admin','attacker');
perform pg_temp.expect_error(format('select public.start_premium_trial(%L)',v_p3),'TRIAL_ALREADY_USED'); -- 1 por conta
perform pg_temp.as_user(3); perform public.create_match(v_p1,now()); -- com Premium, 3 assistentes de novo
perform pg_temp.as_user(6);
perform pg_temp.assert((select count(*)=1 from public.player_career_stats where pelada_id=v_p1),'carreira visível no teste');
-- Troca de admin não reinicia o teste (1 por pelada).
perform pg_temp.as_user(1); perform public.leave_pelada(v_p1);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.start_premium_trial(%L)',v_p1),'TRIAL_ALREADY_USED');

-- ===== Compra e eventos da loja =====
perform pg_temp.as_user(5);
v_buy := public.start_premium_purchase(v_p2);
perform pg_temp.assert(public.start_premium_purchase(v_p2)=v_buy,'compra pendente reaproveitada');
perform pg_temp.expect_error(format('select public.apply_subscription_event(%L)','{"id":"x","type":"RENEWAL"}'),'permission denied');
execute 'reset role';
v_until := date_trunc('second', now()+interval '30 days'); -- a loja manda milissegundos
perform pg_temp.assert(pg_temp.event('ev-1','INITIAL_PURCHASE',5,v_until)='activated','compra ativada');
perform pg_temp.assert(pg_temp.event('ev-1','INITIAL_PURCHASE',5,v_until)='duplicate','evento repetido ignorado');
perform pg_temp.assert(pg_temp.event('ev-2','RENEWAL',5,now()+interval '10 days')='activated','renovação');
perform pg_temp.assert((select premium_until=v_until and status='active' from public.pelada_entitlements where pelada_id=v_p2),'período pago não encurta');
perform pg_temp.assert(pg_temp.event('ev-3','INITIAL_PURCHASE',6,v_until)='unmatched','evento sem compra registrada');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(5);
v_e := public.get_pelada_entitlement(v_p2);
perform pg_temp.assert((v_e->>'is_premium')::boolean and v_e->>'source'='subscription','Premium pago');
perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_p2),'ALREADY_SUBSCRIBED');
perform pg_temp.expect_error(format('select public.start_premium_purchase(%L)',v_p5),'BUYER_ALREADY_SUBSCRIBED');
perform pg_temp.expect_error(format('select public.start_premium_trial(%L)',v_p2),'ALREADY_PREMIUM');
perform pg_temp.assert((select count(*)=1 from public.subscription_purchasers),'comprador vê só a própria compra');
execute 'reset role';
perform pg_temp.assert(pg_temp.event('ev-4','CANCELLATION',5,v_until)='cancelled','renovação cancelada');
perform pg_temp.assert(private.pelada_has_premium(v_p2),'cancelar não tira o mês pago');
perform pg_temp.assert(pg_temp.event('ev-5','EXPIRATION',5,v_until)='expired','expirou');
perform pg_temp.assert((select status='expired' from public.subscription_purchasers where id=v_buy),'compra expirada');
perform pg_temp.assert((select count(*)=5 from private.subscription_events where event_id like 'ev-%'),'5 eventos registrados');
update private.app_config set value='true'::jsonb where key='premium_beta_open';

  raise exception 'PASS: 012_premium (rollback proposital - nada foi gravado)';
end
$test$;
