// Sessão em armazenamento seguro (lib/securestorage.ts).
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { CHUNK, chunkedStorage, type KV } from '../src/lib/securestorage.ts';

function mem(): KV & { m: Map<string, string> } {
  const m = new Map<string, string>();
  return {
    m,
    getItem: async (k) => m.get(k) ?? null,
    setItem: async (k, v) => { m.set(k, v); },
    removeItem: async (k) => { m.delete(k); },
  };
}

test('sessão grande é dividida em partes de até CHUNK e lida inteira', async () => {
  const s = mem();
  const st = chunkedStorage(s, null);
  const big = 'x'.repeat(CHUNK * 2 + 10);
  await st.setItem('sb', big);
  assert.equal(s.m.get('sb.n'), '3');
  assert.ok([...s.m.values()].every((v) => v.length <= CHUNK));
  assert.equal(await st.getItem('sb'), big);
});

test('regravar menor apaga as partes que sobraram', async () => {
  const s = mem();
  const st = chunkedStorage(s, null);
  await st.setItem('sb', 'y'.repeat(CHUNK * 3));
  await st.setItem('sb', 'curta');
  assert.equal(await st.getItem('sb'), 'curta');
  assert.equal(s.m.size, 2);
});

test('sessão antiga do AsyncStorage migra sem deslogar e sai de lá', async () => {
  const s = mem();
  const old = mem();
  old.m.set('sb', '{"token":"abc"}');
  const st = chunkedStorage(s, old);
  assert.equal(await st.getItem('sb'), '{"token":"abc"}');
  assert.equal(old.m.has('sb'), false);
  assert.equal(await st.getItem('sb'), '{"token":"abc"}');
});

test('parte faltando devolve null (sem sessão corrompida)', async () => {
  const s = mem();
  const st = chunkedStorage(s, null);
  await st.setItem('sb', 'z'.repeat(CHUNK + 1));
  s.m.delete('sb.1');
  assert.equal(await st.getItem('sb'), null);
});

test('sair apaga tudo, inclusive no AsyncStorage', async () => {
  const s = mem();
  const old = mem();
  const st = chunkedStorage(s, old);
  await st.setItem('sb', 'abc');
  old.m.set('sb', 'resto');
  await st.removeItem('sb');
  assert.equal(s.m.size + old.m.size, 0);
});
