// Motor V7.7 (formula_version 3): testes unitários, regressões congeladas e conferência contra o protótipo Python.
// node --test rating_v77.test.mjs   (precisa de python3 para a conferência com o protótipo)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as E from './rating/v77.mjs';

const P = E.V77;
const near = (a, b, eps = 1e-9, what = '') => assert.ok(Math.abs(a - b) <= eps, `${what} ${a} != ${b}`);
const mk = (o = {}) => ({ played: true, q: 8, goals: 0, assists: 0, conceded: 3, saves: 3, result: 1 / 3, yellow: 0, red: 0, resenha: null, ...o });
const season = (events, pos, prev = null, before = 0) => E.evaluateSeason(events, pos, prev, before);
const last = (r) => r.rows[r.rows.length - 1];
const rep = (n, o) => Array.from({ length: n }, () => mk(o));

let seed = 7791;
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const int = (a, b) => a + Math.floor(rnd() * (b - a + 1));
const pick = (a) => a[int(0, a.length - 1)];

// ---------------------------------------------------------------- pesos e escala
test('pesos posicionais congelados (DEF, LET/REF, APR, RES, DIS) somam 100%', () => {
  const want = { GOL: [40, 35, 10, 10, 5], ZAG: [45, 30, 10, 10, 5], LAT: [40, 35, 10, 10, 5], VOL: [35, 40, 10, 10, 5], MEI: [25, 50, 10, 10, 5], ATA: [20, 55, 10, 10, 5], PON: [20, 55, 10, 10, 5] };
  for (const pos of E.POSITIONS) {
    assert.deepEqual(P.weights[pos].map((w) => Math.round(w * 100)), want[pos], pos);
    near(P.weights[pos].reduce((a, b) => a + b, 0), 1, 1e-12, pos);
  }
  assert.equal(E.secCode('GOL'), 'REF');
  for (const pos of E.POSITIONS.slice(1)) assert.equal(E.secCode(pos), 'LET');
});

test('referências V7.5 inalteradas (sem curva LET V7.9)', () => {
  assert.deepEqual({ ...P.muG }, { ZAG: 0.1, LAT: 0.15, VOL: 0.2, MEI: 0.4, ATA: 0.7, PON: 0.7 });
  assert.deepEqual({ ...P.muA }, { ZAG: 0.1, LAT: 0.2, VOL: 0.25, MEI: 0.4, ATA: 0.3, PON: 0.3 });
  assert.equal(P.defMu, 3);
  assert.equal(P.refMu, 3);
});

test('vote: curva da nota 0-10 para 40-99', () => {
  near(E.vote(7), 68); near(E.vote(8), 80); near(E.vote(9), 91); near(E.vote(10), 99); near(E.vote(0), 40); near(E.vote(4), 40);
  let prev = -1;
  for (let q = 0; q <= 10; q += 0.5) { const v = E.vote(q); assert.ok(v >= prev && v >= 40 && v <= 99); prev = v; }
});

test('fórmulas: limites 40-99, monotonia e ausência de NaN', () => {
  for (const pos of E.POSITIONS.slice(1)) {
    let prev = -1;
    for (let g = 0; g <= 30; g++) {
      const v = E.letScore(Array(10).fill(0).map((_, i) => (i === 0 ? g : 0)), Array(10).fill(0), pos, 70);
      assert.ok(Number.isFinite(v) && v >= 40 && v <= 99 && v >= prev, `${pos} ${g}`); prev = v;
    }
  }
  let prev = 100;
  for (let c = 0; c <= 80; c++) { const v = E.defence([c, 3, 3], 70); assert.ok(v <= prev && v >= 40 && v <= 99); prev = v; }
  prev = -1;
  for (let d = 0; d <= 30; d++) { const v = E.reflex([d], 70); assert.ok(v >= prev && v >= 40 && v <= 99); prev = v; }
  assert.equal(E.reflex([null, undefined], 80), 70);
  near(E.reflex([5, null, 5], 80), E.reflex([5, 5], 80), 0, 'defesa ausente não vira zero');
  assert.ok(E.reflex([5, 0], 80) < E.reflex([5], 80), 'zero defesas é observação real');
  prev = -1;
  for (let v = 0; v <= 10; v++) { const x = E.apr([...Array(v).fill(1), ...Array(10 - v).fill(0)], 70); assert.ok(x > prev); prev = x; }
});

