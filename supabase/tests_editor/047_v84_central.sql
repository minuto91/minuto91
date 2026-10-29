-- V8.4 (migração 060): feed de notificações (E14), layout da Central (E13) e último jogo (E05).
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 047_v84_central".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99840000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Partida finalizada (como dono do banco), igual à do teste 038. p_rows: [{m, team, pos, g, a}].
create function pg_temp.finish(p_pelada uuid, p_at timestamptz, a int, b int, p_rows jsonb) returns uuid language plpgsql as
 $$ declare v_id uuid; r jsonb; v_part uuid; begin
  insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
  values(p_pelada,private.season_for_date(p_pelada,private.pelada_local_date(p_pelada,p_at)),p_at,'finalized',a,b,now())
  returning id into v_id;
  for r in select * from jsonb_array_elements(p_rows) loop
   insert into public.match_participants(pelada_id,match_id,membership_id,team,primary_position)
   values(p_pelada,v_id,pg_temp.mem(p_pelada,(r->>'m')::int),r->>'team',r->>'pos') returning id into v_part;
   if coalesce((r->>'g')::int,0) > 0 then insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
    values(p_pelada,v_id,v_part,r->>'team','goal',(r->>'g')::int); end if;
   if coalesce((r->>'a')::int,0) > 0 then insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
    values(p_pelada,v_id,v_part,r->>'team','assist',(r->>'a')::int); end if;
   insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,
    objective_rating,final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
   values(p_pelada,v_id,pg_temp.mem(p_pelada,(r->>'m')::int),0,null,5,null,false,coalesce((r->>'g')::int,0),coalesce((r->>'a')::int,0),0,
    case when a=b then 'draw' when (a>b)=(r->>'team'='A') then 'win' else 'loss' end, r->>'pos',1);
  end loop;
  perform private.after_match_finalized(v_id);
  return v_id;
 end $$;

do $test$
declare v_a uuid; v_b uuid; v_tok text; v_m1 uuid; v_m2 uuid; v_n1 uuid; v_n2 uuid; v_n3 uuid; v_other uuid;
 j jsonb; v_ver int; i int; v_n int;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v84'||n||'@example.invalid','',now(),now(),now() from generate_series(1,4) n;
perform set_config('role','authenticated',true);
for i in 1..4 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada A','ATA'); v_tok := public.create_pelada_invite(v_a);
perform pg_temp.as_user(2); perform public.join_pelada(v_tok,'GOL');
perform pg_temp.as_user(3); perform public.join_pelada(v_tok,'ZAG');
perform pg_temp.as_user(4); v_b := public.create_pelada('Pelada B','MEI');

-- ===== E14: feed =====
execute 'reset role';
insert into public.notification_events(user_id,pelada_id,event_type,category,dedupe_key,payload,status,sent_at)
 values(pg_temp.uid(1),v_a,'result_published','essential','t1',jsonb_build_object('pelada_id',v_a,'match_id',gen_random_uuid(),'secret','x'),'sent',now())
 returning id into v_n1;
insert into public.notification_events(user_id,pelada_id,event_type,category,dedupe_key,payload,status,created_at)
 values(pg_temp.uid(1),v_a,'sticker_unlocked','engagement','t2','{}','sent',now()-interval '2 days') returning id into v_n2;
-- fora do feed: Bola Murcha (privada), suprimida, agendada para o futuro, com mais de 90 dias, de outra pessoa, de pelada sem vínculo
insert into public.notification_events(user_id,pelada_id,event_type,category,dedupe_key,payload,status) values
 (pg_temp.uid(1),v_a,'award_bola_murcha','engagement','t3','{}','sent'),
 (pg_temp.uid(1),v_a,'sticker_unlocked','engagement','t4','{}','suppressed');
insert into public.notification_events(user_id,pelada_id,event_type,category,dedupe_key,payload,status,scheduled_at)
 values(pg_temp.uid(1),v_a,'voting_opened','essential','t5','{}','pending',now()+interval '1 hour');
insert into public.notification_events(user_id,pelada_id,event_type,category,dedupe_key,payload,status,created_at)
 values(pg_temp.uid(1),v_a,'result_published','essential','t6','{}','sent',now()-interval '91 days');
insert into public.notification_events(user_id,pelada_id,event_type,category,dedupe_key,payload,status)
 values(pg_temp.uid(2),v_a,'result_published','essential','t7','{}','sent') returning id into v_other;
