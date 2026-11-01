// Minuto 91 — motor V7.7 (formula_version 3), versão de referência em JS.
// A fonte de verdade é o SQL (migração 053, funções private.v77_*). Este arquivo existe para os testes unitários,
// para conferir o SQL caso a caso (rating_v77_sql.test.mjs), para conferir o protótipo Python (v77_python.test.mjs)
// e para a simulação populacional. Funções puras: nada aqui lê banco, relógio ou aleatoriedade.
//
// Porte fiel de v77_engine.py (que importa v72_corrected.py e a MovingState de v73_engine.py). Curvas, pesos e
// referências posicionais são os da V7.5 (= v72_corrected: MG/MA originais, REF com 3 defesas por jogo). A curva
// experimental de LET da V7.9 NÃO está aqui. Diferenças deliberadas em relação ao protótipo (todas documentadas em
// docs/relatorio_v77_2026-10-24.md, seção 2):
//  D1. cardsKnown=false (pelada sem registro de cartões ou súmula com disciplina pendente) não move o DIS: dado
//      ausente não é "partida limpa". No protótipo toda partida disputada tinha cartões conhecidos.
//  D2. Elegibilidade (OVR exibido) a partir de 5 partidas oficiais na pelada (carreira), não 5 na temporada.
//      Dentro da primeira temporada é idêntico ao protótipo.
//  D3. Transição de posição: 5 partidas após a troca, OVR = k/5 * OVR(nova) + (1 - k/5) * OVR(antiga). O protótipo
//      não tinha troca de posição.
//  D4. Temporada sem nenhuma partida disputada pelo jogador não gera estado: a herança vem da última temporada
//      em que ele jogou (senão a evidência herdada zeraria só por uma temporada de ausência).
// Comportamentos do protótipo preservados como estão (congelados), mesmo quando parecem acidentais:
//  P1. Sem nenhuma nota válida, q = 70 (o protótipo procura 'q' em prior['attrs'], onde a chave não existe).
//  P2. RES sem nenhuma resposta de resenha conhecida: primeira temporada usa 50% de resenha e q=70; temporadas
//      seguintes partem do RES herdado e só a frequência anda.

export const V77 = Object.freeze({
  formulaVersion: 3,
  paramsVersion: 2,
  // DEF, LET/REF, APR, RES, DIS
  weights: Object.freeze({
    GOL: [0.4, 0.35, 0.1, 0.1, 0.05],
    ZAG: [0.45, 0.3, 0.1, 0.1, 0.05],
    LAT: [0.4, 0.35, 0.1, 0.1, 0.05],
    VOL: [0.35, 0.4, 0.1, 0.1, 0.05],
    MEI: [0.25, 0.5, 0.1, 0.1, 0.05],
    ATA: [0.2, 0.55, 0.1, 0.1, 0.05],
    PON: [0.2, 0.55, 0.1, 0.1, 0.05],
  }),
  // Referências posicionais V7.5 (inalteradas desde a V7.2): gols e assistências por partida.
  muG: Object.freeze({ ZAG: 0.1, LAT: 0.15, VOL: 0.2, MEI: 0.4, ATA: 0.7, PON: 0.7 }),
  muA: Object.freeze({ ZAG: 0.1, LAT: 0.2, VOL: 0.25, MEI: 0.4, ATA: 0.3, PON: 0.3 }),
  defMu: 3, // gols sofridos por partida de referência (env do protótipo)
  refMu: 3, // defesas difíceis por partida de referência
  minMatches: 5,
  carryShare: 0.5,
  carryCap: 20,
  transition: 5,
  window: 10,
  dis: Object.freeze({ start: 70, min: 50, max: 99, recovery: 0.06, yellow: 8, red: 20 }),
});

export const POSITIONS = ['GOL', 'ZAG', 'LAT', 'VOL', 'MEI', 'ATA', 'PON'];
export const SPORT = ['DEF', 'SEC', 'APR'];

