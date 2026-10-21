-- Temporadas (migração 006). Rodar SOMENTE em banco local descartável. Tudo em transação com ROLLBACK.
\set ON_ERROR_STOP on
begin;
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('30000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
  v_pid uuid;
  v_tok text;
  v_m2 uuid;
  v_today date;
  v_s1 uuid;
  v_s2 uuid;
  v_g uuid;
  v_n int;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-s'||n||'@example.invalid','',now(),now(),now() from generate_series(1,4) n;

-- ===== Pelada nasce com a temporada anual =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1); perform public.complete_onboarding('Admin',true,true);
perform pg_temp.as_user(2); perform public.complete_onboarding('Assis',true,true);
perform pg_temp.as_user(3); perform public.complete_onboarding('Joga',true,true);
perform pg_temp.as_user(4); perform public.complete_onboarding('Fora',true,true);
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Temporadas','attacker');
v_tok := public.create_pelada_invite(v_pid);
perform pg_temp.as_user(2); v_m2 := public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(3); perform public.join_pelada(v_tok,'midfielder');
perform pg_temp.as_user(1); perform public.set_assistant(v_pid,v_m2,true);
execute 'reset role';

v_today := private.pelada_today(v_pid);
perform pg_temp.assert((select count(*)=1 from public.seasons where pelada_id=v_pid),'uma temporada ao criar');
perform pg_temp.assert((select kind='annual' and status='active'
  and starts_on=make_date(extract(year from v_today)::int,1,1)
  and ends_on=make_date(extract(year from v_today)::int,12,31)
  and name='Temporada '||extract(year from v_today)::int
  from public.seasons where pelada_id=v_pid),'temporada anual jan-dez ativa');

-- ===== RLS e escrita direta =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform pg_temp.assert((select count(*)=1 from public.seasons where pelada_id=v_pid),'membro vê a temporada');
perform pg_temp.as_user(4);
perform pg_temp.assert((select count(*)=0 from public.seasons where pelada_id=v_pid),'não membro não vê');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format($q$insert into public.seasons(pelada_id,name,starts_on,ends_on) values(%L,'Hack',current_date,current_date)$q$,v_pid),'permission denied');
perform pg_temp.expect_error(format($q$update public.seasons set name='Hack' where pelada_id=%L$q$,v_pid),'permission denied');

-- ===== customize_season: validações =====
perform pg_temp.as_user(3);
perform pg_temp.expect_error(format($q$select public.customize_season(%L,'close_and_start','Copa',%L,%L,true)$q$,v_pid,v_today,v_today+30),'ADMIN_REQUIRED');
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format($q$select public.customize_season(%L,'close_and_start','Copa',%L,%L,true)$q$,v_pid,v_today,v_today+30),'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format($q$select public.customize_season(%L,'reset','Copa',%L,%L,true)$q$,v_pid,v_today,v_today+30),'INVALID_SEASON_MODE');
perform pg_temp.expect_error(format($q$select public.customize_season(%L,'close_and_start','C',%L,%L,true)$q$,v_pid,v_today,v_today+30),'INVALID_NAME');
perform pg_temp.expect_error(format($q$select public.customize_season(%L,'close_and_start','Copa',%L,%L)$q$,v_pid,v_today,v_today+30),'CONFIRMATION_REQUIRED');
perform pg_temp.expect_error(format($q$select public.customize_season(%L,'close_and_start','Copa',%L,%L,true)$q$,v_pid,v_today-1,v_today+30),'INVALID_SEASON_DATES');
perform pg_temp.expect_error(format($q$select public.customize_season(%L,'close_and_start','Copa',%L,%L,true)$q$,v_pid,v_today+5,v_today+4),'INVALID_SEASON_DATES');
perform pg_temp.expect_error(format($q$select public.customize_season(%L,'keep_current','Copa',null,%L,true)$q$,v_pid,v_today-1),'INVALID_SEASON_DATES');
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format($q$select public.customize_season(%L,'close_and_start','Copa',%L,%L,true)$q$,v_pid,v_today,v_today+30),'PREMIUM_REQUIRED');
execute 'reset role';
update private.app_config set value='true'::jsonb where key='premium_beta_open';

-- ===== Encerrar e iniciar (começa hoje) =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_s1 := public.customize_season(v_pid,'close_and_start','Copa 1',v_today,v_today+60,true);
execute 'reset role';
perform pg_temp.assert((select kind='custom' and status='active' and starts_on=v_today and ends_on=v_today+60
  from public.seasons where id=v_s1),'personalizada ativa hoje..+60');
perform pg_temp.assert((select count(*)=1 from public.seasons where pelada_id=v_pid
  and v_today between starts_on and ends_on),'só uma temporada cobre hoje');
perform pg_temp.assert((select bool_and(status='closed' and closed_at is not null) from public.seasons
  where pelada_id=v_pid and ends_on < v_today) is not false,'anteriores encerradas, sem apagar');

-- ===== Futura (planejada) e sobreposição =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_s2 := public.customize_season(v_pid,'close_and_start','Copa 2',v_today+200,v_today+250,true);
execute 'reset role';
perform pg_temp.assert((select status='planned' from public.seasons where id=v_s2),'futura fica planejada');
perform pg_temp.assert((select ends_on=v_today+60 from public.seasons where id=v_s1),'atual não foi esticada');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format($q$select public.customize_season(%L,'keep_current','Copa 1 longa',null,%L,true)$q$,v_pid,v_today+220),'SEASON_OVERLAP');

-- ===== Manter a atual (só muda nome e fim) =====
perform pg_temp.assert(public.customize_season(v_pid,'keep_current','Copa 1 estendida',null,v_today+90,true)=v_s1,'mantém o mesmo registro');
execute 'reset role';
perform pg_temp.assert((select name='Copa 1 estendida' and starts_on=v_today and ends_on=v_today+90
  from public.seasons where id=v_s1),'nome e fim alterados, início mantido');

-- ===== Lacuna vira temporada anual automática =====
v_g := private.season_for_date(v_pid, v_today+150);
perform pg_temp.assert((select kind='annual' and starts_on>=v_today+91 and ends_on<=v_today+199
  and v_today+150 between starts_on and ends_on from public.seasons where id=v_g),'lacuna preenchida sem sobrepor');
perform pg_temp.assert(private.season_for_date(v_pid, v_today+150)=v_g,'mesma data devolve a mesma temporada');
select count(*) into v_n from private.audit_events where pelada_id=v_pid and event_type='season_customized';
perform pg_temp.assert(v_n=3,'3 eventos de auditoria');

  raise notice 'OK: 003_seasons';
end
$test$;
rollback;
\echo 'PASS: 003_seasons (temporadas anual, personalizada, sobreposicao, RLS)'
