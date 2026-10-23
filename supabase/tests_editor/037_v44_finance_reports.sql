-- V4.4 (migração 044): relatórios, paginação e exportação do Financeiro com mais de 2.000 movimentações no mês.
-- Prova que nada se perde por limite de consulta: totais = categorias = verdade calculada direto nas tabelas;
-- cobranças e livro-caixa paginados sem repetir nem pular; exportação completa; estornos e pendências fora do
-- resultado; parciais; isolamento por pelada; permissões (admin, assistente com/sem permissão, jogador, outra pelada,
-- ex-integrante, Premium expirada).
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 037_v44_finance_reports".
-- Leva alguns segundos (cria ~3.600 registros pelas funções oficiais).
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99440000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Verdade calculada como dono do banco (sem RLS), direto nas tabelas.
create function pg_temp.truth(p_sql text) returns bigint language plpgsql as
 $$ declare v bigint; begin reset role; execute p_sql into v; perform set_config('role','authenticated',true); return coalesce(v,0); end $$;
create function pg_temp.owner_today(p_pelada uuid) returns date language plpgsql as
 $$ declare v date; begin reset role; v := private.pelada_today(p_pelada); perform set_config('role','authenticated',true); return v; end $$;

do $test$
declare
 v_p uuid; v_q uuid; v_tok text; v_today date; v_m0 date; v_days int; v_payer1 uuid; v_payer2 uuid; v_c jsonb; v_ch uuid;
 v_due int; v_r jsonb; v_page jsonb; v_after jsonb; v_ids uuid[] := '{}'; v_n int; v_total int; v_prev jsonb; v_x jsonb;
 v_sum bigint; v_pay uuid; v_inc bigint; v_exp bigint; v_q_charge uuid; v_moves int; v_hist int; v_before bigint; i int;
 v_qmem uuid; v_who uuid[]; v_cat text[] := array['Patrocínio','Venda de uniformes','Outras receitas']; v_ecat text[] := array['Aluguel do campo','Arbitragem','Água'];
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v44f'||n||'@example.invalid','',now(),now(),now() from generate_series(1,12) n;
perform set_config('role','authenticated',true);
for k in 1..12 loop perform pg_temp.as_user(k); perform public.complete_onboarding('Jogador '||lpad(k::text,2,'0'),true,true); end loop;
-- P: admin 1; assistentes 2 (com permissão) e 3 (sem); jogadores 4..8. Q: admin 9, jogador 10.
perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada Grande Caixa','GOL');
v_tok := public.create_pelada_invite(v_p);
for k in 2..8 loop perform pg_temp.as_user(k); perform public.join_pelada(v_tok, 'MEI'); end loop;
perform pg_temp.as_user(1);
perform public.set_assistant(v_p, pg_temp.mem(v_p,2), true);
perform public.set_assistant(v_p, pg_temp.mem(v_p,3), true);
perform public.set_finance_access(v_p, pg_temp.mem(v_p,2), true);
perform pg_temp.as_user(9); v_q := public.create_pelada('Pelada Vizinha Caixa','ZAG');
v_tok := public.create_pelada_invite(v_q); perform pg_temp.as_user(10); v_qmem := public.join_pelada(v_tok,'ATA');
v_today := pg_temp.owner_today(v_p);
v_m0 := date_trunc('month', v_today)::date;
v_days := v_today - v_m0 + 1;

-- ===== Massa: 1.200 cobranças, 1.200 pagamentos (100 estornados), 1.150 lançamentos, tudo no mês atual =====
perform pg_temp.as_user(1);
v_payer1 := public.save_finance_payer(v_p, null, 'Convidado Fixo');
v_payer2 := public.save_finance_payer(v_p, null, 'Patrocinador');
v_who := array[pg_temp.mem(v_p,4), pg_temp.mem(v_p,5), pg_temp.mem(v_p,6), pg_temp.mem(v_p,7), pg_temp.mem(v_p,8)];
for i in 1..1200 loop
 -- admin e assistente com permissão se alternam (os dois escrevem no mesmo caixa)
 perform pg_temp.as_user(case when i % 2 = 0 then 1 else 2 end);
 v_due := 1000 + (i * 37) % 9000;
 v_c := public.create_charge(v_p, 'single',
  case when i % 7 < 5 then v_who[1 + i % 7] end, case when i % 7 = 5 then v_payer1 when i % 7 = 6 then v_payer2 end,
  null, 'Avulso '||i, v_due, v_m0 + (i % 3) * 10, gen_random_uuid());
 v_ch := (v_c->>'id')::uuid;
 if i % 10 <> 0 then
  v_r := public.register_payment(v_ch, case when i % 10 in (1,2) then v_due / 2 else v_due end, v_m0 + (i % v_days), 'pix', null, gen_random_uuid());
  if i % 10 = 2 then -- completa a parcial com um segundo pagamento
   v_r := public.register_payment(v_ch, v_due - v_due / 2, v_m0 + (i % v_days), 'dinheiro', null, gen_random_uuid(), true);
  end if;
  if i % 12 = 0 then
   v_pay := ((v_r->'payments'->0)->>'id')::uuid;
   perform public.reverse_payment(v_pay, 'Estorno de teste '||i);
  end if;
 end if;
