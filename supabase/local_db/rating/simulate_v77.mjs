// Simulação populacional do motor V7.7 (formula_version 3). DADOS SINTÉTICOS, não são do app.
// Uso: node rating/simulate_v77.mjs [peladas=1000] [rodadas1=30] [rodadas2=20] -> docs/v77_simulacao_resultados.json
// Partidas coerentes (dois times da mesma partida, gols de um = gols sofridos do outro), duas temporadas (herança),
// faltas, reservas, notas insuficientes, resenha com respostas faltando, defesas difíceis às vezes sem registro,
// cartões com segundo amarelo. O motor é o de referência (rating/v77.mjs), idêntico ao SQL (rating_v77_sql.test.mjs).
// Objetivo: monitorar distribuição por posição, variação rodada a rodada e saltos extremos. NÃO recalibra nada.
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import * as E from './v77.mjs';

const PELADAS = Number(process.argv[2] ?? 1000);
const R1 = Number(process.argv[3] ?? 30);
const R2 = Number(process.argv[4] ?? 20);
let seed = 20261024;
const rnd = () => ((seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296);
const normal = () => Math.sqrt(-2 * Math.log(rnd() + 1e-12)) * Math.cos(2 * Math.PI * rnd());
const poisson = (l) => { let k = 0; let p = 1; const L = Math.exp(-l); do { k++; p *= rnd(); } while (p > L); return k - 1; };
const pick = (arr, w) => { const t = w.reduce((a, b) => a + b, 0); let x = rnd() * t; for (let i = 0; i < arr.length; i++) { x -= w[i]; if (x <= 0) return arr[i]; } return arr[arr.length - 1]; };
const shuffle = (a) => { for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(rnd() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };
const clampHalf = (x) => Math.min(10, Math.max(0, Math.round(x * 2) / 2));
const POS = E.POSITIONS;
const ATTACK = { GOL: 0.02, ZAG: 0.25, LAT: 0.35, VOL: 0.45, MEI: 0.9, ATA: 1.6, PON: 1.4 };
const CREATE = { GOL: 0.03, ZAG: 0.3, LAT: 0.6, VOL: 0.7, MEI: 1.2, ATA: 0.8, PON: 1.0 };
const quant = (a, q) => { if (!a.length) return null; const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor(q * (s.length - 1)))]; };
const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : null);
const maxOf = (a) => a.reduce((m, x) => (x > m ? x : m), -Infinity);
const minOf = (a) => a.reduce((m, x) => (x < m ? x : m), Infinity);
const r3 = (x) => (x === null ? null : Math.round(x * 1000) / 1000);

function playSeason(players, rounds, startRound) {
  for (let r = 0; r < rounds; r++) {
    const eligible = players.filter((p) => p.joinedRound <= startRound + r);
    const present = eligible.filter((p) => rnd() < p.attend);
    const keepers = shuffle(present.filter((p) => p.pos === 'GOL'));
    const field = shuffle(present.filter((p) => p.pos !== 'GOL'));
    const perTeam = Math.min(11, Math.floor(present.length / 2));
    if (perTeam < 5) continue; // rodada sem jogo
    const teams = [[], []];
    keepers.slice(0, 2).forEach((k, i) => teams[i].push(k));
    const bench = [...keepers.slice(2), ...field];
    for (const p of field) { const t = teams[0].length <= teams[1].length ? 0 : 1; if (teams[t].length < perTeam) teams[t].push(p); }
    for (const p of bench.filter((x) => !teams[0].includes(x) && !teams[1].includes(x))) if (rnd() < 0.6) teams[rnd() < 0.5 ? 0 : 1].push(p);
    const str = teams.map((t) => t.reduce((s, p) => s + p.skill, 0) / t.length);
    const goals = [0, 1].map((t) => poisson(2.6 * Math.exp(0.6 * (str[t] - str[1 - t]))));
    const lines = new Map();
    for (const [t, team] of teams.entries()) for (const p of team) lines.set(p, { team: t, goals: 0, assists: 0, saves: null, yellow: 0, red: 0 });
    for (const t of [0, 1]) for (let g = 0; g < goals[t]; g++) {
      const team = teams[t];
      const scorer = pick(team, team.map((p) => ATTACK[p.pos] * Math.exp(0.5 * p.skill)));
      lines.get(scorer).goals++;
      if (rnd() < 0.7) { const others = team.filter((p) => p !== scorer); if (others.length) lines.get(pick(others, others.map((p) => CREATE[p.pos] * Math.exp(0.4 * p.skill)))).assists++; }
    }
    for (const [p, l] of lines) {
      if (p.pos === 'GOL' && rnd() < 0.85) l.saves = poisson(2.4 * Math.exp(0.3 * p.skill));
      const c = rnd();
      if (c < 0.07 * p.temper) l.yellow = 1;
      else if (c < 0.085 * p.temper) l.secondYellow = 1;
      else if (c < 0.09 * p.temper) l.red = 1;
    }
    // Resenha: 70% dos participantes respondem; cada um marca os outros conforme o hábito deles.
    const all = [...teams[0], ...teams[1]];
    const answers = new Map();
    for (const v of all) if (rnd() < 0.7) answers.set(v, new Set(all.filter((u) => u !== v && rnd() < u.social)));
    const tracking = players.tracking;
    for (const p of eligible) {
      const l = lines.get(p);
      if (!l) { p.season.push({ played: false }); continue; }
      const own = goals[l.team];
      const opp = goals[1 - l.team];
      const q = rnd() < 0.15 ? null : clampHalf(7 + 0.7 * p.skill + 0.25 * (l.goals + l.assists) + 0.6 * normal());
      const voters = [...answers.keys()].filter((v) => v !== p);
      const c = E.normalizeCards({ yellowCard: l.yellow, secondYellow: l.secondYellow ?? 0, redCard: l.red });
      p.season.push({
        played: true, q, goals: l.goals, assists: l.assists, conceded: opp, saves: l.saves,
        result: own > opp ? 1 : own === opp ? 1 / 3 : 0, yellow: c.yellow, red: c.red, cardsKnown: tracking,
        resenha: E.resenhaOutcome(voters.filter((v) => answers.get(v).has(p)).length, voters.length),
      });
    }
  }
}

