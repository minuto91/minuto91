-- Envio de push (migração 035): reserva com prazo, confirmação depois do aceite, tentativas, tokens inválidos,
-- acesso no momento do envio, preferências, novos avisos e permissões.
-- Cole no SQL Editor do Supabase DEV (ou rode no banco local: supabase/local_db).
-- Termina SEMPRE com o erro proposital "PASS: 029_push_delivery" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('c2890000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
create function pg_temp.as_user(n int) returns void language plpgsql as
 $$ begin perform set_config('role','authenticated',true);
  perform set_config('request.jwt.claim.sub', pg_temp.uid(n)::text, true); end $$;
create function pg_temp.as_service() returns void language plpgsql as
 $$ begin perform set_config('request.jwt.claim.sub', '', true); perform set_config('role','service_role',true); end $$;
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
-- Notificação de teste (como os gatilhos fazem), devolve o id.
create function pg_temp.enqueue(n int, p_pelada uuid, p_type text, p_cat text, p_key text, p_payload jsonb default '{}')
 returns uuid language plpgsql as
 $$ begin perform private.notify(pg_temp.uid(n), p_pelada, p_type, p_cat, 't029:'||p_key, p_payload);
  return (select id from public.notification_events where dedupe_key='t029:'||p_key); end $$;
create function pg_temp.st(p_id uuid) returns text language sql as
 $$ select status||coalesce(':'||last_error,'') from public.notification_events where id=p_id $$;
create function pg_temp.tok(n int, d int default 1) returns text language sql as
 $$ select 'ExponentPushToken[t029-'||n||'-'||d||']' $$;

do $test$
declare v_a uuid; v_tok text; n1 uuid; n2 uuid; n3 uuid; n4 uuid; n5 uuid; x uuid; v_rows int; v_c record;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-pd'||n||'@example.invalid','',now(),now(),now() from generate_series(1,4) n;
for i in 1..4 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada Push','attacker'); v_tok := public.create_pelada_invite(v_a);
perform pg_temp.as_user(2); perform public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(3); perform public.join_pelada(v_tok,'midfielder');
-- 1 tem dois aparelhos, 2 tem um, 3 e 4 nenhum.
perform pg_temp.as_user(1); perform public.register_push_device(pg_temp.tok(1,1),'ios'); perform public.register_push_device(pg_temp.tok(1,2),'android');
perform pg_temp.as_user(2); perform public.register_push_device(pg_temp.tok(2),'ios');
execute 'reset role';
-- Limpa o que a criação da pelada já enfileirou, para o teste olhar só o que ele cria.
delete from public.notification_events where user_id in (select pg_temp.uid(n) from generate_series(1,4) n);

n1 := pg_temp.enqueue(1, v_a, 'result_published', 'essential', 'r1');
n2 := pg_temp.enqueue(2, v_a, 'result_published', 'essential', 'r2');
n3 := pg_temp.enqueue(3, v_a, 'result_published', 'essential', 'r3');

-- ===== Reserva: só o que tem aparelho; o resto é pulado com motivo =====
perform pg_temp.as_service();
select count(*) total, count(*) filter (where cardinality(c.tokens)=2 and c.user_id=pg_temp.uid(1)) two into v_c
 from public.claim_notifications(100) c;
perform pg_temp.assert(v_c.total=2 and v_c.two=1, '2 reservadas (1 e 2), com os 2 aparelhos do 1; 3 sem aparelho');
execute 'reset role';
perform pg_temp.assert(pg_temp.st(n1)='sending' and pg_temp.st(n2)='sending' and pg_temp.st(n3)='skipped:NO_DEVICE', 'estados após reservar');
perform pg_temp.assert((select attempt_count=1 and claimed_at is not null and sent_at is null from public.notification_events where id=n1),
 'reservada não é enviada: sent_at vazio');
-- Segunda chamada logo em seguida: nada (prazo da reserva).
perform pg_temp.as_service();
perform pg_temp.assert((select count(*) from public.claim_notifications(100))=0, 'sem dupla reserva');

-- ===== Confirmação: aceito vira sent; erro temporário volta para a fila com espera =====
perform public.complete_notifications(jsonb_build_array(
 jsonb_build_object('id',n1,'outcome','accepted','tickets',jsonb_build_array(jsonb_build_object('token',pg_temp.tok(1,1),'ticket_id','tk-1'))),
 jsonb_build_object('id',n2,'outcome','retry','error','HTTP 503')));
execute 'reset role';
perform pg_temp.assert(pg_temp.st(n1)='sent' and (select sent_at is not null and push_tickets is not null from public.notification_events where id=n1),
 'aceito pelo Expo = sent, com ticket');
perform pg_temp.assert(pg_temp.st(n2)='pending:HTTP 503' and (select scheduled_at > now() + interval '90 seconds' from public.notification_events where id=n2),
 'retry: volta para pending com espera (2 min na 1ª tentativa)');
-- Resposta atrasada ou repetida não muda nada.
perform pg_temp.as_service();
perform pg_temp.assert(public.complete_notifications(jsonb_build_array(jsonb_build_object('id',n1,'outcome','failed','error','x')))=0,
 'confirmação duplicada ignorada');
perform pg_temp.expect_error('select public.complete_notifications(''[{"id":"00000000-0000-0000-0000-000000000000","outcome":"talvez"}]'')','INVALID_OUTCOME');
execute 'reset role';

-- ===== Remetente que caiu: reserva vencida é retomada =====
update public.notification_events set scheduled_at=now() - interval '1 minute' where id=n2;
perform pg_temp.as_service();
perform public.claim_notifications(100);
execute 'reset role';
update public.notification_events set claimed_at=now() - interval '6 minutes' where id=n2;
perform pg_temp.as_service();
perform pg_temp.assert((select count(*) from public.claim_notifications(100) c where c.id=n2 and c.attempt=3)=1, 'retomada após o prazo, 3ª tentativa');
-- Token inválido: apaga só o aparelho daquele usuário (um token de outro na lista não é apagado).
perform public.complete_notifications(jsonb_build_array(jsonb_build_object('id',n2,'outcome','failed','error','DeviceNotRegistered',
 'invalid_tokens',jsonb_build_array(pg_temp.tok(2), pg_temp.tok(1,2)))));
execute 'reset role';
perform pg_temp.assert(pg_temp.st(n2)='failed:DeviceNotRegistered', 'falha definitiva');
perform pg_temp.assert(not exists(select 1 from public.push_devices where expo_push_token=pg_temp.tok(2)), 'token morto apagado');
perform pg_temp.assert(exists(select 1 from public.push_devices where expo_push_token=pg_temp.tok(1,2)), 'token de outro usuário intacto');

-- ===== Limite de tentativas =====
n4 := pg_temp.enqueue(1, v_a, 'match_annulled', 'essential', 'max');
update public.notification_events set attempt_count=5 where id=n4;
perform pg_temp.as_service(); perform public.claim_notifications(100); execute 'reset role';
perform pg_temp.assert(pg_temp.st(n4)='failed:MAX_ATTEMPTS', '5 tentativas = failed');

-- ===== Acesso no momento do envio: quem saiu da pelada não recebe =====
perform pg_temp.as_user(2); perform public.register_push_device(pg_temp.tok(2,2),'ios');
execute 'reset role';
n5 := pg_temp.enqueue(2, v_a, 'result_published', 'essential', 'left');
perform pg_temp.as_user(2); perform public.leave_pelada(v_a);
perform pg_temp.as_service(); perform public.claim_notifications(100); execute 'reset role';
perform pg_temp.assert(pg_temp.st(n5)='skipped:NO_ACCESS', 'saiu da pelada: pulada');

-- ===== Preferências =====
perform pg_temp.as_user(1);
perform public.set_notification_preferences(false, true);
perform pg_temp.assert((select count(*) from public.notification_preferences)=1, 'lê só a própria preferência');
perform pg_temp.expect_error('select public.set_notification_preferences(null, true)','INVALID_PREFERENCES');
perform pg_temp.expect_error('insert into public.notification_preferences(user_id) values (auth.uid())','permission denied');
perform pg_temp.as_user(3);
perform pg_temp.assert((select count(*) from public.notification_preferences)=0, 'não lê a de outro');
execute 'reset role';
x := pg_temp.enqueue(1, v_a, 'result_published', 'essential', 'opt');
n3 := pg_temp.enqueue(1, null, 'account_transferred', 'essential', 'transfer');
n4 := pg_temp.enqueue(1, v_a, 'award_match_craque', 'engagement', 'award');
perform pg_temp.as_service(); perform public.claim_notifications(100); execute 'reset role';
perform pg_temp.assert(pg_temp.st(x)='skipped:OPTED_OUT', 'essenciais desligadas');
perform pg_temp.assert(pg_temp.st(n3)='sending', 'transferência de conta sempre vai');
perform pg_temp.assert(pg_temp.st(n4)='sending', 'engajamento ligado continua');

-- ===== Votação que já fechou e aviso velho =====
x := pg_temp.enqueue(3, v_a, 'voting_closing_soon', 'essential', 'closed', jsonb_build_object('match_id', gen_random_uuid()));
n5 := pg_temp.enqueue(3, v_a, 'result_published', 'essential', 'old');
update public.notification_events set created_at=now() - interval '25 hours' where id=n5;
perform pg_temp.as_service(); perform public.claim_notifications(100); execute 'reset role';
perform pg_temp.assert(pg_temp.st(x)='skipped:VOTING_CLOSED', 'votação fechada: pulada');
perform pg_temp.assert(pg_temp.st(n5)='skipped:STALE', 'mais de 24h: pulada');
n5 := pg_temp.enqueue(1, v_a, 'award_bola_murcha', 'engagement', 'murcha');
perform pg_temp.as_service(); perform public.claim_notifications(100); execute 'reset role';
perform pg_temp.assert(pg_temp.st(n5)='skipped:POLICY', 'Bola Murcha não vira push');

-- ===== Recibos (entrega à Apple/Google) =====
update public.notification_events set sent_at=now() - interval '20 minutes' where id=n1;
perform pg_temp.as_service();
perform pg_temp.assert((select count(*) from public.claim_push_receipts(100) r where r.id=n1)=1, 'recibo pendente listado');
perform pg_temp.assert(public.record_push_receipts(jsonb_build_array(jsonb_build_object('id',n1,'error','DeviceNotRegistered',
 'invalid_tokens',jsonb_build_array(pg_temp.tok(1,1)))))=1, 'recibo gravado');
perform pg_temp.assert(public.record_push_receipts(jsonb_build_array(jsonb_build_object('id',n1,'error',null)))=0, 'recibo repetido ignorado');
execute 'reset role';
perform pg_temp.assert((select delivery_error='DeviceNotRegistered' and status='sent' from public.notification_events where id=n1),
 'sent continua sent; o erro de entrega fica separado');
perform pg_temp.assert(not exists(select 1 from public.push_devices where expo_push_token=pg_temp.tok(1,1)), 'token morto do recibo apagado');

-- ===== Novos avisos: função de assistente e sucessor (só o afetado), retrospectiva no fim da temporada =====
perform pg_temp.as_user(1);
perform public.set_assistant(v_a, pg_temp.mem(v_a,3), true);
perform public.set_successor(v_a, pg_temp.mem(v_a,3));
execute 'reset role';
perform pg_temp.assert((select count(*) from public.notification_events where user_id=pg_temp.uid(3)
 and event_type in ('role_changed','successor_designated'))=2, 'assistente e sucessor avisados');
perform pg_temp.assert(not exists(select 1 from public.notification_events where user_id=pg_temp.uid(1)
 and event_type in ('role_changed','successor_designated')), 'quem fez a mudança não é avisado');
insert into private.season_cleanups(season_id) select id from public.seasons where pelada_id=v_a limit 1;
perform pg_temp.assert((select count(*) from public.notification_events where event_type='season_review'
 and pelada_id=v_a)=2, 'retrospectiva: os 2 membros ativos (1 e 3)');

-- ===== Permissões =====
perform pg_temp.as_user(1);
perform pg_temp.expect_error('select * from public.claim_notifications(10)','permission denied');
perform pg_temp.expect_error('select public.complete_notifications(''[]'')','permission denied');
perform pg_temp.expect_error('select * from public.claim_push_receipts(10)','permission denied');
perform pg_temp.expect_error('select public.record_push_receipts(''[]'')','permission denied');
perform pg_temp.expect_error('update public.notification_events set status=''sent''','permission denied');
execute 'reset role';
perform pg_temp.assert(not has_function_privilege('anon','public.set_notification_preferences(boolean,boolean)','execute'), 'anon sem preferências');

raise exception 'PASS: 029_push_delivery (rollback proposital - nada foi gravado)';
end
$test$;
