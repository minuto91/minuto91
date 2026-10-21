create function pg_temp.assert(p_ok boolean, p_msg text) returns void language plpgsql as
 $$ begin if not coalesce(p_ok,false) then raise exception 'FALHOU: %', p_msg; end if; end $$;
create function pg_temp.expect_error(p_sql text, p_msg text) returns void language plpgsql as
 $$ begin
  begin execute p_sql; exception when others then
   if sqlerrm like '%'||p_msg||'%' then return; end if;
   raise exception 'erro inesperado "%" (esperado "%")', sqlerrm, p_msg;
  end;
  raise exception 'deveria falhar com "%"', p_msg;
 end $$;

do $test$
declare
  v_pid text;
  v_tok text;
begin
-- Verificacoes negativas: privilegios, esquema, capacidade e convites invalidos.



insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
values ('20000000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','m91-neg1@example.invalid','',now(),now(),now()),
       ('20000000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','m91-neg2@example.invalid','',now(),now(),now());

-- Esquema de configuracoes (Doc 04 v1.1).
perform pg_temp.assert(not exists(select 1 from information_schema.columns
  where table_schema='public' and table_name='pelada_settings' and column_name='minimum_eligible_voters'),
  'minimo de 6 votantes e fixo: sem coluna em settings');
perform pg_temp.assert((select column_default from information_schema.columns
  where table_schema='public' and table_name='pelada_settings' and column_name='bola_murcha_enabled')='true','Bola Murcha ligada por padrao');
perform pg_temp.assert((select is_nullable from information_schema.columns
  where table_schema='public' and table_name='pelada_memberships' and column_name='preferred_position')='NO','posicao obrigatoria');

-- Privilegios.
perform pg_temp.assert(not has_table_privilege('authenticated','public.peladas','INSERT'),'sem INSERT direto em peladas');
perform pg_temp.assert(not has_table_privilege('authenticated','public.pelada_memberships','UPDATE'),'sem UPDATE direto em memberships');
perform pg_temp.assert(not has_table_privilege('authenticated','public.pelada_settings','UPDATE'),'sem UPDATE direto em settings');
perform pg_temp.assert(not has_schema_privilege('anon','private','USAGE'),'anon sem acesso ao schema private');
perform pg_temp.assert(not has_table_privilege('authenticated','private.pelada_invites','SELECT'),'convites inacessiveis');
perform pg_temp.assert(not has_table_privilege('authenticated','private.app_config','SELECT'),'app_config inacessivel');
perform pg_temp.assert(not has_function_privilege('anon','public.join_pelada(text,text)','EXECUTE'),'anon nao executa join_pelada');
perform pg_temp.assert(not has_function_privilege('anon','public.leave_pelada(uuid)','EXECUTE'),'anon nao executa leave_pelada');
perform pg_temp.assert(not has_column_privilege('authenticated','public.profiles','adult_declared_at','UPDATE'),'carimbo de maioridade nao editavel direto');
perform pg_temp.assert(not has_column_privilege('authenticated','public.profiles','terms_accepted_at','UPDATE'),'carimbo de termos nao editavel direto');

perform set_config('role','authenticated',true);
perform set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',true);
perform pg_temp.expect_error($q$select public.join_pelada('invalid')$q$,'ONBOARDING_REQUIRED');
perform public.complete_onboarding('Neg1',true,true);
perform pg_temp.expect_error($q$select public.join_pelada('invalid','defender')$q$,'INVALID_INVITE');
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)',repeat('0',64),'defender'),'INVALID_OR_EXPIRED_INVITE');
perform pg_temp.expect_error($q$update public.profiles set adult_declared_at=null where id='20000000-0000-4000-8000-000000000001'$q$,'permission denied');
perform pg_temp.expect_error($q$insert into public.peladas(name,created_by) values('Hack','20000000-0000-4000-8000-000000000001')$q$,'permission denied');

-- Capacidade: 100 membros ativos.
v_pid := public.create_pelada('Pelada Cheia','midfielder');
v_tok := public.create_pelada_invite(v_pid::uuid);
execute 'reset role';
insert into public.pelada_memberships(pelada_id,user_id,player_name,preferred_position)
select v_pid::uuid,null,'Jogador '||g,'defender' from generate_series(1,99) g;
perform set_config('role','authenticated',true);
perform set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000002',true);
perform public.complete_onboarding('Neg2',true,true);
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)',v_tok,'defender'),'PELADA_FULL');
execute 'reset role';


  raise exception 'PASS: 002_negative (rollback proposital - nada foi gravado)';
end
$test$;
