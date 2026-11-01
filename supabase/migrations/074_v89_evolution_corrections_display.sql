-- Minuto 91 / 074: evolução da carta — correções mostram o OVR exibido, não o interno.
--
-- Achado da V8.9 (01/11/2026, ao recalcular todo o histórico com a 073): get_player_evolution (037, remendada pela
-- 051 e pela 070) já mostra nos pontos e no valor atual o OVR exibido para as fórmulas v2/v3 (ovr_display, nulo
-- enquanto a carta é provisória), mas a lista "corrections" (cartas corrigidas por anulação, 037) continuava
-- devolvendo snapshot_data->>'overall', o OVR INTERNO com 6 casas. Com carta v2/v3 isso:
--   - revelava o OVR de quem ainda não tem 5 partidas (o motor esconde o OVR antes disso);
--   - mostrava um número diferente do valor atual (73,049656 × nulo), quebrando a coerência testada em 031.
-- Correção: para formula_version >= 2, a correção devolve o OVR como seria exibido (inteiro arredondado, nulo se a
-- carta era provisória). Cartas v1 continuam com o overall gravado (regra antiga).
-- Mesmo método de remendo da 051/070: se o texto esperado não existir, a migração para.

do $patch$
declare v_def text; v_new text;
begin
 v_def := pg_get_functiondef('public.get_player_evolution(uuid,uuid)'::regprocedure);
 v_new := replace(v_def,
  '''overall'', (k.snapshot_data->>''overall'')::numeric, ''tier'', k.snapshot_data->>''tier'')',
  '''overall'', case when k.formula_version >= 2 then
     case when coalesce((k.snapshot_data->>''is_provisional'')::boolean, false) then null
          else floor((k.snapshot_data->>''overall'')::numeric + 0.5) end
    else (k.snapshot_data->>''overall'')::numeric end,
   ''is_provisional'', (k.snapshot_data->>''is_provisional'')::boolean,
   ''tier'', k.snapshot_data->>''tier'')');
 if v_new = v_def then raise exception 'PATCH_EVOLUTION_CORRECTIONS_V89_FAILED'; end if;
 execute v_new;
end $patch$;
