// V8.5 (061): verificação independente do sorteio exato (REV-31/32/33/42/43, LAC-02).
//  1) força bruta: em casos pequenos aleatórios, enumera TODAS as 2^n divisões e confere custo ótimo e contagem;
//  2) bijeção: decodifica todos os índices [0, total) e confere que geram exatamente o conjunto ótimo, sem repetição;
//  3) uniformidade: qui-quadrado das composições sorteadas com aleatoriedade segura;
//  4) limite de 100 participantes, grupos vazios, capitães e total ímpar.
// node --test draw_exact.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PGlite } from '@electric-sql/pglite';
import { btree_gist } from '@electric-sql/pglite/contrib/btree_gist';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = join(import.meta.dirname, '..');
let seed = 85;
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const int = (a, b) => a + Math.floor(rnd() * (b - a + 1));
const GROUPS = ['GOL', 'ZAG', 'LD', 'LE', 'VOL', 'MEI', 'ATA', 'none'];

let d;
async function db() {
  if (d) return d;
  d = await PGlite.create({ extensions: { pgcrypto, btree_gist } });
  await d.exec(readFileSync(join(import.meta.dirname, 'shim.sql'), 'utf8'));
  for (const f of readdirSync(join(root, 'migrations')).filter((f) => f.endsWith('.sql')).sort())
    await d.exec(readFileSync(join(root, 'migrations', f), 'utf8'));
  return d;
}
const solve = async (g, f, r = null) =>
  (await (await db()).query('select private.draw_solve($1::text[], $2::text[], $3::numeric) v', [g, f, r])).rows[0].v;

function costOf(g, t) {
  const m = new Map();
  g.forEach((k, i) => { const c = m.get(k) ?? [0, 0]; c[t[i] === 'A' ? 0 : 1]++; m.set(k, c); });
  let s = 0; for (const [a, b] of m.values()) s += Math.abs(a - b); return s;
}
function brute(g, f) {
  const n = g.length; let best = Infinity; const all = [];
  for (let mask = 0; mask < 1 << n; mask++) {
    const t = Array.from({ length: n }, (_, i) => (mask >> i) & 1 ? 'A' : 'B');
    const na = t.filter((x) => x === 'A').length;
    if (Math.abs(2 * na - n) > 1) continue;
    if (f && f.some((x, i) => x && x !== t[i])) continue;
    const c = costOf(g, t);
    if (c < best) { best = c; all.length = 0; }
    if (c === best) all.push(t.join(''));
  }
  return { best, all };
}
function randomCase(maxN) {
  const n = int(2, maxN);
  const used = GROUPS.slice(0, int(1, GROUPS.length));
  const g = Array.from({ length: n }, () => used[int(0, used.length - 1)]).sort(
    (a, b) => GROUPS.indexOf(a) - GROUPS.indexOf(b));
  let f = null;
  if (rnd() < 0.5 && n >= 2) {
    f = Array(n).fill(null); const a = int(0, n - 1); let b = int(0, n - 1); while (b === a) b = int(0, n - 1);
    f[a] = 'A'; f[b] = 'B';
  }
  return { g, f };
}

test('ótimo e contagem exatos = força bruta (300 casos, n ≤ 12)', { timeout: 600000 }, async () => {
  for (let i = 0; i < 300; i++) {
    const { g, f } = randomCase(12);
    const v = await solve(g, f);
    const b = brute(g, f);
    assert.equal(v.cost, b.best, `custo ${JSON.stringify({ g, f })}`);
    assert.equal(BigInt(v.count), BigInt(b.all.length), `contagem ${JSON.stringify({ g, f })}`);
  }
});

test('decodificação é bijeção sobre o conjunto ótimo (80 casos, n ≤ 10)', { timeout: 600000 }, async () => {
  for (let i = 0; i < 80; i++) {
    const { g, f } = randomCase(10);
    const b = brute(g, f);
    const seen = new Set();
    for (let r = 0; r < b.all.length; r++) {
      const v = await solve(g, f, String(r));
      const t = v.teams.join('');
      assert.ok(b.all.includes(t), `índice ${r} gerou composição não ótima ${t}`);
      assert.ok(!seen.has(t), `índice ${r} repetiu ${t}`);
      seen.add(t);
    }
    assert.equal(seen.size, b.all.length);
    await assert.rejects(solve(g, f, String(b.all.length)), /DRAW_INVALID_RANK/);
  }
});

