-- Notificações e tarefas agendadas (migração 022). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 015_notifications_jobs" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('f0000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.n(p_type text) returns bigint language sql as
 $$ select count(*) from public.notification_events where event_type=p_type and user_id::text like 'f0000000%' $$;

do $test$
declare v_pid uuid; v_tok text; v_x uuid; v_s uuid; v_parts jsonb; v_old uuid; v_claimed int;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-nt'||n||'@example.invalid','',now(),now(),now() from generate_series(1,7) n;
perform set_config('role','authenticated',true);
for i in 1..7 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Avisos','attacker');
v_tok := public.create_pelada_invite(v_pid);
for i in 2..6 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,'midfielder'); end loop;

-- ===== Votação aberta / súmula corrigida avisam os 6 eleitores =====
perform pg_temp.as_user(1);
v_parts := (select jsonb_agg(jsonb_build_object('membership_id',pg_temp.mem(v_pid,i),'team',case when i%2=1 then 'A' else 'B' end))
 from generate_series(1,6) i);
v_x := public.create_match(v_pid,now());
perform public.save_match_sheet(v_x,v_parts,'[]');
v_s := (public.publish_match(v_x)->>'session_id')::uuid;
perform public.correct_match_sheet(v_x,v_parts,jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_pid,1),
  'type','goal','quantity',1)),'Faltou um gol');
execute 'reset role';
perform pg_temp.assert(pg_temp.n('voting_opened')=6,'votação aberta: 6 avisos');
perform pg_temp.assert(pg_temp.n('sheet_corrected')=6,'súmula corrigida: 6 avisos');
perform pg_temp.assert((select bool_and(category='essential' and not payload ? 'rating') from public.notification_events
  where user_id::text like 'f0000000%'),'essenciais e sem dado de voto');

-- ===== Lembrete 1h antes e fechamento pelo agendador =====
update public.voting_sessions set closes_at=now()+interval '30 minutes' where id=v_s;
perform private.run_scheduled_tasks();
perform private.run_scheduled_tasks(); -- repetir não duplica
perform pg_temp.assert(pg_temp.n('voting_closing_soon')=6,'lembrete para quem não votou, uma vez');
update public.voting_sessions set closes_at=now()-interval '1 minute' where id=v_s;
perform private.run_scheduled_tasks();
perform pg_temp.assert((select status='finalized' and not is_valid from public.voting_sessions where id=v_s),'agendador fecha a votação vencida');
perform pg_temp.assert(pg_temp.n('result_published')=6,'resultado avisado aos membros');

-- ===== Limite de engajamento: 3 por semana =====
for i in 1..4 loop
 perform private.notify(pg_temp.uid(7),null,'sticker_unlocked','engagement','teste-eng-'||i);
end loop;
perform private.notify(pg_temp.uid(7),null,'sticker_unlocked','engagement','teste-eng-1'); -- repetido
perform pg_temp.assert((select count(*) filter (where status='pending')=3 and count(*) filter (where status='suppressed')=1
  from public.notification_events where user_id=pg_temp.uid(7)),'3 enviadas, a 4ª suprimida, repetida ignorada');

-- ===== Envio (Edge Function) =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(7);
perform public.register_push_device('ExponentPushToken[teste-7]','ios');
perform pg_temp.assert((select count(*)=4 from public.notification_events),'cada um vê só as suas');
perform pg_temp.expect_error('select * from public.claim_notifications(10)','permission denied');
perform pg_temp.expect_error($q$insert into public.notification_events(user_id,event_type,category,dedupe_key) values(auth.uid(),'x','essential','x')$q$,'permission denied');
perform set_config('role','service_role',true);
select count(*) into v_claimed from public.claim_notifications(1000) c where c.user_id=pg_temp.uid(7)
 and c.tokens=array['ExponentPushToken[teste-7]'];
execute 'reset role';
perform pg_temp.assert(v_claimed=3,'envio leva as 3 pendentes com o token do aparelho');
perform pg_temp.assert((select count(*)=0 from public.notification_events where user_id::text like 'f0000000%' and status='pending'),'marcadas como enviadas');

-- ===== Fim de temporada e falhas registradas =====
v_old := private.season_for_date(v_pid, (now() - interval '400 days')::date);
perform private.run_scheduled_tasks();
perform pg_temp.assert(exists(select 1 from private.season_cleanups where season_id=v_old),'temporada encerrada limpa');
perform private.run_job('teste_falha', v_pid, 'select 1/0');
perform pg_temp.assert(exists(select 1 from private.background_jobs where job_type='teste_falha' and status='failed'
  and last_error like '%division by zero%'),'falha registrada para o desenvolvedor');

  raise exception 'PASS: 015_notifications_jobs (rollback proposital - nada foi gravado)';
end
$test$;
