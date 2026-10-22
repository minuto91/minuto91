// Banco local descartável (PGlite, Postgres em WebAssembly): aplica shim.sql + todas as migrações
// em ordem e roda os testes de supabase/tests_editor (os mesmos do SQL Editor: terminam com o erro
// proposital "PASS: ...", que desfaz tudo).
// Uso: cd supabase/local_db; npm install; node run.mjs [filtro]
// Nada aqui conecta ao Supabase. Diferenças em relação ao Supabase real: auth e storage simulados
// (shim.sql), sem pg_cron (a migração 022 só avisa), um único usuário de banco com SET ROLE.
import { PGlite } from '@electric-sql/pglite';
import { btree_gist } from '@electric-sql/pglite/contrib/btree_gist';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = join(import.meta.dirname, '..');
const filter = process.argv[2] ?? '';
const extensions = { pgcrypto, btree_gist };
const sqlFiles = (dir) => readdirSync(join(root, dir)).filter((f) => f.endsWith('.sql')).sort();

const t0 = Date.now();
const base = await PGlite.create({ extensions });
await base.exec(readFileSync(join(import.meta.dirname, 'shim.sql'), 'utf8'));
for (const f of sqlFiles('migrations')) {
  try {
    await base.exec(readFileSync(join(root, 'migrations', f), 'utf8'));
  } catch (e) {
    console.log(`FAIL migração ${f}: ${e.message}`);
    process.exit(1);
  }
}
console.log(`${sqlFiles('migrations').length} migrações aplicadas (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
const dump = await base.dumpDataDir('none');
await base.close();

let fail = 0;
const tests = sqlFiles('tests_editor').filter((f) => f.includes(filter));
for (const f of tests) {
  const db = await PGlite.create({ loadDataDir: dump, extensions });
  const t = Date.now();
  try {
    await db.exec(readFileSync(join(root, 'tests_editor', f), 'utf8'));
    fail++;
    console.log(`FAIL ${f}: terminou sem o "PASS" final`);
  } catch (e) {
    if (e.message.startsWith('PASS')) console.log(`PASS ${f} (${((Date.now() - t) / 1000).toFixed(1)}s)`);
    else {
      fail++;
      console.log(`FAIL ${f}: ${e.message}`);
    }
  }
  await db.close();
}
console.log(fail ? `${fail} de ${tests.length} falharam` : `todos os ${tests.length} passaram`);
process.exit(fail ? 1 : 0);
