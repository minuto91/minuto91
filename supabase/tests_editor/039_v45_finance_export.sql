-- V4.5 (migração 047): exportação do Financeiro num único instantâneo e permissão financeira que termina junto com
-- o papel de assistente.
--  1) Reproduz o problema da V4.4: exportar em páginas com escritas entre elas (estorno de linha já lida e lançamento
--     que muda de data) gera arquivo com situação velha ou linha repetida, e a contagem não percebe.
--  2) get_finance_export: tudo numa chamada; linhas = verdade das tabelas; ordem estável sem repetição; totais do
--     mesmo instantâneo batem com as linhas; estorno, cancelamento, pendência e edição aparecem do jeito atual.
--  3) Validações (período, filtro), função STABLE (um instantâneo), permissões e isolamento entre peladas.
--  4) Permissão financeira: tirar o assistente, sair e voltar, ser suspenso → a permissão some (com auditoria) e só
--     volta se o admin der de novo.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 039_v45_finance_export".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99450000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.truth(p_sql text) returns bigint language plpgsql as
 $$ declare v bigint; begin reset role; execute p_sql into v; perform set_config('role','authenticated',true); return coalesce(v,0); end $$;
create function pg_temp.owner_today(p_pelada uuid) returns date language plpgsql as
 $$ declare v date; begin reset role; v := private.pelada_today(p_pelada); perform set_config('role','authenticated',true); return v; end $$;
-- Confere uma exportação: sem id repetido, ordem estritamente decrescente (data, criação, id), quantidade e somas
-- das linhas iguais aos totais devolvidos.
create function pg_temp.check_export(p jsonb, p_label text) returns void language plpgsql as
 $$ declare v_dups int; v_bad int; begin
  select count(*) - count(distinct x->>'id') into v_dups from jsonb_array_elements(p->'items') x;
  perform pg_temp.assert(v_dups = 0, p_label||': sem linha repetida');
  select count(*) into v_bad from (
   select (x->>'date')::date d, (x->>'created_at')::timestamptz c, (x->>'id')::uuid i,
    lag((x->>'date')::date) over w pd, lag((x->>'created_at')::timestamptz) over w pc, lag((x->>'id')::uuid) over w pi
   from jsonb_array_elements(p->'items') with ordinality t(x, o) window w as (order by o)) q
  where pd is not null and not ((d, c, i) < (pd, pc, pi));
  perform pg_temp.assert(v_bad = 0, p_label||': ordem estável (data, criação, id) decrescente');
  perform pg_temp.assert(jsonb_array_length(p->'items') = (p->'total'->>'count')::int, p_label||': linhas = total');
  perform pg_temp.assert((select coalesce(sum((x->>'amount_cents')::bigint),0) from jsonb_array_elements(p->'items') x
    where x->>'direction'='income' and x->>'status'='settled') = (p->'total'->>'settled_income_cents')::bigint, p_label||': receitas das linhas = total');
  perform pg_temp.assert((select coalesce(sum((x->>'amount_cents')::bigint),0) from jsonb_array_elements(p->'items') x
    where x->>'direction'='expense' and x->>'status'='settled') = (p->'total'->>'settled_expense_cents')::bigint, p_label||': despesas das linhas = total');
  perform pg_temp.assert((select coalesce(sum((x->>'amount_cents')::bigint),0) from jsonb_array_elements(p->'items') x
    where x->>'status'='reversed') = (p->'total'->>'reversed_cents')::bigint, p_label||': estornos das linhas = total');
 end $$;

do $test$
declare
 v_p uuid; v_q uuid; v_tok text; v_qtok text; v_today date; v_m0 date; v_m1 date; v_days int; v_c jsonb; v_ch uuid; v_r jsonb;
 v_e jsonb; v_pay uuid; v_entry uuid; v_after jsonb; v_page jsonb; v_rows jsonb := '[]'; v_first jsonb; v_x jsonb;
 v_n int; v_inc bigint; v_exp bigint; v_count bigint; v_dups int; v_stale int; i int; v_who uuid[]; v_ev int; v_mem2 uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v45e'||n||'@example.invalid','',now(),now(),now() from generate_series(1,10) n;
