-- V4.3 (migração 043): Financeiro da Pelada Premium — os 24 cenários da seção 9.16 (o 15, concorrência real
-- com duas conexões, também roda em supabase/local_db/concurrency.mjs).
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 036_v43_finance".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.owner_mem(p_pelada uuid, n int) returns uuid language plpgsql as
 $$ declare v uuid; begin reset role; v := pg_temp.mem(p_pelada, n); perform set_config('role','authenticated',true); return v; end $$;
create function pg_temp.owner_today(p_pelada uuid) returns date language plpgsql as
 $$ declare v date; begin reset role; v := private.pelada_today(p_pelada); perform set_config('role','authenticated',true); return v; end $$;
create function pg_temp.ov(p_pelada uuid, k text) returns bigint language sql as
 $$ select (public.get_finance_overview(p_pelada)->>k)::bigint $$;

do $test$
declare
 v_p uuid; v_q uuid; v_tok text; v_today date; v_m4 jsonb; v_m5 jsonb; v_c jsonb; v_c2 jsonb; v_ch uuid; v_pay uuid; v_rid uuid;
 v_x uuid; v_payer uuid; v_r jsonb; v_e jsonb; v_n int; v_prev date; v_bal bigint; v_mem6 uuid; v_mem7 uuid; v_req uuid; v_match uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-fin'||n||'@example.invalid','',now(),now(),now() from generate_series(1,12) n;
perform set_config('role','authenticated',true);
for i in 1..12 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||lpad(i::text,2,'0'),true,true); end loop;
-- Pelada P: admin 1; assistentes 2 (com permissão financeira) e 3 (sem); jogadores 4..8. Pelada Q: admin 9.
perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada Caixa','GOL');
v_tok := public.create_pelada_invite(v_p);
for i in 2..8 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok, 'MEI'); end loop;
perform pg_temp.as_user(9); v_q := public.create_pelada('Pelada Vizinha','ZAG');
perform pg_temp.as_user(1);
perform public.set_assistant(v_p, pg_temp.mem(v_p,2), true);
perform public.set_assistant(v_p, pg_temp.mem(v_p,3), true);
v_today := pg_temp.owner_today(v_p);
v_prev := (date_trunc('month', v_today) - interval '1 month')::date;

-- ===== 17) permissões =====
v_r := public.get_finance_access(v_p);
perform pg_temp.assert((v_r->>'can_access')::boolean and (v_r->>'is_admin')::boolean and jsonb_array_length(v_r->'assistants')=2,'admin acessa');
perform pg_temp.as_user(4);
v_r := public.get_finance_access(v_p);
perform pg_temp.assert(not (v_r->>'can_access')::boolean and v_r->'assistants'='null'::jsonb and v_r->'has_records'='null'::jsonb,
 'jogador comum: sem acesso e nada financeiro na resposta');
perform pg_temp.expect_error(format('select public.get_finance_overview(%L)',v_p),'FINANCE_FORBIDDEN');
perform pg_temp.expect_error(format('select public.set_finance_access(%L,%L,true)',v_p,pg_temp.mem(v_p,4)),'ADMIN_REQUIRED');
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.get_finance_overview(%L)',v_p),'FINANCE_FORBIDDEN'); -- assistente sem permissão explícita
perform pg_temp.expect_error(format('select public.set_finance_access(%L,%L,true)',v_p,pg_temp.mem(v_p,2)),'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.set_finance_access(%L,%L,true)',v_p,pg_temp.mem(v_p,4)),'FINANCE_ASSISTANT_REQUIRED');
perform public.set_finance_access(v_p, pg_temp.mem(v_p,2), true);
perform pg_temp.as_user(2);
perform pg_temp.assert(public.get_finance_overview(v_p) ? 'balance_cents','assistente com permissão acessa');
perform pg_temp.as_user(3);
perform pg_temp.expect_error(format('select public.get_finance_overview(%L)',v_p),'FINANCE_FORBIDDEN');

