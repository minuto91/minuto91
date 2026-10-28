# Changelog

Somente trabalho efetivamente feito. Versões anteriores: `docs/v77/` (V7.7) e `docs/rev80/RELATORIO_REV80.md` (V8.0).

## V8.1 — etapa 2: ciclo de vida da temporada (28/10/2026)

### Feito
- Migração `supabase/migrations/059_v81_season_lifecycle.sql`: coluna `seasons.lifecycle` (normal/suspended/cancelled), tabela imutável `private.season_lifecycle_events`, RPCs `suspend_season`, `resume_season`, `cancel_season`, `reactivate_season` (só admin, motivo 3–300 caracteres, linha travada, repetir falha com `INVALID_SEASON_STATE`), `get_season_lifecycle` (motivo/autor só para admin; dias sem partida só informativo). `sync_season_status` não encerra suspensa; `season_consolidation` nunca marca suspensa/cancelada como pronta.
- Teste `supabase/tests_editor/046_v81_season_lifecycle.sql`.
- Resultado: SQL **46/46** (`docs/v81_sql_apos_059.txt`), `node --test` 43/43, motor `050–052` sem diff. App não alterado (sem telas; não rodei lint/typecheck de novo).
- Não aplicada no Supabase dev (fica para você rodar `059` e depois `046` no SQL Editor).
- Riscos: partidas novas em temporada cancelada/suspensa não são bloqueadas; sem notificação nem tela.

## V8.1 — etapa 1: auditoria e documentação permanente (28/10/2026) — **V8.1 NÃO está concluída**

### Feito
- Auditoria do código, banco, testes e assets contra os requisitos da V8.1 (resultado: `MATRIZ_RASTREABILIDADE.md`).
- Criada a pasta de documentação permanente: `README.md`, `DECISOES_MESTRE.md`, `ESPECIFICACAO_V8.0.md`,
  `ESPECIFICACAO_V8.1.md`, `TROFEUS_BRANDING.md`, `MATRIZ_RASTREABILIDADE.md`, este `CHANGELOG.md`.
- `ESPECIFICACAO_V8.0.md` contém a matriz das 50 revisões extraída do relatório da V8.0 (o texto original não está no repositório; aviso no topo do arquivo).
- Arquivada a saída da suíte SQL de base: `docs/v81_baseline_sql.txt`.

### Não feito (e por quê) — ver `MATRIZ_RASTREABILIDADE.md` §G
- Sete troféus com arte oficial e logo original: **arquivos não fornecidos**.
- Etapas 42–45 (movimentação, interrupção, cancelamento, reativação): faltam definições de mecanismo e permissão; nada foi inventado.
- Etapas 8–9 e 16–19: texto original não recuperado.
- Artilheiro da Temporada e Seleção da Rodada na Sala: faltam regras de concessão/contagem.

### Código, migrações, telas
Nenhuma alteração. `git status` sem mudanças em `app/` e `supabase/`; motor V7.7 (`050–052`, `local_db/rating/*`) intacto. Sem migração nova.

### Testes executados (estado de base, antes de qualquer alteração de código)
| Suíte | Comando | Resultado |
|---|---|---|
| SQL, 60 migrações, 45 testes (inclui `010` empate 1º/1º, `044` V7.7, `045` REV 8.0) | `cd supabase/local_db; node run.mjs` | **45/45 passam** (`docs/v81_baseline_sql.txt`) |
| Motor de notas e lógica (SQL = JS, push, storage, dinheiro) | `cd supabase/local_db; node --test` | **43/43 passam** |
| App | `cd app; npm test` | **29/29 passam** |
| Tipos | `cd app; npm run typecheck` | 1ª execução: 5 erros de rotas tipadas (cache desatualizado, arquivos não tocados); 2ª execução: **0 erros** |
| Lint, bundle web, Supabase dev | — | **não executados** nesta etapa |
| Visual (aparelho, logo, assets) | — | **não executado**: não há assets oficiais |

### Decisões superadas
Nenhuma.

### Pendências para fechar a V8.1
Ver `DECISOES_MESTRE.md` §5.
