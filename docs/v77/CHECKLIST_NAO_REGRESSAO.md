# Checklist de não regressão V7.7

| Item | Como foi verificado | Resultado |
|---|---|---|
| Fórmulas do motor intactas | `git diff main -- supabase/migrations/05[01]_* supabase/local_db/rating/` vazio; `rating_engine.test.mjs`, `rating_sql.test.mjs`; simulação idêntica | OK |
| Paleta branco/azul/dourado | Componentes novos usam só `colors.*` do tema (`blue`, `deepBlue`, `gold`, `danger` para o selo) | OK |
| R$ 29,90 por pelada | Sem mudança em `043`, `purchases.ts`, `legalText.ts` 11.2 | OK |
| Sigilo dos votos | `044` §1–2, `042`, `020_security_invariants`; admin sem média/validade; `private.*` sem SELECT | OK |
| Sem quórum antigo (50%) | `grep -rn "50%"` no app só acha estilos de layout; Termos 6.8 reescritos; tela da partida sem a regra | OK |
| Sem limite de 7 dias na anulação | `ANNULMENT_WINDOW_EXPIRED` removido do banco e do app; `013` anula partida com 8 dias | OK |
| Sem placar de partida anulada | Banco: privilégio de coluna + `public_team_*_score`; `044` §7; app: `scoreLine`, `v77.test.ts` | OK |
| Sem votos apagados | Triggers `VOTE_DELETE_FORBIDDEN`/`VOTE_HISTORY_IMMUTABLE`; `044` §1; única exceção documentada: anonimização da exclusão de conta | OK |
| Sem republicação duplicada | `044` §6 e §8 (mesmos ids de prêmios, uma auditoria de publicação); `rating_concurrency` publicação dupla | OK |
| Sem exclusão "concluída" com falha | `044` §14 (falha no login mantém `pending`, conclui só na nova tentativa) | OK |
| Reserva de vaga por 30 dias | `044` §14 (pelada com 100: reservada bloqueia entrada; liberada depois da exclusão definitiva) | OK |
| Garçom da Partida ausente | `041`, `push_logic.test.mjs`, `grep -rn match_garcom app/src` vazio | OK |
