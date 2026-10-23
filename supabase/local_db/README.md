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
