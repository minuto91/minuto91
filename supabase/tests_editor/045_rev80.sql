-- REV 8.0 (migração 058).
--  1) REV-050 cancelada: só rascunho; idempotente; remarcação na mesma linha; publicada não cancela; não conta.
--  2) REV-047/048/008/049 saída e retorno: mesmo vínculo, períodos, classificação pendente, mensalidade encerrada
--     na saída, dívida antiga preservada e separada, sem cobrança dupla da competência, ausência sem cobrança.
--  3) REV-007 lote: um pagamento por cobrança, parcial e integral, retry não duplica, estorno, item inválido desfaz tudo.
--  4) REV-010 goleiro temporário; REV-013 defesas informadas (temporário não alimenta o motor); REV-011 secundária
--     por partida.
--  5) REV-002 álbum global: soma entre peladas, sequência pela melhor marca, revogação após correção.
--  6) REV-018 rankings Premium no servidor; REV-019/026 retrospectiva só consolidada.
--  7) REV-028 pendências só para quem administra; REV-006 criação idempotente; permissões.
-- Termina SEMPRE com o erro proposital "PASS: 045_rev80".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99800000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.sheet(p_pelada uuid, p_from int, p_to int) returns jsonb language sql as
 $$ select jsonb_agg(jsonb_build_object('membership_id',pg_temp.mem(p_pelada,n),'team',case when n-p_from < (p_to-p_from+1)/2 then 'A' else 'B' end))
    from generate_series(p_from,p_to) n $$;

do $test$
declare v_a uuid; v_b uuid; v_tok text; v_tok2 text; i int; v_m uuid; v_m2 uuid; r jsonb; v_n int; v_c uuid; v_c2 uuid;
 v_req uuid := gen_random_uuid(); v_p uuid; v_claim uuid; v_def uuid; v_season uuid; v_id uuid; v_id2 uuid; v_today date := (now() at time zone 'America/Sao_Paulo')::date;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-r80-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,20) n;
update private.app_config set value='true'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
for i in 1..20 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||lpad(i::text,2,'0'),true,true); end loop;

-- ===== 7a) REV-006 criação idempotente =====
perform pg_temp.as_user(1);
v_a := public.create_pelada_wizard(jsonb_build_object('name','Pelada R80','position','GOL','location','Arena Central',
 'team_a_name','Azul','team_b_name','Branco','team_a_color','azul','team_b_color','branco','weekday',4,'time','20:00',
 'voting_duration_minutes',120,'cards_tracking',true), v_req);
perform pg_temp.assert(public.create_pelada_wizard(jsonb_build_object('name','Pelada R80','position','GOL'), v_req) = v_a,
 'mesmo request_id devolve a mesma pelada');
perform pg_temp.assert((select count(*) from public.peladas where name='Pelada R80')=1, 'sem pelada duplicada');
perform pg_temp.assert((select location='Arena Central' and default_team_a_color='azul' and recurring_weekday=4 from public.peladas where id=v_a),
 'identidade, times e agenda gravados');
perform pg_temp.assert((select voting_duration_minutes=120 and cards_tracking from public.pelada_settings where pelada_id=v_a), 'configurações gravadas');
perform pg_temp.expect_error(format('select public.create_pelada_wizard(%L::jsonb, %L)', '{"name":"X","position":"GOL","voting_duration_minutes":90}', gen_random_uuid()),
 'INVALID_VOTING_DURATION');

v_tok := public.create_pelada_invite(v_a);
for i in 2..14 loop perform pg_temp.as_user(i);
 perform public.join_pelada(v_tok, (array['ZAG','ATA','ZAG','MEI','MEI','ATA','ZAG','MEI','ATA','ZAG','MEI','ATA','MEI'])[i-1]);
end loop;
perform pg_temp.assert((select billing_class from public.pelada_memberships where id=pg_temp.mem(v_a,3))='pending', 'REV-008: entrada pede classificação');
perform pg_temp.assert((select billing_class from public.pelada_memberships where id=pg_temp.mem(v_a,1)) is null, 'criador não é perguntado');

