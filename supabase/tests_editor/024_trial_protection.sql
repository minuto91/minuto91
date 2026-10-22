-- Proteção do teste grátis do Premium (migração 031). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 024_trial_protection" = tudo certo, nada gravado.
-- Chamadas realmente simultâneas não dá para simular numa transação só: ver o procedimento manual no relatório.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('c2840000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.trial_sql(p uuid) returns text language sql as
 $$ select format('select public.start_premium_trial(%L)', p) $$;

do $test$
declare p1 uuid; p2 uuid; p3 uuid; p4 uuid; p5 uuid; p6 uuid; p7 uuid; p8 uuid; v_tok text; v_code text; v_r jsonb;
 v_g record; v_n int;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-tr'||n||'@example.invalid','',now(),now(),now() from generate_series(1,8) n;
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
for i in 1..8 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;

-- ===== Beta não consome o teste comercial =====
execute 'reset role';
update private.app_config set value='true'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(8); p8 := public.create_pelada('Pelada Oito','attacker');
perform pg_temp.expect_error(pg_temp.trial_sql(p8),'PREMIUM_BETA_ACTIVE');
execute 'reset role';
perform pg_temp.assert(not exists(select 1 from public.premium_trial_usage where admin_user_id=pg_temp.uid(8)),'beta não registra teste');
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(8);
perform pg_temp.assert((public.get_pelada_entitlement(p8)->>'trial_available')::boolean,'depois do beta o teste continua disponível');

-- ===== Uma vez por pelada e por conta; só o admin =====
perform pg_temp.as_user(1); p1 := public.create_pelada('Pelada Um','attacker'); v_tok := public.create_pelada_invite(p1);
-- 3, 4 e 5 ficam fora: a transferência exige que as contas não tenham registro na mesma pelada.
foreach v_n in array array[2,6,7] loop perform pg_temp.as_user(v_n); perform public.join_pelada(v_tok,'defender'); end loop;
perform pg_temp.as_user(2); perform pg_temp.expect_error(pg_temp.trial_sql(p1),'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
perform public.start_premium_trial(p1);
perform pg_temp.expect_error(pg_temp.trial_sql(p1),'TRIAL_ALREADY_USED');
p2 := public.create_pelada('Pelada Dois','attacker');
perform pg_temp.expect_error(pg_temp.trial_sql(p2),'TRIAL_ALREADY_USED');
perform pg_temp.assert(not (public.get_pelada_entitlement(p2)->>'trial_available')::boolean,'conta já usou: botão some');

-- ===== Registro da concessão (para revisão, sem bloqueio) =====
execute 'reset role';
select * into v_g from private.premium_trial_grants where pelada_id=p1;
perform pg_temp.assert(v_g.admin_user_id=pg_temp.uid(1) and v_g.active_players=4 and v_g.suspicious
 and v_g.signals ? 'fresh_admin_and_pelada','concessão registrada; conta e pelada novas = sinal de revisão');
perform set_config('role','authenticated',true);

-- ===== Renomear, expirar e "cancelar" não devolvem o teste =====
perform pg_temp.as_user(1);
perform public.update_pelada_profile(p1,'Pelada Um Renomeada',null,null,null,null,null);
execute 'reset role';
update public.pelada_entitlements set trial_ends_at=now()-interval '1 day', status='expired' where pelada_id=p1;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(pg_temp.trial_sql(p1),'TRIAL_ALREADY_USED');
perform pg_temp.expect_error('delete from public.premium_trial_usage','permission denied');

-- ===== Troca de admin: a pelada continua usada; o novo admin tem o próprio teste para outra pelada =====
perform public.set_successor(p1, pg_temp.mem(p1,2));
perform public.leave_pelada(p1);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(pg_temp.trial_sql(p1),'TRIAL_ALREADY_USED');
p3 := public.create_pelada('Pelada Três','defender');
perform public.start_premium_trial(p3);

-- ===== Transferência de conta: o teste acompanha a pessoa =====
perform pg_temp.as_user(3); p4 := public.create_pelada('Pelada Quatro','attacker');
perform public.start_premium_trial(p4);
v_code := public.create_transfer_code();
perform pg_temp.as_user(4);
v_r := public.redeem_transfer_code(v_code);
perform pg_temp.assert((v_r->>'peladas')::int=1,'histórico (a Pelada Quatro) transferido para a conta 4');
p5 := public.create_pelada('Pelada Cinco','attacker');
perform pg_temp.expect_error(pg_temp.trial_sql(p5),'TRIAL_ALREADY_USED');
perform pg_temp.assert(not (public.get_pelada_entitlement(p5)->>'trial_available')::boolean,'conta nova da mesma pessoa: sem teste');
-- Em cadeia: 3 -> 4 -> 5.
v_code := public.create_transfer_code();
perform pg_temp.as_user(5);
v_r := public.redeem_transfer_code(v_code);
p6 := public.create_pelada('Pelada Seis','attacker');
perform pg_temp.expect_error(pg_temp.trial_sql(p6),'TRIAL_ALREADY_USED');

-- ===== Pelada recriada com o mesmo grupo: concede, mas marca para revisão =====
perform pg_temp.as_user(6); p7 := public.create_pelada('Pelada Sete','attacker'); v_tok := public.create_pelada_invite(p7);
perform pg_temp.as_user(7); perform public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(2); perform public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(7); perform pg_temp.expect_error(pg_temp.trial_sql(p7),'ADMIN_REQUIRED');
perform pg_temp.as_user(6);
perform public.start_premium_trial(p7);
perform pg_temp.assert((public.get_pelada_entitlement(p7)->>'is_premium')::boolean,'usuário legítimo não é bloqueado');
execute 'reset role';
select * into v_g from private.premium_trial_grants where pelada_id=p7;
perform pg_temp.assert(v_g.active_players=3 and v_g.overlapping_players=3 and v_g.signals ? 'member_overlap',
 'mesmo grupo de outra pelada com teste: sinal de revisão');
perform pg_temp.assert((select count(*) from private.trial_review where pelada_id in (p1,p7))=2,'fila de revisão');

-- ===== Ninguém do app lê ou mexe nos registros =====
perform set_config('role','authenticated',true);
perform pg_temp.expect_error('select * from private.premium_trial_grants','permission denied');
perform pg_temp.expect_error('select * from private.account_lineage','permission denied');
perform set_config('role','anon',true);
perform pg_temp.expect_error(pg_temp.trial_sql(p8),'permission denied');

  raise exception 'PASS: 024_trial_protection (rollback proposital - nada foi gravado)';
end
$test$;