-- ===== 1) mensalista, 3) geração, 2) alteração de valor =====
perform pg_temp.as_user(1);
v_m4 := public.save_monthly_member(v_p, null, pg_temp.mem(v_p,4), null, 5000, 10, v_prev, 'Paga sempre no Pix');
perform pg_temp.assert(v_m4->>'status'='active' and (v_m4->>'amount_cents')::int=5000 and v_m4->>'person_name'='Jogador 04','mensalista cadastrado');
perform pg_temp.expect_error(format('select public.save_monthly_member(%L,null,%L,null,5000,10,%L)',v_p,pg_temp.mem(v_p,4),v_prev),'FINANCE_ALREADY_MONTHLY');
perform pg_temp.expect_error(format('select public.save_monthly_member(%L,null,%L,null,5000,31,%L)',v_p,pg_temp.mem(v_p,5),v_prev),'FINANCE_INVALID_DUE_DAY');
perform pg_temp.expect_error(format('select public.save_monthly_member(%L,null,%L,%L,5000,10,%L)',v_p,pg_temp.mem(v_p,5),gen_random_uuid(),v_prev),'FINANCE_PERSON_REQUIRED');
v_n := public.generate_monthly_charges(v_p, v_prev);
perform pg_temp.assert(v_n=1,'cobrança do mês anterior gerada');
perform pg_temp.assert(public.generate_monthly_charges(v_p, v_prev)=0,'geração idempotente (sem duplicar)');
perform pg_temp.assert(public.generate_monthly_charges(v_p, null)=1,'mês atual');
perform pg_temp.expect_error(format('select public.generate_monthly_charges(%L,%L)',v_p,(v_today + interval '3 months')::date),'FINANCE_INVALID_DATE');
v_m4 := public.save_monthly_member(v_p, (v_m4->>'id')::uuid, pg_temp.mem(v_p,4), null, 6000, 10, v_prev, null, (v_m4->>'version')::int);
perform pg_temp.expect_error(format('select public.save_monthly_member(%L,%L,%L,null,7000,10,%L,null,1)',v_p,v_m4->>'id',pg_temp.mem(v_p,4),v_prev),'FINANCE_VERSION_CONFLICT');
perform pg_temp.assert((select bool_and((x->>'amount_due_cents')::int=5000) from jsonb_array_elements(public.get_finance_charges(v_p,null,null,pg_temp.mem(v_p,4))) x),
 'novo valor não muda cobranças já geradas');
perform public.generate_monthly_charges(v_p, (date_trunc('month', v_today) + interval '1 month')::date);
perform pg_temp.assert((select (x->>'amount_due_cents')::int from jsonb_array_elements(public.get_finance_charges(v_p,null,null,pg_temp.mem(v_p,4))) x
 order by x->>'due_date' desc limit 1)=6000,'próximo mês com o novo valor');

-- ===== 9) mensalidade vencida =====
v_c := (select x from jsonb_array_elements(public.get_finance_charges(v_p,v_prev,null,pg_temp.mem(v_p,4))) x);
perform pg_temp.assert((v_c->>'overdue')::boolean and v_c->>'status'='pending','mês anterior vencido');
perform pg_temp.assert(pg_temp.ov(v_p,'monthly_late')=1 and pg_temp.ov(v_p,'overdue_cents')>=5000,'painel: 1 mensalista atrasado');
perform pg_temp.assert(jsonb_array_length(public.get_finance_charges(v_p,null,'overdue'))>=1,'filtro de vencidas');

-- ===== 4) pagamento integral =====
v_rid := gen_random_uuid();
v_c := public.register_payment((v_c->>'id')::uuid, 5000, v_today, 'pix', null, v_rid);
perform pg_temp.assert(v_c->>'status'='paid' and (v_c->>'outstanding_cents')::int=0 and not (v_c->>'overdue')::boolean,'pago integral');
-- mesma requisição de novo (toque duplo / reenvio): nada novo
v_c := public.register_payment((v_c->>'id')::uuid, 5000, v_today, 'pix', null, v_rid);
perform pg_temp.assert(jsonb_array_length(v_c->'payments')=1,'reenvio idempotente');
perform pg_temp.expect_error(format('select public.register_payment(%L,1,%L,null,null,%L)',v_c->>'id',v_today,gen_random_uuid()),'FINANCE_OVERPAYMENT');
perform pg_temp.assert(pg_temp.ov(v_p,'monthly_late')=(case when jsonb_array_length(public.get_finance_charges(v_p,null,'overdue',pg_temp.mem(v_p,4)))>0 then 1 else 0 end),
 'atraso conta só cobranças vencidas em aberto (o mês anterior foi quitado)');

