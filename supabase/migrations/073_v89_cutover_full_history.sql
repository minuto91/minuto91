-- Minuto 91 / 073: motor V7.7 em TODO o histórico (decisão do fundador, 01/11/2026).
--
-- A 070 (como a 053 da V7.7) gravava cutover_date = data da aplicação: temporadas encerradas antes disso
-- mantinham as cartas v1/v2. Decisão: o corte vale desde o início, e todas as temporadas de todas as peladas são
-- recalculadas com a fórmula V7.7 (formula_version 3, rating_params version 2).
--
-- O que muda
-- - private.rating_params (version 2): cutover_date = '0001-01-01'. Nenhuma temporada fica antes do corte, então
--   private.recompute_card nunca mais desvia para a carta histórica v1/v2.
-- - Publicação: para cada pelada com partida oficial, recalcula a partir da temporada MAIS ANTIGA.
--   private.recompute_cards(temporada, null) reprocessa a pelada inteira em ordem cronológica
--   (recompute_pelada_ratings) e propaga para as temporadas seguintes que têm cartas (051).
--
-- O que NÃO muda
-- - Fórmulas, pesos e constantes da V7.7 (070): só o parâmetro de corte.
-- - Prêmios do Paredão (066) e da Luva de Ouro (068): continuam presos aos parâmetros v1 pela 072.
-- - Notas de partida, votos, súmulas, Rei do Mês, Seleção da Rodada e figurinhas: não dependem do OVR.
-- - Linhas antigas de player_rating_history e card_snapshots com formula_version 1/2 ficam guardadas; as novas
--   publicações entram com formula_version 3.
--
-- Rollback: update private.rating_params set params = jsonb_set(params,'{cutover_date}',to_jsonb('<data>'::text))
-- where version = 2; e recalcular como abaixo. As cartas v1/v2 das temporadas antigas NÃO voltam sozinhas
-- (foram reescritas); só desativando a versão 2 (ver rollback da 070) o motor da V5 volta a publicar.

update private.rating_params
   set params = jsonb_set(params, '{cutover_date}', to_jsonb('0001-01-01'::text))
 where version = 2;

do $init$
declare v_p uuid; v_season uuid;
begin
 if not exists (select 1 from private.rating_params where version = 2 and params->>'cutover_date' = '0001-01-01') then
  raise exception 'rating_params version 2 ausente: aplique a 070 antes da 073';
 end if;
 perform set_config('minuto91.rating_event', 'recompute', true);
 for v_p in select distinct pelada_id from public.matches where status = 'finalized' order by 1 loop
  select s.id into v_season
    from public.seasons s
   where s.pelada_id = v_p
     and exists (select 1 from public.matches m where m.season_id = s.id and m.status = 'finalized')
   order by s.starts_on, s.id
   limit 1;
  perform private.recompute_cards(v_season, null);
 end loop;
 perform set_config('minuto91.rating_event', '', true);
end $init$;
