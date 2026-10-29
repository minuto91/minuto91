import assert from 'node:assert/strict';
import { test } from 'node:test';

import { candidateReason, canVoteSelf, quorum, remaining, statusTitle } from '../src/lib/v86logic.ts';

test('V14: quórum arredondado para cima, mínimo um voto', () => {
  assert.equal(quorum(9), 5);
  assert.equal(quorum(8), 4);
  assert.equal(quorum(1), 1);
  assert.equal(quorum(0), 1);
});

test('V24/V30: voto próprio só no 1º turno com 2 candidatos', () => {
  assert.equal(canVoteSelf(1, 2), true);
  assert.equal(canVoteSelf(1, 3), false);
  assert.equal(canVoteSelf(2, 2), false);
});

test('textos de estado', () => {
  assert.match(statusTitle('no_winner', null, 'sem_quorum'), /quórum/);
  assert.match(statusTitle('no_winner', null, 'candidato_unico'), /um candidato/);
  assert.match(statusTitle('round2', 2), /Segundo turno/);
  assert.match(statusTitle('tie_blocked', null), /decisão/);
});

test('motivo da candidatura e tempo restante', () => {
  assert.equal(candidateReason({ slot: 'goals', substitute: false }), 'Artilheiro');
  assert.match(candidateReason({ slot: 'craque', substitute: true }), /próximo maior OVR/);
  const now = Date.parse('2026-10-01T00:00:00Z');
  assert.equal(remaining('2026-10-03T03:30:00Z', now), '2 d 3 h');
  assert.equal(remaining('2026-10-01T00:45:00Z', now), '45 min');
  assert.equal(remaining('2026-09-30T00:00:00Z', now), 'menos de 1 min');
  assert.equal(remaining(null, now), null);
});