-- ===== 5) parcial e 6) duplicado =====
v_m5 := public.save_monthly_member(v_p, null, pg_temp.mem(v_p,5), null, 10000, 5, date_trunc('month', v_today)::date);
perform public.generate_monthly_charges(v_p, null);
v_ch := ((select x from jsonb_array_elements(public.get_finance_charges(v_p,null,null,pg_temp.mem(v_p,5))) x)->>'id')::uuid;
v_c := public.register_payment(v_ch, 2000, v_today, 'dinheiro', 'metade na quinta', gen_random_uuid());
perform pg_temp.assert(v_c->>'status'='partial' and (v_c->>'outstanding_cents')::int=8000,'parcial: falta 80,00');
-- outro admin registra o mesmo valor logo em seguida: possível duplicidade
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.register_payment(%L,2000,%L,%L,null,%L)',v_ch,v_today,'dinheiro',gen_random_uuid()),'FINANCE_POSSIBLE_DUPLICATE');
v_c := public.register_payment(v_ch, 2000, v_today, 'dinheiro', 'confirmado: era outra parcela', gen_random_uuid(), true);
perform pg_temp.assert((v_c->>'amount_paid_cents')::int=4000 and jsonb_array_length(v_c->'payments')=2,'segunda parcela confirmada');
perform pg_temp.expect_error(format('select public.register_payment(%L,6001,%L,null,null,%L)',v_ch,v_today,gen_random_uuid()),'FINANCE_OVERPAYMENT');

-- ===== 8) estorno =====
v_bal := pg_temp.ov(v_p,'balance_cents');
v_pay := ((v_c->'payments'->1)->>'id')::uuid;
perform pg_temp.expect_error(format('select public.reverse_payment(%L,%L)',v_pay,''),'FINANCE_REASON_REQUIRED');
v_c := public.reverse_payment(v_pay, 'lançado em dobro');
perform pg_temp.assert(v_c->>'status'='partial' and (v_c->>'amount_paid_cents')::int=2000 and (v_c->'payments'->1->>'reversed_at') is not null,
 'estorno: pagamento mantido como estornado');
perform pg_temp.assert(pg_temp.ov(v_p,'balance_cents')=v_bal-2000,'saldo cai o valor estornado');
perform pg_temp.expect_error(format('select public.reverse_payment(%L,%L)',v_pay,'de novo'),'FINANCE_ALREADY_REVERSED');

-- ===== 7) cancelamento =====
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.cancel_charge(%L,%L)',v_ch,'desistiu'),'FINANCE_CHARGE_HAS_PAYMENTS');
v_c := public.create_charge(v_p, 'extra', pg_temp.mem(v_p,6), null, null, 'Rateio do churrasco', 3000, v_today, gen_random_uuid());
perform pg_temp.expect_error(format('select public.cancel_charge(%L,%L)',v_c->>'id',''),'FINANCE_REASON_REQUIRED');
v_c := public.cancel_charge((v_c->>'id')::uuid, 'churrasco cancelado');
perform pg_temp.assert(v_c->>'status'='cancelled' and (v_c->>'outstanding_cents')::int=0,'cancelada (exclusão lógica)');
perform pg_temp.expect_error(format('select public.register_payment(%L,100,%L,null,null,%L)',v_c->>'id',v_today,gen_random_uuid()),'FINANCE_CHARGE_CANCELLED');
-- alteração de vencimento
v_c := public.create_charge(v_p, 'extra', pg_temp.mem(v_p,6), null, null, 'Uniforme novo', 4500, v_today + 5, gen_random_uuid());
v_c2 := public.update_charge((v_c->>'id')::uuid, 4500, v_today + 10, null, 1);
perform pg_temp.assert((v_c2->>'due_date')::date=v_today+10 and (v_c2->>'version')::int=2,'vencimento alterado');
perform pg_temp.expect_error(format('select public.update_charge(%L,4500,%L,null,1)',v_c->>'id',v_today),'FINANCE_VERSION_CONFLICT');
perform public.register_payment((v_c->>'id')::uuid, 1500, v_today, null, null, gen_random_uuid());
perform pg_temp.expect_error(format('select public.update_charge(%L,1000,%L,null)',v_c->>'id',v_today),'FINANCE_AMOUNT_BELOW_PAID');