-- ===== 7b) REV-028 pendências =====
perform pg_temp.as_user(1);
r := public.get_my_admin_pending();
perform pg_temp.assert(jsonb_array_length(r)=1 and (r->0->>'billing_pending')::int=13, 'pendência real de classificação: '||r::text);
perform pg_temp.as_user(2);
perform pg_temp.assert(jsonb_array_length(public.get_my_admin_pending())=0, 'jogador comum não vê pendências');

-- ===== 1) REV-050 cancelada =====
perform pg_temp.as_user(1);
v_m := public.create_match(v_a, now() - interval '1 day');
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.cancel_match(%L,null)',v_m),'STAFF_REQUIRED');
perform pg_temp.as_user(1);
perform public.cancel_match(v_m, 'Chuva');
perform public.cancel_match(v_m, 'Chuva'); -- retry
perform pg_temp.assert((select status='cancelled' and cancel_reason='Chuva' and cancelled_by=pg_temp.uid(1) and originally_scheduled_at is not null
 from public.matches where id=v_m), 'cancelada com motivo, autor e data original');
perform pg_temp.expect_error(format('select public.save_match_sheet(%L,%L::jsonb,%L::jsonb)',v_m,pg_temp.sheet(v_a,1,12),'[]'),'');
perform public.reschedule_match(v_m, now() - interval '2 hours');
perform pg_temp.assert((select status='draft' and cancelled_at is null from public.matches where id=v_m), 'remarcada volta a rascunho');
perform pg_temp.assert((select count(*) from public.matches where pelada_id=v_a)=1, 'remarcação não duplica');
perform pg_temp.assert(jsonb_array_length(public.get_match_schedule_history(v_m))=2, 'histórico cancelada + remarcada');
perform public.save_match_sheet(v_m, pg_temp.sheet(v_a,1,12),
 jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_a,3),'type','goal','quantity',1)));
perform public.publish_match(v_m);
perform pg_temp.expect_error(format('select public.cancel_match(%L,null)',v_m),'MATCH_ALREADY_PUBLISHED');
perform pg_temp.expect_error(format('select public.reschedule_match(%L,now())',v_m),'MATCH_ALREADY_PUBLISHED');
-- Cancelada não entra em estatística.
v_m2 := public.create_match(v_a, now() - interval '3 hours');
perform public.save_match_sheet(v_m2, pg_temp.sheet(v_a,1,12),
 jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_a,5),'type','goal','quantity',4)));
perform public.cancel_match(v_m2, null);
perform pg_temp.assert(not exists(select 1 from public.player_season_stats s where s.membership_id=pg_temp.mem(v_a,5) and s.goals >= 4),
 'gols de partida cancelada não contam');

-- ===== 4) REV-010 / REV-013 / REV-011 =====
-- Time A (1..6) tem o goleiro 1; time B (7..12) não tem goleiro.
v_p := (select id from public.match_participants where match_id=v_m and membership_id=pg_temp.mem(v_a,2));
perform pg_temp.expect_error(format('select public.set_match_temp_goalkeeper(%L,%L,true)',v_m,v_p),'TEAM_HAS_GOALKEEPER');
v_p := (select id from public.match_participants where match_id=v_m and membership_id=pg_temp.mem(v_a,8));
perform public.set_match_temp_goalkeeper(v_m, v_p, true);
perform pg_temp.assert((select temp_goalkeeper and primary_position<>'goalkeeper' from public.match_participants where id=v_p),
 'goleiro temporário sem mudar posição');
perform pg_temp.assert((select preferred_position from public.pelada_memberships where id=pg_temp.mem(v_a,8))<>'goalkeeper',
 'posição oficial intacta');