export const clip = (x, lo = 40, hi = 99) => Math.min(hi, Math.max(lo, x));
const sum = (a) => a.reduce((s, x) => s + x, 0);
const mean = (a) => sum(a) / a.length;
// Exibição: inteiro mais próximo, 0,5 para cima (mesma regra da V5).
export const roundDisplay = (x) => Math.floor(x + 0.5);
export const tier = (d) => (d === null ? null : d < 65 ? 'bronze' : d < 80 ? 'prata' : 'ouro');
export const secCode = (pos) => (pos === 'GOL' ? 'REF' : 'LET');

// Nota da partida (0-10) para a escala do atributo.
export const vote = (q) => clip(q <= 8 ? 68 + 12 * (q - 7) : 80 + 11 * (q - 8));

export function letScore(goals, assists, pos, q, p = V77) {
  const n = goals.length;
  const g = sum(goals);
  const a = sum(assists);
  const score = (r, mu) => {
    const z = 5 * (r / mu - 1);
    return clip(75 + (z >= 0 ? 24 : 25) * Math.tanh(z));
  };
  const sg = score(g / n, p.muG[pos]);
  const sa = score(a / n, p.muA[pos]);
  const stat = Math.min(99, Math.max(sg, sa) + 0.1 * Math.max(0, Math.min(sg, sa) - 75));
  const base = 70 + (n / (n + 3)) * (stat - 70);
  return clip(0.75 * base + 0.25 * q);
}

export function defence(conceded, q, mu = V77.defMu) {
  const n = conceded.length;
  const r = (sum(conceded) + 6 * mu) / (n + 6);
  const z = Math.log(mu / r);
  const stat = 75 + (z >= 0 ? 24 * Math.tanh(1.2 * z) : 25 * Math.tanh(1.2 * z));
  return clip(0.75 * (70 + (n / (n + 3)) * (stat - 70)) + 0.25 * q);
}

export function reflex(saves, q, mu = V77.refMu) {
  const valid = saves.filter((x) => x !== null && x !== undefined);
  if (!valid.length) return 70;
  const n = valid.length;
  const d = sum(valid) / n;
  const z = (d - mu) / 2;
  const stat = clip(75 + (z >= 0 ? 24 * Math.tanh(1.4 * z) : 25 * Math.tanh(1.4 * z)));
  return clip(0.75 * (70 + (n / (n + 3)) * (stat - 70)) + 0.25 * q);
}

// results: 1 vitória, 1/3 empate, 0 derrota.
export function apr(results, q) {
  const n = results.length;
  const pr = (sum(results) + 2) / (n + 4);
  return clip(0.9 * (70 + (35 * (2 * pr - 1) * n) / (n + 4)) + 0.1 * q);
}

export const RESULT_VALUE = { win: 1, draw: 1 / 3, loss: 0 };

// Resenha de UM jogador numa partida. yes = confirmações, voters = eleitores válidos (quem respondeu, sem o próprio).
// null = indeterminado (menos de 2 eleitores).
export function resenhaOutcome(yes, voters) {
  if (voters < 2) return null;
  return yes >= 2 && yes * 2 > voters;
}
// Versão do protótipo (mapa eleitor -> sim/não/null), usada nos testes.
export function resenhaFromVotes(votes, playerId) {
  if (!votes) return null;
  const valid = Object.entries(votes).filter(([k, v]) => String(k) !== String(playerId) && v !== null && v !== undefined);
  return resenhaOutcome(valid.filter(([, v]) => v).length, valid.length);
}

// Cartões de uma partida como a súmula os guarda: segundo amarelo = uma expulsão e absorve os amarelos; no máximo
// uma expulsão e um amarelo por partida (evita contar o mesmo lance duas vezes).
export function normalizeCards({ yellowCard = 0, secondYellow = 0, redCard = 0 }) {
  const red = Math.min(1, (redCard || 0) + (secondYellow || 0));
  const yellow = secondYellow > 0 ? 0 : Math.min(1, yellowCard || 0);
  return { yellow, red };
}

export function stepDis(cur, yellow = 0, red = 0, p = V77) {
  const d = p.dis;
  if (yellow || red) return Math.max(d.min, cur - d.yellow * yellow - d.red * red);
  return Math.min(d.max, cur + d.recovery * (d.max - cur));
}