-- ===== 10) avulso (com e sem conta) =====
v_payer := public.save_finance_payer(v_p, null, 'Carlos Externo', 'amigo do Zé');
perform pg_temp.expect_error(format('select public.save_finance_payer(%L,null,%L)',v_p,' carlos externo '),'FINANCE_DUPLICATE_PAYER');
v_match := public.create_match(v_p, now() - interval '1 hour', 'Azul', 'Dourado');
v_c := public.create_charge(v_p, 'single', null, v_payer, v_match, null, 2500, v_today, gen_random_uuid());
perform pg_temp.assert(v_c->>'person_name'='Carlos Externo' and v_c->>'description'='Avulso' and (v_c->>'match_id')::uuid=v_match,'avulso externo ligado à partida');
v_c := public.create_charge(v_p, 'single', pg_temp.mem(v_p,8), null, null, 'Avulso quinta', 2500, v_today - 2, gen_random_uuid());
perform pg_temp.assert((v_c->>'overdue')::boolean,'avulso pendente vencido');
perform pg_temp.as_user(9); v_x := public.create_match(v_q, now() - interval '1 hour', 'A', 'B');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.create_charge(%L,%L,null,%L,%L,null,2500,%L,%L)',v_p,'single',v_payer,v_x,v_today,gen_random_uuid()),'FINANCE_INVALID_MATCH');
perform pg_temp.expect_error(format('select public.create_charge(%L,%L,%L,null,null,null,2500,%L,%L)',v_p,'single',pg_temp.owner_mem(v_q,9),v_today,gen_random_uuid()),'FINANCE_INVALID_PERSON');
perform pg_temp.assert(pg_temp.ov(v_p,'single_count_month')>=1,'avulsos do mês no painel');

-- ===== 11) receita extra e 12) despesas =====
v_e := public.save_finance_entry(v_p, null, 'income', 'Patrocínio', 'Padaria do bairro', 15000, v_today, 'settled', 'pix', null, gen_random_uuid());
v_rid := gen_random_uuid();
v_e := public.save_finance_entry(v_p, null, 'expense', 'Aluguel do campo', 'Campo de outubro', 20000, v_today, 'settled', 'transferencia', null, v_rid);
v_e := public.save_finance_entry(v_p, null, 'expense', 'Aluguel do campo', 'Campo de outubro', 20000, v_today, 'settled', 'transferencia', null, v_rid);
perform pg_temp.assert((select count(*) from jsonb_array_elements(public.get_finance_ledger(v_p)) x where x->>'description'='Campo de outubro')=1,
 'despesa idempotente pelo request_id');
v_e := public.save_finance_entry(v_p, null, 'expense', 'Arbitragem', 'Juiz da final', 5000, v_today + 7, 'pending', null, null, gen_random_uuid());
perform public.save_finance_entry(v_p, null, 'expense', 'Água', 'Galões', 1200, v_today, 'settled', 'dinheiro', null, gen_random_uuid());
perform pg_temp.expect_error(format('select public.save_finance_entry(%L,null,%L,%L,%L,-100,%L,%L,null,null,%L)',v_p,'expense','Água','x',v_today,'settled',gen_random_uuid()),'FINANCE_INVALID_AMOUNT');
perform pg_temp.expect_error(format('select public.save_finance_entry(%L,null,%L,%L,%L,100,%L,%L,null,null,%L)',v_p,'expense','Água','x',v_today+1,'settled',gen_random_uuid()),'FINANCE_INVALID_DATE');
-- categoria livre (sem lista rígida)
perform public.save_finance_entry(v_p, null, 'expense', 'Troféu da temporada', 'Troféu', 8000, v_today, 'settled', null, null, gen_random_uuid());
-- cancelar lançamento (sem apagar)
perform public.cancel_finance_entry((public.save_finance_entry(v_p, null, 'income', 'Outras receitas', 'Engano', 999, v_today, 'settled', null, null, gen_random_uuid())->>'id')::uuid, 'lançado errado');

