-- Publicação, sessões e elegibilidade (migração 010). Rodar SOMENTE em banco local descartável. Tudo em transação com ROLLBACK.
\set ON_ERROR_STOP on
begin;
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('70000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Súmula com os membros 1..n (ímpares no A, pares no B), opcionalmente + convidado e sem-conta.
create function pg_temp.parts(p_pelada uuid, n int, p_extra jsonb default '[]') returns jsonb language sql as
 $$ select coalesce(jsonb_agg(jsonb_build_object('membership_id',m.id,'team',case when i%2=1 then 'A' else 'B' end)),'[]') || p_extra
    from generate_series(1,n) i join public.pelada_memberships m
      on m.pelada_id=p_pelada and m.user_id=pg_temp.uid(i) $$;

do $test$
declare
  v_pid uuid; v_tok text; v_g uuid; v_mgr uuid; v_m2 uuid;
  v_x uuid; v_xb uuid; v_xc uuid; v_xd uuid;
  v_extra jsonb; v_parts jsonb; v_r jsonb; v_s1 uuid; v_s2 uuid; v_close timestamptz;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-w'||n||'@example.invalid','',now(),now(),now() from generate_series(1,8) n;

perform set_config('role','authenticated',true);
for i in 1..8 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Votacao','attacker');
v_tok := public.create_pelada_invite(v_pid);
for i in 2..7 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,'midfielder'); end loop;
execute 'reset role';
select id into v_m2 from public.pelada_memberships where pelada_id=v_pid and user_id=pg_temp.uid(2);
insert into public.pelada_memberships(pelada_id,user_id,player_name,preferred_position)
values(v_pid,null,'Sem Celular','defender') returning id into v_mgr;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform public.set_assistant(v_pid,v_m2,true);
v_g := public.create_guest(v_pid,'Convidado',true);
v_extra := jsonb_build_array(jsonb_build_object('guest_id',v_g,'team','A','position','defender'),
                             jsonb_build_object('membership_id',v_mgr,'team','B'));

-- ===== Validações de publicação =====
v_x := public.create_match(v_pid,now());
perform public.save_match_sheet(v_x,pg_temp.parts(v_pid,7,v_extra),'[]');
v_xb := public.create_match(v_pid,now());
perform public.save_match_sheet(v_xb,jsonb_build_array(jsonb_build_object('guest_id',v_g,'team','A','position','defender')),'[]');
perform pg_temp.as_user(3);
perform pg_temp.expect_error(format('select public.publish_match(%L)',v_x),'STAFF_REQUIRED');
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.publish_match(%L)',v_xb),'TEAMS_INCOMPLETE');
perform pg_temp.expect_error(format('select public.publish_match(%L,100)',v_x),'INVALID_VOTING_DURATION');
perform pg_temp.expect_error(format('select public.publish_match(%L,240,%L)',v_x,now()+interval '3 hours'),'INVALID_VOTING_DURATION');
perform pg_temp.expect_error(format('select public.publish_match(%L,null,%L)',v_x,now()+interval '30 minutes'),'INVALID_CLOSING_TIME');
perform pg_temp.expect_error(format('select public.publish_match(%L,null,%L)',v_x,now()+interval '25 hours'),'INVALID_CLOSING_TIME');
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.publish_match(%L,null,%L)',v_x,now()+interval '3 hours'),'PREMIUM_REQUIRED');
execute 'reset role';
update private.app_config set value='true'::jsonb where key='premium_beta_open';

-- ===== Publicar: 7 eleitores (convidado e sem-conta não votam) =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
v_r := public.publish_match(v_x);
perform pg_temp.assert(v_r->>'status'='voting_open' and (v_r->>'eligible_voter_count')::int=7,'publicada com 7 eleitores');
v_s1 := (v_r->>'session_id')::uuid;
perform pg_temp.expect_error(format('select public.publish_match(%L)',v_x),'MATCH_NOT_DRAFT');
execute 'reset role';
perform pg_temp.assert((select status='open' and closes_at=now()+interval '240 minutes' and duration_minutes=240
  and not fixed_close and sheet_version=1 and eligible_voter_count=7 and bola_murcha_required
  from public.voting_sessions where id=v_s1),'sessão aberta, 4h, Bola Murcha (beta Premium)');
perform pg_temp.assert((select count(*)=7 from public.voting_eligible_members where session_id=v_s1),'7 elegíveis gravados');
perform pg_temp.assert((select count(*)=0 from public.voting_eligible_members where session_id=v_s1 and membership_id=v_mgr),'sem-conta não vota');
perform pg_temp.assert((select changed_by=pg_temp.uid(2) and version_number=1 from public.match_versions where match_id=v_x),'versão 1 gravada na publicação');
perform pg_temp.expect_error(format($q$insert into public.voting_sessions(pelada_id,match_id,closes_at,duration_minutes,sheet_version,bola_murcha_required,formula_version,eligible_voter_count)
  values(%L,%L,now(),120,1,false,1,6)$q$,v_pid,v_x),'duplicate key');

