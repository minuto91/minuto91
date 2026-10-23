-- V4.6 (migração 048): os pagamentos de uma cobrança saem sempre na mesma ordem (data, criação, id).
-- Antes, dois pagamentos registrados na mesma transação (mesmo created_at) podiam trocar de lugar entre duas leituras
-- (intermitência do teste 037, "mesmo formato"). Confere a regra na função e que leitura única = leitura em lote.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 040_v46_payment_order".
do $test$
declare v_def text; v_bad int;
begin
 v_def := pg_get_functiondef('private.finance_charges_json(uuid,uuid[])'::regprocedure);
 if position('order by p.received_on, p.created_at, p.id' in v_def) = 0 then
  raise exception 'FALHOU: pagamentos sem desempate final por id';
 end if;
 -- Com os dados que existirem (no dev): a cobrança lida sozinha e em lote traz os pagamentos na mesma ordem.
 select count(*) into v_bad from (
  select c.id, private.finance_charges_json(c.pelada_id, array[c.id]) -> 0 -> 'payments' one,
   (select x -> 'payments' from jsonb_array_elements(private.finance_charges_json(c.pelada_id,
     array(select c2.id from public.finance_charges c2 where c2.pelada_id = c.pelada_id order by c2.due_date, c2.created_at, c2.id))) x
    where x ->> 'id' = c.id::text) many
  from public.finance_charges c
  where (select count(*) from public.finance_payments p where p.charge_id = c.id) > 1
  limit 50) q
 where q.one is distinct from q.many;
 if v_bad > 0 then raise exception 'FALHOU: % cobrança(s) com pagamentos em ordem diferente', v_bad; end if;
 raise exception 'PASS: 040_v46_payment_order';
end $test$;