-- ===== 13) saldo (conferência independente) =====
execute 'reset role';
v_bal := (select coalesce(sum(amount_cents),0) from public.finance_payments where pelada_id=v_p and reversed_at is null)
 + (select coalesce(sum(amount_cents),0) from public.finance_entries where pelada_id=v_p and direction='income' and status='settled')
 - (select coalesce(sum(amount_cents),0) from public.finance_entries where pelada_id=v_p and direction='expense' and status='settled');
perform set_config('role','authenticated',true);
v_r := public.get_finance_overview(v_p);
perform pg_temp.assert((v_r->>'balance_cents')::bigint = v_bal,'saldo = recebido - pago: '||(v_r->>'balance_cents')||' x '||v_bal);
-- números conhecidos: 5000 + 2000 + 1500 (pagamentos) + 15000 (patrocínio) - 20000 - 1200 - 8000 = -5700
perform pg_temp.assert(v_bal = -5700,'saldo esperado -57,00 (pendências não contam): '||v_bal);
perform pg_temp.assert((v_r->>'pending_expense_cents')::bigint=5000,'despesa pendente separada');
perform pg_temp.assert((v_r->>'projected_balance_cents')::bigint = v_bal + (v_r->>'receivable_cents')::bigint - 5000,'projeção separada do realizado');

-- ===== 14) relatório mensal, por categoria e por jogador =====
v_r := public.get_finance_report(v_p, v_today);
perform pg_temp.assert((v_r->>'income_cents')::bigint - (v_r->>'expense_cents')::bigint = (v_r->>'result_cents')::bigint,'resumo mensal fecha');
perform pg_temp.assert((select (x->>'amount_cents')::bigint from jsonb_array_elements(v_r->'by_category') x where x->>'category'='Aluguel do campo')=20000,
 'despesa por categoria');
perform pg_temp.assert((select (x->>'amount_cents')::bigint from jsonb_array_elements(v_r->'by_category') x where x->>'category'='Mensalidade')=7000,
 'mensalidades recebidas no mês (5000 + 2000)');
perform pg_temp.assert((select (x->>'paid_cents')::bigint from jsonb_array_elements(v_r->'by_person') x where x->>'name'='Jogador 05')=2000,
 'por jogador: pago no mês');
-- mês anterior não recebe o que foi pago hoje
v_r := public.get_finance_report(v_p, v_prev);
perform pg_temp.assert((v_r->>'income_cents')::bigint=0,'mês anterior sem receitas (datas no fuso da pelada)');

-- ===== 21) valores decimais =====
v_c := public.create_charge(v_p, 'extra', pg_temp.mem(v_p,8), null, null, 'Rateio 100/3', 3334, v_today, gen_random_uuid());
perform public.register_payment((v_c->>'id')::uuid, 1111, v_today, null, null, gen_random_uuid());
perform public.register_payment((v_c->>'id')::uuid, 1112, v_today, null, null, gen_random_uuid());
v_c := public.register_payment((v_c->>'id')::uuid, 1111, v_today, null, null, gen_random_uuid(), true);
perform pg_temp.assert(v_c->>'status'='paid' and (v_c->>'amount_paid_cents')::int=3334,'centavos exatos (sem float)');
perform pg_temp.expect_error(format('select public.create_charge(%L,%L,%L,null,null,null,0,%L,%L)',v_p,'extra',pg_temp.mem(v_p,8),v_today,gen_random_uuid()),'FINANCE_INVALID_AMOUNT');
perform pg_temp.expect_error(format('select public.create_charge(%L,%L,%L,null,null,null,100000001,%L,%L)',v_p,'extra',pg_temp.mem(v_p,8),v_today,gen_random_uuid()),'FINANCE_INVALID_AMOUNT');

