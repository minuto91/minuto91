-- Participantes, convidados e eventos (migração 008). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 005_participants_events" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('50000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Chama save_match_sheet esperando erro.
create function pg_temp.sheet_error(p_match uuid, p_parts jsonb, p_events jsonb, p_msg text) returns void language plpgsql as
 $$ begin perform pg_temp.expect_error(format('select public.save_match_sheet(%L,%L,%L)',p_match,p_parts,p_events),p_msg); end $$;

do $test$
declare
  v_pid uuid; v_qid uuid; v_tok text;
  v_m1 uuid; v_m2 uuid; v_m3 uuid; v_m5 uuid; v_q4 uuid;
  v_g1 uuid; v_gq uuid;
  v_x uuid; v_x2 uuid;
  v_parts jsonb; v_events jsonb; v_r jsonb;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-e'||n||'@example.invalid','',now(),now(),now() from generate_series(1,5) n;

perform set_config('role','authenticated',true);
perform pg_temp.as_user(1); perform public.complete_onboarding('Admin',true,true);
perform pg_temp.as_user(2); perform public.complete_onboarding('Assis',true,true);
perform pg_temp.as_user(3); perform public.complete_onboarding('Joga',true,true);
perform pg_temp.as_user(4); perform public.complete_onboarding('Outra',true,true);
perform pg_temp.as_user(5); perform public.complete_onboarding('Saiu',true,true);
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Sumula','attacker');
v_tok := public.create_pelada_invite(v_pid);
perform pg_temp.as_user(2); v_m2 := public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(3); v_m3 := public.join_pelada(v_tok,'midfielder');
perform pg_temp.as_user(5); v_m5 := public.join_pelada(v_tok,'goalkeeper'); perform public.leave_pelada(v_pid);
perform pg_temp.as_user(1); perform public.set_assistant(v_pid,v_m2,true);
perform pg_temp.as_user(4);
v_qid := public.create_pelada('Outra Pelada','defender');
v_gq := public.create_guest(v_qid,'Convidado de fora',true);
execute 'reset role';
select id into v_m1 from public.pelada_memberships where pelada_id=v_pid and user_id=pg_temp.uid(1);
select id into v_q4 from public.pelada_memberships where pelada_id=v_qid and user_id=pg_temp.uid(4);

-- ===== Convidados =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform pg_temp.expect_error(format('select public.create_guest(%L,%L,true)',v_pid,'Tio'),'STAFF_REQUIRED');
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.create_guest(%L,%L,false)',v_pid,'Tio'),'ADULT_DECLARATION_REQUIRED');
perform pg_temp.expect_error(format('select public.create_guest(%L,%L,true)',v_pid,'  '),'INVALID_NAME');
v_g1 := public.create_guest(v_pid,'Tio do Joga',true);
perform pg_temp.as_user(3);
perform pg_temp.assert((select count(*)=1 from public.guests where pelada_id=v_pid),'membro vê convidado');
perform pg_temp.as_user(4);
perform pg_temp.assert((select count(*)=0 from public.guests where pelada_id=v_pid),'não membro não vê convidado');