end loop;
perform pg_temp.as_user(1);
for i in 1..500 loop
 perform public.save_finance_entry(v_p, null, 'income', v_cat[1 + i % 3], 'Receita '||i, 500 + i, v_m0 + (i % v_days), 'settled', 'pix', null, gen_random_uuid());
 perform public.save_finance_entry(v_p, null, 'expense', v_ecat[1 + i % 3], 'Despesa '||i, 300 + i, v_m0 + (i % v_days), 'settled', 'pix', null, gen_random_uuid());
end loop;
for i in 1..60 loop perform public.save_finance_entry(v_p, null, 'income', 'Patrocínio', 'Pendente '||i, 999, v_m0 + 20, 'pending', null, null, gen_random_uuid()); end loop;
for i in 1..70 loop perform public.save_finance_entry(v_p, null, 'expense', 'Arbitragem', 'A pagar '||i, 777, v_m0 + 20, 'pending', null, null, gen_random_uuid()); end loop;
for i in 1..20 loop
 v_r := public.save_finance_entry(v_p, null, 'expense', 'Água', 'Cancelada '||i, 5000, v_m0, 'settled', null, null, gen_random_uuid());
 perform public.cancel_finance_entry((v_r->>'id')::uuid, 'Lançada errado');
end loop;
-- Q (outra pelada) também tem movimento no mesmo mês
perform pg_temp.as_user(9);
v_c := public.create_charge(v_q, 'single', v_qmem, null, null, 'Avulso Q', 4321, v_m0, gen_random_uuid());
v_q_charge := (v_c->>'id')::uuid;
perform public.register_payment(v_q_charge, 4321, v_m0, 'pix', null, gen_random_uuid());
perform public.save_finance_entry(v_q, null, 'expense', 'Aluguel do campo', 'Campo Q', 12345, v_m0, 'settled', null, null, gen_random_uuid());