-- ===== 22) datas =====
perform pg_temp.expect_error(format('select public.register_payment(%L,1,%L,null,null,%L)',v_ch,v_today+1,gen_random_uuid()),'FINANCE_INVALID_DATE');
v_c := public.register_payment(v_ch, 100, v_prev, null, 'pago adiantado no mês passado', gen_random_uuid());
perform pg_temp.assert((public.get_finance_report(v_p, v_prev)->>'income_cents')::bigint=100,'pagamento entra no mês da data informada');

-- ===== 20) jogador sai da pelada =====
v_x := (public.save_monthly_member(v_p, null, pg_temp.mem(v_p,7), null, 5000, 1, v_prev)->>'id')::uuid;
perform public.generate_monthly_charges(v_p, v_prev);
v_mem7 := pg_temp.mem(v_p,7);
perform pg_temp.as_user(7); perform public.leave_pelada(v_p);
perform pg_temp.as_user(1);
perform pg_temp.assert(public.generate_monthly_charges(v_p, (date_trunc('month', v_today) + interval '1 month')::date)=0
 or not exists(select 1 from jsonb_array_elements(public.get_finance_charges(v_p,(date_trunc('month', v_today) + interval '1 month')::date,null,v_mem7)) x),
 'quem saiu não recebe novas cobranças');
perform pg_temp.assert(jsonb_array_length(public.get_finance_charges(v_p,v_prev,'open',v_mem7))=1,'pendência antiga continua devida');
perform pg_temp.assert((select not (x->>'person_active')::boolean from jsonb_array_elements(public.get_finance_people(v_p)->'monthly') x where x->>'id'=v_x::text),
 'mensalista marcado como fora da pelada');
perform pg_temp.expect_error(format('select public.create_charge(%L,%L,%L,null,null,null,100,%L,%L)',v_p,'single',v_mem7,v_today,gen_random_uuid()),'FINANCE_INVALID_PERSON');
perform public.set_monthly_member_status(v_x, 'ended', 'saiu da pelada');
perform pg_temp.expect_error(format('select public.set_monthly_member_status(%L,%L)',v_x,'active'),'FINANCE_INVALID_STATUS');

-- ===== 19) exclusão de conta =====
v_mem6 := pg_temp.mem(v_p,6);
perform pg_temp.as_user(6); perform public.request_account_deletion(true);
execute 'reset role';
update private.account_deletion_requests set purge_after=now()-interval '1 minute' where user_id=pg_temp.uid(6) and status='pending';
select id into v_req from private.account_deletion_requests where user_id=pg_temp.uid(6) and status='pending';
perform private.purge_account(v_req);
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.assert(public.get_finance_charges(v_p,null,null,v_mem6)::text like '%Aposentado%'
 and public.get_finance_charges(v_p)::text not like '%Jogador 06%','registros financeiros preservados, sem o nome');
perform pg_temp.assert(public.get_finance_ledger(v_p)::text not like '%Jogador 06%' and public.get_finance_report(v_p)::text not like '%Jogador 06%','relatórios sem o nome');

-- ===== 23) auditoria =====
v_r := public.get_finance_history(v_p, 500);
perform pg_temp.assert((select count(distinct x->>'event_type') from jsonb_array_elements(v_r) x where x->>'event_type' in
 ('access_granted','monthly_created','monthly_updated','charge_created','charge_due_date_changed','charge_cancelled',
  'payment_registered','payment_reversed','entry_created','entry_cancelled','payer_created','monthly_status'))=12,'todos os eventos auditados');
perform pg_temp.assert((select (x->'before'->>'amount_cents')::int=5000 and (x->'after'->>'amount_cents')::int=6000 and x->>'author'='Jogador 01'
 from jsonb_array_elements(v_r) x where x->>'event_type'='monthly_updated'),'antes/depois e autor');
