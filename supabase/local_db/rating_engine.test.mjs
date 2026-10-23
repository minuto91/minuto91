// Testes matemáticos do motor v2 (Prompt Master v2.0, Etapa 23.1-23.3). node --test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as E from './rating/engine.mjs';

const P = E.PARAMS;
const near = (a, b, eps = 1e-9) => assert.ok(Math.abs(a - b) < eps, `${a} != ${b}`);
const finite = (x) => assert.ok(Number.isFinite(x), `não finito: ${x}`);
const refs = { muG: P.muG0, muA: P.muA0, muC: P.muC0 };
const POS = ['GOL', 'ZAG', 'LAT', 'VOL', 'MEI', 'ATA', 'PON'];
const mk = (n, f = () => ({})) =>
  Array.from({ length: n }, (_, i) => ({ q: null, goals: 0, assists: 0, conceded: 3, result: 'draw', saves: null, discipline: 'confirmed', yellow: 0, red: 0, ...f(i) }));
const player = (matches, extra = {}) => E.computeRating({ matches, rounds: matches.map(() => true), position: 'MEI', refs, cardsTracking: true, ...extra });

test('pesos somam 100% e fórmula expandida do goleiro é equivalente', () => {
  near(Object.values(P.weights).reduce((a, b) => a + b, 0), 1);
  for (let i = 0; i < 200; i++) {
    const [ATU, REF, DEF, PEQ, RES, DIS] = Array.from({ length: 6 }, () => Math.random() * 99);
    const EST = 0.7 * REF + 0.3 * DEF;
    const expanded = 0.3325 * ATU + 0.23275 * REF + 0.09975 * DEF + 0.19 * PEQ + 0.095 * RES + 0.05 * DIS;
    near(E.ovr({ ATU, EST, PEQ, RES, DIS }), expanded, 1e-9);
  }
});

test('interpolação da nota', () => {
  const pts = [[0, 0], [2.5, 25], [5, 50], [5.5, 54], [6, 58], [6.5, 63], [7, 68], [7.5, 74], [8, 80], [8.5, 85.5], [9, 91], [9.5, 95], [10, 99]];
  for (const [q, v] of pts) near(E.atuCurve(q), v);
});

test('nota da partida: 50/50 entre grupos, sem nota fictícia', () => {
  near(E.matchScore([10, 10, 10, 10], [6]), 8);
  near(E.matchScore([6], [10, 10, 10]), 8);
  assert.equal(E.matchScore([8], []), null);
  assert.equal(E.matchScore([], [8]), null);
  near(E.matchScore([0], [10]), 5);
});

test('ATU: neutro sem votos, partidas sem voto contam em J', () => {
  assert.equal(E.atu([]), 70);
  assert.equal(E.atu([null, null, null]), 70);
  near(E.atu([9]), 70 + 21 / 3);
  near(E.atu([9, null, null, null]), 70 + 21 / (1 + 2 + 0.25 * 3));
  near(E.atu(Array(25).fill(10)), 70 + (20 * 29) / 22);
  assert.ok(E.atu(Array(20).fill(0)) >= 0);
});

test('OFF/DEF: neutro na referência, monotonicidade, sem NaN', () => {
  for (const pos of POS.filter((p) => p !== 'GOL')) {
    near(E.off(P.muG0[pos] * 10, P.muA0[pos] * 10, 10, P.muG0[pos], P.muA0[pos], P.goalShare[pos]), 70);
    let prev = -1;
    for (let g = 0; g <= 30; g++) {
      const v = E.off(g, 0, 10, P.muG0[pos], P.muA0[pos], P.goalShare[pos]);
      finite(v);
      assert.ok(v > prev && v > 50 && v < 99);
      prev = v;
    }
  }
  near(E.def(30, 10, 3), 70);
  let prev = 100;
  for (let c = 0; c <= 100; c++) {
    const v = E.def(c, 10, 3);
    finite(v);
    assert.ok(v < prev && v > 50 && v < 99, `DEF ${c} -> ${v}`);
    prev = v;
  }
  finite(E.def(0, 0, 3));
  near(E.def(0, 0, 3), 70);
});

test('REF: valores de referência, crescente, neutro sem registro, estabilização C4', () => {
  near(E.refMatch(0), 65); near(E.refMatch(1), 68); near(E.refMatch(5), 80);
  assert.equal(E.refMatch(10).toFixed(1), '93.6');
  assert.equal(E.refMatch(20).toFixed(1), '98.6');
  for (let d = 0; d < 40; d++) assert.ok(E.refMatch(d + 1) > E.refMatch(d));
  assert.equal(E.ref([null, null]), 65);
  near(E.ref([5]), 68.75);
  near(E.ref([5, 5, 5, 5, 5]), 65 + (5 / 8) * 15);
  near(E.ref([0, null]), 65); // zero registrado = 65, ausente não vira zero
  // Pesos 11..30: a recente pesa mais.
  assert.ok(E.ref([0, 10]) > E.ref([10, 0]));
});