// Checkpoint de quedas (MovingState da V7.3): janela real das 10 últimas variações do valor bruto.
export class Smoother {
  constructor(initial = null) {
    this.published = initial ?? null;
    this.lastRaw = null;
    this.recent = [];
  }
  push(d) {
    this.recent.push(d);
    if (this.recent.length > V77.window) this.recent.shift();
  }
  update(raw) {
    if (raw === null || raw === undefined) return this.published;
    if (this.published === null) {
      this.published = raw;
      this.lastRaw = raw;
      this.push(0);
      return raw;
    }
    const delta = this.lastRaw !== null ? raw - this.lastRaw : 0;
    this.push(delta);
    this.lastRaw = raw;
    if (raw >= this.published) {
      this.published = raw;
      return raw;
    }
    const downs = this.recent.filter((x) => x < -0.00001).length;
    const decline = Math.max(0, -sum(this.recent));
    const severity = Math.min(1, decline / 12);
    const alpha = 0.3 + 0.35 * (downs / 10) + 0.2 * severity;
    this.published = clip(this.published + alpha * (raw - this.published));
    return this.published;
  }
}

export function ovrOf(a, pos, p = V77) {
  const w = p.weights[pos];
  return clip(w[0] * a.DEF + w[1] * a.SEC + w[2] * a.APR + w[3] * a.RES + w[4] * a.DIS);
}

const validFor = (attr, e, pos) => {
  if (attr === 'DEF') return e.conceded !== null && e.conceded !== undefined;
  if (attr === 'SEC') {
    if (pos === 'GOL') return e.saves !== null && e.saves !== undefined;
    return e.goals !== null && e.goals !== undefined && e.assists !== null && e.assists !== undefined;
  }
  return e.result !== null && e.result !== undefined;
};

// Uma temporada. events: rodadas oficiais da temporada desde a entrada do jogador, em ordem cronológica:
//  {played, q (0-10 ou null), goals, assists, conceded, saves, result (1, 1/3, 0 ou null), yellow, red,
//   cardsKnown (padrão true), resenha (true/false/null)}
// prev: {attrs:{DEF,SEC,APR,RES,DIS}, evidence:{DEF,SEC,APR}} da última temporada disputada, ou null.
// playedBefore: partidas oficiais disputadas nas temporadas anteriores (elegibilidade D2).
export function evaluateSeason(events, pos, prev = null, playedBefore = 0, p = V77) {
  const prior = prev ? prev.attrs : {};
  const evidence = prev ? prev.evidence : {};
  const st = Object.fromEntries(SPORT.map((a) => [a, new Smoother(prev ? prior[a] : null)]));
  const hist = { DEF: [], SEC: [], APR: [] };
  const votes = { DEF: [], SEC: [], APR: [] };
  let played = 0;
  let attended = 0;
  const after = [];
  const qAll = [];
  let lastRes = prev ? prior.RES : 70;
  let lastDis = prev ? prior.DIS : p.dis.start;
  const rows = [];
  events.forEach((e, idx) => {
    const active = !!e.played;
    if (active) attended++;
    if (active) {
      played++;
      const q = e.q ?? null;
      for (const a of SPORT) {
        if (!validFor(a, e, pos)) continue;
        hist[a].push(e);
        if (q !== null) votes[a].push(vote(q));
      }
      if (q !== null) qAll.push(vote(q));
      after.push(e.resenha ?? null);
      if (e.cardsKnown !== false) lastDis = stepDis(lastDis, e.yellow || 0, e.red || 0, p);
    }
    const attrs = {};
    for (const a of SPORT) {
      const n = hist[a].length;
      if (!active || !n || !validFor(a, e, pos)) {
        attrs[a] = st[a].published !== null ? st[a].published : 70;
        continue;
      }
      const q = votes[a].length ? mean(votes[a]) : 70;
      let raw;
      if (a === 'DEF') raw = defence(hist[a].map((x) => x.conceded), q, p.defMu);
      else if (a === 'SEC')
        raw = pos === 'GOL' ? reflex(hist[a].map((x) => x.saves), q, p.refMu) : letScore(hist[a].map((x) => x.goals), hist[a].map((x) => x.assists), pos, q, p);
      else raw = apr(hist[a].map((x) => x.result), q);
      if (prev) {
        const strength = p.carryShare * Math.min(p.carryCap, evidence[a] || 0);
        if (strength > 0) raw = (strength * prior[a] + n * raw) / (strength + n);
      }
      attrs[a] = st[a].update(raw);
    }
    const rounds = idx + 1;
    const freq = (attended + 2) / (rounds + 4);
    const known = after.filter((x) => x !== null);
    if (known.length) {
      const post = (known.filter(Boolean).length + 2) / (known.length + 4);
      const qmean = qAll.length ? mean(qAll) : 70;
      lastRes = clip(0.95 * (0.6 * (40 + 59 * freq) + 0.4 * (40 + 59 * post)) + 0.05 * qmean);
    } else if (!prev) {
      lastRes = clip(0.95 * (0.6 * (40 + 59 * freq) + 0.4 * (40 + 59 * 0.5)) + 0.05 * 70);
    } else {
      lastRes = clip(prior.RES + 0.95 * 0.6 * 59 * (freq - 0.5));
    }
    attrs.RES = lastRes;
    attrs.DIS = lastDis;
    const ovr = ovrOf(attrs, pos, p);
    const eligible = playedBefore + played >= p.minMatches;
    rows.push({ round: rounds, played, ...attrs, ovr, eligible, evidence: { DEF: hist.DEF.length, SEC: hist.SEC.length, APR: hist.APR.length } });
  });
  const last = rows[rows.length - 1];
  const payload = played > 0 ? { attrs: { DEF: last.DEF, SEC: last.SEC, APR: last.APR, RES: last.RES, DIS: last.DIS }, evidence: last.evidence } : prev;
  return { rows, played, payload };
}

