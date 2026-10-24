// Central do Jogador 2.0: regras de exibição (lib/centrallogic.ts).
// Rodar: cd app; node --experimental-strip-types --test tests/
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  deltaA11y,
  deltaText,
  leftLabel,
  matchRating,
  nextVoteBoundary,
  ofPelada,
  ovrDelta,
  pickPelada,
  resultOf,
  serverOffset,
  URGENT_MS,
  voteState,
} from '../src/lib/centrallogic.ts';

const NOW = Date.parse('2026-10-24T20:00:00Z');
const at = (ms: number) => new Date(NOW + ms).toISOString();
const MIN = 60_000;

test('votação com mais de 1 hora fica entre as pendências normais', () => {
  assert.equal(voteState(at(61 * MIN), 0, NOW), 'open');
  assert.equal(voteState(at(5 * 60 * MIN), 0, NOW), 'open');
});

test('votação com até 1 hora restante é urgente', () => {
  assert.equal(voteState(at(URGENT_MS), 0, NOW), 'urgent');
  assert.equal(voteState(at(59 * MIN), 0, NOW), 'urgent');
  assert.equal(voteState(at(30_000), 0, NOW), 'urgent');
});

test('votação encerrada não aparece como aberta', () => {
  assert.equal(voteState(at(0), 0, NOW), 'closed');
  assert.equal(voteState(at(-MIN), 0, NOW), 'closed');
});

test('prorrogação além de 1 hora tira a votação do estado urgente', () => {
  const original = at(40 * MIN);
  const extended = at(40 * MIN + 60 * MIN);
  assert.equal(voteState(original, 0, NOW), 'urgent');
  assert.equal(voteState(extended, 0, NOW), 'open');
});

test('a urgência segue o relógio do servidor, não o do aparelho', () => {
  // Aparelho 10 min atrasado: pelo servidor já faltam 55 min.
  const offset = serverOffset(new Date(NOW + 10 * MIN).toISOString(), NOW);
  assert.equal(offset, 10 * MIN);
  assert.equal(voteState(at(65 * MIN), 0, NOW), 'open');
  assert.equal(voteState(at(65 * MIN), offset, NOW), 'urgent');
  assert.equal(serverOffset(undefined, NOW), 0);
  assert.equal(serverOffset('inválido', NOW), 0);
});

test('tempo restante legível', () => {
  assert.equal(leftLabel(at(45 * MIN), 0, NOW), 'Faltam 45 min');
  assert.equal(leftLabel(at(2 * 60 * MIN + 5 * MIN), 0, NOW), 'Faltam 2h05');
  assert.equal(leftLabel(at(26 * 60 * MIN), 0, NOW), 'Faltam 1d 2h');
  assert.equal(leftLabel(at(-1), 0, NOW), 'Prazo encerrado');
});

test('a Central se reavalia ao entrar na última hora e no fim do prazo', () => {
  const closes = at(3 * 60 * MIN);
  assert.equal(nextVoteBoundary([closes], 0, NOW), NOW + 2 * 60 * MIN);
  assert.equal(nextVoteBoundary([at(30 * MIN)], 0, NOW), NOW + 30 * MIN);
  assert.equal(nextVoteBoundary([at(-MIN)], 0, NOW), null);
});

const h = (match: string | null, ovr: number | null, t: string) => ({ match_id: match, ovr_display: ovr, created_at: t });

test('variação positiva desde a última publicação', () => {
  const rows = [h('m2', 82, '2026-10-20T10:00:00Z'), h('m1', 80, '2026-10-13T10:00:00Z')];
  assert.equal(ovrDelta(82, rows), 2);
  assert.equal(deltaText(2), '+2');
});

test('variação negativa', () => {
  const rows = [h('m2', 77, '2026-10-20T10:00:00Z'), h('m1', 80, '2026-10-13T10:00:00Z')];
  assert.equal(ovrDelta(77, rows), -3);
  assert.equal(deltaText(-3), '−3');
  assert.match(deltaA11y(-3), /caiu 3 pontos/);
});

test('variação neutra', () => {
  const rows = [h('m2', 80, '2026-10-20T10:00:00Z'), h('m1', 80, '2026-10-13T10:00:00Z')];
  assert.equal(ovrDelta(80, rows), 0);
  assert.equal(deltaText(0), '0');
  assert.match(deltaA11y(0), /sem alteração/);
});

