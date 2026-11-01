// Confere o núcleo V7.7 em SQL (migração 053, private.v77_*) contra a referência em JS (rating/v77.mjs), rodada a
// rodada, em carreiras aleatórias reprodutíveis, num PostgreSQL de verdade (PGlite) com todas as migrações.
// node --test rating_v77_sql.test.mjs
// Tolerância 1e-9: as duas implementações fazem as mesmas operações IEEE-754 na mesma ordem; só tanh/ln/exp vêm de
// bibliotecas matemáticas diferentes (libm do Postgres x V8), com diferença de no máximo 1 ulp por chamada.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { migratedDb } from './rating/testdb.mjs';
import * as E from './rating/v77.mjs';

let seed = 53;
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const int = (a, b) => a + Math.floor(rnd() * (b - a + 1));
const pick = (a) => a[int(0, a.length - 1)];
const TOL = 1e-9;

const randomEvent = () => {
  if (rnd() < 0.15) return { played: false };
  return {
    played: true, q: rnd() < 0.2 ? null : int(0, 20) / 2, goals: rnd() < 0.04 ? null : int(0, 4), assists: int(0, 3),
    conceded: rnd() < 0.04 ? null : int(0, 9), saves: rnd() < 0.25 ? null : int(0, 12), result: rnd() < 0.04 ? null : pick([0, 1 / 3, 1]),
    yellow: rnd() < 0.12 ? 1 : 0, red: rnd() < 0.03 ? 1 : 0, cardsKnown: rnd() < 0.9, resenha: pick([true, false, null, null]),
  };
};
function randomInput() {
  const position = pick(E.POSITIONS);
  const previousPosition = rnd() < 0.3 ? pick(E.POSITIONS) : null;
  return {
    position, previousPosition, transitionK: previousPosition ? int(0, 7) : null,
    seasons: Array.from({ length: int(1, 3) }, (_, i) => ({ seasonId: `00000000-0000-4000-8000-00000000000${i}`, events: Array.from({ length: int(1, 35) }, randomEvent) })),
  };
}

