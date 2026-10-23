// Minuto 91 — motor de pontuação v2 (Prompt Master v2.0), versão de referência em JS.
// A fonte de verdade é o SQL (migração 052, funções private.rating_*). Este arquivo existe para os
// testes unitários, para conferir o SQL caso a caso (rating_sql.test.mjs) e para a simulação.
// Funções puras: nada aqui lê banco, relógio ou aleatoriedade.

export const PARAMS = Object.freeze({
  formulaVersion: 2,
  paramsVersion: 1,
  weights: { ATU: 0.3325, EST: 0.3325, PEQ: 0.19, RES: 0.095, DIS: 0.05 },
  window: 20,
  minMatchesForOvr: 5,
  atuCurve: [[0, 0], [5, 50], [6, 58], [7, 68], [8, 80], [9, 91], [10, 99]],
  defShare: { ZAG: 0.65, LAT: 0.5, VOL: 0.5, MEI: 0.15, ATA: 0.05, PON: 0.05 },
  goalShare: { ZAG: 0.45, LAT: 0.5, VOL: 0.5, MEI: 0.55, ATA: 0.7, PON: 0.7 },
  // C2 (aprovado em 23/10/2026): referências iniciais por partida.
  muG0: { ZAG: 0.1, LAT: 0.15, VOL: 0.2, MEI: 0.4, ATA: 0.7, PON: 0.7 },
  muA0: { ZAG: 0.1, LAT: 0.2, VOL: 0.25, MEI: 0.4, ATA: 0.3, PON: 0.3 },
  muC0: 3.0,
  muFloor: 0.05,
  shrink: 6,
  // C3: média aparada 10% sem o próprio jogador, últimas 40 partidas da pelada, alfa = n/(n+150) <= 0,5.
  localWindow: 40,
  localTrim: 0.1,
  alphaK: 150,
  alphaMax: 0.5,
  // C4: REF = 65 + n/(n+3) * (média ponderada - 65).
  refNeutral: 65,
  refShrink: 3,
  // C5: transição de 5 partidas só no EST.
  transitionMatches: 5,
  dis: { start: 70, min: 50, max: 99, recovery: 0.06, yellow: 8, red: 20 },
});

// Códigos do app (041) -> posições do motor (D7).
export function ratingPosition(code, sector) {
  const map = { GOL: 'GOL', ZAG: 'ZAG', LD: 'LAT', LE: 'LAT', VOL: 'VOL', MEI: 'MEI', CA: 'ATA', ATA: 'ATA', PD: 'PON', PE: 'PON' };
  if (code && map[code]) return map[code];
  return { goalkeeper: 'GOL', defender: 'ZAG', midfielder: 'MEI', attacker: 'ATA' }[sector] ?? 'MEI';
}

const clip = (x, lo, hi) => Math.min(hi, Math.max(lo, x));

// Arredondamento só para exibir: inteiro mais próximo, 0,5 para cima.
export const roundDisplay = (x) => Math.floor(x + 0.5);

// 4.2: interpolação linear da nota (0-10) para 0-99.
export function atuCurve(q, p = PARAMS) {
  const pts = p.atuCurve;
  const x = clip(q, 0, 10);
  for (let i = 1; i < pts.length; i++) {
    const [x0, y0] = pts[i - 1];
    const [x1, y1] = pts[i];
    if (x <= x1) return y0 + ((y1 - y0) * (x - x0)) / (x1 - x0);
  }
  return pts[pts.length - 1][1];
}

// 4.1: nota da partida (só votos). null = avaliação insuficiente.
export function matchScore(teammateRatings, opponentRatings) {
  if (!teammateRatings.length || !opponentRatings.length) return null;
  const mean = (a) => a.reduce((s, x) => s + x, 0) / a.length;
  return 0.5 * mean(teammateRatings) + 0.5 * mean(opponentRatings);
}

// 4.3. scores: notas das partidas da janela (null = sem votação válida).
export function atu(scores, p = PARAMS) {
  const w = scores.slice(-p.window);
  const J = w.length;
  const valid = w.filter((q) => q !== null && q !== undefined);
  const m = valid.length;
  if (m === 0) return 70;
  const sum = valid.reduce((s, q) => s + (atuCurve(q, p) - 70), 0);
  return 70 + sum / (m + 2 + 0.25 * (J - m));
}

// 5.2
export function off(goals, assists, n, muG, muA, goalShare, p = PARAMS) {
  const rG = (goals + p.shrink * muG) / (n + p.shrink);
  const rA = (assists + p.shrink * muA) / (n + p.shrink);
  const z = goalShare * Math.log(rG / muG) + (1 - goalShare) * Math.log(rA / muA);
  return 70 + 29 * Math.tanh(1.3 * Math.max(0, z)) - 20 * Math.tanh(Math.max(0, -z));
}

// 5.3 com a interpretação aprovada (C1).
export function def(conceded, n, muC, p = PARAMS) {
  const rC = (conceded + p.shrink * muC) / (n + p.shrink);
  const l = Math.log(muC / rC);
  return 70 + 29 * Math.tanh(1.2 * Math.max(0, l)) - 20 * Math.tanh(1.2 * Math.max(0, -l));
}

// 6.1
export function refMatch(d) {
  if (d <= 5) return 65 + 3 * d;
  return 80 + 19 * (1 - Math.exp(-(d - 5) / 4));
}