// ---------------------------------------------------------------- regressão obrigatória
test('regressão: atacante, 10 gols em 10 partidas, nota 9,0 => LET 91,60 (protótipo 91.60479306925015)', () => {
  const r = season(rep(10, { goals: 1, q: 9 }), 'ATA');
  near(last(r).SEC, 91.60479306925015, 1e-9, 'LET');
  assert.ok(last(r).SEC > 90);
});

// ---------------------------------------------------------------- elegibilidade
test('OVR publicado só a partir da 5ª partida oficial, sem salto na elegibilidade', () => {
  const r = season(rep(6, {}), 'ATA');
  assert.deepEqual(r.rows.map((x) => x.eligible), [false, false, false, false, true, true]);
  const c = E.computeCareer({ position: 'ATA', seasons: [{ seasonId: 's', events: rep(4, {}) }] });
  assert.equal(c.current.ovrDisplay, null); assert.equal(c.current.eligible, false);
  const c5 = E.computeCareer({ position: 'ATA', seasons: [{ seasonId: 's', events: rep(5, {}) }] });
  assert.equal(c5.current.ovrDisplay, E.roundDisplay(c5.current.ovr));
  // D2: veterano não volta a "em avaliação" na temporada nova.
  const c2 = E.computeCareer({ position: 'ATA', seasons: [{ seasonId: 'a', events: rep(5, {}) }, { seasonId: 'b', events: rep(1, {}) }] });
  assert.equal(c2.seasons[1].state.eligible, true);
  const c3 = E.computeCareer({ position: 'ATA', seasons: [{ seasonId: 'a', events: rep(3, {}) }, { seasonId: 'b', events: rep(2, {}) }] });
  assert.equal(c3.seasons[0].state.eligible, false); assert.equal(c3.seasons[1].state.eligible, true);
});

// ---------------------------------------------------------------- ausência e nulos
test('ausência não muda DEF/LET/APR nem DIS; reduz a frequência do RES', () => {
  const a = last(season([...rep(5, { yellow: 1 }), mk({ played: false })], 'ATA'));
  const b = last(season(rep(5, { yellow: 1 }), 'ATA'));
  for (const k of ['DEF', 'SEC', 'APR', 'DIS']) near(a[k], b[k], 0, k);
  assert.ok(a.RES < b.RES);
});

test('estatística ausente preserva o atributo; zero é observação', () => {
  const base = rep(6, { saves: 4, q: 7 });
  near(last(season([...base, mk({ saves: null, q: 10 })], 'GOL')).SEC, last(season(base, 'GOL')).SEC, 0, 'REF');
  const b2 = rep(6, { result: 1, q: 7 });
  near(last(season([...b2, mk({ result: null, q: 10 })], 'ATA')).APR, last(season(b2, 'ATA')).APR, 0, 'APR');
  const b3 = rep(6, { goals: 1 });
  near(last(season([...b3, mk({ goals: null })], 'ATA')).SEC, last(season(b3, 'ATA')).SEC, 0, 'LET sem súmula');
  near(last(season([...b3, mk({ conceded: null })], 'ATA')).DEF, last(season(b3, 'ATA')).DEF, 0, 'DEF');
  assert.ok(last(season([...rep(5, { saves: 5 }), mk({ saves: 0 })], 'GOL')).SEC < last(season(rep(5, { saves: 5 }), 'GOL')).SEC);
  // Nota ausente não é zero: só não entra na média.
  near(last(season([mk({ q: 9 }), mk({ q: null })], 'ATA')).RES, last(season([mk({ q: 9 }), mk({ q: 9 })], 'ATA')).RES, 1e-9);
  // Goleiro sem nenhuma defesa registrada: REF neutro 70.
  assert.equal(last(season(rep(5, { saves: null }), 'GOL')).SEC, 70);
});

// ---------------------------------------------------------------- checkpoint
test('checkpoint: janela real de 10, quedas amortecidas, melhoria sem limite, RES/DIS sem checkpoint', () => {
  const s = new E.Smoother();
  s.update(80);
  for (let i = 0; i < 20; i++) s.update(80 - i);
  assert.equal(s.recent.length, 10);
  const up = new E.Smoother(60);
  assert.equal(up.update(95), 95, 'melhoria aceita na hora, sem teto artificial');
  const down = new E.Smoother(90);
  const v = down.update(60);
  assert.ok(v < 90 && v > 60, 'queda amortecida');
  near(v, 90 + 0.3 * (60 - 90), 1e-12, 'primeira queda: alfa 0,30 (delta 0 na janela)');
  const path = season([...rep(10, { goals: 1, q: 9 }), ...rep(20, { goals: 0, q: 7 })], 'ATA').rows;
  assert.ok(path[29].SEC < path[9].SEC, 'não congela');
  // DIS cai na hora (sem checkpoint)
  near(last(season([...rep(5, {}), mk({ yellow: 1 })], 'ATA')).DIS, last(season(rep(5, {}), 'ATA')).DIS - 8, 1e-9);
});