test('SQL = JS no núcleo V7.7 (funções puras, rodada a rodada e carreira completa)', { timeout: 900000 }, async () => {
  const d = await migratedDb();
  const p = (await d.query('select params from private.rating_params where version=2')).rows[0].params;
  const fv = (await d.query('select (private.rating_params_active()).formula_version fv')).rows[0].fv;
  assert.equal(fv, 3, 'V7.7 ativa');
  let maxDiff = 0;
  const close = (a, b, what) => {
    const diff = Math.abs(Number(a) - Number(b));
    maxDiff = Math.max(maxDiff, diff);
    assert.ok(diff <= TOL, `${what}: SQL ${a} x JS ${b}`);
  };
  const one = async (sql, args) => Object.values((await d.query(sql, args)).rows[0])[0];

  // Fórmulas isoladas
  for (let i = 0; i < 400; i++) {
    const pos = pick(E.POSITIONS.slice(1));
    const n = int(1, 40); const g = int(0, 40); const a = int(0, 30); const c = int(0, 200); const s = int(0, 300); const q = 40 + rnd() * 59;
    const gs = Array(n).fill(0); gs[0] = g; const as = Array(n).fill(0); as[0] = a;
    close(await one('select private.v77_let($1,$2,$3,$4,$5,$6)', [g, a, n, E.V77.muG[pos], E.V77.muA[pos], q]), E.letScore(gs, as, pos, q), `LET ${pos}`);
    const cs = Array(n).fill(0); cs[0] = c;
    close(await one('select private.v77_def($1,$2,$3,3)', [c, n, q]), E.defence(cs, q), 'DEF');
    const ss = Array(n).fill(0); ss[0] = s;
    close(await one('select private.v77_ref($1,$2,$3,3)', [s, n, q]), E.reflex(ss, q), 'REF');
    const wins = int(0, n); const rs = Array(n).fill(0).map((_, k) => (k < wins ? 1 : 0));
    close(await one('select private.v77_apr($1,$2,$3)', [wins, n, q]), E.apr(rs, q), 'APR');
    const qq = int(0, 20) / 2;
    close(await one('select private.v77_vote($1)', [qq]), E.vote(qq), 'vote');
    const cur = 50 + rnd() * 49; const y = int(0, 1); const r = int(0, 1);
    close(await one('select private.v77_step_dis($1,$2,$3,$4)', [cur, y, r, p.dis]), E.stepDis(cur, y, r), 'DIS');
    const yes = int(0, 8); const voters = int(0, 8);
    assert.equal(await one('select private.v77_resenha($1,$2)', [Math.min(yes, voters), voters]), E.resenhaOutcome(Math.min(yes, voters), voters));
  }
  assert.equal(await one('select private.v77_ref(0,0,80,3)', []), 70);

  // Rodada a rodada (uma temporada, com e sem herança)
  let rounds = 0;
  for (let i = 0; i < 150; i++) {
    const pos = pick(E.POSITIONS);
    const events = Array.from({ length: int(1, 40) }, randomEvent);
    const prev = rnd() < 0.5 ? null : { attrs: { DEF: 40 + rnd() * 59, SEC: 40 + rnd() * 59, APR: 40 + rnd() * 59, RES: 40 + rnd() * 59, DIS: 50 + rnd() * 49 }, evidence: { DEF: int(0, 30), SEC: int(0, 30), APR: int(0, 30) } };
    const before = int(0, 6);
    const js = E.evaluateSeason(events, pos, prev, before);
    const sql = await one('select private.v77_season($1::jsonb,$2,$3::jsonb,$4,$5::jsonb,true)', [JSON.stringify(events), pos, prev && JSON.stringify(prev), before, p]);
    assert.equal(sql.rows.length, js.rows.length);
    js.rows.forEach((r, k) => {
      for (const key of ['DEF', 'SEC', 'APR', 'RES', 'DIS', 'ovr']) close(sql.rows[k][key], r[key], `temporada ${i} rodada ${k + 1} ${key} (${pos})`);
      assert.equal(sql.rows[k].played, r.played);
      assert.equal(sql.rows[k].eligible, r.eligible);
      assert.deepEqual(sql.rows[k].evidence, r.evidence);
      rounds++;
    });
  }

  // Carreira completa com herança e transição de posição
  for (let i = 0; i < 250; i++) {
    const input = randomInput();
    const js = E.computeCareer(input);
    const sql = await one('select private.v77_career($1::jsonb,$2::jsonb)', [JSON.stringify(input), p]);
    assert.equal(sql.position, js.position); assert.equal(sql.secCode, js.secCode);
    assert.equal(sql.transitionK ?? null, js.transitionK); assert.equal(sql.previousPosition ?? null, js.previousPosition);
    assert.equal(sql.matchesPlayed, js.matchesPlayed);
    assert.equal(sql.seasons.length, js.seasons.length);
    js.seasons.forEach((s, k) => {
      const t = sql.seasons[k];
      assert.equal(t.played, s.played); assert.equal(t.careerPlayed, s.careerPlayed);
      if (!s.state) return assert.equal(t.state, null);
      for (const key of ['DEF', 'SEC', 'APR', 'RES', 'DIS', 'ovr']) close(t.state[key], s.state[key], `carreira ${i} temporada ${k} ${key}`);
      assert.equal(t.state.eligible, s.state.eligible);
      assert.equal(t.state.ovrDisplay ?? null, s.state.ovrDisplay, `carreira ${i} OVR exibido`);
    });
  }
  // Regressão obrigatória também no SQL.
  const striker = await one('select private.v77_season($1::jsonb,$2,null,0,$3::jsonb)', [JSON.stringify(Array(10).fill({ played: true, q: 9, goals: 1, assists: 0, conceded: 3, saves: 3, result: 1 / 3 })), 'ATA', p]);
  close(striker.last.SEC, 91.60479306925015, 'regressão LET 91,60');
  console.log(`# SQL x JS: 2.400 fórmulas, ${rounds} rodadas e 250 carreiras; maior diferença ${maxDiff.toExponential(2)}`);
  await d.close();
});
