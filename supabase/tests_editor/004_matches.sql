-- Partidas (migração 007). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 004_matches" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('40000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
  v_now timestamptz := now();
  v_x1 uuid;
  v_x2 uuid;
  v_x3 uuid;
  v_n int;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-p'||n||'@example.invalid','',now(),now(),now() from generate_series(1,4) n;

perform set_config('role','authenticated',true);
perform pg_temp.as_user(1); perform public.complete_onboarding('Admin',true,true);
perform pg_temp.as_user(2); perform public.complete_onboarding('Assis',true,true);
perform pg_temp.as_user(3); perform public.complete_onboarding('Joga',true,true);
perform pg_temp.as_user(4); perform public.complete_onboarding('Fora',true,true);
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Partidas','attacker');
v_tok := public.create_pelada_invite(v_pid);
perform pg_temp.as_user(2); v_m2 := public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(3); perform public.join_pelada(v_tok,'midfielder');
perform pg_temp.as_user(1); perform public.set_assistant(v_pid,v_m2,true);
execute 'reset role';
v_today := private.pelada_today(v_pid);

-- ===== Quem pode lançar e validações =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform pg_temp.expect_error(format('select public.create_match(%L,%L)',v_pid,v_now),'STAFF_REQUIRED');
perform pg_temp.as_user(4);
perform pg_temp.expect_error(format('select public.create_match(%L,%L)',v_pid,v_now),'STAFF_REQUIRED');
perform pg_temp.as_user(2);
-- V8.5 (063): rascunho pode ter data futura (pré-cadastro); o limite é 366 dias e publicar exige a data (049).
perform pg_temp.expect_error(format('select public.create_match(%L,%L)',v_pid,v_now+interval '400 days'),'INVALID_MATCH_DATE');
perform pg_temp.expect_error(format('select public.create_match(%L,null)',v_pid),'INVALID_MATCH_DATE');
perform pg_temp.expect_error(format('select public.create_match(%L,%L,%L)',v_pid,v_now,repeat('x',41)),'INVALID_TEAM_NAME');
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.create_match(%L,%L,%L,%L)',v_pid,v_now,'Azul','Branco'),'TEAM_NAMES_PREMIUM');
execute 'reset role';
update private.app_config set value='true'::jsonb where key='premium_beta_open';

-- ===== Assistente lança rascunho (agora) =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
v_x1 := public.create_match(v_pid,v_now);
execute 'reset role';
perform pg_temp.assert((select status='draft' and team_a_name='Time A' and team_b_name='Time B'
  and team_a_score=0 and team_b_score=0 and sheet_version=1 and created_by=pg_temp.uid(2)
  and season_id=(select id from public.seasons where pelada_id=v_pid and v_today between starts_on and ends_on)
  from public.matches where id=v_x1),'rascunho com padrões e temporada de hoje');

-- ===== Rascunho invisível ao jogador; sem escrita direta =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform pg_temp.assert((select count(*)=0 from public.matches where pelada_id=v_pid),'jogador não vê rascunho');
perform pg_temp.as_user(1);
perform pg_temp.assert((select count(*)=1 from public.matches where pelada_id=v_pid),'admin vê rascunho');
perform pg_temp.expect_error(format($q$update public.matches set team_a_score=9 where id=%L$q$,v_x1),'permission denied');
perform pg_temp.expect_error(format($q$delete from public.matches where id=%L$q$,v_x1),'permission denied');
perform pg_temp.expect_error(format($q$insert into public.matches(pelada_id,season_id,played_at) select pelada_id,season_id,now() from public.matches where id=%L$q$,v_x1),'permission denied');

-- ===== Nomes Premium, data antiga cria temporada do ano =====
v_x2 := public.create_match(v_pid,v_now,' Azul ','Branco');
perform pg_temp.assert((select team_a_name='Azul' and team_b_name='Branco' from public.matches where id=v_x2),'nomes personalizados');
v_x3 := public.create_match(v_pid,v_now-interval '400 days');
execute 'reset role';
perform pg_temp.assert((select s.kind='annual' and private.pelada_local_date(v_pid,m.played_at) between s.starts_on and s.ends_on
  from public.matches m join public.seasons s on s.id=m.season_id where m.id=v_x3),'partida antiga na temporada anual daquele ano');

-- ===== Editar e excluir rascunho =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform pg_temp.expect_error(format('select public.update_match_draft(%L,%L)',v_x1,v_now),'STAFF_REQUIRED');
perform pg_temp.expect_error(format('select public.discard_match_draft(%L)',v_x3),'STAFF_REQUIRED');
perform pg_temp.as_user(1);
perform public.update_match_draft(v_x1,v_now-interval '1 day','Preto',null);
perform pg_temp.expect_error(format('select public.update_match_draft(%L,%L)',v_x1,v_now+interval '400 days'),'INVALID_MATCH_DATE');
perform pg_temp.as_user(2);
perform public.discard_match_draft(v_x3);
perform pg_temp.expect_error(format('select public.discard_match_draft(%L)',v_x3),'MATCH_NOT_FOUND');
execute 'reset role';
perform pg_temp.assert((select team_a_name='Preto' and team_b_name='Time B' from public.matches where id=v_x1),'rascunho editado');

-- ===== Publicada: não edita, não exclui; jogador passa a ver =====
update public.matches set status='voting_open' where id=v_x2;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.update_match_draft(%L,%L)',v_x2,v_now),'MATCH_NOT_DRAFT');
perform pg_temp.expect_error(format('select public.discard_match_draft(%L)',v_x2),'MATCH_NOT_DRAFT');
perform pg_temp.as_user(3);
perform pg_temp.assert((select count(*)=1 from public.matches where pelada_id=v_pid),'jogador vê só a publicada');

-- ===== Temporada não pode deixar partidas de fora =====
if v_today > make_date(extract(year from v_today)::int,1,1) then
 perform pg_temp.as_user(1);
 perform pg_temp.expect_error(format($q$select public.customize_season(%L,'close_and_start','Copa',%L,%L,true)$q$,
   v_pid,v_today,v_today+30),'SEASON_HAS_MATCHES_OUTSIDE');
end if;
execute 'reset role';
perform pg_temp.expect_error(format($q$update public.matches set played_at=%L where id=%L$q$,v_now-interval '400 days',v_x2),'MATCH_OUTSIDE_SEASON');

select count(*) into v_n from private.audit_events where pelada_id=v_pid and event_type in ('match_created','match_draft_discarded');
perform pg_temp.assert(v_n=4,'auditoria: 3 criadas + 1 excluída');

  raise exception 'PASS: 004_matches (rollback proposital - nada foi gravado)';
end
$test$;
