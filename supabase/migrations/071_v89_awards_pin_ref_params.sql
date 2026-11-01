-- Minuto 91 / 071: V8.9. Integração do motor V7.7 (069) com os prêmios de temporada (066, 068).
--
-- O REF do Paredão (V8.6) e o REF "do encerramento" da Luva de Ouro (V8.7, F04) usam a fórmula de goleiro da 051
-- (ref_neutral 65, ref_shrink 3, janela `window` = 20), que é critério PRÓPRIO desses prêmios (V8.7: o REF do motor não
-- substitui o critério dos prêmios). As duas funções liam esses parâmetros da versão ATIVA (rating_params_active()).
-- Com a versão 2 (V7.7) ativa, ref_neutral/ref_shrink não existem e `window` passa a ser 10 (janela do checkpoint),
-- o que mudaria os prêmios sem decisão. Aqui os parâmetros ficam fixados na versão 1 (valores aprovados dos prêmios);
-- nenhuma conta muda e o resultado independe de qual versão do motor está ativa (rollback do motor continua seguro).
-- Mesmo método de cópia das migrações 051/069: se o texto esperado não existir, a migração para.
do $patch$
declare v_def text; v_new text; v_sig text;
begin
 foreach v_sig in array array['private.paredao_ranking(uuid,date)', 'private.v87_ref_at(uuid,timestamptz)'] loop
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_new := replace(v_def, 'from private.rating_params_active()', 'from private.rating_params where version = 1');
  if v_new = v_def then raise exception 'PATCH_AWARDS_PIN_PARAMS_FAILED (%)', v_sig; end if;
  execute v_new;
 end loop;
end $patch$;