insert into public.notification_events(user_id,pelada_id,event_type,category,dedupe_key,payload,status)
 values(pg_temp.uid(1),v_b,'result_published','essential','t8','{}','sent');

perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform pg_temp.assert(public.has_unread_notifications(),'há não lida');
j := public.get_my_notifications();
perform pg_temp.assert(jsonb_array_length(j->'items')=2,'só 2 visíveis, achou '||jsonb_array_length(j->'items'));
perform pg_temp.assert((j->'items'->0->>'id')::uuid=v_n1 and (j->'items'->1->>'id')::uuid=v_n2,'mais recentes primeiro');
perform pg_temp.assert(not ((j->'items'->0->'payload') ? 'secret') and (j->'items'->0->'payload') ? 'match_id','payload só com chaves de navegação');
perform pg_temp.assert(j->'items'->0->>'pelada_name'='Pelada A' and j->'items'->0->>'read_at' is null,'nome da pelada e não lida');
-- paginação por cursor
j := public.get_my_notifications(null,1);
perform pg_temp.assert(jsonb_array_length(j->'items')=1 and j->'next' is not null and j->'next' <> 'null'::jsonb,'primeira página com cursor');
j := public.get_my_notifications(j->'next',1);
perform pg_temp.assert((j->'items'->0->>'id')::uuid=v_n2 and (j->'next' is null or j->'next'='null'::jsonb),'segunda página, sem próxima');
perform pg_temp.expect_error($q$select public.get_my_notifications('{"at":"x","id":"y"}'::jsonb)$q$,'INVALID_CURSOR');
-- leitura: idempotente, só a própria, não resolve nada
j := public.mark_notification_read(v_n1);
perform pg_temp.assert(j->>'read_at' is not null,'marcada');
perform pg_temp.assert(public.mark_notification_read(v_n1)->>'read_at' = j->>'read_at','idempotente: mesmo read_at');
perform pg_temp.expect_error(format($q$select public.mark_notification_read(%L)$q$,v_other),'NOTIFICATION_NOT_FOUND');
execute 'reset role';
perform pg_temp.assert((select read_at is null from public.notification_events where id=v_other),'a de outra pessoa continua não lida');
perform set_config('role','authenticated',true);
perform pg_temp.assert(public.has_unread_notifications(),'ainda há a v_n2 não lida');
perform pg_temp.assert((public.mark_all_notifications_read()->>'marked')::int=1,'marcar todas: 1');
perform pg_temp.assert((public.mark_all_notifications_read()->>'marked')::int=0,'marcar todas é idempotente');
perform pg_temp.assert(not public.has_unread_notifications(),'sem não lidas');
perform pg_temp.as_user(2);
perform pg_temp.assert(public.has_unread_notifications() and jsonb_array_length(public.get_my_notifications()->'items')=1,'usuário 2 isolado e com a dele não lida');
-- sem sessão
perform set_config('request.jwt.claim.sub','',true);
perform pg_temp.expect_error($q$select public.get_my_notifications()$q$,'AUTH_REQUIRED');
perform pg_temp.expect_error($q$select public.has_unread_notifications()$q$,'AUTH_REQUIRED');
-- ex-integrante mantém o histórico; suspenso não vê
execute 'reset role';
update public.pelada_memberships set status='left' where pelada_id=v_a and user_id=pg_temp.uid(2);
perform set_config('role','authenticated',true); perform pg_temp.as_user(2);
perform pg_temp.assert(jsonb_array_length(public.get_my_notifications()->'items')=1,'ex-integrante (left) ainda vê o aviso do histórico');
execute 'reset role';
update public.pelada_memberships set status='suspended' where pelada_id=v_a and user_id=pg_temp.uid(2);
perform set_config('role','authenticated',true); perform pg_temp.as_user(2);
perform pg_temp.assert(jsonb_array_length(public.get_my_notifications()->'items')=0,'suspenso não vê os avisos da pelada');
-- retenção de 90 dias: só a fila
execute 'reset role';
v_n := private.purge_old_notifications();
perform pg_temp.assert(v_n=1 and not exists(select 1 from public.notification_events where dedupe_key='t6'),'purge removeu só a de 91 dias');
perform pg_temp.assert(exists(select 1 from public.notification_events where dedupe_key='t1'),'recentes preservadas');
perform pg_temp.assert(exists(select 1 from private.audit_events),'trilha de auditoria preservada');

