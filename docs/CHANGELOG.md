# Changelog

Somente trabalho efetivamente feito. Versões anteriores: `docs/v77/` (V7.7) e `docs/rev80/RELATORIO_REV80.md` (V8.0).

## V8.6 — Paredão do Mês + Craque da Temporada (29/10/2026) — parcial, com bloqueios fail-closed

Detalhes: `docs/V8.6_IMPLEMENTACAO.md`, matriz `docs/V8.6_MATRIZ_RASTREABILIDADE.md`, anexo normativo `docs/V8.6_DECISOES_COMPLETAS.md`.

### Feito
- Migração `063_v86_paredao_craque_temporada.sql` + teste SQL `049_v86_paredao_craque.sql`: Paredão (REF mensal pela fórmula vigente, publicação só após confirmação do admin, versões de retificação) e Craque da Temporada (candidatos, eleitores congelados, 1º/2º turno, quórum, prorrogação única, voto secreto, desempate, reinício por correção).
- App: tela `craque-temporada`, troféus novos na Sala de Troféus, mensagens de erro, `v86logic.ts` + `tests/v86.test.ts`.
- Regressão: 49/49 testes SQL; 60/60 testes do app; `tsc` e `eslint` sem erros.

### Pendente (decisão do produto)
- Empate de OVR na formação de candidatos (G03), ordem dos atributos no desempate final e passo do admin (F04), política de retificação pós-publicação (G10), arte dedicada dos dois troféus, avisos de abertura/encerramento da votação.

## V8.4 — Central do Jogador + padronização global (28/10/2026) — Entrega A implementada com pendências; Entrega B parcial

Detalhes: `docs/V8.4_*.md` (decisões E01–E16, matriz, auditoria, padronização, testes).

### Feito
- Migração `060_v84_central.sql` (incremental) + teste SQL `047_v84_central.sql`: feed de notificações com leitura persistida e retenção de 90 dias, layout versionado da Central, `get_my_last_game`.
- App: Central reescrita (cabeçalho, seletor com Bottom Sheet, Carta e evolução, Próxima Rodada, Último Jogo, Resumo, Atenção, Minhas Peladas), tela de Notificações, Personalizar Central, carregamento por bloco com cache autorizado, push a frio pela Central, proteção de parâmetros de rota, toque repetido na aba Início.
- Padronização compartilhada: tokens (`layout`, `radius.card = 16`), `Screen`/`ListScreen` centralizados (máx. 560), `Card` branco com borda, `Skeleton`/`BottomSheet` únicos.
- Dependência nova: `expo-haptics`. `package-lock.json` regenerado (estava fora de sincronia).
- Corrigido o erro de lint preexistente de `push.tsx` (`AndroidImportance`).

### Não feito / pendente
- Pilhas e rolagem **independentes por aba** (E09/E15-18): exige mover as rotas; precisa de aprovação e teste em dispositivo.
- Data, horário e local da rodada (E04): o modelo não os guarda.
- Reorganização página a página (Entrega B), verificação autenticada, em dispositivo e com leitor de tela.

## V8.2 — tela de login (28/10/2026) — encerrada com pendências (ver RELATORIO_V82.md)

- Nova identidade visual da entrada (`app/src/lib/loginui.tsx`, `app/src/app/login.tsx`, fundo em `app/assets/login/`). Fluxos de autenticação não alterados. Detalhes, diferenças e testes não feitos: `RELATORIO_V82.md`.

## V8.1 — etapa 3: telas do ciclo de vida (28/10/2026)

- `app/src/lib/seasonlifecycle.tsx` (novo) integrado em `app/src/app/pelada/[id]/temporadas.tsx`: estado (suspensa/cancelada), linha do tempo, e para o admin botões Suspender/Retomar/Cancelar/Reativar com motivo obrigatório e confirmação. Mensagem nova em `errors.ts` (`INVALID_SEASON_STATE`).
- `npm run typecheck` 0 erros; `npm test` 29/29; `npm run lint`: 1 erro **que já existia** em `lib/push.tsx:47` (`AndroidImportance`), arquivo não tocado; nenhum erro nos arquivos novos.
- **Não verificado:** tela rodando (web/aparelho) e o fluxo contra o Supabase dev (a 059 ainda não foi aplicada lá). Sem notificação aos jogadores.

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