// ---------------------------------------------------------------- DIS
test('DIS: 70, -8, -20, recuperação 6% até 99, piso 50, teto 99, igual para todas as posições', () => {
  near(E.stepDis(70), 70 + 0.06 * 29); assert.equal(E.stepDis(70, 1, 0), 62); assert.equal(E.stepDis(70, 0, 1), 50);
  assert.equal(E.stepDis(55, 1, 1), 50); assert.equal(E.stepDis(50, 0, 1), 50);
  let d = 50; for (let i = 0; i < 500; i++) { const n = E.stepDis(d); assert.ok(n > d || n === 99); assert.ok(n <= 99); d = n; }
  const seq = [mk({ yellow: 1 }), mk({}), mk({ red: 1 }), mk({})];
  const vals = E.POSITIONS.map((p) => last(season(seq, p)).DIS);
  for (const v of vals) near(v, vals[0], 0);
  near(vals[0], E.stepDis(E.stepDis(E.stepDis(E.stepDis(70, 1), 0), 0, 1), 0));
  // Registro ausente (pendente / pelada sem cartões) não recupera.
  assert.equal(last(season(rep(5, { cardsKnown: false }), 'ATA')).DIS, 70);
});

test('cartões: segundo amarelo = uma expulsão, sem contar o amarelo de novo', () => {
  assert.deepEqual(E.normalizeCards({ secondYellow: 1 }), { yellow: 0, red: 1 });
  assert.deepEqual(E.normalizeCards({ yellowCard: 1, secondYellow: 1 }), { yellow: 0, red: 1 });
  assert.deepEqual(E.normalizeCards({ yellowCard: 1, redCard: 1 }), { yellow: 1, red: 1 });
  assert.deepEqual(E.normalizeCards({ redCard: 3 }), { yellow: 0, red: 1 });
  assert.deepEqual(E.normalizeCards({ redCard: 1, secondYellow: 1 }), { yellow: 0, red: 1 });
  assert.deepEqual(E.normalizeCards({}), { yellow: 0, red: 0 });
});

test('DIS: continuidade entre temporadas', () => {
  const c = E.computeCareer({ position: 'ATA', seasons: [{ seasonId: 'a', events: rep(6, { yellow: 1 }) }, { seasonId: 'b', events: [mk({})] }] });
  near(c.seasons[1].state.DIS, E.stepDis(c.seasons[0].state.DIS), 1e-12);
});

// ---------------------------------------------------------------- resenha
test('resenha: autovoto, duas confirmações, maioria estrita, 1 eleitor indeterminado, falta de resposta neutra', () => {
  const f = E.resenhaFromVotes;
  assert.equal(f({ a: true, b: true }, 'self'), true);
  assert.equal(f({ a: true, b: false }, 'self'), false);
  assert.equal(f({ a: true }, 'self'), null);
  assert.equal(f({ self: true, a: true, b: false }, 'self'), false);
  assert.equal(f({ a: true, b: true, c: false }, 'self'), true);
  assert.equal(f({ a: true, b: true, c: false, d: false }, 'self'), false);
  assert.equal(f({ a: true, b: null }, 'self'), null);
  assert.equal(f(null, 'self'), null);
  assert.equal(E.resenhaOutcome(1, 1), null);
  assert.equal(E.resenhaOutcome(2, 2), true);
  assert.equal(E.resenhaOutcome(1, 2), false);
  assert.equal(E.resenhaOutcome(2, 3), true);
  assert.equal(E.resenhaOutcome(2, 4), false);
  assert.equal(E.resenhaOutcome(3, 5), true);
  assert.equal(E.resenhaOutcome(0, 0), null);
  // Sem resposta (null) não derruba o RES: igual a não ter a pergunta.
  near(last(season([...rep(5, { resenha: true }), mk({ resenha: null })], 'ATA')).RES,
    last(season([...rep(5, { resenha: true }), mk({ resenha: true })], 'ATA')).RES - 0, 5, 'sanidade');
  assert.ok(last(season([...rep(5, { resenha: true }), mk({ resenha: null })], 'ATA')).RES >
    last(season([...rep(5, { resenha: true }), mk({ resenha: false })], 'ATA')).RES);
  // 60% frequência, 40% resenha
  const r = last(season(rep(4, { resenha: true, q: 7 }), 'ATA'));
  near(r.RES, E.clip(0.95 * (0.6 * (40 + 59 * (6 / 8)) + 0.4 * (40 + 59 * (6 / 8))) + 0.05 * 68), 1e-9);
});

