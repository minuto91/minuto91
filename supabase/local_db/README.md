# Banco local de testes (PGlite)

Postgres descartável em WebAssembly, no próprio computador. Aplica `shim.sql` (o mínimo do Supabase:
papéis, `auth.users`, `auth.uid()`, `storage`) e todas as migrações, e roda os testes de `../tests_editor`.
Não conecta ao Supabase e não precisa de senha.

```
cd $HOME\Documents\minuto91\supabase\local_db; npm install; node run.mjs
```

`node run.mjs 027` roda só os testes cujo nome contém "027". `node load.mjs` roda o teste de carga
(`PLAYERS=100 MATCHES=40 node load.mjs` para a pelada grande; compara a finalização incremental com o recálculo
completo e mede o sorteio). `node --test` roda a lógica do push e da limpeza do Storage.

`node concurrency.mjs 20` (V4.2): sobe um **PostgreSQL 17 real** (pacote `embedded-postgres`, numa pasta temporária)
e disputa correção da súmula × último voto em duas conexões ao mesmo tempo, com as migrações até a 035 (V4.1) e
com todas (V4.2). Passa quando a V4.2 não tem deadlock nem voto de versão antiga apurado.

V4.3: `concurrency.mjs` também disputa o **Financeiro** (admin e assistente ao mesmo tempo: mesmo request_id, pagamentos
que estouram a dívida, geração de mensalidades e estorno x pagamento) e confere as invariantes contábeis. `node --test` inclui
`money_logic.test.mjs` (valores em centavos do app). O teste 035 (propriedade do sorteio, 2.400 sorteios + 150 sequências)
leva 2-3 min no PGlite.

Limites: sem pg_cron, `auth` e `storage` simulados. Antes do lançamento, rode os testes também no SQL Editor do dev.

V4.4: `node perf.mjs` sobe um **PostgreSQL 17 real** com dois bancos e a mesma massa sintética (V4.3 = migrações até a 043;
V4.4 = todas): peladas de 20, 50, 100, 200 e 500 jogadores, 100 a 5.000 partidas, e 1.000, 5.000 e 10.000 movimentações
financeiras. Mede as mesmas chamadas nos dois (Financeiro, Central do Jogador, Minha Carreira, telas da pelada, sorteio e
leituras simultâneas) e grava `docs/evidencias_v44/perf_resultados.json` e os planos (`explain_*.txt`, EXPLAIN ANALYZE
BUFFERS das consultas internas via auto_explain). Leva ~15 min; `SMALL=1 node perf.mjs` é a versão rápida. Pelada com mais de
100 jogadores é montada direto no banco (o servidor só aceita 100 ativos pelo convite) apenas para medir.
Novos testes SQL: `037_v44_finance_reports` (2.350 movimentações no mês, ~1 min no PGlite) e `038_v44_central_career`.

V4.5: `ONLY_EXPORT=1 node concurrency.mjs 20` roda só a **exportação concorrente** (leitor exporta o mês enquanto outra conexão
registra, estorna, edita e cancela; compara as páginas da V4.4 com `get_finance_export` e com um controle VOLATILE que
precisa falhar). `node concurrency.mjs 15` roda tudo (votação, Financeiro e exportação). `PERF_COMPARE=v45 node perf.mjs`
compara V4.4 (migrações até a 046) × V4.5 (todas) com a mesma massa, mede as telas nos dois bancos com p50 e p95 (`REPS`,
padrão 15) e grava em `docs/evidencias_v45/`. `node --test` inclui `pager_logic.test.mjs` (paginação do app sob pedidos
simultâneos e respostas fora de ordem) e a conferência da exportação. Novo teste SQL: `039_v45_finance_export`.

V8.7: `node v87_load.mjs` (PGlite) monta uma pelada de 100 jogadores com 12 goleiros oficiais e 2 temporadas e mede a publicação conjunta
dos prêmios de temporada, o recálculo idempotente e as leituras (Sala, Meus Prêmios, tela do admin). `node v87_concurrency.mjs 20` sobe um
**PostgreSQL 17 real** e disputa apurações simultâneas, correção × apuração e concessões simultâneas da exceção da Luva, conferindo as
invariantes (uma versão corrente por categoria, nenhum prêmio ativo duplicado, avisos deduplicados, estado final igual ao de um recálculo limpo).
O `initdb` do PostgreSQL recusa root: em contêiner root rode como usuário comum, por exemplo
`mkdir -p /tmp/pg87 && chown nobody /tmp/pg87 && runuser -u nobody -- env TMPDIR=/tmp/pg87 HOME=/tmp/pg87 node v87_concurrency.mjs 20`.
Novo teste SQL: `054_v87_season_awards` (T054, ~6 s no PGlite). `node --test` inclui os avisos da V8.7 em `push_logic.test.mjs`.