// saves: defesas difíceis das partidas da janela, da mais antiga à mais recente (null = sem registro).
export function ref(saves, p = PARAMS) {
  const w = saves.slice(-p.window);
  const J = w.length;
  let sw = 0;
  let sv = 0;
  let n = 0;
  w.forEach((d, i) => {
    if (d === null || d === undefined) return;
    const weight = 30 - (J - 1 - i); // a mais recente pesa 30
    sw += weight;
    sv += weight * refMatch(d);
    n++;
  });
  if (n === 0) return p.refNeutral;
  return p.refNeutral + (n / (n + p.refShrink)) * (sv / sw - p.refNeutral);
}

// EST de uma posição sobre a janela.
export function est(pos, win, refs, p = PARAMS) {
  const n = win.length;
  const conceded = win.reduce((s, x) => s + x.conceded, 0);
  const D = def(conceded, n, refs.muC, p);
  if (pos === 'GOL') return 0.7 * ref(win.map((x) => x.saves), p) + 0.3 * D;
  const goals = win.reduce((s, x) => s + x.goals, 0);
  const assists = win.reduce((s, x) => s + x.assists, 0);
  const O = off(goals, assists, n, refs.muG[pos], refs.muA[pos], p.goalShare[pos], p);
  const w = p.defShare[pos];
  return w * D + (1 - w) * O;
}

// 7
export function peq(results, p = PARAMS) {
  const w = results.slice(-p.window);
  const N = w.length;
  if (N === 0) return 70;
  const V = w.filter((r) => r === 'win').length;
  const E = w.filter((r) => r === 'draw').length;
  const P = (3 * V + E) / (3 * N);
  return clip(70 + 35 * (2 * P - 1) * (N / (N + 4)), 0, 99);
}

// 8. rounds: rodadas oficiais desde a entrada, da mais antiga à mais recente (true = presente).
export function res(rounds, p = PARAMS) {
  const w = rounds.slice(-p.window);
  const N = w.length;
  if (N === 0) return 70;
  const A = w.filter(Boolean).length;
  return 70 + (100 * A - 70 * N) / (N + 4);
}

// 9. matches em ordem cronológica: {discipline:'confirmed'|'pending'|'not_tracked', yellow, red}.
// second_yellow já chega como red (uma única penalidade de vermelho).
export function dis(matches, cardsTracking, p = PARAMS) {
  const c = p.dis;
  if (!cardsTracking) return c.start;
  let d = c.start;
  for (const m of matches) {
    if (m.discipline !== 'confirmed') continue;
    if (!m.yellow && !m.red) {
      d = d + c.recovery * (c.max - d);
      continue;
    }
    for (let i = 0; i < (m.yellow || 0); i++) d = Math.max(c.min, d - c.yellow);
    for (let i = 0; i < (m.red || 0); i++) d = Math.max(c.min, d - c.red);
  }
  return clip(d, c.min, c.max);
}

export function ovr(a, p = PARAMS) {
  const w = p.weights;
  return clip(w.ATU * a.ATU + w.EST * a.EST + w.PEQ * a.PEQ + w.RES * a.RES + w.DIS * a.DIS, 0, 99);
}

// Referência local híbrida (5.4 + C3). samples: valores por jogador-partida (ou por time-partida em
// gols sofridos) da posição, já SEM o próprio jogador.
export function trimmedMean(values, trim) {
  if (!values.length) return null;
  const s = [...values].sort((a, b) => a - b);
  const k = Math.floor(s.length * trim);
  const t = s.slice(k, s.length - k);
  return t.reduce((x, y) => x + y, 0) / t.length;
}
export function localReference(mu0, samples, p = PARAMS) {
  const n = samples.length;
  if (n === 0) return Math.max(p.muFloor, mu0);
  const alpha = Math.min(p.alphaMax, n / (n + p.alphaK));
  return Math.max(p.muFloor, (1 - alpha) * mu0 + alpha * trimmedMean(samples, p.localTrim));
}

// Cálculo completo de um jogador numa pelada.
// input: {
//   matches: [{q, goals, assists, conceded, result, saves, discipline, yellow, red}] cronológico (todas as oficiais disputadas),
//   rounds: [bool] cronológico desde a entrada,
//   position, previousPosition (ou null), matchesSinceChange (ou null),
//   refs: {muG:{pos}, muA:{pos}, muC}, cardsTracking
// }
export function computeRating(input, p = PARAMS) {
  const all = input.matches;
  const win = all.slice(-p.window);
  const ATU = atu(win.map((m) => m.q), p);
  let EST = est(input.position, win, input.refs, p);
  const k = input.matchesSinceChange;
  if (input.previousPosition && k !== null && k !== undefined && k < p.transitionMatches) {
    const old = est(input.previousPosition, win, input.refs, p);
    EST = (k / p.transitionMatches) * EST + (1 - k / p.transitionMatches) * old;
  }
  const PEQ = peq(win.map((m) => m.result), p);
  const RES = res(input.rounds, p);
  const DIS = dis(all, input.cardsTracking, p);
  const OVR = ovr({ ATU, EST, PEQ, RES, DIS }, p);
  const eligible = all.length >= p.minMatchesForOvr;
  return { ATU, EST, PEQ, RES, DIS, OVR, eligible, ovrDisplay: eligible ? roundDisplay(OVR) : null, matchesPlayed: all.length };
}

// D2 (aprovado): bronze < 65 <= prata < 80 <= ouro, sobre o OVR exibido.
export function tier(display) {
  if (display === null) return null;
  return display < 65 ? 'bronze' : display < 80 ? 'prata' : 'ouro';
}