-- ===== E13: layout =====
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
j := public.get_central_layout();
perform pg_temp.assert((j->>'version')::int=0 and (j->>'is_default')::boolean and j->'order'='["next_round","last_game","career_summary"]'::jsonb,'padrão');
j := public.set_central_layout(array['career_summary','next_round','last_game'], array['my_peladas','last_game'], 0);
perform pg_temp.assert((j->>'version')::int=1 and j->'order'->>0='career_summary' and not (j->>'is_default')::boolean,'primeira gravação: versão 1');
perform pg_temp.expect_error($q$select public.set_central_layout(array['next_round','last_game','career_summary'], '{}', 0)$q$,'LAYOUT_VERSION_CONFLICT');
j := public.set_central_layout(array['last_game','career_summary','next_round'], '{}', 1);
perform pg_temp.assert((j->>'version')::int=2 and jsonb_array_length(j->'hidden')=0,'versão 2');
perform pg_temp.expect_error($q$select public.set_central_layout(array['next_round','last_game'], '{}', 2)$q$,'INVALID_LAYOUT');
perform pg_temp.expect_error($q$select public.set_central_layout(array['next_round','last_game','last_game'], '{}', 2)$q$,'INVALID_LAYOUT');
perform pg_temp.expect_error($q$select public.set_central_layout(array['next_round','last_game','career_summary'], array['header'], 2)$q$,'INVALID_LAYOUT');
perform pg_temp.expect_error($q$select public.set_central_layout(array['next_round','last_game','career_summary'], array['attention'], 2)$q$,'INVALID_LAYOUT');
perform pg_temp.expect_error($q$select public.set_central_layout(array['next_round','last_game','career_summary'], array['my_peladas','my_peladas'], 2)$q$,'INVALID_LAYOUT');
perform pg_temp.expect_error($q$select public.set_central_layout(array['next_round','my_peladas','career_summary'], '{}', 2)$q$,'INVALID_LAYOUT');
perform pg_temp.as_user(2);
perform pg_temp.assert((public.get_central_layout()->>'version')::int=0,'layout é por usuário');
perform pg_temp.as_user(1);
j := public.reset_central_layout();
perform pg_temp.assert((j->>'version')::int=0 and (j->>'is_default')::boolean,'restaurado');
perform pg_temp.assert((public.reset_central_layout()->>'is_default')::boolean,'restaurar é idempotente');
perform pg_temp.expect_error($q$update public.user_central_layout set version=9$q$,'permission denied');

-- ===== E05: último jogo disputado e publicado =====
execute 'reset role';
-- 1 joga a partida 1 (Time A, 2 gols); 2 (goleiro) joga a 1; só o 3 joga a partida 2 (mais recente)
v_m1 := pg_temp.finish(v_a, now()-interval '10 days', 3, 1, jsonb_build_array(
 jsonb_build_object('m',1,'team','A','pos','attacker','g',2,'a',0), jsonb_build_object('m',2,'team','B','pos','goalkeeper','g',0,'a',0)));
v_m2 := pg_temp.finish(v_a, now()-interval '2 days', 1, 0, jsonb_build_array(
 jsonb_build_object('m',3,'team','A','pos','defender','g',1,'a',0)));
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
j := public.get_my_last_game(v_a)->'game';
perform pg_temp.assert((j->>'match_id')::uuid=v_m1,'o último jogo é o que ELE disputou, não o mais recente da pelada');
perform pg_temp.assert((j->>'goals')::int=2 and (j->>'assists')::int=0,'zero real de assistência é 0, não ausência');
perform pg_temp.assert(j->>'my_team'='A' and (j->>'team_a_score')::int=3 and (j->>'team_b_score')::int=1,'time e placar oficiais');
perform pg_temp.assert(j->>'hard_saves' is null and (j->>'has_valid_rating')::boolean=false,'sem defesas registradas e sem nota válida');
perform pg_temp.as_user(3);
perform pg_temp.assert((public.get_my_last_game(v_a)->'game'->>'match_id')::uuid=v_m2,'o 3 disputou a mais recente');
perform pg_temp.as_user(4);
perform pg_temp.expect_error(format($q$select public.get_my_last_game(%L)$q$,v_a),'PELADA_NOT_FOUND');
perform pg_temp.assert(public.get_my_last_game(v_b)->'game' = 'null'::jsonb,'quem não jogou nada na pelada: sem jogo');
-- partida anulada não é o último jogo
execute 'reset role';
update public.matches set status='annulled' where id=v_m1;
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform pg_temp.assert(public.get_my_last_game(v_a)->'game' = 'null'::jsonb,'anulada não aparece');

  raise exception 'PASS: 047_v84_central (rollback proposital - nada foi gravado)';
end
$test$;