// ---------------------------------------------------------------- temporadas
test('herança: 50% das observações válidas, teto de 20; publicado não é dividido pela metade', () => {
  const s1 = E.computeCareer({ position: 'ATA', seasons: [{ events: rep(20, { goals: 1 }) }] });
  const c = E.evaluateCareer([{ events: rep(20, { goals: 1 }) }, { events: rep(5, { goals: 0, q: 7 }) }], 'ATA');
  assert.equal(c[0].prev.evidence.SEC, 20, 'evidência herdada');
  const fresh = last(season(rep(5, { goals: 0, q: 7 }), 'ATA'));
  const carried = c[1].last;
  assert.ok(carried.SEC > fresh.SEC, 'herança pesa');
  assert.ok(c[1].rows[0].SEC > s1.current.SEC * 0.5 + 10, 'não divide pela metade');
  // força = 0,5 * min(20, n): 30 partidas valem o mesmo que 20.
  const attrs = { DEF: 80, SEC: 90, APR: 75, RES: 70, DIS: 80 };
  const ev = rep(5, { goals: 0, q: 7 });
  const at = (n) => last(season(ev, 'ATA', { attrs, evidence: { DEF: n, SEC: n, APR: n } }));
  near(at(30).SEC, at(20).SEC, 0, 'teto de 20 observações');
  assert.ok(at(6).SEC < at(20).SEC, 'menos evidência herdada pesa menos');
  // força 0,5 * 6 = 3 observações equivalentes: confere o primeiro valor bruto à mão.
  const raw = E.letScore([0], [0], 'ATA', E.vote(7));
  near(season([mk({ goals: 0, q: 7 })], 'ATA', { attrs, evidence: { DEF: 6, SEC: 6, APR: 6 } }).rows[0].SEC,
    90 + 0.3 * ((3 * 90 + 1 * raw) / 4 - 90), 1e-9, 'prior 3 + 1 observação, depois o checkpoint');
  // Temporada inteira sem jogar não apaga a herança (D4).
  const skip = E.evaluateCareer([{ events: rep(10, { goals: 1 }) }, { events: [mk({ played: false })] }, { events: rep(2, { goals: 0 }) }], 'ATA');
  assert.equal(skip[1].prev.evidence.SEC, 10, 'herança atravessa a temporada sem jogos');
});

// ---------------------------------------------------------------- posição
test('transição de posição em 5 partidas (OVR), atributos da posição nova', () => {
  const events = rep(8, { goals: 1, saves: 2 });
  const zag = E.computeCareer({ position: 'ZAG', seasons: [{ events }] });
  const ata = E.computeCareer({ position: 'ATA', seasons: [{ events }] });
  for (let k = 0; k <= 6; k++) {
    const t = E.computeCareer({ position: 'ATA', previousPosition: 'ZAG', transitionK: k, seasons: [{ events }] });
    const w = Math.min(1, k / 5);
    near(t.current.ovr, w * ata.current.ovr + (1 - w) * zag.current.ovr, 1e-9, `k=${k}`);
    near(t.current.SEC, ata.current.SEC, 0);
    assert.equal(t.transitionK, k < 5 ? k : null);
  }
  const gk = E.computeCareer({ position: 'GOL', previousPosition: 'ATA', transitionK: 2, seasons: [{ events }] });
  assert.equal(gk.secCode, 'REF');
});

// ---------------------------------------------------------------- correção retroativa / determinismo
test('replay determinístico; correção e anulação retroativas mudam o resultado', () => {
  const evs = rep(8, { goals: 1 });
  assert.deepEqual(season(evs, 'ATA'), season(evs, 'ATA'));
  const fixed = [mk({ goals: 0 }), ...evs.slice(1)];
  assert.notEqual(last(season(fixed, 'ATA')).SEC, last(season(evs, 'ATA')).SEC);
  const annulled = evs.slice(1);
  assert.equal(last(season(annulled, 'ATA')).played, 7);
});