const byPos = Object.fromEntries(POS.map((p) => [p, { ovr: [], ovr2: [], DEF: [], SEC: [], APR: [], RES: [], DIS: [] }]));
const deltas = [];
const secDeltas = [];
const extreme = [];
let players = 0;
let rounds = 0;
let resKnown = 0;
let resTotal = 0;
let refMissing = 0;
let refTotal = 0;
const carry = { withPrev: [], fresh: [] };
const t0 = Date.now();
for (let g = 0; g < PELADAS; g++) {
  const size = 25 + Math.floor(rnd() * 16);
  const roster = Array.from({ length: size }, (_, i) => ({
    id: i, pos: i < 3 ? 'GOL' : pick(POS.slice(1), [22, 18, 15, 20, 15, 10]), skill: normal(), attend: 0.45 + rnd() * 0.5,
    temper: rnd() < 0.15 ? 3 : 1, social: 0.2 + rnd() * 0.7, joinedRound: rnd() < 0.85 ? 0 : Math.floor(rnd() * R1 * 0.6), season: [], seasons: [],
  }));
  roster.tracking = rnd() < 0.6;
  players += size;
  playSeason(roster, R1, 0);
  for (const p of roster) { p.seasons.push({ seasonId: 's1', events: p.season }); p.season = []; }
  playSeason(roster, R2, R1);
  for (const p of roster) p.seasons.push({ seasonId: 's2', events: p.season });
  for (const p of roster) {
    // Só a partir da primeira participação (como o servidor).
    const flat = p.seasons.map((s) => ({ ...s, events: [...s.events] }));
    const firstS = flat.findIndex((s) => s.events.some((e) => e.played));
    if (firstS < 0) continue;
    flat[firstS].events = flat[firstS].events.slice(flat[firstS].events.findIndex((e) => e.played));
    const seasons = flat.slice(firstS).filter((s) => s.events.length);
    const career = E.evaluateCareer(seasons, p.pos);
    let prevPub = null;
    let prevSec = null;
    for (const [si, s] of career.entries()) {
      for (const row of s.rows) {
        rounds++;
        if (row.eligible) {
          if (prevPub !== null) {
            const d = row.ovr - prevPub;
            deltas.push(d);
            if (Math.abs(d) >= 6 && extreme.length < 40) extreme.push({ pos: p.pos, season: si + 1, round: row.round, delta: r3(d), ovr: r3(row.ovr), sec_delta: r3(row.SEC - prevSec) });
          }
          if (prevSec !== null && p.pos !== 'GOL') secDeltas.push(row.SEC - prevSec);
          prevPub = row.ovr;
          prevSec = row.SEC;
        }
      }
      const last = s.last;
      if (!last || !last.eligible) continue;
      const bucket = byPos[p.pos];
      (si === 0 ? bucket.ovr : bucket.ovr2).push(last.ovr);
      if (si === career.length - 1) for (const k of ['DEF', 'SEC', 'APR', 'RES', 'DIS']) bucket[k].push(last[k]);
    }
    for (const s of seasons) for (const e of s.events) if (e.played) {
      resTotal++; if (e.resenha !== null) resKnown++;
      if (p.pos === 'GOL') { refTotal++; if (e.saves === null) refMissing++; }
    }
    // Herança: começo da temporada 2 com e sem o estado da temporada 1.
    if (career.length === 2 && career[0].played >= 5 && career[1].rows.length >= 3) {
      const fresh = E.evaluateSeason(seasons[1].events, p.pos, null, 0).rows[2];
      carry.withPrev.push(career[1].rows[2].ovr - career[0].last.ovr);
      carry.fresh.push(fresh.ovr - career[0].last.ovr);
    }
  }
}
const absSorted = deltas.map(Math.abs);
const out = {
  note: 'Dados sintéticos. Motor V7.7 congelado (rating/v77.mjs = SQL 053). Nenhum parâmetro foi alterado a partir deste resultado.',
  peladas: PELADAS, players, rounds_per_season: [R1, R2], player_rounds: rounds, seconds: Math.round((Date.now() - t0) / 100) / 10,
  ovr_by_position_season1: Object.fromEntries(POS.map((p) => [p, { n: byPos[p].ovr.length, mean: r3(mean(byPos[p].ovr)), p5: r3(quant(byPos[p].ovr, 0.05)), p50: r3(quant(byPos[p].ovr, 0.5)), p95: r3(quant(byPos[p].ovr, 0.95)) }])),
  ovr_by_position_season2: Object.fromEntries(POS.map((p) => [p, { n: byPos[p].ovr2.length, mean: r3(mean(byPos[p].ovr2)), p5: r3(quant(byPos[p].ovr2, 0.05)), p50: r3(quant(byPos[p].ovr2, 0.5)), p95: r3(quant(byPos[p].ovr2, 0.95)) }])),
  attributes_final_mean: Object.fromEntries(POS.map((p) => [p, Object.fromEntries(['DEF', 'SEC', 'APR', 'RES', 'DIS'].map((k) => [k === 'SEC' ? (p === 'GOL' ? 'REF' : 'LET') : k, r3(mean(byPos[p][k]))]))])),
  spread_mean_ovr_season1: r3(Math.max(...POS.map((p) => mean(byPos[p].ovr))) - Math.min(...POS.map((p) => mean(byPos[p].ovr)))),
  round_to_round_ovr: {
    n: deltas.length, mean: r3(mean(deltas)), p1: r3(quant(deltas, 0.01)), p5: r3(quant(deltas, 0.05)), p50: r3(quant(deltas, 0.5)),
    p95: r3(quant(deltas, 0.95)), p99: r3(quant(deltas, 0.99)), max_rise: r3(maxOf(deltas)), max_fall: r3(minOf(deltas)),
    share_abs_ge_3: r3(absSorted.filter((x) => x >= 3).length / deltas.length), share_abs_ge_5: r3(absSorted.filter((x) => x >= 5).length / deltas.length),
    share_abs_ge_8: r3(absSorted.filter((x) => x >= 8).length / deltas.length),
  },
  round_to_round_let: { n: secDeltas.length, p1: r3(quant(secDeltas, 0.01)), p99: r3(quant(secDeltas, 0.99)), max_rise: r3(maxOf(secDeltas)), max_fall: r3(minOf(secDeltas)), share_abs_ge_10: r3(secDeltas.filter((x) => Math.abs(x) >= 10).length / secDeltas.length) },
  extreme_ovr_jumps_sample: extreme,
  season_carryover_ovr_change_at_round3: { with_prev_mean_abs: r3(mean(carry.withPrev.map(Math.abs))), fresh_mean_abs: r3(mean(carry.fresh.map(Math.abs))), n: carry.withPrev.length },
  missing_data: { resenha_unknown_share: r3(1 - resKnown / resTotal), keeper_saves_missing_share: r3(refMissing / refTotal) },
  bounds_ok: POS.every((p) => byPos[p].ovr.concat(byPos[p].ovr2).every((x) => x >= 40 && x <= 99)),
};
writeFileSync(join(import.meta.dirname, '../../../docs/v77_simulacao_resultados.json'), JSON.stringify(out, null, 2));
console.log(JSON.stringify(out, null, 1));
