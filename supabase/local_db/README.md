# Banco local de testes (PGlite)

Postgres descartável em WebAssembly, no próprio computador. Aplica `shim.sql` (o mínimo do Supabase:
papéis, `auth.users`, `auth.uid()`, `storage`) e todas as migrações, e roda os testes de `../tests_editor`.
Não conecta ao Supabase e não precisa de senha.

```
cd $HOME\Documents\minuto91\supabase\local_db; npm install; node run.mjs
```

`node run.mjs 027` roda só os testes cujo nome contém "027". `node load.mjs` roda o teste de carga.

Limites: sem pg_cron, `auth` e `storage` simulados. Antes do lançamento, rode os testes também no SQL Editor do dev.
