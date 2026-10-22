// Limpeza do Storage (supabase/functions/storage-cleanup/logic.ts), sem rede. A24: paginação completa.
// Uso: cd supabase/local_db; node --test
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { candidates, listAll } from '../functions/storage-cleanup/logic.ts';

// Bucket falso: 3 pastas; a pasta "u1" tem 2.345 arquivos (mais de 2 páginas de 1.000).
const OLD = '2026-01-01T00:00:00Z';
const NEW = new Date(Date.now()).toISOString();
const tree = {
  '': [{ name: 'u1' }, { name: 'u2' }, { name: 'u3' }],
  u1: Array.from({ length: 2345 }, (_, i) => ({ name: `f${String(i).padStart(5, '0')}.jpg`, id: `i${i}`, created_at: OLD })),
  u2: [{ name: 'novo.jpg', id: 'n', created_at: NEW }],
  u3: [],
};
const lister = async (prefix, offset, limit) => tree[prefix].slice(offset, offset + limit);

test('lista todos os arquivos de uma pasta com mais de 1.000', async () => {
  assert.equal((await listAll(lister, 'u1', 1000)).length, 2345);
});

test('candidatos: todos os antigos, nenhum recente, sem repetir', async () => {
  const c = await candidates(lister, 1000, Date.now() - 3600_000);
  assert.equal(c.length, 2345);
  assert.equal(new Set(c).size, 2345);
  assert.ok(!c.includes('u2/novo.jpg'));
});

test('página exata (múltiplo do limite) também termina', async () => {
  const t = { '': [], x: Array.from({ length: 2000 }, (_, i) => ({ name: `a${i}`, id: `${i}`, created_at: OLD })) };
  assert.equal((await listAll(async (p, o, l) => t[p].slice(o, o + l), 'x', 1000)).length, 2000);
});