-- ===== Súmula: validações =====
perform pg_temp.as_user(1);
v_x := public.create_match(v_pid,now());
perform pg_temp.as_user(3);
perform pg_temp.sheet_error(v_x,'[]','[]','STAFF_REQUIRED');
perform pg_temp.as_user(1);
perform pg_temp.sheet_error(v_x,jsonb_build_array(jsonb_build_object('membership_id',v_m1,'guest_id',v_g1,'team','A')),'[]','INVALID_PARTICIPANT');
perform pg_temp.sheet_error(v_x,jsonb_build_array(jsonb_build_object('membership_id',v_q4,'team','A')),'[]','INVALID_PARTICIPANT');
perform pg_temp.sheet_error(v_x,jsonb_build_array(jsonb_build_object('membership_id',v_m5,'team','A')),'[]','INVALID_PARTICIPANT');
perform pg_temp.sheet_error(v_x,jsonb_build_array(jsonb_build_object('guest_id',v_gq,'team','A','position','attacker')),'[]','INVALID_PARTICIPANT');
perform pg_temp.sheet_error(v_x,jsonb_build_array(jsonb_build_object('guest_id',v_g1,'team','A')),'[]','INVALID_POSITION');
perform pg_temp.sheet_error(v_x,jsonb_build_array(jsonb_build_object('membership_id',v_m1,'team','C')),'[]','INVALID_TEAM');
perform pg_temp.sheet_error(v_x,jsonb_build_array(jsonb_build_object('membership_id',v_m1,'team','A'),
  jsonb_build_object('membership_id',v_m1,'team','B')),'[]','DUPLICATE_IN_SHEET');
perform pg_temp.sheet_error(v_x,'[{"membership_id":"nao-e-uuid","team":"A"}]','[]','INVALID_SHEET');
perform pg_temp.sheet_error(v_x,'{}','[]','INVALID_SHEET');

v_parts := jsonb_build_array(
  jsonb_build_object('membership_id',v_m1,'team','A'),
  jsonb_build_object('membership_id',v_m2,'team','A'),
  jsonb_build_object('membership_id',v_m3,'team','B'),
  jsonb_build_object('guest_id',v_g1,'team','B','position','goalkeeper'));
perform pg_temp.sheet_error(v_x,v_parts,jsonb_build_array(jsonb_build_object('membership_id',v_m5,'type','goal','quantity',1)),'EVENT_PARTICIPANT_NOT_IN_MATCH');
perform pg_temp.sheet_error(v_x,v_parts,jsonb_build_array(jsonb_build_object('membership_id',v_m1,'type','unattributed_goal','quantity',1)),'INVALID_EVENT');
perform pg_temp.sheet_error(v_x,v_parts,jsonb_build_array(jsonb_build_object('type','goal','quantity',1,'team','A')),'INVALID_EVENT');
perform pg_temp.sheet_error(v_x,v_parts,jsonb_build_array(jsonb_build_object('membership_id',v_m1,'type','goal','quantity',0)),'INVALID_EVENT');
perform pg_temp.sheet_error(v_x,v_parts,jsonb_build_array(jsonb_build_object('membership_id',v_m1,'type','penalty','quantity',1)),'INVALID_EVENT');
perform pg_temp.sheet_error(v_x,v_parts,jsonb_build_array(jsonb_build_object('type','unattributed_goal','quantity',1)),'INVALID_TEAM');
perform pg_temp.sheet_error(v_x,v_parts,jsonb_build_array(
  jsonb_build_object('membership_id',v_m1,'type','goal','quantity',1),
  jsonb_build_object('membership_id',v_m1,'type','goal','quantity',1)),'DUPLICATE_IN_SHEET');
perform pg_temp.sheet_error(v_x,v_parts,jsonb_build_array(
  jsonb_build_object('membership_id',v_m1,'type','goal','quantity',1),
  jsonb_build_object('membership_id',v_m2,'type','assist','quantity',2)),'ASSISTS_EXCEED_GOALS');

-- ===== Súmula válida: placar sai dos eventos =====
-- A: Admin 2 gols + 1 gol sem autor = 3. B: gol contra do Assis (A) + 1 gol do convidado = 2.
v_events := jsonb_build_array(
  jsonb_build_object('membership_id',v_m1,'type','goal','quantity',2),
  jsonb_build_object('membership_id',v_m2,'type','assist','quantity',1),
  jsonb_build_object('type','unattributed_goal','quantity',1,'team','A'),
  jsonb_build_object('membership_id',v_m2,'type','own_goal','quantity',1),
  jsonb_build_object('guest_id',v_g1,'type','goal','quantity',1),
  jsonb_build_object('membership_id',v_m3,'type','red_card','quantity',1));