perform pg_temp.as_user(9);
perform pg_temp.expect_error(format('select public.submit_keeper_saves_claim(%L,3)',v_m),'NOT_A_GOALKEEPER');
perform pg_temp.as_user(8);
v_claim := public.submit_keeper_saves_claim(v_m, 3);
perform public.submit_keeper_saves_claim(v_m, 4); -- ajusta enquanto pendente
perform pg_temp.as_user(1);
r := public.get_my_admin_pending();
perform pg_temp.assert((r->0->>'keeper_claims')::int=1, 'claim aparece nas pendências');
perform public.review_keeper_saves_claim(v_claim, 2);
perform pg_temp.assert((select status='corrected' and official_saves=2 from public.match_keeper_save_claims where id=v_claim), 'corrigido pela administração');
perform pg_temp.assert(not exists(select 1 from public.match_keeper_save_claims c join public.match_keeper_saves k on k.participant_id=c.participant_id where c.id=v_claim),
 'temporário não alimenta o motor');
perform pg_temp.as_user(8);
perform pg_temp.expect_error(format('select public.submit_keeper_saves_claim(%L,9)',v_m),'CLAIM_ALREADY_REVIEWED');
perform pg_temp.as_user(1);
v_claim := (select id from public.match_participants where match_id=v_m and membership_id=pg_temp.mem(v_a,1));
perform pg_temp.as_user(1);
v_claim := public.submit_keeper_saves_claim(v_m, 5);
perform public.review_keeper_saves_claim(v_claim, 5);
perform pg_temp.assert((select hard_saves from public.match_keeper_saves where participant_id=(select participant_id from public.match_keeper_save_claims where id=v_claim))=5,
 'goleiro de posição confirmado vira dado oficial');
-- V10.0 (075, REV-147): segunda posição removida; as funções não existem mais e a principal fica intacta.
perform pg_temp.assert(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
 and p.proname in ('request_secondary_position','decide_secondary_position','set_match_secondary_played')), 'REV-147: sem funções de secundária');
perform pg_temp.assert((select preferred_position from public.pelada_memberships where id=pg_temp.mem(v_a,4))='defender', 'principal intacta');

-- ===== 2) Saída e retorno + financeiro =====
perform public.set_default_monthly_amount(v_a, 5000);
r := public.classify_member_billing(pg_temp.mem(v_a,3), true);
perform pg_temp.assert(r->>'billing_class'='monthly' and r->>'finance_member_id' is not null, 'mensalista com valor padrão');
perform public.classify_member_billing(pg_temp.mem(v_a,5), false);
perform pg_temp.assert(not exists(select 1 from public.finance_members where membership_id=pg_temp.mem(v_a,5)), 'não mensalista sem cobrança');
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.classify_member_billing(%L,true)',pg_temp.mem(v_a,6)),'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
perform pg_temp.assert(public.generate_monthly_charges(v_a)=1, 'uma mensalidade');
v_c := (select id from public.finance_charges where membership_id=pg_temp.mem(v_a,3));
perform public.register_payment(v_c, 2000, v_today, 'pix', null, gen_random_uuid());
v_id := pg_temp.mem(v_a,3);
perform pg_temp.as_user(3); perform public.leave_pelada(v_a);
execute 'reset role';
perform pg_temp.assert((select count(*) from public.membership_periods where membership_id=v_id and ended_at is not null)=1, 'saída fecha o período');
perform pg_temp.assert((select status from public.finance_members where membership_id=v_id)='ended', 'mensalidade encerrada na saída');
perform pg_temp.assert((select status from public.finance_charges where id=v_c)='partial', 'dívida antiga preservada');
perform pg_temp.assert(not private.is_member_active_on(v_id, v_today + 40), 'ausência não é participação');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.assert(public.generate_monthly_charges(v_a)=0, 'ausente não é cobrado');
perform pg_temp.as_user(3); perform pg_temp.assert(public.join_pelada(v_tok, null)=v_id, 'retorno reativa o mesmo vínculo');
perform pg_temp.assert((select count(*) from public.pelada_memberships where pelada_id=v_a and user_id=pg_temp.uid(3))=1, 'sem vínculo duplicado');
perform pg_temp.assert((select billing_class='pending' and role='player' and preferred_position='attacker' from public.pelada_memberships where id=v_id),
 'retorno: classificação pendente, sem privilégio, posição preservada');