// Carreira na pelada para uma posição: temporadas em ordem, herança entre elas (D4).
export function evaluateCareer(seasons, pos, p = V77) {
  let prev = null;
  let playedBefore = 0;
  const out = [];
  for (const s of seasons) {
    const r = evaluateSeason(s.events, pos, prev, playedBefore, p);
    playedBefore += r.played;
    if (r.played > 0) prev = r.payload;
    const last = r.rows[r.rows.length - 1] ?? null;
    out.push({ seasonId: s.seasonId ?? null, played: r.played, careerPlayed: playedBefore, last, rows: r.rows, prev });
  }
  return out;
}

// Entrada completa (mesmo formato JSON que private.v77_career recebe):
// {position, previousPosition, transitionK, seasons:[{seasonId, events:[...]}]}
export function computeCareer(input, p = V77) {
  const pos = input.position;
  const cur = evaluateCareer(input.seasons, pos, p);
  const k = input.transitionK;
  const inTransition = !!input.previousPosition && input.previousPosition !== pos && k !== null && k !== undefined && k < p.transition;
  const old = inTransition ? evaluateCareer(input.seasons, input.previousPosition, p) : null;
  const seasons = cur.map((s, i) => {
    if (!s.last) return { seasonId: s.seasonId, played: 0, careerPlayed: s.careerPlayed, state: null };
    const a = s.last;
    let ovr = a.ovr;
    if (old && i === cur.length - 1) ovr = (k / p.transition) * a.ovr + (1 - k / p.transition) * old[i].last.ovr;
    const eligible = s.careerPlayed >= p.minMatches;
    return {
      seasonId: s.seasonId,
      played: s.played,
      careerPlayed: s.careerPlayed,
      state: { DEF: a.DEF, SEC: a.SEC, APR: a.APR, RES: a.RES, DIS: a.DIS, ovr, eligible, ovrDisplay: eligible ? roundDisplay(ovr) : null, evidence: a.evidence },
    };
  });
  const lastWithState = [...seasons].reverse().find((s) => s.state) ?? null;
  return {
    position: pos,
    secCode: secCode(pos),
    transitionK: inTransition ? k : null,
    previousPosition: inTransition ? input.previousPosition : null,
    matchesPlayed: cur.length ? cur[cur.length - 1].careerPlayed : 0,
    current: lastWithState ? lastWithState.state : null,
    seasons,
  };
}
