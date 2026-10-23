// Confere as funções do motor em SQL (migração 051) contra a referência em JS (rating/engine.mjs),
// caso a caso, em entradas aleatórias reprodutíveis. node --test rating_sql.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PGlite } from '@electric-sql/pglite';
import { btree_gist } from '@electric-sql/pglite/contrib/btree_gist';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import * as E from './rating/engine.mjs';

const root = join(import.meta.dirname, '..');
let seed = 91;
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const int = (a, b) => a + Math.floor(rnd() * (b - a + 1));

async function db() {
  const d = await PGlite.create({ extensions: { pgcrypto, btree_gist } });
  await d.exec(readFileSync(join(import.meta.dirname, 'shim.sql'), 'utf8'));
  for (const f of readdirSync(join(root, 'migrations')).filter((f) => f.endsWith('.sql')).sort())
    await d.exec(readFileSync(join(root, 'migrations', f), 'utf8'));
  return d;
}

test('SQL = JS nas funções puras do motor', { timeout: 600000 }, async () => {
  const d = await db();
  const P = E.PARAMS;
  const params = (await d.query('select params from private.rating_params where version=1')).rows[0].params;
  const one = async (sql, args) => Number(Object.values((await d.query(sql, args)).rows[0])[0]);
  const close = (a, b, what) => assert.ok(Math.abs(a - b) < 1e-9, `${what}: SQL ${a} x JS ${b}`);
  let n = 0;
  for (let i = 0; i < 300; i++) {
    const q = int(0, 20) / 2;
    close(await one('select private.rating_atu_curve($1)', [q]), E.atuCurve(q), `curva ${q}`);
    const pos = ['ZAG', 'LAT', 'VOL', 'MEI', 'ATA', 'PON'][int(0, 5)];
    const N = int(0, 20); const g = int(0, 30); const a = int(0, 20); const c = int(0, 80);
    close(await one('select private.rating_off($1,$2,$3,$4,$5,$6)', [g, a, N, P.muG0[pos], P.muA0[pos], P.goalShare[pos]]),
      E.off(g, a, N, P.muG0[pos], P.muA0[pos], P.goalShare[pos]), `OFF ${pos} ${g}/${a}/${N}`);
    close(await one('select private.rating_def($1,$2,$3)', [c, N, P.muC0]), E.def(c, N, P.muC0), `DEF ${c}/${N}`);
    const dd = int(0, 25);
    close(await one('select private.rating_ref_match($1)', [dd]), E.refMatch(dd), `REF ${dd}`);
    const v = int(0, N); const e = int(0, N - v);
    const res = Array.from({ length: N }, (_, k) => (k < v ? 'win' : k < v + e ? 'draw' : 'loss'));
    close(await one('select private.rating_peq($1,$2,$3)', [v, e, N]), E.peq(res), `PEQ ${v}/${e}/${N}`);
    const A = int(0, N);
    close(await one('select private.rating_res($1,$2)', [A, N]), E.res(Array.from({ length: N }, (_, k) => k < A)), `RES ${A}/${N}`);
    const samples = Array.from({ length: int(0, 400) }, () => int(0, 3));
    const mu0 = P.muG0[pos];
    const trimmed = E.trimmedMean(samples, P.localTrim);
    close(await one('select private.rating_local_ref($1,$2,$3,$4)', [mu0, samples.length, trimmed, params]),
      E.localReference(mu0, samples), 'referência local');
    const rx = 65 + rnd() * 30;
    const win = Array.from({ length: N || 1 }, () => ({ goals: 0, assists: 0, conceded: 0, saves: null }));
    win[0].goals = g; win[0].assists = a; win[0].conceded = c;
    const refs = { muG: P.muG0, muA: P.muA0, muC: P.muC0 };
    if (pos !== 'GOL') close(await one('select private.rating_est($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)',
      [pos, g, a, c, win.length, rx, P.muG0[pos], P.muA0[pos], P.muC0, params]), E.est(pos, win, refs), `EST ${pos}`);
    n++;
  }
  assert.equal(await one("select private.rating_round(64.5)"), 65);
  assert.equal(await one("select private.rating_round(64.4999999)"), 64);
  for (const [code, sector, want] of [['LD', 'defender', 'LAT'], ['PE', 'attacker', 'PON'], ['CA', 'attacker', 'ATA'], [null, 'defender', 'ZAG'], [null, 'midfielder', 'MEI'], [null, 'attacker', 'ATA'], ['GOL', 'goalkeeper', 'GOL']])
    assert.equal((await d.query('select private.rating_position($1,$2) p', [code, sector])).rows[0].p, want);
  assert.equal(n, 300);
  await d.close();
});