perform pg_temp.as_user(2);
v_r := public.save_match_sheet(v_x,v_parts,v_events);
perform pg_temp.assert(v_r = '{"team_a_score":3,"team_b_score":2}'::jsonb,'retorno do placar 3x2');
execute 'reset role';
perform pg_temp.assert((select team_a_score=3 and team_b_score=2 from public.matches where id=v_x),'placar gravado 3x2');
perform pg_temp.assert((select count(*)=4 from public.match_participants where match_id=v_x),'4 participantes');
perform pg_temp.assert((select count(*)=6 from public.match_events where match_id=v_x),'6 eventos');
perform pg_temp.assert((select team='B' from public.match_events where match_id=v_x and event_type='own_goal'),'gol contra conta para o outro time');
perform pg_temp.assert((select primary_position='attacker' from public.match_participants where membership_id=v_m1 and match_id=v_x),'retrato da posição do perfil');
perform pg_temp.assert((select primary_position='goalkeeper' from public.match_participants where guest_id=v_g1 and match_id=v_x),'posição informada do convidado');

-- Retrato não muda quando o perfil muda.
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1); perform public.set_my_position(v_pid,'defender');
execute 'reset role';
perform pg_temp.assert((select primary_position='attacker' from public.match_participants where membership_id=v_m1 and match_id=v_x),'retrato preservado');

-- Salvar de novo substitui tudo.
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_r := public.save_match_sheet(v_x,jsonb_build_array(jsonb_build_object('membership_id',v_m3,'team','A')),'[]');
perform pg_temp.assert(v_r = '{"team_a_score":0,"team_b_score":0}'::jsonb,'súmula substituída, 0x0');
perform pg_temp.assert((select count(*)=1 from public.match_participants where match_id=v_x),'1 participante após substituir');
perform pg_temp.assert((select primary_position='midfielder' and team='A' from public.match_participants where membership_id=v_m3 and match_id=v_x),'jogador 3 meia, agora no time A');
perform public.save_match_sheet(v_x,v_parts,v_events);

-- ===== Visibilidade e escrita direta =====
perform pg_temp.as_user(3);
perform pg_temp.assert((select count(*)=0 from public.match_participants where match_id=v_x),'jogador não vê súmula de rascunho');
perform pg_temp.assert((select count(*)=0 from public.match_events where match_id=v_x),'jogador não vê eventos de rascunho');
perform pg_temp.expect_error(format($q$insert into public.match_events(pelada_id,match_id,team,event_type,quantity) values(%L,%L,'A','unattributed_goal',5)$q$,v_pid,v_x),'permission denied');
perform pg_temp.expect_error(format($q$update public.match_participants set team='A' where match_id=%L$q$,v_x),'permission denied');
execute 'reset role';
update public.matches set status='voting_open' where id=v_x;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform pg_temp.assert((select count(*)=4 from public.match_participants where match_id=v_x),'jogador vê súmula publicada');
perform pg_temp.assert((select count(*)=6 from public.match_events where match_id=v_x),'jogador vê eventos publicados');
perform pg_temp.as_user(4);
perform pg_temp.assert((select count(*)=0 from public.match_participants where match_id=v_x),'não membro não vê');
perform pg_temp.as_user(1);
perform pg_temp.sheet_error(v_x,v_parts,v_events,'MATCH_NOT_DRAFT');

-- ===== Excluir rascunho leva a súmula junto =====
v_x2 := public.create_match(v_pid,now());
perform public.save_match_sheet(v_x2,v_parts,v_events);
perform public.discard_match_draft(v_x2);
execute 'reset role';
perform pg_temp.assert((select count(*)=0 from public.match_participants where match_id=v_x2)
  and (select count(*)=0 from public.match_events where match_id=v_x2),'súmula do rascunho excluída junto');

  raise exception 'PASS: 005_participants_events (rollback proposital - nada foi gravado)';
end
$test$;