v_moves := pg_temp.truth(format('select (select count(*) from public.finance_payments where pelada_id=%L and received_on >= %L)
 + (select count(*) from public.finance_entries where pelada_id=%L and entry_date >= %L)', v_p, v_m0, v_p, v_m0));
perform pg_temp.assert(v_moves > 2000, 'massa com mais de 2.000 movimentações no mês ('||v_moves||')');

-- ===== 1) Relatório = verdade =====
perform pg_temp.as_user(1);
v_r := public.get_finance_report(v_p, v_m0);
v_inc := pg_temp.truth(format('select (select sum(amount_cents) from public.finance_payments where pelada_id=%L and reversed_at is null and received_on >= %L)
 + (select sum(amount_cents) from public.finance_entries where pelada_id=%L and direction=''income'' and status=''settled'' and entry_date >= %L)', v_p, v_m0, v_p, v_m0));
v_exp := pg_temp.truth(format('select sum(amount_cents) from public.finance_entries where pelada_id=%L and direction=''expense'' and status=''settled'' and entry_date >= %L', v_p, v_m0));
perform pg_temp.assert((v_r->>'income_cents')::bigint = v_inc, 'receitas do mês = verdade');
perform pg_temp.assert((v_r->>'expense_cents')::bigint = v_exp, 'despesas do mês = verdade (canceladas e pendentes fora)');
perform pg_temp.assert((select sum((x->>'amount_cents')::bigint) from jsonb_array_elements(v_r->'by_category') x where x->>'direction'='income') = v_inc,
 'soma das categorias de receita = total contábil');
perform pg_temp.assert((select sum((x->>'amount_cents')::bigint) from jsonb_array_elements(v_r->'by_category') x where x->>'direction'='expense') = v_exp,
 'soma das categorias de despesa = total contábil');
perform pg_temp.assert((select (x->>'amount_cents')::bigint from jsonb_array_elements(v_r->'by_category') x where x->>'category'='Avulso')
 = pg_temp.truth(format('select sum(amount_cents) from public.finance_payments where pelada_id=%L and reversed_at is null', v_p)),
 'categoria Avulso = pagamentos não estornados (estorno não é receita)');
perform pg_temp.assert((v_r->>'reversed_cents')::bigint = pg_temp.truth(format('select sum(amount_cents) from public.finance_payments where pelada_id=%L and reversed_at is not null', v_p))
 and (v_r->>'reversed_cents')::bigint > 0, 'estornos informados à parte');
perform pg_temp.assert((v_r->>'pending_income_cents')::bigint = 60*999 and (v_r->>'pending_expense_cents')::bigint = 70*777,
 'pendentes separados dos efetivados');
perform pg_temp.assert((v_r->>'result_cents')::bigint = v_inc - v_exp, 'resultado só com efetivados');
perform pg_temp.assert((v_r->>'movements_count')::int = v_moves, 'quantidade de movimentações do mês');
perform pg_temp.assert((select sum((x->>'paid_cents')::bigint) from jsonb_array_elements(v_r->'by_person') x)
 = pg_temp.truth(format('select sum(amount_cents) from public.finance_payments where pelada_id=%L and reversed_at is null', v_p)),
 'por jogador: pago = pagamentos não estornados');
perform pg_temp.assert((select sum((x->>'due_cents')::bigint) from jsonb_array_elements(v_r->'by_person') x)
 = pg_temp.truth(format('select sum(amount_due_cents) from public.finance_charges where pelada_id=%L and status<>''cancelled''', v_p)),
 'por jogador: devido no mês');
perform pg_temp.assert((select sum((x->>'open_total_cents')::bigint) from jsonb_array_elements(v_r->'by_person') x)
 = pg_temp.truth(format('select sum(amount_due_cents-amount_paid_cents) from public.finance_charges where pelada_id=%L and status in (''pending'',''partial'')', v_p)),
 'por jogador: em aberto');
perform pg_temp.assert(jsonb_array_length(v_r->'by_person') = 7, 'por jogador: 5 jogadores + 2 pessoas de fora, uma linha cada');
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements(v_r->'by_person') x where x->>'name' like '%Jogador 10%'), 'nada da outra pelada');
-- o caminho antigo (lista de 1.000) não alcançava todas as movimentações do mês
perform pg_temp.assert(jsonb_array_length(public.get_finance_ledger(v_p, v_m0, null, null, 5000)) = 1000, 'lista antiga continua limitada a 1.000');
-- painel: mesmo total do relatório e as 8 últimas = primeira página do livro-caixa
v_x := public.get_finance_overview(v_p, v_m0);
perform pg_temp.assert((v_x->>'month_income_cents')::bigint = v_inc and (v_x->>'month_expense_cents')::bigint = v_exp, 'painel = relatório');
perform pg_temp.assert(v_x->'latest' = (public.get_finance_ledger_page(v_p, null, null, null, null, null, 8))->'items', 'painel: últimas 8 movimentações');
perform pg_temp.assert((v_x->>'partial_count')::int = pg_temp.truth(format('select count(*) from public.finance_charges where pelada_id=%L and status=''partial''', v_p)),
 'painel: quantidade de parciais');

-- ===== 2) Cobranças paginadas (ordem estável, sem repetir nem pular) =====
v_total := pg_temp.truth(format('select count(*) from public.finance_charges where pelada_id=%L', v_p));
v_after := null; v_prev := null; v_n := 0;
loop
 v_page := public.get_finance_charges_page(v_p, null, null, null, null, null, v_after, 37);
 if v_after is null then
  perform pg_temp.assert((v_page->'summary'->>'count')::int = v_total, 'resumo: total de cobranças do filtro');
  perform pg_temp.assert((v_page->'summary'->>'outstanding_cents')::bigint = pg_temp.truth(format(
   'select sum(amount_due_cents-amount_paid_cents) from public.finance_charges where pelada_id=%L and status in (''pending'',''partial'')', v_p)),
   'resumo: em aberto de todas as páginas');
 else
  perform pg_temp.assert(v_page->'summary' = 'null'::jsonb, 'resumo só na primeira página');
 end if;
 for v_x in select x from jsonb_array_elements(v_page->'items') x loop
  if v_prev is not null then
   perform pg_temp.assert(((v_prev->>'due_date')::date, (v_prev->>'created_at')::timestamptz, (v_prev->>'id')::uuid)
     < ((v_x->>'due_date')::date, (v_x->>'created_at')::timestamptz, (v_x->>'id')::uuid), 'ordem estável');
  end if;
  v_ids := v_ids || (v_x->>'id')::uuid; v_prev := v_x;
 end loop;
 v_n := v_n + 1;
 perform pg_temp.assert(jsonb_array_length(v_page->'items') <= 37, 'limite por página');
 -- uma cobrança nova no meio da leitura não duplica nem embaralha as próximas páginas
 if v_n = 3 then perform public.create_charge(v_p, 'extra', v_who[1], null, null, 'No meio da leitura', 100, v_m0, gen_random_uuid()); end if;
 v_after := v_page->'next';
 exit when v_after = 'null'::jsonb or v_after is null;