perform pg_temp.assert((select count(*) from public.membership_periods where membership_id=v_id)=2, 'datas de saída e retorno');
perform pg_temp.as_user(1);
perform public.classify_member_billing(v_id, true, 6000);
perform pg_temp.assert(public.generate_monthly_charges(v_a)=0, 'mesma competência não é cobrada duas vezes');
r := public.get_member_finance_statement(v_id);
perform pg_temp.assert(jsonb_array_length(r->'charges')=1 and r->'charges'->0->>'segment'='before_leave' and (r->>'open_cents')::int=3000
 and jsonb_array_length(r->'periods')=2, 'extrato separa dívida anterior: '||r::text);
perform pg_temp.as_user(3);
perform pg_temp.expect_error(format('select public.get_member_finance_statement(%L)',v_id),'FINANCE_FORBIDDEN');

-- ===== 3) Lote =====
perform pg_temp.as_user(1);
perform public.classify_member_billing(pg_temp.mem(v_a,6), true, 4000);
perform public.classify_member_billing(pg_temp.mem(v_a,7), true, 4000);
perform public.generate_monthly_charges(v_a);
v_c2 := (select id from public.finance_charges where membership_id=pg_temp.mem(v_a,6));
v_id2 := (select id from public.finance_charges where membership_id=pg_temp.mem(v_a,7));
v_req := gen_random_uuid();
r := jsonb_build_array(jsonb_build_object('charge_id',v_c,'amount_cents',3000),jsonb_build_object('charge_id',v_c2,'amount_cents',1500),
 jsonb_build_object('charge_id',v_id2,'amount_cents',4000));
perform public.register_payments_batch(v_a, r, v_today, 'pix', v_req);
perform public.register_payments_batch(v_a, r, v_today, 'pix', v_req); -- duplo clique
perform pg_temp.assert((select count(*) from public.finance_payments where charge_id in (v_c,v_c2,v_id2) and reversed_at is null)=4,
 'um lançamento por cobrança, retry sem duplicar');
perform pg_temp.assert((select status from public.finance_charges where id=v_c)='paid' and (select status from public.finance_charges where id=v_c2)='partial'
 and (select status from public.finance_charges where id=v_id2)='paid', 'integral e parcial');
perform pg_temp.expect_error(format('select public.register_payments_batch(%L,%L::jsonb,%L,%L,%L)',v_a,
 jsonb_build_array(jsonb_build_object('charge_id',v_c2,'amount_cents',100),jsonb_build_object('charge_id',v_c2,'amount_cents',100)),
 v_today,'pix',gen_random_uuid()),'INVALID_VALUE');
perform pg_temp.expect_error(format('select public.register_payments_batch(%L,%L::jsonb,%L,%L,%L)',v_a,
 jsonb_build_array(jsonb_build_object('charge_id',v_c2,'amount_cents',100),jsonb_build_object('charge_id',v_id2,'amount_cents',100)),
 v_today,'pix',gen_random_uuid()),'FINANCE_OVERPAYMENT');
perform pg_temp.assert((select amount_paid_cents from public.finance_charges where id=v_c2)=1500, 'lote com erro não grava nada');
perform public.reverse_payment((select id from public.finance_payments where charge_id=v_c2 and reversed_at is null), 'Valor errado');
perform pg_temp.assert((select status from public.finance_charges where id=v_c2)='pending', 'estorno devolve a pendência');
execute 'reset role';
perform pg_temp.assert((select count(*) from public.finance_events where pelada_id=v_a and event_type='payment_batch_registered')=1, 'lote auditado uma vez');
perform set_config('role','authenticated',true);

