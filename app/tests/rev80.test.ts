// REV 8.0: busca por nome (REV-045) e diferenciação de homônimos (REV-046).
// Rodar: cd app; node --experimental-strip-types --test tests/
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { disambiguators, matchesName, normalizeName, showSearch } from '../src/lib/search.ts';

test('busca ignora acentos e maiúsculas', () => {
  assert.equal(normalizeName('  JOÃO Ângelo '), 'joao angelo');
  assert.ok(matchesName('João Ângelo', 'joao'));
  assert.ok(matchesName('Sérgio', 'SER'));
  assert.ok(!matchesName('Sérgio', 'paulo'));
  assert.ok(matchesName('Qualquer', ''));
});

test('campo de busca só em listas a partir de 12', () => {
  assert.equal(showSearch(11), false);
  assert.equal(showSearch(12), true);
});

test('homônimos: foto ou posição diferente bastam; identificador só se ainda houver empate', () => {
  const tags = disambiguators([
    { id: 'aaaa1111-0000-0000-0000-000000000000', name: 'Pedro Silva', position: 'ZAG', hasPhoto: false },
    { id: 'bbbb2222-0000-0000-0000-000000000000', name: 'Pedro Silva', position: 'ZAG', hasPhoto: false },
    { id: 'cccc3333-0000-0000-0000-000000000000', name: 'Pedro Silva', position: 'ATA', hasPhoto: false },
    { id: 'dddd4444-0000-0000-0000-000000000000', name: 'Ana', position: 'MEI', hasPhoto: true },
  ]);
  assert.deepEqual(tags, { 'aaaa1111-0000-0000-0000-000000000000': '#aaaa', 'bbbb2222-0000-0000-0000-000000000000': '#bbbb' });
});
