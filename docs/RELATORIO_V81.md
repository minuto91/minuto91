# Minuto 91 — V8.1: relatório de implementação (28/10/2026)

**Estado: PARCIAL. A V8.1 não está concluída** (critérios de aceite do prompt mestre não cumpridos; ver §5).
Base: V8.0 (`8f7f8cc`). Commits: `c89685f` (docs + banco), `dadb923` (telas), mais este relatório. Todos na `main` do GitHub.

## 1. Resumo
- Auditoria completa contra os 11 blocos de requisitos; resultado em `MATRIZ_RASTREABILIDADE.md`.
- Pasta `docs` permanente criada (7 arquivos).
- Etapas 43, 44 e 45 (suspender, cancelar e reativar temporada) implementadas no banco e nas telas, só admin, com motivo e auditoria.
- Etapa 41 (empate 1º, 1º, 3º) já existia e tem teste.

## 2. Arquivos
| Tipo | Arquivo |
|---|---|
| Migração | `supabase/migrations/059_v81_season_lifecycle.sql` |
| Teste SQL | `supabase/tests_editor/046_v81_season_lifecycle.sql` |
| Componente novo | `app/src/lib/seasonlifecycle.tsx` |
| Alterados | `app/src/app/pelada/[id]/temporadas.tsx`, `app/src/lib/errors.ts` |
| Docs | `docs/README.md`, `DECISOES_MESTRE.md`, `ESPECIFICACAO_V8.0.md`, `ESPECIFICACAO_V8.1.md`, `TROFEUS_BRANDING.md`, `MATRIZ_RASTREABILIDADE.md`, `CHANGELOG.md`, `v81_baseline_sql.txt`, `v81_sql_apos_059.txt` |

## 3. Regras implementadas (059)
- `seasons.lifecycle`: normal, suspensa, cancelada. O `status` por data não mudou.
- `suspend_season`, `resume_season`, `cancel_season`, `reactivate_season`: só admin (assistente recusado), motivo de 3 a 300 caracteres, linha travada, repetir a chamada falha (`INVALID_SEASON_STATE`).
- Suspensa: não é encerrada pelo calendário nem consolidada. Falta de jogos é só informação (`get_season_lifecycle`) e nunca encerra nada.
- Cancelada: nada é apagado; não consolida (sem retrospectiva nem título sazonal). Reativada: mesmo id, nome, datas e partidas; nenhum prêmio é concedido.
- Eventos imutáveis (`private.season_lifecycle_events`) + `audit_events`. Motivo e autor só para admin.

## 4. Testes executados
| Suíte | Resultado |
|---|---|
| SQL, 61 migrações, 46 testes (inclui `046`) | 46/46 passam (`docs/v81_sql_apos_059.txt`) |
| Motor e lógica (`node --test`) | 43/43 |
| App `npm test` | 29/29 |
| Typecheck | 0 erros |
| Lint | 1 erro em `lib/push.tsx:47` (`AndroidImportance`), arquivo não tocado; não verifiquei se já existia |
| Não executados | tela rodando (web/aparelho), bundle web, Supabase dev, testes visuais |

Preservação: `git diff` de `050–052` e `supabase/local_db/rating/` vazio; nenhuma migração antiga editada; nenhuma fórmula tocada.

## 5. Pendências (impedem declarar a V8.1 concluída)
1. **Artes dos 7 troféus e logo original**: arquivos não fornecidos. A Sala segue com 5 SVG da V4.4/V8.0.
2. **Artilheiro da Temporada** (sem tipo de prêmio) e **Seleção da Rodada** (fora da Sala): faltam regras de concessão e contagem.
3. **Etapa 42** (movimentação): falta definir "ranking oficial".
4. **Etapas 8–9, 16–19**: texto original não recuperado. **Etapas 20–40**: condições individuais incompletas; E5 e F6 "a verificar".
5. **Pedestal do Artilheiro do Mês**: conflito V8.0 × arte nova, aguarda decisão.
6. Aplicar `059` + teste `046` no Supabase dev; ver a tela rodando.
7. `ESPECIFICACAO_V8.0.md` traz só a matriz do relatório da V8.0; o texto original das 50 revisões não está no repositório.

## 6. Riscos
- Partidas novas em temporada suspensa ou cancelada não são bloqueadas (não especificado).
- Cancelar temporada já consolidada é permitido (não especificado).
- Sem notificação aos jogadores sobre mudança de ciclo de vida.
- D2 (Bola Murcha privada por padrão) sem teste dedicado.
- Telas sem verificação visual.

## 7. Onde ver o detalhe
Etapa por etapa: `MATRIZ_RASTREABILIDADE.md`. Decisões e precedência: `DECISOES_MESTRE.md`. Histórico: `CHANGELOG.md`.