-- ===== 6) Rankings e retrospectiva =====
v_season := (select season_id from public.matches where id=v_m);
perform pg_temp.assert((select count(*) from public.get_season_ranking(v_season,'matches')) >= 0, 'Premium: ranking de jogos');
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.expect_error(format('select * from public.get_season_ranking(%L,%L)',v_season,'wins'),'PREMIUM_REQUIRED');
perform pg_temp.expect_error(format('select * from public.get_season_ranking(%L,%L)',v_season,'avg_rating'),'PREMIUM_REQUIRED');
perform (select count(*) from public.get_season_ranking(v_season,'goals'));
perform pg_temp.expect_error(format('select public.get_season_retrospective_official(%L)',v_season),'PREMIUM_REQUIRED');
execute 'reset role';
update private.app_config set value='true'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.expect_error(format('select public.get_season_retrospective_official(%L)',v_season),'SEASON_NOT_CONSOLIDATED');
r := public.get_season_consolidation(v_season);
perform pg_temp.assert(not (r->>'ready')::boolean and not (r->>'calendar_closed')::boolean, 'temporada em andamento não consolida');
-- Temporada encerrada e consolidada (fim no passado, sem votação pendente) gera uma versão só.
execute 'reset role';
update public.matches set status='finalized', finalized_at=now() where id=v_m;
delete from public.rating_vote_sessions where match_id=v_m;
update public.matches set played_at=now() - interval '2 days' where season_id=v_season;
update public.seasons set ends_on=v_today - 1, starts_on=least(starts_on, v_today - 30) where id=v_season;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
r := public.get_season_retrospective_official(v_season);
perform pg_temp.assert((r->>'version')::int=1 and r ? 'selection_leaders' and r ? 'records', 'retrospectiva oficial v1');
perform pg_temp.assert((public.get_season_retrospective_official(v_season)->>'version')::int=1, 'sem duplicar versão');
execute 'reset role';
perform pg_temp.assert((select count(*) from public.season_retrospectives where season_id=v_season)=1, 'uma linha');
update public.matches set team_a_score=team_a_score+3 where id=v_m; -- correção posterior
perform set_config('role','authenticated',true);
perform pg_temp.assert((public.get_season_retrospective_official(v_season)->>'version')::int=2, 'correção gera nova versão');

-- ===== 5) Álbum global =====
execute 'reset role';
v_def := (select id from public.sticker_definitions where code like 'artilheiro%' and level=2);
v_b := (select id from public.peladas where id<>v_a limit 1);
perform set_config('role','authenticated',true);
perform pg_temp.as_user(15); v_b := public.create_pelada('Outra R80','ATA'); v_tok2 := public.create_pelada_invite(v_b);
perform pg_temp.as_user(4); perform public.join_pelada(v_tok2, 'ZAG');
execute 'reset role';
insert into public.player_sticker_progress(pelada_id,membership_id,sticker_definition_id,current_value,target_value,is_unlocked)
select v_a, pg_temp.mem(v_a,4), d.id, 6, d.threshold, 6 >= d.threshold from public.sticker_definitions d where d.metric_code='goals'
on conflict (membership_id, sticker_definition_id) do update set current_value=excluded.current_value;
perform pg_temp.assert(not exists(select 1 from public.player_global_sticker_unlocks where user_id=pg_temp.uid(4) and sticker_definition_id=v_def and status='active'),
 '6 gols ainda não chegam a 10');
insert into public.player_sticker_progress(pelada_id,membership_id,sticker_definition_id,current_value,target_value,is_unlocked)
select v_b, pg_temp.mem(v_b,4), d.id, 5, d.threshold, 5 >= d.threshold from public.sticker_definitions d where d.metric_code='goals'
on conflict (membership_id, sticker_definition_id) do update set current_value=excluded.current_value;
perform pg_temp.assert(exists(select 1 from public.player_global_sticker_unlocks where user_id=pg_temp.uid(4) and sticker_definition_id=v_def and status='active'),
 '6 + 5 = 11 gols somados entre peladas');
perform pg_temp.assert((select count(*) from public.player_global_sticker_unlocks where user_id=pg_temp.uid(4) and status='active'
 and sticker_definition_id in (select id from public.sticker_definitions where metric_code='goals'))=2, 'Artilheiro I e II, sem duplicar');