test('limites: atributos e OVR sempre entre 40 e 99, DIS entre 50 e 99', () => {
  for (let i = 0; i < 300; i++) {
    const pos = pick(E.POSITIONS);
    const evs = Array.from({ length: int(1, 40) }, () => mk({ played: rnd() < 0.85, q: rnd() < 0.2 ? null : int(0, 20) / 2, goals: int(0, 6), assists: int(0, 4), conceded: int(0, 12), saves: rnd() < 0.2 ? null : int(0, 15), result: pick([0, 1 / 3, 1, null]), yellow: rnd() < 0.15 ? 1 : 0, red: rnd() < 0.05 ? 1 : 0, resenha: pick([true, false, null]) }));
    for (const r of season(evs, pos).rows) {
      for (const k of ['DEF', 'SEC', 'APR', 'RES', 'ovr']) assert.ok(r[k] >= 40 && r[k] <= 99, `${k}=${r[k]}`);
      assert.ok(r.DIS >= 50 && r.DIS <= 99);
    }
  }
});

// ---------------------------------------------------------------- protótipo Python
function randomCase() {
  const position = pick(E.POSITIONS);
  const seasons = Array.from({ length: int(1, 3) }, () =>
    Array.from({ length: int(1, 30) }, () => {
      const played = rnd() < 0.85;
      if (!played) return { played: false };
      const votes = rnd() < 0.25 ? null : Object.fromEntries(Array.from({ length: int(0, 6) }, (_, j) => [j === 0 && rnd() < 0.2 ? 'self' : `v${j}`, rnd() < 0.1 ? null : rnd() < 0.6]));
      return {
        played: true, q: rnd() < 0.2 ? null : int(0, 20) / 2, goals: rnd() < 0.05 ? null : int(0, 4), assists: int(0, 3),
        conceded: rnd() < 0.05 ? null : int(0, 9), saves: rnd() < 0.2 ? null : int(0, 12), result: rnd() < 0.05 ? null : pick([0, 1 / 3, 1]),
        yellow: rnd() < 0.12 ? 1 : 0, red: rnd() < 0.03 ? 1 : 0, resenha_votes: votes,
      };
    }),
  );
  return { position, seasons };
}

test('JS = protótipo Python V7.7 (800 carreiras aleatórias, até 3 temporadas) e 21/21 checagens do protótipo', { timeout: 300000 }, () => {
  const cases = Array.from({ length: 800 }, randomCase);
  const dir = mkdtempSync(join(tmpdir(), 'm91-v77-'));
  writeFileSync(join(dir, 'cases.json'), JSON.stringify(cases));
  const out = JSON.parse(execFileSync('python3', ['-I', join(import.meta.dirname, 'rating/v77_reference/run_cases.py'), join(dir, 'cases.json')], { maxBuffer: 1 << 30 }).toString());
  assert.equal(Object.values(out.checks).filter(Boolean).length, 21, JSON.stringify(out.checks));
  near(out.striker_let, 91.60479306925015, 0);
  const expected = JSON.parse(readFileSync(join(import.meta.dirname, 'rating/v77_reference/v77_validation.json'), 'utf8'));
  near(out.striker_let, expected.striker_let, 0);
  let maxDiff = 0;
  let rows = 0;
  cases.forEach((c, i) => {
    const js = E.evaluateCareer(c.seasons.map((s) => ({ events: s.map((e) => ({ ...e, resenha: e.played ? E.resenhaFromVotes(e.resenha_votes, 'self') : null })) })), c.position);
    out.results[i].forEach((pyRows, si) => {
      pyRows.forEach((py, ri) => {
        const r = js[si].rows[ri];
        for (const [a, b] of [['DEF', 'DEF'], ['SEC', 'SECOND'], ['APR', 'APR'], ['RES', 'RES'], ['DIS', 'DIS'], ['ovr', 'internal_ovr']]) {
          const d = Math.abs(r[a] - py[b]);
          maxDiff = Math.max(maxDiff, d);
          assert.ok(d < 1e-9, `caso ${i} temporada ${si} rodada ${ri + 1} ${a}: JS ${r[a]} x Python ${py[b]}`);
        }
        assert.equal(r.played, py.played_games);
        assert.deepEqual(r.evidence, { DEF: py.evidence.DEF, SEC: py.evidence.SECOND, APR: py.evidence.APR });
        rows++;
      });
    });
  });
  console.log(`# JS x Python: ${rows} rodadas comparadas, maior diferença ${maxDiff.toExponential(2)}`);
});
