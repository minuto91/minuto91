-- Configurações da pelada (migração 025). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 018_pelada_settings" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('12000000-0000-4000-8000-' || lpad((n+100)::text,12,'0'))::uuid $$;
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
declare v_pid uuid; v_s public.pelada_settings;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-set'||n||'@example.invalid','',now(),now(),now() from generate_series(1,2) n;
perform set_config('role','authenticated',true);
for i in 1..2 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Config','attacker');
execute 'reset role';
insert into public.pelada_memberships(pelada_id,user_id,player_name,preferred_position)
values(v_pid,pg_temp.uid(2),'Jogador 2','defender');
perform set_config('role','authenticated',true);

-- Padrão: 4h, Bola Murcha ligada, avaliar todos.
select * into v_s from public.pelada_settings where pelada_id=v_pid;
perform pg_temp.assert(v_s.voting_duration_minutes=240 and v_s.bola_murcha_enabled and v_s.minimum_numeric_ratings is null,'padrão');

-- Admin muda tudo.
perform public.update_pelada_settings(v_pid,120,false,5);
select * into v_s from public.pelada_settings where pelada_id=v_pid;
perform pg_temp.assert(v_s.voting_duration_minutes=120 and not v_s.bola_murcha_enabled and v_s.minimum_numeric_ratings=5,'admin muda');

-- Validações.
perform pg_temp.expect_error(format('select public.update_pelada_settings(%L,90,true,null)',v_pid),'INVALID_VOTING_DURATION');
perform pg_temp.expect_error(format('select public.update_pelada_settings(%L,240,true,0)',v_pid),'INVALID_MINIMUM_RATINGS');
perform pg_temp.expect_error(format('select public.update_pelada_settings(%L,240,null,null)',v_pid),'INVALID_SETTINGS');

-- Jogador comum não pode.
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.update_pelada_settings(%L,240,true,null)',v_pid),'ADMIN_REQUIRED');
perform pg_temp.assert(not exists(select 1 from public.pelada_settings where pelada_id=v_pid and voting_duration_minutes=240),'jogador não mudou');

-- Sem Premium: pode mudar prazo e mínimo, mas não ligar/desligar Bola Murcha.
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.update_pelada_settings(%L,240,true,null)',v_pid),'PREMIUM_REQUIRED');
perform public.update_pelada_settings(v_pid,360,false,null);
select * into v_s from public.pelada_settings where pelada_id=v_pid;
perform pg_temp.assert(v_s.voting_duration_minutes=360 and v_s.minimum_numeric_ratings is null,'sem premium muda prazo');

execute 'reset role';
perform pg_temp.assert((select count(*) from private.audit_events where pelada_id=v_pid and event_type='settings_updated')=2,'auditoria');

raise exception 'PASS: 018_pelada_settings (rollback proposital - nada foi gravado)';
end
$test$;