insert into public.player_sticker_progress(pelada_id,membership_id,sticker_definition_id,current_value,target_value,is_unlocked)
select v_a, pg_temp.mem(v_a,4), d.id, 4, d.threshold, false from public.sticker_definitions d where d.metric_code='best_win_streak'
on conflict (membership_id, sticker_definition_id) do update set current_value=excluded.current_value;
insert into public.player_sticker_progress(pelada_id,membership_id,sticker_definition_id,current_value,target_value,is_unlocked)
select v_b, pg_temp.mem(v_b,4), d.id, 2, d.threshold, false from public.sticker_definitions d where d.metric_code='best_win_streak'
on conflict (membership_id, sticker_definition_id) do update set current_value=excluded.current_value;
perform pg_temp.assert((select global_value from private.global_sticker_values(pg_temp.uid(4)) v join public.sticker_definitions d on d.id=v.sticker_definition_id
 where d.metric_code='best_win_streak' and d.level=1)=4, 'sequência = melhor marca, não soma');
update public.player_sticker_progress set current_value=3 where membership_id=pg_temp.mem(v_b,4)
 and sticker_definition_id in (select id from public.sticker_definitions where metric_code='goals'); -- correção
perform pg_temp.assert(exists(select 1 from public.player_global_sticker_unlocks where user_id=pg_temp.uid(4) and sticker_definition_id=v_def and status='revoked')
 and not exists(select 1 from public.player_global_sticker_unlocks where user_id=pg_temp.uid(4) and sticker_definition_id=v_def and status='active'),
 'correção bloqueia de novo, com rastro');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(4);
r := public.get_my_global_album();
perform pg_temp.assert((select (x->>'value')::int from jsonb_array_elements(r->'stickers') x where (x->>'id')::uuid=v_def)=9
 and (select x->>'unlocked_at' from jsonb_array_elements(r->'stickers') x where (x->>'id')::uuid=v_def) is null, 'álbum global da própria pessoa');
perform pg_temp.as_user(5);
perform pg_temp.assert(not exists(select 1 from public.player_global_sticker_unlocks where user_id=pg_temp.uid(4)), 'RLS: outra conta não lê o álbum');

-- ===== REV-001: Artilheiro do Mês na Sala de Troféus (empate = troféu para todos; revogado não conta) =====
execute 'reset role';
insert into public.awards(pelada_id,season_id,membership_id,award_type,period_month,is_shared)
values(v_a,v_season,pg_temp.mem(v_a,2),'top_scorer',date_trunc('month',now())::date - interval '1 month',true),
      (v_a,v_season,pg_temp.mem(v_a,6),'top_scorer',date_trunc('month',now())::date - interval '1 month',true);
insert into public.awards(pelada_id,season_id,membership_id,award_type,period_month,status,revoked_at)
values(v_a,v_season,pg_temp.mem(v_a,2),'top_scorer',date_trunc('month',now())::date - interval '2 month','revoked',now());
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.assert((public.get_player_career_summary(pg_temp.uid(2))->'trophies'->>'top_scorer')::int=1, 'um troféu ativo, revogado fora');
perform pg_temp.assert(jsonb_array_length(public.get_trophy_history(pg_temp.uid(2),'top_scorer')->'items')=1
 and (public.get_trophy_history(pg_temp.uid(2),'top_scorer')->'items'->0->>'is_shared')::boolean, 'histórico do Artilheiro do Mês, dividido');
perform pg_temp.as_user(6);
perform pg_temp.assert((public.get_player_career_summary(pg_temp.uid(6))->'trophies'->>'top_scorer')::int=1, 'empatado também recebe');
perform pg_temp.expect_error(format('select public.get_trophy_history(%L,%L)',pg_temp.uid(6),'match_garcom'),'INVALID_TROPHY');

raise exception 'PASS: 045_rev80';
end $test$;
