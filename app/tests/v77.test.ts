// V7.7: partida anulada sem placar e id de pedido para operações idempotentes.
// Rodar: cd app; node --experimental-strip-types --test tests/
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { requestId } from '../src/lib/ids.ts';
import { scoreLine } from '../src/lib/matchview.ts';

const base = { team_a_name: 'Azul', team_b_name: 'Branco', team_a_score: 3, team_b_score: 1 };

test('partida anulada não mostra placar', () => {
  assert.equal(scoreLine({ ...base, status: 'annulled' }), 'Azul x Branco');
  assert.equal(scoreLine({ ...base, status: 'finalized', team_a_score: null, team_b_score: null }), 'Azul x Branco');
});

test('partida válida mostra placar', () => {
  assert.equal(scoreLine({ ...base, status: 'finalized' }), 'Azul 3 x 1 Branco');
});

test('id de pedido é UUID v4 e não repete', () => {
  const ids = new Set(Array.from({ length: 2000 }, requestId));
  assert.equal(ids.size, 2000);
  for (const id of ids) assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});