end loop;
perform pg_temp.assert(cardinality(v_ids) = (select count(distinct x) from unnest(v_ids) x), 'nenhuma cobrança repetida');
perform pg_temp.assert(cardinality(v_ids) between v_total and v_total + 1, 'todas as cobranças lidas ('||cardinality(v_ids)||'/'||v_total||')');
perform pg_temp.assert(not (v_q_charge = any(v_ids)), 'isolamento: cobrança da outra pelada nunca aparece');
-- filtros: parciais, vencidas, pessoa, tipo; limite máximo; cursor e filtro inválidos
v_page := public.get_finance_charges_page(v_p, v_m0, 'partial', null, null, null, null, 100);
perform pg_temp.assert((v_page->'summary'->>'count')::int = pg_temp.truth(format('select count(*) from public.finance_charges where pelada_id=%L and status=''partial''', v_p))
 and (v_page->'summary'->>'count')::int > 0, 'filtro de pagamentos parciais');
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements(v_page->'items') x where x->>'status' <> 'partial'), 'só parciais');
v_page := public.get_finance_charges_page(v_p, null, null, null, v_payer1, null, null, 100);
perform pg_temp.assert((v_page->'summary'->>'count')::int = pg_temp.truth(format('select count(*) from public.finance_charges where payer_id=%L', v_payer1)),
 'filtro por pessoa de fora');
v_page := public.get_finance_charges_page(v_p, null, null, null, null, 'extra', null, 100);
perform pg_temp.assert((v_page->'summary'->>'count')::int = 1, 'filtro por tipo');
v_page := public.get_finance_charges_page(v_p, null, null, null, null, null, null, 100000);
perform pg_temp.assert(jsonb_array_length(v_page->'items') = 100, 'limite máximo de 100 por requisição');
perform pg_temp.assert(jsonb_array_length(v_page->'items'->0->'payments') >= 0 and v_page->'items'->0 ? 'person_name', 'cobrança traz pessoa e pagamentos');
v_page := public.get_finance_charges_page(v_p, null, null, v_qmem, null, null, null, 100);
perform pg_temp.assert((v_page->'summary'->>'count')::int = 0, 'filtro com jogador de outra pelada: nada');
perform pg_temp.expect_error(format('select public.get_finance_charges_page(%L,null,%L)', v_p, 'qualquer'), 'FINANCE_INVALID_FILTER');
perform pg_temp.expect_error(format('select public.get_finance_charges_page(%L,null,null,null,null,null,%L::jsonb)', v_p, '{"due_date":"x"}'), 'FINANCE_INVALID_CURSOR');
-- a função antiga devolve a mesma lista (apps antigos)
perform pg_temp.assert(jsonb_array_length(public.get_finance_charges(v_p)) = v_total + 1, 'lista antiga completa');
perform pg_temp.assert(public.get_finance_charges(v_p) -> 0 = private_charge.c, 'mesmo formato')
 from (select (public.get_finance_charges_page(v_p, null, null, null, null, null, null, 1))->'items'->0 c) private_charge;

-- ===== 3) Exportação completa do livro-caixa (páginas de 500) =====
v_after := null; v_n := 0; v_sum := 0; v_ids := '{}'; v_prev := null;
loop
 v_page := public.get_finance_ledger_page(v_p, v_m0, v_today + 40, null, null, v_after, 500, v_after is null);
 if v_after is null then v_total := (v_page->'total'->>'count')::int; end if;
 for v_x in select x from jsonb_array_elements(v_page->'items') x loop
  if v_prev is not null then
   perform pg_temp.assert(((v_prev->>'date')::date, (v_prev->>'created_at')::timestamptz, (v_prev->>'id')::uuid)
     > ((v_x->>'date')::date, (v_x->>'created_at')::timestamptz, (v_x->>'id')::uuid), 'livro-caixa em ordem decrescente estável');
  end if;
  v_ids := v_ids || (v_x->>'id')::uuid; v_prev := v_x; v_n := v_n + 1;
  if v_x->>'status' = 'settled' then v_sum := v_sum + case when v_x->>'direction'='income' then 1 else -1 end * (v_x->>'amount_cents')::bigint; end if;
 end loop;
 v_after := v_page->'next';
 exit when v_after = 'null'::jsonb or v_after is null;
