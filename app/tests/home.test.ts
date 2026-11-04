import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  greetingText,
  individualStats,
  pickCard,
  pickGreetingIndex,
  pickLastGame,
  pickNextRound,
  resultLabel,
  safeName,
  type CardCandidate,
} from '../src/lib/homelogic.ts';

const c = (id: string, ovr: number | null, matches: number, last: string | null, eligible = true): CardCandidate => ({
  pelada_id: id,
  ovr,
  matches,
  last_played_at: last,
  eligible,
});

test('REV-080: maior OVR; depois partidas; depois partida mais recente; depois id da pelada', () => {
  assert.equal(pickCard([c('a', 80, 9, '2026-01-01'), c('b', 85, 5, '2026-01-01')])?.pelada_id, 'b');
  assert.equal(pickCard([c('a', 80, 9, '2026-01-01'), c('b', 80, 12, '2026-01-01')])?.pelada_id, 'b');
  assert.equal(pickCard([c('a', 80, 9, '2026-02-01'), c('b', 80, 9, '2026-01-01')])?.pelada_id, 'a');
  assert.equal(pickCard([c('b', 80, 9, '2026-01-01'), c('a', 80, 9, '2026-01-01')])?.pelada_id, 'a');
});

test('REV-079/082: sem OVR elegível não há Card (não inventa valor)', () => {
  assert.equal(pickCard([]), null);
  assert.equal(pickCard([c('a', null, 3, null, false), c('b', 70, 2, null, false)]), null);
});

test('REV-067: último jogo é a partida oficial mais recente entre as peladas', () => {
  const g = pickLastGame([
    { match_id: 'm1', played_at: '2026-10-01T20:00:00Z' },
    { match_id: 'm2', played_at: '2026-10-05T20:00:00Z' },
    { match_id: 'm3', played_at: '2026-09-01T20:00:00Z' },
  ]);
  assert.equal(g?.match_id, 'm2');
  assert.equal(pickLastGame([]), null);
});

test('REV-056/068: próximo jogo = futuro mais próximo com data; sem data ou passado não conta', () => {
  const now = new Date('2026-11-04T12:00:00Z').getTime();
  const r = pickNextRound(
    [
      { pelada_id: 'p1', scheduled_at: '2026-11-10T20:00:00Z' },
      { pelada_id: 'p2', scheduled_at: '2026-11-06T20:00:00Z' },
      { pelada_id: 'p3', scheduled_at: '2026-11-01T20:00:00Z' },
      { pelada_id: 'p4', scheduled_at: null },
    ],
    now,
  );
  assert.equal(r?.pelada_id, 'p2');
  assert.equal(pickNextRound([{ pelada_id: 'p4', scheduled_at: null }], now), null);
  // empate de horário: id da pelada
  assert.equal(
    pickNextRound([{ pelada_id: 'pb', scheduled_at: '2026-11-06T20:00:00Z' }, { pelada_id: 'pa', scheduled_at: '2026-11-06T20:00:00Z' }], now)?.pelada_id,
    'pa',
  );
});

test('REV-063: VITÓRIA / DERROTA / EMPATE pelo time do jogador; sem time não afirma vitória nem derrota', () => {
  assert.equal(resultLabel('A', 3, 1), 'VITÓRIA');
  assert.equal(resultLabel('B', 3, 1), 'DERROTA');
  assert.equal(resultLabel('A', 2, 2), 'EMPATE');
  assert.equal(resultLabel(null, 3, 1), null);
  assert.equal(resultLabel('A', null, null), null);
});

test('REV-065: estatísticas só do que o jogador fez (sem zeros)', () => {
  assert.deepEqual(individualStats({ goals: 0, assists: 0 }), []);
  assert.deepEqual(individualStats({ goals: 2, assists: 1 }), [
    { label: 'Gols', value: 2 },
    { label: 'Assistência', value: 1 },
  ]);
});

test('REV-094: nome seguro; sem nome, saudação sem nome e sem null/undefined/e-mail/id', () => {
  assert.equal(safeName('Rafael Abreu'), 'Rafael');
  assert.equal(safeName(null), null);
  assert.equal(safeName('undefined'), null);
  assert.equal(safeName('a@b.com'), null);
  assert.equal(safeName('3f2b6f0a-1111-2222-3333-444455556666'), null);
  assert.equal(greetingText(0, 'Rafael Abreu'), 'Vamos pra mais um jogo, Rafael!');
  assert.equal(greetingText(0, null), 'Vamos pra mais um jogo!');
});

test('REV-053/093: nunca repete a frase da vez anterior quando há mais de uma', () => {
  for (let prev = 0; prev < 5; prev++) {
    for (const r of [0, 0.25, 0.5, 0.99]) {
      assert.notEqual(pickGreetingIndex(prev, () => r, 5), prev);
    }
  }
  assert.equal(pickGreetingIndex(0, Math.random, 1), 0);
});