perform set_config('role','authenticated',true);
for k in 1..10 loop perform pg_temp.as_user(k); perform public.complete_onboarding('Jogador '||lpad(k::text,2,'0'),true,true); end loop;
-- P: admin 1; assistentes 2 (com permissão) e 3 (sem); jogadores 4..6. Q: admin 9, jogador 10.
perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada Exporta','GOL');
v_tok := public.create_pelada_invite(v_p);
for k in 2..6 loop perform pg_temp.as_user(k); perform public.join_pelada(v_tok, 'MEI'); end loop;
perform pg_temp.as_user(1);
perform public.set_assistant(v_p, pg_temp.mem(v_p,2), true);
perform public.set_assistant(v_p, pg_temp.mem(v_p,3), true);
perform public.set_finance_access(v_p, pg_temp.mem(v_p,2), true);
perform pg_temp.as_user(9); v_q := public.create_pelada('Pelada Outra Exporta','ZAG');
v_qtok := public.create_pelada_invite(v_q); perform pg_temp.as_user(10); perform public.join_pelada(v_qtok,'ATA');
v_today := pg_temp.owner_today(v_p);
v_m0 := date_trunc('month', v_today)::date;
v_m1 := (v_m0 + interval '1 month - 1 day')::date;
v_days := v_today - v_m0 + 1;

-- ===== Massa no mês atual: 500 cobranças com pagamentos (estornos e parciais), 600 lançamentos =====
perform pg_temp.as_user(1);
v_who := array[pg_temp.mem(v_p,4), pg_temp.mem(v_p,5), pg_temp.mem(v_p,6)];
for i in 1..500 loop
 perform pg_temp.as_user(case when i % 2 = 0 then 1 else 2 end);
 v_c := public.create_charge(v_p, 'single', v_who[1 + i % 3], null, null, 'Avulso '||i, 2000 + i, v_m0, gen_random_uuid());
 v_ch := (v_c->>'id')::uuid;
 v_r := public.register_payment(v_ch, case when i % 5 = 0 then 1000 else 2000 + i end, v_m0 + (i % v_days), 'pix', null, gen_random_uuid());
 if i % 9 = 0 then perform public.reverse_payment(((v_r->'payments'->0)->>'id')::uuid, 'Estorno '||i); end if;
end loop;
perform pg_temp.as_user(1);
for i in 1..250 loop
 perform public.save_finance_entry(v_p, null, 'income', 'Patrocínio', 'Receita '||i, 700 + i, v_m0 + (i % v_days), 'settled', 'pix', null, gen_random_uuid());
 perform public.save_finance_entry(v_p, null, 'expense', 'Aluguel do campo', 'Despesa '||i, 400 + i, v_m0 + (i % v_days), 'settled', 'pix', null, gen_random_uuid());
end loop;
for i in 1..50 loop perform public.save_finance_entry(v_p, null, 'expense', 'Arbitragem', 'A pagar '||i, 333, v_m0, 'pending', null, null, gen_random_uuid()); end loop;
for i in 1..50 loop
 v_e := public.save_finance_entry(v_p, null, 'expense', 'Água', 'Cancelada '||i, 900, v_m0, 'settled', null, null, gen_random_uuid());
 perform public.cancel_finance_entry((v_e->>'id')::uuid, 'Lançada errado');
end loop;
perform pg_temp.as_user(9);
v_c := public.create_charge(v_q, 'single', pg_temp.mem(v_q,10), null, null, 'Avulso Q', 4321, v_m0, gen_random_uuid());
perform public.register_payment((v_c->>'id')::uuid, 4321, v_m0, 'pix', null, gen_random_uuid());
perform public.save_finance_entry(v_q, null, 'expense', 'Campo', 'Campo Q', 12345, v_m0, 'settled', null, null, gen_random_uuid());