perform pg_temp.assert(exists(select 1 from jsonb_array_elements(v_r) x where x->>'event_type'='payment_registered' and x->>'author'='Jogador 02'),
 'autor do pagamento (assistente)');

-- ===== 24) manipulação direta =====
perform pg_temp.expect_error(format('insert into public.finance_payments(pelada_id,charge_id,amount_cents,received_on,request_id) values(%L,%L,999999,%L,%L)',
 v_p,v_ch,v_today,gen_random_uuid()),'permission denied');
perform pg_temp.expect_error(format('update public.finance_charges set amount_paid_cents=amount_due_cents where id=%L',v_ch),'permission denied');
perform pg_temp.expect_error(format('delete from public.finance_events where pelada_id=%L',v_p),'permission denied');
perform pg_temp.expect_error(format('select private.require_finance(%L,true)',v_p),'permission denied');
perform pg_temp.expect_error(format('select private.finance_log(%L,%L,%L,null,null,null)',v_p,'x','y'),'permission denied');
perform pg_temp.assert((select count(*) from public.finance_charges where pelada_id=v_p) > 0,'admin lê pelo RLS');

-- ===== 18) outra pelada =====
perform pg_temp.as_user(9);
perform pg_temp.expect_error(format('select public.get_finance_overview(%L)',v_p),'FINANCE_FORBIDDEN');
perform pg_temp.expect_error(format('select public.register_payment(%L,100,%L,null,null,%L)',v_ch,v_today,gen_random_uuid()),'FINANCE_FORBIDDEN');
perform pg_temp.expect_error(format('select public.reverse_payment(%L,%L)',v_pay,'tentativa'),'FINANCE_FORBIDDEN');
perform pg_temp.expect_error(format('select public.get_finance_access(%L)',v_p),'PELADA_NOT_FOUND');
perform pg_temp.assert((select count(*) from public.finance_charges)=0 and (select count(*) from public.finance_events)=0
 and (select count(*) from public.finance_payments)=0,'RLS: nada da outra pelada');
perform pg_temp.assert(pg_temp.ov(v_q,'balance_cents')=0,'pelada vizinha com caixa próprio');
-- jogador comum também não lê nada pelo RLS
perform pg_temp.as_user(4);
perform pg_temp.assert((select count(*) from public.finance_charges)=0 and (select count(*) from public.finance_members)=0,'RLS: jogador comum não vê');
-- permissão revogada
perform pg_temp.as_user(1); perform public.set_finance_access(v_p, pg_temp.mem(v_p,2), false);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.get_finance_overview(%L)',v_p),'FINANCE_FORBIDDEN');
perform pg_temp.assert((select count(*) from public.finance_charges)=0,'revogado: RLS também fecha');

-- ===== 16) Pelada Premium expirada =====
perform pg_temp.as_user(1);
v_bal := pg_temp.ov(v_p,'balance_cents');
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
v_n := (select count(*) from public.finance_charges where pelada_id=v_p);
perform set_config('role','authenticated',true);
perform pg_temp.expect_error(format('select public.get_finance_overview(%L)',v_p),'PREMIUM_REQUIRED');
perform pg_temp.expect_error(format('select public.register_payment(%L,100,%L,null,null,%L)',v_ch,v_today,gen_random_uuid()),'PREMIUM_REQUIRED');
perform pg_temp.expect_error(format('select public.generate_monthly_charges(%L)',v_p),'PREMIUM_REQUIRED');
perform pg_temp.assert(not (public.get_finance_access(v_p)->>'premium')::boolean and (public.get_finance_access(v_p)->>'has_records')::boolean,
 'app sabe que há registros guardados');
perform pg_temp.assert((select count(*) from public.finance_charges)=0,'RLS fechado sem Premium');
execute 'reset role';
perform pg_temp.assert((select count(*) from public.finance_charges where pelada_id=v_p)=v_n,'nada apagado na expiração');
update private.app_config set value='true'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.assert(pg_temp.ov(v_p,'balance_cents')=v_bal,'Premium de volta: acesso e saldo restaurados');

raise exception 'PASS: 036_v43_finance';
end $test$;