test('PEQ e RES: monotonia com N fixo, neutros sem dados', () => {
  assert.equal(E.peq([]), 70); assert.equal(E.res([]), 70);
  const N = 10;
  let prev = -1;
  for (let v = 0; v <= N; v++) {
    const x = E.peq([...Array(v).fill('win'), ...Array(N - v).fill('loss')]);
    assert.ok(x > prev); prev = x;
  }
  near(E.peq(Array(10).fill('draw')), 70 + 35 * (-1 / 3) * (10 / 14)); // empate rende 1/3 dos pontos
  near(E.peq(['win', 'loss']), 70);
  assert.equal(E.peq(Array(20).fill('win')), 99); // 99,17 limitado a 99
  prev = -Infinity;
  for (let a = 0; a <= N; a++) {
    const x = E.res([...Array(a).fill(true), ...Array(N - a).fill(false)]);
    assert.ok(x > prev); prev = x;
  }
  near(E.res(Array(20).fill(true)), 70 + 600 / 24);
});

test('DIS: amarelo, vermelho, recuperação, limites, desativado = 70, pendente não é limpo', () => {
  const m = (y, r, discipline = 'confirmed') => ({ discipline, yellow: y, red: r });
  assert.equal(E.dis([m(1, 0), m(0, 1)], false), 70);
  near(E.dis([m(0, 0)], true), 70 + 0.06 * 29);
  assert.equal(E.dis([m(1, 0)], true), 62);
  assert.equal(E.dis([m(0, 1)], true), 50);
  assert.ok(E.dis([m(0, 1)], true) < E.dis([m(1, 0)], true));
  assert.equal(E.dis([m(0, 1), m(0, 1), m(1, 0)], true), 50);
  assert.equal(E.dis([m(0, 0, 'pending')], true), 70);
  assert.equal(E.dis([m(0, 0, 'not_tracked')], true), 70);
  let prev = 50;
  const seq = [m(0, 1)];
  for (let i = 0; i < 200; i++) {
    seq.push(m(0, 0));
    const x = E.dis(seq, true);
    assert.ok(x > prev && x <= 99); prev = x;
  }
  // segundo amarelo chega como um único vermelho
  assert.equal(E.dis([m(0, 1)], true), 50);
});

test('históricos de 0, 1, 4, 5, 20 e 25 partidas; elegibilidade aos 5 jogos', () => {
  for (const n of [0, 1, 4, 5, 20, 25]) {
    const r = player(mk(n));
    for (const k of ['ATU', 'EST', 'PEQ', 'RES', 'DIS', 'OVR']) { finite(r[k]); assert.ok(r[k] >= 0 && r[k] <= 99); }
    assert.equal(r.eligible, n >= 5);
    assert.equal(r.ovrDisplay === null, n < 5);
  }
  // Jogador neutro em tudo => OVR ~70.
  const r = player(mk(10, () => ({ goals: 0.4, assists: 0.4 })), { cardsTracking: false });
  assert.ok(Math.abs(r.OVR - 70) < 1.5, String(r.OVR));
});

test('goleiro: EST = 0,7 REF + 0,3 DEF, sem GAR', () => {
  const win = mk(10, () => ({ saves: 5 }));
  const r = player(win, { position: 'GOL' });
  near(r.EST, 0.7 * E.ref(win.map((x) => x.saves)) + 0.3 * E.def(30, 10, 3));
  assert.ok(!('GAR' in r));
  for (const d of [0, 1, 5, 10, 20]) finite(player(mk(10, () => ({ saves: d })), { position: 'GOL' }).EST);
});

test('transição de posição: EST interpola em 5 partidas, outros atributos intactos', () => {
  const ms = mk(10, () => ({ goals: 1, assists: 0 }));
  const a = player(ms, { position: 'ZAG' });
  const b = player(ms, { position: 'ATA' });
  for (let k = 0; k <= 5; k++) {
    const t = player(ms, { position: 'ATA', previousPosition: 'ZAG', matchesSinceChange: k });
    near(t.EST, (k / 5) * b.EST + (1 - k / 5) * a.EST);
    near(t.ATU, a.ATU); near(t.PEQ, a.PEQ); near(t.RES, a.RES); near(t.DIS, a.DIS);
  }
});

test('referência local híbrida', () => {
  near(E.localReference(0.4, []), 0.4);
  near(E.localReference(0.4, Array(150).fill(0.8)), 0.6);
  near(E.localReference(0.4, Array(100000).fill(0.8)), 0.6); // alfa limitado a 0,5
  assert.equal(E.localReference(0.1, Array(1000).fill(0)), 0.05); // piso
  near(E.trimmedMean([0, 1, 1, 1, 1, 1, 1, 1, 1, 100], 0.1), 1);
});

test('arredondamento: empate 0,5 para cima e faixas', () => {
  assert.equal(E.roundDisplay(64.5), 65); assert.equal(E.roundDisplay(64.4999), 64);
  assert.equal(E.tier(64), 'bronze'); assert.equal(E.tier(65), 'prata'); assert.equal(E.tier(80), 'ouro'); assert.equal(E.tier(null), null);
});