-- ===== Conferência da súmula =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(8);
perform pg_temp.expect_error(format('select public.confirm_match_sheet(%L,1)',v_x),'NOT_ELIGIBLE_VOTER');
perform pg_temp.assert(public.get_my_voting_state(v_x) is null,'não membro sem estado');
perform pg_temp.as_user(3);
perform pg_temp.expect_error(format('select public.confirm_match_sheet(%L,9)',v_x),'SHEET_VERSION_OUTDATED');
perform public.confirm_match_sheet(v_x,1);
v_r := public.get_my_voting_state(v_x);
perform pg_temp.assert((v_r->>'eligible')::boolean and (v_r->>'sheet_confirmed')::boolean,'conferiu a versão 1');
perform pg_temp.assert((select count(*)=7 from public.voting_eligible_members where session_id=v_s1),'membro vê quem pode votar');
perform pg_temp.expect_error(format('select confirmed_sheet_version from public.voting_eligible_members where session_id=%L',v_s1),'permission denied');
perform pg_temp.as_user(8);
perform pg_temp.assert((select count(*)=0 from public.voting_sessions where match_id=v_x),'não membro não vê sessão');

-- ===== Correção sem mudar eleitores: invalida conferência e garante 1h =====
execute 'reset role';
update public.voting_sessions set closes_at=now()+interval '10 minutes' where id=v_s1;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_parts := pg_temp.parts(v_pid,7,v_extra);
perform public.correct_match_sheet(v_x,v_parts,jsonb_build_array(jsonb_build_object('guest_id',v_g,'type','goal','quantity',1)),'Gol do convidado');
execute 'reset role';
perform pg_temp.assert((select status='open' and closes_at=now()+interval '1 hour' and sheet_version=2
  from public.voting_sessions where id=v_s1),'mesma sessão, versão 2, prazo de 1h');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform pg_temp.assert(not (public.get_my_voting_state(v_x)->>'sheet_confirmed')::boolean,'conferência anterior invalidada');
perform public.confirm_match_sheet(v_x,2);

-- Com prazo folgado, a correção não mexe no prazo.
execute 'reset role';
update public.voting_sessions set closes_at=now()+interval '3 hours' where id=v_s1;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform public.correct_match_sheet(v_x,v_parts,jsonb_build_array(jsonb_build_object('guest_id',v_g,'type','goal','quantity',2)),'Foram 2 gols');
execute 'reset role';
perform pg_temp.assert((select closes_at=now()+interval '3 hours' from public.voting_sessions where id=v_s1),'prazo folgado mantido');

-- ===== Correção que muda eleitores: reinicia a votação =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_r := public.correct_match_sheet(v_x,pg_temp.parts(v_pid,6,v_extra),'[]','Jogador 7 não jogou');
perform pg_temp.assert((v_r->>'eligible_voters_changed')::boolean,'eleitores mudaram');
execute 'reset role';
perform pg_temp.assert((select status='cancelled' and cancelled_at is not null from public.voting_sessions where id=v_s1),'sessão antiga cancelada');
select id into v_s2 from public.voting_sessions where match_id=v_x and status='open';
perform pg_temp.assert(v_s2 is not null and v_s2<>v_s1,'nova sessão aberta');
perform pg_temp.assert((select eligible_voter_count=6 and closes_at=now()+interval '240 minutes' and sheet_version=4
  from public.voting_sessions where id=v_s2),'nova sessão: 6 eleitores, 4h, versão atual');

-- Caindo para 5 eleitores: finaliza sem votação.
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform public.correct_match_sheet(v_x,pg_temp.parts(v_pid,5,v_extra),'[]','Jogador 6 não jogou');
execute 'reset role';
perform pg_temp.assert((select status='finalized' and finalized_at is not null from public.matches where id=v_x),'finalizada sem votação');
perform pg_temp.assert((select count(*)=0 from public.voting_sessions where match_id=v_x and status='open'),'nenhuma sessão aberta');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.correct_match_sheet(%L,%L,%L,%L)',v_x,v_parts,'[]','De novo'),'SHEET_LOCKED');

-- ===== Menos de 6 já na publicação =====
v_xc := public.create_match(v_pid,now());
perform public.save_match_sheet(v_xc,pg_temp.parts(v_pid,5,v_extra),'[]');
v_r := public.publish_match(v_xc);
perform pg_temp.assert(v_r->>'status'='finalized' and v_r->>'session_id' is null and (v_r->>'eligible_voter_count')::int=5,'5 eleitores: sem votação');

-- ===== Horário fixo (Premium) =====
v_close := now()+interval '3 hours';
v_xd := public.create_match(v_pid,now());
perform public.save_match_sheet(v_xd,pg_temp.parts(v_pid,6),'[]');
v_r := public.publish_match(v_xd,null,v_close);
execute 'reset role';
perform pg_temp.assert((select fixed_close and duration_minutes is null and closes_at=v_close
  from public.voting_sessions where id=(v_r->>'session_id')::uuid),'horário fixo gravado');

  raise notice 'OK: 007_voting_sessions';
end
$test$;
rollback;
\echo 'PASS: 007_voting_sessions (publicacao, eleitores, conferencia, reinicio)'