v_count := pg_temp.truth(format('select (select count(*) from public.finance_payments where pelada_id=%L and received_on between %L and %L)
 + (select count(*) from public.finance_entries where pelada_id=%L and entry_date between %L and %L)', v_p, v_m0, v_m1, v_p, v_m0, v_m1));
perform pg_temp.assert(v_count >= 1100, 'massa com mais de 1.100 movimentações ('||v_count||')');

-- ===== 1) V4.4: páginas com escritas entre elas ficam inconsistentes sem a contagem perceber =====
perform pg_temp.as_user(1);
v_page := public.get_finance_ledger_page(v_p, v_m0, v_m1, null, null, null, 200, true);
v_first := v_page;
v_rows := v_page->'items';
v_after := nullif(v_page->'next', 'null'::jsonb);
-- estorno de um pagamento que já está na 1ª página (lida como "Efetivado")
select (x->>'id')::uuid into v_pay from jsonb_array_elements(v_rows) x where x->>'source'='payment' and x->>'status'='settled' limit 1;
perform public.reverse_payment(v_pay, 'Estorno durante a exportação');
-- lançamento ainda não lido (fica numa página seguinte) muda para a data mais recente: volta para trás do cursor
-- (some) ou, se já lido, aparece de novo. Aqui: um lançamento já lido vai para uma data mais antiga -> lido duas vezes.
select (x->>'id')::uuid into v_entry from jsonb_array_elements(v_rows) x where x->>'source'='entry' and x->>'status'='settled'
 and x->>'direction'='income' limit 1;
v_e := (select to_jsonb(e) from public.finance_entries e where e.id = v_entry);
perform public.save_finance_entry(v_p, v_entry, 'income', v_e->>'category', v_e->>'description', (v_e->>'amount_cents')::int,
 v_m0, 'settled', 'pix', null, null, (v_e->>'version')::int);
while v_after is not null loop
 v_page := public.get_finance_ledger_page(v_p, v_m0, v_m1, null, null, v_after, 200, false);
 v_rows := v_rows || (v_page->'items');
 v_after := nullif(v_page->'next', 'null'::jsonb);
end loop;
select count(*) - count(distinct x->>'id') into v_dups from jsonb_array_elements(v_rows) x;
select count(*) into v_stale from jsonb_array_elements(v_rows) x where (x->>'id')::uuid = v_pay and x->>'status' = 'settled';
perform pg_temp.assert((v_dups = 1 or v_days = 1) and v_stale = 1,
 format('V4.4 reproduzida: páginas com escritas no meio (repetidas=%s, estorno lido como efetivado=%s)', v_dups, v_stale));
perform pg_temp.assert(jsonb_array_length(v_rows) = (v_first->'total'->>'count')::int + v_dups,
 'V4.4: a conferência por quantidade só viu a diferença da linha repetida (o estorno passou sem ser percebido)');

-- ===== 2) V4.5: exportação num único instantâneo =====
v_x := public.get_finance_export(v_p, v_m0, v_m1);
perform pg_temp.check_export(v_x, 'exportação do mês');
perform pg_temp.assert((v_x->'total'->>'count')::bigint = v_count, 'exportação = todas as movimentações do mês (verdade)');
v_inc := pg_temp.truth(format('select (select sum(amount_cents) from public.finance_payments where pelada_id=%L and reversed_at is null and received_on between %L and %L)
 + (select sum(amount_cents) from public.finance_entries where pelada_id=%L and direction=''income'' and status=''settled'' and entry_date between %L and %L)', v_p, v_m0, v_m1, v_p, v_m0, v_m1));
v_exp := pg_temp.truth(format('select sum(amount_cents) from public.finance_entries where pelada_id=%L and direction=''expense'' and status=''settled'' and entry_date between %L and %L', v_p, v_m0, v_m1));
perform pg_temp.assert((v_x->'total'->>'settled_income_cents')::bigint = v_inc, 'receitas efetivadas = verdade');
perform pg_temp.assert((v_x->'total'->>'settled_expense_cents')::bigint = v_exp, 'despesas efetivadas = verdade');
perform pg_temp.assert((v_x->'total'->>'settled_income_cents')::bigint = (public.get_finance_report(v_p, v_m0)->>'income_cents')::bigint
 and (v_x->'total'->>'settled_expense_cents')::bigint = (public.get_finance_report(v_p, v_m0)->>'expense_cents')::bigint,
 'exportação bate com o relatório oficial do mês');
perform pg_temp.assert((v_x->'total'->>'pending_expense_cents')::bigint = 50*333, 'pendências informadas à parte');
perform pg_temp.assert((v_x->'total'->>'cancelled_cents')::bigint = 50*900, 'canceladas informadas à parte');
perform pg_temp.assert(exists(select 1 from jsonb_array_elements(v_x->'items') x where (x->>'id')::uuid = v_pay and x->>'status'='reversed'),
 'estorno feito antes da exportação aparece como Estornado');
perform pg_temp.assert((select count(*) from jsonb_array_elements(v_x->'items') x where (x->>'id')::uuid = v_entry) = 1,
 'lançamento que mudou de data aparece uma vez só');
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements(v_x->'items') x where x->>'description' like '%Q%' and x->>'description' like 'Campo%'),
 'outra pelada não entra');