test('sem publicação anterior comparável: sem variação', () => {
  assert.equal(ovrDelta(80, []), null);
  assert.equal(ovrDelta(80, [h('m1', 80, '2026-10-13T10:00:00Z')]), null);
  // antes de 5 partidas não há OVR exibido: esses registros não contam
  assert.equal(ovrDelta(80, [h('m2', 80, '2026-10-20T10:00:00Z'), h('m1', null, '2026-10-13T10:00:00Z')]), null);
  // sem OVR atual, nada a comparar
  assert.equal(ovrDelta(null, [h('m2', 80, '2026-10-20T10:00:00Z'), h('m1', 78, '2026-10-13T10:00:00Z')]), null);
});

test('vários eventos da mesma partida contam pelo último; recálculos sem partida ficam fora', () => {
  const rows = [
    h(null, 81, '2026-10-21T10:00:00Z'), // recálculo geral
    h('m2', 82, '2026-10-20T12:00:00Z'), // votos publicados
    h('m2', 79, '2026-10-20T10:00:00Z'), // partida finalizada
    h('m1', 78, '2026-10-13T12:00:00Z'),
    h('m1', 76, '2026-10-13T10:00:00Z'),
  ];
  assert.equal(ovrDelta(81, rows), 3); // atual 81 contra 78 ao fim da partida anterior
});

test('nota da partida só depois da publicação', () => {
  const ok = { final_rating: 7.25, has_valid_rating: true };
  assert.deepEqual(matchRating({ played: true, result: ok, session: { status: 'published' }, legacyFinalized: false }), {
    kind: 'rated',
    value: 7.25,
  });
  assert.deepEqual(matchRating({ played: true, result: ok, session: { status: 'open' }, legacyFinalized: false }), { kind: 'pending' });
  assert.deepEqual(matchRating({ played: true, result: null, session: { status: 'awaiting_publication' }, legacyFinalized: false }), {
    kind: 'pending',
  });
  assert.deepEqual(matchRating({ played: true, result: ok, session: null, legacyFinalized: true }), { kind: 'rated', value: 7.25 });
});

test('avaliação insuficiente', () => {
  const none = { final_rating: null, has_valid_rating: false };
  assert.deepEqual(matchRating({ played: true, result: none, session: { status: 'published' }, legacyFinalized: false }), { kind: 'insufficient' });
  assert.deepEqual(matchRating({ played: true, result: none, session: null, legacyFinalized: true }), { kind: 'insufficient' });
});

test('quem não jogou não recebe nota; partida sem votação não mostra nota', () => {
  const ok = { final_rating: 8, has_valid_rating: true };
  assert.deepEqual(matchRating({ played: false, result: ok, session: { status: 'published' }, legacyFinalized: false }), { kind: 'none' });
  assert.deepEqual(matchRating({ played: true, result: null, session: null, legacyFinalized: false }), { kind: 'none' });
  assert.deepEqual(matchRating({ played: true, result: ok, session: { status: 'cancelled' }, legacyFinalized: false }), { kind: 'none' });
});

test('resultado pelo time do jogador', () => {
  assert.equal(resultOf('A', 3, 1), 'win');
  assert.equal(resultOf('B', 3, 1), 'loss');
  assert.equal(resultOf('B', 2, 2), 'draw');
});

test('seleção de pelada: guardada, senão principal, senão a primeira', () => {
  const ps = [
    { id: 'a', is_primary: false },
    { id: 'b', is_primary: true },
    { id: 'c', is_primary: false },
  ];
  assert.equal(pickPelada(ps, 'c')?.id, 'c');
  assert.equal(pickPelada(ps, 'saiu-da-pelada')?.id, 'b');
  assert.equal(pickPelada(ps, null)?.id, 'b');
  assert.equal(pickPelada([{ id: 'x' }], null)?.id, 'x');
  assert.equal(pickPelada([], 'a'), null);
});

test('isolamento: só itens da pelada escolhida', () => {
  const votes = [
    { pelada_id: 'a', match_id: '1' },
    { pelada_id: 'b', match_id: '2' },
    { pelada_id: 'a', match_id: '3' },
  ];
  assert.deepEqual(
    ofPelada(votes, 'a').map((v) => v.match_id),
    ['1', '3'],
  );
  assert.deepEqual(ofPelada(votes, null), []);
});
