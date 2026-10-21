-- Transferência de conta por código (migração 024). Rodar SOMENTE em banco local descartável. Tudo em transação com ROLLBACK.
\set ON_ERROR_STOP on
begin;
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('12000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
declare v_pid uuid; v_mem uuid; v_old text; v_code text; v_r jsonb;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-tr'||n||'@example.invalid','',now(),now(),now() from generate_series(1,4) n;
perform set_config('role','authenticated',true);
for i in 1..4 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Transferencia','attacker');
perform pg_temp.as_user(4); perform public.create_pelada('Pelada do 4','attacker');
execute 'reset role';
select id into v_mem from public.pelada_memberships where pelada_id=v_pid and user_id=pg_temp.uid(1);

-- ===== Gerar código =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_old := public.create_transfer_code();
v_code := public.create_transfer_code(); -- revoga o anterior
perform pg_temp.assert(v_code ~ '^[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){3}$','formato XXXX-XXXX-XXXX-XXXX: '||v_code);
perform pg_temp.expect_error('select * from private.account_transfer_codes','permission denied');
execute 'reset role';
perform pg_temp.assert((select count(*)=1 from private.account_transfer_codes where user_id=pg_temp.uid(1)
  and redeemed_at is null and revoked_at is null),'só um código ativo');
perform pg_temp.assert((select code_hash=encode(extensions.digest(replace(v_code,'-',''),'sha256'),'hex')
  from private.account_transfer_codes where user_id=pg_temp.uid(1) and revoked_at is null),'só o hash é guardado');

-- ===== Resgatar =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(4);
perform pg_temp.expect_error(format('select public.redeem_transfer_code(%L)',v_code),'DESTINATION_HAS_PELADA');
perform pg_temp.as_user(2);
v_r := public.redeem_transfer_code(v_old);
perform pg_temp.assert(v_r->>'error'='INVALID_TRANSFER_CODE','código revogado não vale');
v_r := public.redeem_transfer_code(lower(v_code)); -- minúsculas e hífens são aceitos
perform pg_temp.assert((v_r->>'peladas')::int=1,'histórico transferido');
execute 'reset role';
perform pg_temp.assert((select user_id=pg_temp.uid(2) and role='admin' and status='active'
  from public.pelada_memberships where id=v_mem),'mesmo registro, agora da conta nova, ainda admin');
perform pg_temp.assert((select deactivated_at is not null from public.profiles where id=pg_temp.uid(1)),'conta antiga desativada');
perform pg_temp.assert(exists(select 1 from public.notification_events where user_id=pg_temp.uid(1)
  and event_type='account_transferred' and category='essential'),'conta antiga avisada');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error('select public.create_transfer_code()','ACCOUNT_DEACTIVATED');
perform pg_temp.assert((select count(*)=0 from public.peladas where id=v_pid),'conta antiga sem acesso à pelada');
perform pg_temp.as_user(2);
perform pg_temp.assert((select count(*)=1 from public.peladas where id=v_pid),'conta nova acessa a pelada');

-- ===== Uso único e limite de tentativas =====
perform pg_temp.as_user(3);
v_r := public.redeem_transfer_code(v_code);
perform pg_temp.assert(v_r->>'error'='INVALID_TRANSFER_CODE','código já usado');
for i in 1..4 loop perform public.redeem_transfer_code('AAAA-BBBB-CCCC-DDD'||i); end loop;
perform pg_temp.expect_error($q$select public.redeem_transfer_code('AAAA-BBBB-CCCC-DDDD')$q$,'TOO_MANY_ATTEMPTS');

  raise notice 'OK: 017_account_transfer';
end
$test$;
rollback;
\echo 'PASS: 017_account_transfer'