perform pg_temp.assert((v_x->>'as_of') is not null, 'informa o instante da exportação');
-- escritas depois de exportar entram na próxima exportação, inteiras
perform public.reverse_payment((select (x->>'id')::uuid from jsonb_array_elements(v_x->'items') x where x->>'source'='payment' and x->>'status'='settled' limit 1), 'Outro estorno');
perform public.save_finance_entry(v_p, null, 'expense', 'Água', 'Nova despesa', 1234, v_m0, 'settled', 'pix', null, gen_random_uuid());
v_r := public.get_finance_export(v_p, v_m0, v_m1);
perform pg_temp.check_export(v_r, 'exportação depois das escritas');
perform pg_temp.assert((v_r->'total'->>'count')::int = (v_x->'total'->>'count')::int + 1, 'despesa nova entra na próxima exportação');
perform pg_temp.assert((v_r->'total'->>'reversed_cents')::bigint > (v_x->'total'->>'reversed_cents')::bigint, 'estorno novo entra na próxima exportação');
-- filtros
v_r := public.get_finance_export(v_p, v_m0, v_m1, 'expense');
perform pg_temp.check_export(v_r, 'só despesas');
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements(v_r->'items') x where x->>'direction' <> 'expense'), 'filtro de direção');
v_r := public.get_finance_export(v_p, v_m0, v_m1, null, 'Avulso');
perform pg_temp.check_export(v_r, 'categoria Avulso');
perform pg_temp.assert((v_r->'total'->>'count')::int = 500, 'categoria Avulso = 500 pagamentos');
-- período sem nada
v_r := public.get_finance_export(v_p, (v_m0 - interval '5 years')::date, (v_m0 - interval '5 years' + interval '10 days')::date);
perform pg_temp.assert(jsonb_array_length(v_r->'items') = 0 and (v_r->'total'->>'count')::int = 0, 'período vazio');

-- ===== 3) Validações, instantâneo e permissões =====
perform pg_temp.expect_error(format('select public.get_finance_export(%L, null, %L)', v_p, v_m1), 'FINANCE_INVALID_DATE');
perform pg_temp.expect_error(format('select public.get_finance_export(%L, %L, %L)', v_p, v_m1, v_m0), 'FINANCE_INVALID_DATE');
perform pg_temp.expect_error(format('select public.get_finance_export(%L, %L, %L)', v_p, v_m0 - 400, v_m0), 'FINANCE_INVALID_DATE');
perform pg_temp.expect_error(format('select public.get_finance_export(%L, %L, %L, %L)', v_p, v_m0, v_m1, 'xx'), 'FINANCE_INVALID_FILTER');
perform pg_temp.assert((select provolatile = 's' from pg_proc where oid = 'public.get_finance_export(uuid,date,date,text,text)'::regprocedure),
 'get_finance_export é STABLE (linhas e totais no mesmo instantâneo)');
perform pg_temp.as_user(2);
perform pg_temp.check_export(public.get_finance_export(v_p, v_m0, v_m1), 'assistente com permissão');
foreach i in array array[3, 4, 9, 10] loop
 perform pg_temp.as_user(i);
 perform pg_temp.expect_error(format('select public.get_finance_export(%L, %L, %L)', v_p, v_m0, v_m1), 'FINANCE_FORBIDDEN');