end loop;
perform pg_temp.assert(v_total = v_moves and v_n = v_total, 'exportação leu todas as movimentações ('||v_n||'/'||v_total||')');
perform pg_temp.assert(cardinality(v_ids) = (select count(distinct x) from unnest(v_ids) x), 'nenhuma movimentação repetida');
perform pg_temp.assert(v_sum = v_inc - v_exp, 'soma exportada = resultado do mês');
v_page := public.get_finance_ledger_page(v_p, v_m0, null, null, 'Avulso', null, 500, true);
perform pg_temp.assert((v_page->'total'->>'count')::int = pg_temp.truth(format('select count(*) from public.finance_payments where pelada_id=%L', v_p))
 and not exists(select 1 from jsonb_array_elements(v_page->'items') x where x->>'source' <> 'payment'), 'filtro de categoria no livro-caixa');
v_page := public.get_finance_ledger_page(v_p, null, null, 'expense', null, null, 1000);
perform pg_temp.assert(jsonb_array_length(v_page->'items') = 500 and not exists(select 1 from jsonb_array_elements(v_page->'items') x where x->>'direction'<>'expense'),
 'limite de 500 por página e filtro de despesas');
perform pg_temp.expect_error(format('select public.get_finance_ledger_page(%L,%L,%L)', v_p, v_today, v_m0 - 1), 'FINANCE_INVALID_DATE');
perform pg_temp.expect_error(format('select public.get_finance_ledger_page(%L,null,null,%L)', v_p, 'x'), 'FINANCE_INVALID_FILTER');

-- ===== 4) Auditoria paginada =====
v_before := null; v_hist := 0;
loop
 v_page := public.get_finance_history_page(v_p, v_before, 200);
 v_hist := v_hist + jsonb_array_length(v_page->'items');
 v_before := (v_page->>'next')::bigint;
 exit when v_before is null;
end loop;
perform pg_temp.assert(v_hist = pg_temp.truth(format('select count(*) from public.finance_events where pelada_id=%L', v_p)), 'auditoria completa em páginas');

-- ===== 5) Permissões nas funções novas =====
foreach v_n in array array[3, 4, 9] loop
 perform pg_temp.as_user(v_n);
 perform pg_temp.expect_error(format('select public.get_finance_charges_page(%L)', v_p), 'FINANCE_FORBIDDEN');
 perform pg_temp.expect_error(format('select public.get_finance_ledger_page(%L)', v_p), 'FINANCE_FORBIDDEN');
 perform pg_temp.expect_error(format('select public.get_finance_history_page(%L)', v_p), 'FINANCE_FORBIDDEN');
 perform pg_temp.expect_error(format('select public.get_finance_report(%L)', v_p), 'FINANCE_FORBIDDEN');
end loop;
perform pg_temp.as_user(2);
perform pg_temp.assert((public.get_finance_charges_page(v_p))->'summary' ? 'count', 'assistente com permissão lê');
perform public.leave_pelada(v_p); -- ex-integrante
perform pg_temp.expect_error(format('select public.get_finance_ledger_page(%L)', v_p), 'FINANCE_FORBIDDEN');
perform pg_temp.as_user(1);
reset role;
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.expect_error(format('select public.get_finance_charges_page(%L)', v_p), 'PREMIUM_REQUIRED');
perform pg_temp.expect_error(format('select public.get_finance_ledger_page(%L)', v_p), 'PREMIUM_REQUIRED');
reset role;
perform pg_temp.assert((select count(*) from public.finance_payments where pelada_id=v_p) >= 1200, 'Premium expirada não apaga nada');
update private.app_config set value='true'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.assert((public.get_finance_report(v_p, v_m0)->>'income_cents')::bigint = v_inc, 'Premium de volta: mesmos números');
-- anônimo
reset role;
perform set_config('role','anon',true);
perform pg_temp.expect_error(format('select public.get_finance_charges_page(%L)', v_p), 'permission denied');
reset role;

raise exception 'PASS: 037_v44_finance_reports';
end $test$;
