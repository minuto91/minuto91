// Banco PGlite descartável com shim.sql + todas as migrações (para os testes do motor).
import { PGlite } from '@electric-sql/pglite';
import { btree_gist } from '@electric-sql/pglite/contrib/btree_gist';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const here = join(import.meta.dirname, '..');
export async function migratedDb() {
  const d = await PGlite.create({ extensions: { pgcrypto, btree_gist } });
  await d.exec(readFileSync(join(here, 'shim.sql'), 'utf8'));
  for (const f of readdirSync(join(here, '..', 'migrations')).filter((f) => f.endsWith('.sql')).sort())
    await d.exec(readFileSync(join(here, '..', 'migrations', f), 'utf8'));
  return d;
}