end loop;
perform pg_temp.as_user(9);
perform pg_temp.assert((public.get_finance_export(v_q, v_m0, v_m1)->'total'->>'count')::int = 2, 'admin de Q exporta só Q');
reset role;
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.get_finance_export(%L, %L, %L)', v_p, v_m0, v_m1), 'PREMIUM_REQUIRED');
reset role;
update private.app_config set value='true'::jsonb where key='premium_beta_open';
perform set_config('role','anon',true);
perform pg_temp.expect_error(format('select public.get_finance_export(%L, %L, %L)', v_p, v_m0, v_m1), 'permission denied');
reset role;
perform set_config('role','authenticated',true);

-- ===== 4) Permissão financeira termina com o papel de assistente =====
v_mem2 := pg_temp.mem(v_p,2);
v_ev := pg_temp.truth(format('select count(*) from public.finance_events where pelada_id=%L and event_type=''access_revoked''', v_p));
-- 4a) deixa de ser assistente e volta: não recupera a permissão sozinho
perform pg_temp.as_user(1);
perform public.set_assistant(v_p, v_mem2, false);
perform pg_temp.assert(pg_temp.truth(format('select count(*) from public.finance_access where membership_id=%L', v_mem2)) = 0,
 'tirar o assistente apaga a permissão financeira');
perform pg_temp.assert(pg_temp.truth(format('select count(*) from public.finance_events where pelada_id=%L and event_type=''access_revoked''', v_p)) = v_ev + 1,
 'retirada automática fica na auditoria');
perform public.set_assistant(v_p, v_mem2, true);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.get_finance_export(%L, %L, %L)', v_p, v_m0, v_m1), 'FINANCE_FORBIDDEN');
perform pg_temp.as_user(1);
perform public.set_finance_access(v_p, v_mem2, true);
perform pg_temp.as_user(2);
perform pg_temp.check_export(public.get_finance_export(v_p, v_m0, v_m1), 'permissão dada de novo pelo admin');
-- 4b) sai da pelada e volta pelo convite (mesma associação), vira assistente: sem permissão até o admin dar
perform public.leave_pelada(v_p);
perform pg_temp.assert(pg_temp.truth(format('select count(*) from public.finance_access where membership_id=%L', v_mem2)) = 0,
 'sair da pelada apaga a permissão financeira');
perform public.join_pelada(v_tok, 'MEI');
perform pg_temp.assert(pg_temp.mem(v_p,2) = v_mem2, 'quem volta usa a mesma associação');
perform pg_temp.as_user(1);
perform public.set_assistant(v_p, v_mem2, true);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.get_finance_ledger_page(%L)', v_p), 'FINANCE_FORBIDDEN');
-- 4c) assistente 3 (sem permissão) não ganha nada com as mudanças; admin continua com acesso
perform pg_temp.as_user(3);
perform pg_temp.expect_error(format('select public.get_finance_export(%L, %L, %L)', v_p, v_m0, v_m1), 'FINANCE_FORBIDDEN');
perform pg_temp.as_user(1);
perform pg_temp.check_export(public.get_finance_export(v_p, v_m0, v_m1), 'admin');
-- 4d) mudanças que não tiram o papel não mexem na permissão (posição)
perform public.set_finance_access(v_p, v_mem2, true);
reset role;
update public.pelada_memberships set position_code = 'VOL' where id = v_mem2;
perform pg_temp.assert((select count(*) from public.finance_access where membership_id=v_mem2) = 1, 'trocar posição não mexe na permissão');
-- 4e) suspensão feita direto no banco (sem passar por função do app): apaga e registra o motivo
update public.pelada_memberships set status = 'suspended' where id = v_mem2;
perform pg_temp.assert((select count(*) from public.finance_access where membership_id=v_mem2) = 0, 'suspensão apaga a permissão');
perform pg_temp.assert((select after_data->>'reason' from public.finance_events where entity_id=v_mem2 and event_type='access_revoked'
 order by id desc limit 1) = 'role_changed', 'motivo registrado');

raise exception 'PASS: 039_v45_finance_export';
end $test$;
