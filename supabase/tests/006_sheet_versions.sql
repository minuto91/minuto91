-- Versionamento da súmula (migração 009). Rodar SOMENTE em banco local descartável. Tudo em transação com ROLLBACK.
\set ON_ERROR_STOP on
begin;
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('60000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.fix_error(p_match uuid, p_parts jsonb, p_events jsonb, p_reason text, p_msg text) returns void language plpgsql as
 $$ begin perform pg_temp.expect_error(format('select public.correct_match_sheet(%L,%L,%L,%L)',p_match,p_parts,p_events,p_reason),p_msg); end $$;

do $test$
declare
  v_pid uuid; v_tok text;
  v_m1 uuid; v_m2 uuid; v_m3 uuid; v_m4 uuid; v_g uuid;
  v_x uuid; v_x2 uuid; v_p1 uuid;
  v_parts jsonb; v_events jsonb; v_r jsonb;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v'||n||'@example.invalid','',now(),now(),now() from generate_series(1,5) n;

perform set_config('role','authenticated',true);
perform pg_temp.as_user(1); perform public.complete_onboarding('Admin',true,true);
perform pg_temp.as_user(2); perform public.complete_onboarding('Assis',true,true);
perform pg_temp.as_user(3); perform public.complete_onboarding('Joga3',true,true);
perform pg_temp.as_user(4); perform public.complete_onboarding('Joga4',true,true);
perform pg_temp.as_user(5); perform public.complete_onboarding('Fora',true,true);
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Versoes','attacker');
v_tok := public.create_pelada_invite(v_pid);
perform pg_temp.as_user(2); v_m2 := public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(3); v_m3 := public.join_pelada(v_tok,'midfielder');
perform pg_temp.as_user(4); v_m4 := public.join_pelada(v_tok,'goalkeeper');
perform pg_temp.as_user(1); perform public.set_assistant(v_pid,v_m2,true);
v_g := public.create_guest(v_pid,'Convidado',true);
execute 'reset role';
select id into v_m1 from public.pelada_memberships where pelada_id=v_pid and user_id=pg_temp.uid(1);

-- ===== Partida publicada com súmula 1x0 =====
v_parts := jsonb_build_array(
  jsonb_build_object('membership_id',v_m1,'team','A'), jsonb_build_object('membership_id',v_m2,'team','A'),
  jsonb_build_object('membership_id',v_m3,'team','B'), jsonb_build_object('membership_id',v_m4,'team','B'));
v_events := jsonb_build_array(jsonb_build_object('membership_id',v_m1,'type','goal','quantity',1));
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_x := public.create_match(v_pid,now());
perform public.save_match_sheet(v_x,v_parts,v_events);
v_x2 := public.create_match(v_pid,now());
execute 'reset role';
update public.matches set status='voting_open' where id=v_x; -- publicação real chega na 010
select id into v_p1 from public.match_participants where match_id=v_x and membership_id=v_m1;

-- ===== Validações =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform pg_temp.fix_error(v_x,v_parts,v_events,'Corrigindo','STAFF_REQUIRED');
perform pg_temp.as_user(1);
perform pg_temp.fix_error(v_x,v_parts,v_events,'  ','REASON_REQUIRED');
perform pg_temp.fix_error(v_x,v_parts,v_events,'ab','REASON_REQUIRED');
perform pg_temp.fix_error(v_x2,v_parts,v_events,'Corrigindo','MATCH_IS_DRAFT');
perform pg_temp.fix_error(v_x,v_parts,v_events,'Nada mudou','NO_CHANGES');
perform pg_temp.assert((select count(*)=0 from public.match_versions where match_id=v_x),'correção vazia não grava versão');
perform pg_temp.expect_error(format('select public.save_match_sheet(%L,%L,%L)',v_x,v_parts,v_events),'MATCH_NOT_DRAFT');

-- ===== Correção 1 (assistente): faltou o gol do Joga3 =====
perform pg_temp.as_user(2);
v_r := public.correct_match_sheet(v_x,v_parts,v_events || jsonb_build_array(
  jsonb_build_object('membership_id',v_m3,'type','goal','quantity',1)),'Faltou o gol do Joga3');
perform pg_temp.assert(v_r = '{"team_a_score":1,"team_b_score":1,"sheet_version":2,"eligible_voters_changed":false}'::jsonb,'retorno da correção 1');
execute 'reset role';
perform pg_temp.assert((select sheet_version=2 and team_a_score=1 and team_b_score=1 from public.matches where id=v_x),'partida na versão 2, 1x1');
perform pg_temp.assert((select count(*)=2 from public.match_versions where match_id=v_x),'versão base + versão 2');
perform pg_temp.assert((select changed_by is null and change_reason is null and (snapshot->>'team_b_score')='0'
  from public.match_versions where match_id=v_x and version_number=1),'versão 1 guarda os valores anteriores');
perform pg_temp.assert((select changed_by=pg_temp.uid(2) and change_reason='Faltou o gol do Joga3' and (snapshot->>'team_b_score')='1'
  from public.match_versions where match_id=v_x and version_number=2),'versão 2 com autor, motivo e valores novos');
perform pg_temp.assert((select id=v_p1 from public.match_participants where match_id=v_x and membership_id=v_m1),'participante mantém o mesmo registro');

-- ===== Correção 2: entra um convidado (não vota) =====
v_parts := v_parts || jsonb_build_array(jsonb_build_object('guest_id',v_g,'team','B','position','defender'));
v_events := v_events || jsonb_build_array(jsonb_build_object('membership_id',v_m3,'type','goal','quantity',1));
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_r := public.correct_match_sheet(v_x,v_parts,v_events,'Convidado jogou no B');
perform pg_temp.assert((v_r->>'sheet_version')='3' and (v_r->>'eligible_voters_changed')='false','convidado não muda eleitores');

-- ===== Correção 3: Joga4 não jogou (muda eleitores) =====
v_parts := jsonb_build_array(
  jsonb_build_object('membership_id',v_m1,'team','A'), jsonb_build_object('membership_id',v_m2,'team','A'),
  jsonb_build_object('membership_id',v_m3,'team','B'), jsonb_build_object('guest_id',v_g,'team','B','position','defender'));
v_r := public.correct_match_sheet(v_x,v_parts,v_events,'Joga4 não estava');
perform pg_temp.assert((v_r->>'sheet_version')='4' and (v_r->>'eligible_voters_changed')='true','remover jogador muda eleitores');
execute 'reset role';
perform pg_temp.assert((select eligible_voters_changed from public.match_versions where match_id=v_x and version_number=4),'versão 4 marcada');
perform pg_temp.assert((select count(*)=0 from public.match_participants where match_id=v_x and membership_id=v_m4),'Joga4 saiu da súmula');

-- ===== Quem saiu da pelada continua válido na súmula =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3); perform public.leave_pelada(v_pid);
perform pg_temp.as_user(1);
v_r := public.correct_match_sheet(v_x,v_parts,v_events || jsonb_build_array(
  jsonb_build_object('membership_id',v_m1,'type','assist','quantity',1)),'Faltou assistência');
perform pg_temp.assert((v_r->>'sheet_version')='5','correção com quem saiu da pelada');

-- ===== Visibilidade e escrita direta =====
perform pg_temp.as_user(4);
perform pg_temp.assert((select count(*)=5 from public.match_versions where match_id=v_x),'membro vê o histórico');
perform pg_temp.as_user(5);
perform pg_temp.assert((select count(*)=0 from public.match_versions where match_id=v_x),'não membro não vê');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format($q$insert into public.match_versions(pelada_id,match_id,version_number,snapshot) values(%L,%L,9,'{}')$q$,v_pid,v_x),'permission denied');

-- ===== Depois de finalizada: bloqueada =====
execute 'reset role';
update public.matches set status='finalized' where id=v_x;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.fix_error(v_x,v_parts,v_events,'Tarde demais','SHEET_LOCKED');
execute 'reset role';
perform pg_temp.assert((select count(*)=4 from private.audit_events where pelada_id=v_pid and event_type='match_sheet_corrected'),'4 correções auditadas');

  raise notice 'OK: 006_sheet_versions';
end
$test$;
rollback;
\echo 'PASS: 006_sheet_versions (correcoes, versoes, eleitores, bloqueio)'