test('uniformidade estatística (qui-quadrado) com aleatoriedade segura', { timeout: 600000 }, async () => {
  const conn = await db();
  // 7 participantes (total ímpar, as duas orientações), 3 grupos: GOL×1, ZAG×3, ATA×3.
  const g = ['GOL', 'ZAG', 'ZAG', 'ZAG', 'ATA', 'ATA', 'ATA'];
  const b = brute(g, null);
  const N = 6000;
  const rows = (await conn.query(
    `select private.draw_sample($1::text[], null)->'teams' t from generate_series(1, ${N})`, [g])).rows
    .map(({ t }) => ({ t: t.join('') }));
  const freq = new Map(b.all.map((t) => [t, 0]));
  for (const { t } of rows) { assert.ok(freq.has(t), `não ótima ${t}`); freq.set(t, freq.get(t) + 1); }
  const k = b.all.length; const e = N / k;
  let chi = 0; for (const o of freq.values()) chi += (o - e) ** 2 / e;
  // gl = k−1; limite crítico p=0,001 aproximado (Wilson–Hilferty).
  const df = k - 1; const z = 3.09;
  const crit = df * (1 - 2 / (9 * df) + z * Math.sqrt(2 / (9 * df))) ** 3;
  console.log(`uniformidade: ${k} composições ótimas, ${N} sorteios, χ²=${chi.toFixed(1)} (crítico ${crit.toFixed(1)})`);
  assert.ok(chi < crit, `χ²=${chi} ≥ ${crit}`);
  // secure_below: inteiro em [0,7) sem viés.
  const s = (await conn.query('select private.secure_below(7)::int v from generate_series(1, 7000)')).rows;
  const c = Array(7).fill(0); s.forEach(({ v }) => c[v]++);
  const chi2 = c.reduce((acc, o) => acc + (o - 1000) ** 2 / 1000, 0);
  assert.ok(chi2 < 22.46, `secure_below χ²=${chi2}`); // gl=6, p=0,001
});

test('100 participantes, contagem BigInt, limites e casos-limite', { timeout: 600000 }, async () => {
  const g = Array.from({ length: 100 }, (_, i) => GROUPS[i % 8]).sort((a, b) => GROUPS.indexOf(a) - GROUPS.indexOf(b));
  const t0 = Date.now();
  const v = (await (await db()).query('select private.draw_sample($1::text[], null) v', [g])).rows[0].v;
  console.log(`100 participantes: custo ${v.cost}, ${v.count} composições ótimas, ${Date.now() - t0} ms`);
  assert.equal(v.cost, 4); // 4 grupos com 13 (ímpares) e 4 com 12: diferença inevitável de 1 em cada ímpar
  assert.ok(BigInt(v.count) > 2n ** 53n, 'contagem acima da precisão de double');
  assert.equal(v.teams.filter((x) => x === 'A').length, 50);
  assert.equal(costOf(g, v.teams), 4);
  await assert.rejects(solve(Array(101).fill('none'), null), /DRAW_TOO_MANY_PLAYERS/);
  await assert.rejects(solve(['GOL'], null), /DRAW_TOO_FEW_PLAYERS/);
  // sem goleiro, só "sem posição", ímpar
  const odd = await solve(['none', 'none', 'none'], null);
  assert.equal(odd.cost, 1); assert.equal(odd.count, '6'); // 3 (A=1) + 3 (A=2)
  // capitães no mesmo grupo e total 2: única composição
  const cap = await solve(['GOL', 'GOL'], ['A', 'B']);
  assert.equal(cap.count, '1'); assert.equal(cap.cost, 0);
  // dois capitães A é inviável com 2 participantes
  await assert.rejects(solve(['GOL', 'ZAG'], ['A', 'A']), /DRAW_INFEASIBLE/);
});
