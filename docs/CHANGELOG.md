# Changelog

Somente trabalho efetivamente feito. Versões anteriores: `docs/v77/` (V7.7) e `docs/rev80/RELATORIO_REV80.md` (V8.0).

## V8.9 — Oficialização do motor V7.7 (DEF/LET-REF/APR/RES/DIS) (29/10/2026) — implementada localmente; 2 verificações bloqueadas pelo ambiente, 3 pendências de decisão

Detalhes, matriz e divergências: `docs/V8.9_IMPLEMENTACAO.md`; evidências: `docs/evidencias_v89/`.

### Feito
- O motor V7.7 estava só na branch `origin/v7.7-motor`; portado sem alterar fórmulas: migrações `070_v89_rating_engine.sql` (idêntica à referência anexa, exceto o alvo do patch de Minha Carreira) e `071_v89_resenha_vote.sql`.
- `072_v89_awards_pin_ref_params.sql`: REF do Paredão e da Luva fixados nos parâmetros v1 (prêmios não mudam com a versão ativa do motor).
- App: cards e telas com os cinco atributos, pergunta da resenha, variação do OVR só entre publicações da mesma fórmula.
- Testes: novo `055_v89_engine`; ajustes em `054_v87` e no teste de integração (assinatura atual de `annul_match`).

### Testes (resultados reais)
- SQL 55/55; Node 33/34 (a falha é a paridade com Python, indisponível na máquina); app 84/84 e `tsc` 0 erros.

### Pendente
- Paridade Python e concorrência em PostgreSQL real bloqueadas pelo ambiente; V7.5×V7.7 (3,22) não recalibrada; data de corte da v2 a confirmar antes de aplicar; V8.8 não existe no repositório; nada aplicado em banco remoto.

## V8.7 — Artilheiro da Temporada, Maestro da Temporada, Luva de Ouro + Meus Prêmios (29/10/2026) — implementada localmente; 4 IDs com ressalva (C01, C05, C07, AD01), nenhum bloqueado

Detalhes: `docs/V8.7_IMPLEMENTACAO.md`, matriz `docs/V8.7_MATRIZ_RASTREABILIDADE.md`, anexo normativo `docs/V8.7_DECISOES_COMPLETAS.md` (32 decisões: A01–A05, B01–B10, C01–C12, F01–F04, AD01).

### Feito
- Migração `068_v87_season_awards.sql` (incremental, reversível; **não aplicada em banco remoto**) + teste SQL `054_v87_season_awards.sql`:
  três prêmios de temporada (`season_top_scorer`, `season_maestro`, `season_golden_glove`) com apuração conjunta, transacional e idempotente depois do encerramento e da consolidação; resultados versionados e imutáveis em `private.season_award_results`, auditoria em `private.v87_events`;
  REF da Luva **no contexto do encerramento** (mesma conta do motor 051, janela móvel de até 20 partidas que pode atravessar temporadas, sem partidas posteriores, 6 casas); elegibilidade `max(5, ceil(50%))` com posição oficial GOL no encerramento, improvisados fora, ex-integrante pela última posição oficial; desempate REF → defesas difíceis por partida como GOL → partidas como GOL → compartilhado;
  exceção administrativa da Luva (só admin, só sem elegível normal, justificativa e auditoria, piso de 3 atuações), revogável, anulada quando surge elegível normal;
  recálculo em anulação, restauração, correção de súmula, defesas difíceis e posição (ganchos em `close_month` e `after_rating_inputs_changed`), no agendador (`process_season_awards`) e na primeira leitura;
  avisos (coletivo deduplicado, individual do vencedor, revogação só para quem perdeu); Sala de Troféus só com contadores; `get_player_season_titles` (AD01); bloco `season_awards` na retrospectiva oficial.
- App: tela `pelada/[id]/premios-temporada` (vencedores, REF e a exceção do admin), bloco condicional **Meus Prêmios** em Minha Carreira, três ladrilhos com contador na Sala, tela de prêmios na retrospectiva e artes `P07` (conjunta) e `I06` (individual), textos de avisos (`notifs.ts` e `push-sender/logic.ts`), vitrine `dev-v87`, `v87logic.ts` + `tests/v87.test.ts`.
- Carga e concorrência: `supabase/local_db/v87_load.mjs` (100 jogadores) e `v87_concurrency.mjs` (PostgreSQL 17 real, 20 rodadas × 3 disputas).
- Evidências visuais da vitrine: `docs/evidencias_v87/`.

### Testes (resultados reais)
- SQL: baseline V8.6 53/53 → final com a V8.7 54/54 (ver `V8.7_IMPLEMENTACAO.md` §7); `node --test` 48/48; app `tsc` 0 erros, `expo lint` limpo, 80/80 testes; carga e concorrência passam.

### Pendente / divergências
- Artilheiro da Temporada **não existia** no repositório (o prompt dizia que sim): criado uma vez pela regra do anexo (DIV-1).
- Sem concessão retroativa a temporadas já encerradas até decisão do produto (DIV-2); arte dos três troféus é **provisória** (DIV-3); recorte do desempate = temporada, a confirmar (DIV-5).
- Não executados: aplicação no Supabase dev, teste em dispositivo, compartilhamento real das artes e envio real de push.

## V8.6 — Paredão do Mês + Craque da Temporada (29/10/2026) — parcial, com bloqueios fail-closed

Detalhes: `docs/V8.6_IMPLEMENTACAO.md`, matriz `docs/V8.6_MATRIZ_RASTREABILIDADE.md`, anexo normativo `docs/V8.6_DECISOES_COMPLETAS.md`.

### Feito
- Migração `066_v86_paredao_craque_temporada.sql` + teste SQL `052_v86_paredao_craque.sql`: Paredão (REF mensal pela fórmula vigente, publicação só após confirmação do admin, versões de retificação) e Craque da Temporada (candidatos, eleitores congelados, 1º/2º turno, quórum, prorrogação única, voto secreto, desempate, reinício por correção).
- App: tela `craque-temporada`, troféus novos na Sala de Troféus, mensagens de erro, `v86logic.ts` + `tests/v86.test.ts`.
- Regressão: 49/49 testes SQL; 60/60 testes do app; `tsc` e `eslint` sem erros.

- Migração `064` + teste `050`: decisão A (G03: mais partidas, depois entrada mais antiga) e C (retificação pelo admin).

### Pendente
- Ordem dos atributos no desempate final e passo do admin (F04, próxima Rev), arte dedicada dos dois troféus, avisos de abertura/encerramento da votação.

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
