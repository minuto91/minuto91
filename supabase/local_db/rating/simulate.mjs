// Simulação populacional do motor v2 (Prompt Master v2.0, Etapa 24). DADOS SINTÉTICOS, não são do app.
// Uso: node rating/simulate.mjs [peladas=1000] [rodadas=30]  -> grava docs/v5_simulacao_resultados.json
// Regras respeitadas: uma partida por rodada, dois times de até 11 em campo + reservas que podem entrar,
// gols/assistências/votos/cartões só de quem participou, ninguém vota em si, avaliação incompleta é comum.
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import * as E from './engine.mjs';

const PELADAS = Number(process.argv[2] ?? 1000);
const ROUNDS = Number(process.argv[3] ?? 30);
let seed = 20261023;
const rnd = () => ((seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296);
const normal = () => Math.sqrt(-2 * Math.log(rnd() + 1e-12)) * Math.cos(2 * Math.PI * rnd());
const poisson = (l) => { let k = 0; let p = 1; const L = Math.exp(-l); do { k++; p *= rnd(); } while (p > L); return k - 1; };
const pick = (arr, w) => { const t = w.reduce((a, b) => a + b, 0); let x = rnd() * t; for (let i = 0; i < arr.length; i++) { x -= w[i]; if (x <= 0) return arr[i]; } return arr[arr.length - 1]; };
const shuffle = (a) => { for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(rnd() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };
const clampHalf = (x) => Math.min(10, Math.max(0, Math.round(x * 2) / 2));
const POS = ['GOL', 'ZAG', 'LAT', 'VOL', 'MEI', 'ATA', 'PON'];
const ATTACK = { GOL: 0.02, ZAG: 0.25, LAT: 0.35, VOL: 0.45, MEI: 0.9, ATA: 1.6, PON: 1.4 };
const CREATE = { GOL: 0.03, ZAG: 0.3, LAT: 0.6, VOL: 0.7, MEI: 1.2, ATA: 0.8, PON: 1.0 };

function simulatePelada(P = E.PARAMS) {
  const size = 25 + Math.floor(rnd() * 16);
  const players = Array.from({ length: size }, (_, i) => ({
    id: i,
    pos: i < 3 ? 'GOL' : pick(POS.slice(1), [22, 18, 15, 20, 15, 10]),
    skill: normal(),
    attend: 0.45 + rnd() * 0.5,
    temper: rnd() < 0.15 ? 3 : 1,
    joinedRound: rnd() < 0.85 ? 0 : Math.floor(rnd() * ROUNDS * 0.6),
    log: [],
    rounds: [],
  }));
  const tracking = rnd() < 0.5;
  const matches = [];
  const voteStats = { playerMatches: 0, valid: 0, teamVotes: [], err: [] };
  for (let r = 0; r < ROUNDS; r++) {
    const eligible = players.filter((p) => p.joinedRound <= r);
    const present = eligible.filter((p) => rnd() < p.attend);
    for (const p of eligible) p.rounds.push(false);
    const keepers = shuffle(present.filter((p) => p.pos === 'GOL'));
    const field = shuffle(present.filter((p) => p.pos !== 'GOL'));
    const perTeam = Math.min(11, Math.floor(present.length / 2));
    if (perTeam < 5) continue; // rodada sem jogo: não conta para ninguém
    const teams = [[], []];
    keepers.slice(0, 2).forEach((k, i) => teams[i].push(k));
    const bench = [...keepers.slice(2), ...field];
    for (const p of field) { const t = teams[0].length <= teams[1].length ? 0 : 1; if (teams[t].length < perTeam) teams[t].push(p); }
    // Reservas: quem sobrou entra com 60% de chance (conta como participante).
    for (const p of bench.filter((x) => !teams[0].includes(x) && !teams[1].includes(x))) if (rnd() < 0.6) teams[rnd() < 0.5 ? 0 : 1].push(p);
    const str = teams.map((t) => t.reduce((s, p) => s + p.skill, 0) / t.length);
    const goals = [0, 1].map((t) => poisson(2.6 * Math.exp(0.6 * (str[t] - str[1 - t]))));
    const lines = new Map();
    for (const [t, team] of teams.entries()) for (const p of team) lines.set(p, { team: t, goals: 0, assists: 0, saves: null, yellow: 0, red: 0 });
    for (const t of [0, 1]) for (let g = 0; g < goals[t]; g++) {
      const team = teams[t];
      const scorer = pick(team, team.map((p) => ATTACK[p.pos] * Math.exp(0.5 * p.skill)));
      lines.get(scorer).goals++;
      if (rnd() < 0.75) {
        const others = team.filter((p) => p !== scorer);
        if (others.length) lines.get(pick(others, others.map((p) => CREATE[p.pos] * Math.exp(0.5 * p.skill)))).assists++;
      }
    }
    for (const [p, l] of lines) {
      if (p.pos === 'GOL' && rnd() < 0.8) l.saves = poisson(1.6 * Math.exp(0.4 * p.skill));
      if (tracking) {
        if (rnd() < 0.005 * p.temper) l.red = 1; // segundo amarelo também chega aqui como um vermelho
        else if (rnd() < 0.008 * p.temper) l.red = 1;
        else if (rnd() < 0.05 * p.temper) l.yellow = 1;
      }
    }
    // Votação: 60% dos participantes votam, cada um avalia 40% a 100% dos outros.
    const parts = [...lines.keys()];
    const votes = new Map(parts.map((p) => [p, { mates: [], opps: [] }]));
    for (const v of parts) {
      if (rnd() >= 0.6) continue;
      const share = 0.4 + rnd() * 0.6;
      for (const t of parts) {
        if (t === v || rnd() > share) continue;
        const l = lines.get(t);
        const perf = 0.4 * l.goals + 0.25 * l.assists + (l.team === lines.get(v).team ? 0.2 : -0.2);
        const rating = clampHalf(6.6 + 1.1 * t.skill + perf + 1.1 * normal());
        votes.get(t)[l.team === lines.get(v).team ? 'mates' : 'opps'].push(rating);
      }
    }
    const res = goals[0] === goals[1] ? ['draw', 'draw'] : goals[0] > goals[1] ? ['win', 'loss'] : ['loss', 'win'];
    for (const [p, l] of lines) {
      const vv = votes.get(p);
      const q = E.matchScore(vv.mates, vv.opps);
      voteStats.playerMatches++;
      if (q !== null) {
        voteStats.valid++;
        voteStats.teamVotes.push(Math.min(vv.mates.length, vv.opps.length));
        voteStats.err.push({ k: Math.min(vv.mates.length, vv.opps.length), e: q - (6.6 + 1.1 * p.skill) });
      }
      p.log.push({ q, goals: l.goals, assists: l.assists, conceded: goals[1 - l.team], result: res[l.team], saves: l.saves,
        discipline: tracking ? 'confirmed' : 'not_tracked', yellow: l.yellow, red: l.red, round: r, pos: p.pos });
      p.rounds[p.rounds.length - 1] = true;
    }
    matches.push({ round: r, lines: [...lines].map(([p, l]) => ({ id: p.id, pos: p.pos, ...l })), goals });
  }
  return { players, matches, tracking, voteStats };
}

// Referências locais com os mesmos critérios do SQL (C3).
function refsFor(pelada, player, P, uptoRound = Infinity) {
  const recent = pelada.matches.filter((m) => m.round <= uptoRound).slice(-P.localWindow);
  const muG = {}; const muA = {};
  for (const pos of POS.slice(1)) {
    const rows = recent.flatMap((m) => m.lines.filter((l) => l.pos === pos && l.id !== player.id));
    muG[pos] = E.localReference(P.muG0[pos], rows.map((l) => l.goals), P);
    muA[pos] = E.localReference(P.muA0[pos], rows.map((l) => l.assists), P);
  }
  const sides = recent.flatMap((m) => [0, 1].filter((t) => !m.lines.some((l) => l.id === player.id && l.team === t)).map((t) => m.goals[1 - t]));
  return { muG, muA, muC: E.localReference(P.muC0, sides, P) };
}

function rate(pelada, p, P, uptoRound = Infinity) {
  const matches = p.log.filter((m) => m.round <= uptoRound);
  const roundsLimit = Math.min(p.rounds.length, Number.isFinite(uptoRound) ? uptoRound - p.joinedRound + 1 : p.rounds.length);
  return E.computeRating({ matches, rounds: p.rounds.slice(0, Math.max(0, roundsLimit)), position: p.pos,
    refs: refsFor(pelada, p, P, uptoRound), cardsTracking: pelada.tracking }, P);
}

const pct = (arr, q) => { if (!arr.length) return null; const s = [...arr].sort((a, b) => a - b); const i = (s.length - 1) * q; const lo = Math.floor(i); return s[lo] + (s[Math.ceil(i)] - s[lo]) * (i - lo); };
const summary = (arr) => ({ n: arr.length, min: Math.min(...arr), p5: pct(arr, 0.05), p25: pct(arr, 0.25), p50: pct(arr, 0.5), p75: pct(arr, 0.75), p95: pct(arr, 0.95), max: Math.max(...arr), mean: arr.reduce((a, b) => a + b, 0) / arr.length });
const round2 = (o) => JSON.parse(JSON.stringify(o, (k, v) => (typeof v === 'number' ? Math.round(v * 100) / 100 : v)));

const t0 = Date.now();
const peladas = Array.from({ length: PELADAS }, () => simulatePelada());
const rows = [];
const early = [];
for (const pel of peladas) for (const p of pel.players) {
  const r = rate(pel, p, E.PARAMS);
  rows.push({ pos: p.pos, skill: p.skill, attend: p.attend, tracking: pel.tracking, cards: p.log.reduce((s, m) => s + m.yellow + m.red, 0),
    matches: p.log.length, presence: p.rounds.filter(Boolean).length / Math.max(1, p.rounds.length), ...r });
  // Estabilidade: OVR quando o jogador completa a 5ª partida x OVR no fim.
  if (p.log.length >= 15) {
    const fifth = p.log[4].round;
    const r5 = rate(pel, p, E.PARAMS, fifth);
    early.push({ diff: r.OVR - r5.OVR });
  }
}
const elig = rows.filter((r) => r.eligible);
const byPos = Object.fromEntries(POS.map((pos) => [pos, summary(elig.filter((r) => r.pos === pos).map((r) => r.ovrDisplay))]));
const comps = Object.fromEntries(['ATU', 'EST', 'PEQ', 'RES', 'DIS', 'OVR'].map((k) => [k, summary(elig.map((r) => r[k]))]));
const compsByPos = Object.fromEntries(POS.map((pos) => [pos, Object.fromEntries(['ATU', 'EST', 'PEQ', 'RES'].map((k) => [k, pct(elig.filter((r) => r.pos === pos).map((r) => r[k]), 0.5)]))]));
const freq = Object.fromEntries([80, 85, 90, 95].map((t) => [`acima_de_${t}`, elig.filter((r) => r.ovrDisplay > t).length / elig.length]));
const tracked = elig.filter((r) => r.tracking);
const cardImpact = {
  sem_cartao: { n: tracked.filter((r) => r.cards === 0).length, DIS: pct(tracked.filter((r) => r.cards === 0).map((r) => r.DIS), 0.5) },
  um_cartao: { n: tracked.filter((r) => r.cards === 1).length, DIS: pct(tracked.filter((r) => r.cards === 1).map((r) => r.DIS), 0.5) },
  dois_ou_mais: { n: tracked.filter((r) => r.cards >= 2).length, DIS: pct(tracked.filter((r) => r.cards >= 2).map((r) => r.DIS), 0.5) },
  max_efeito_no_ovr: 0.05 * (99 - 50),
};
const bands = [[0, 0.6], [0.6, 0.75], [0.75, 0.9], [0.9, 1.01]];
const absenceImpact = bands.map(([a, b]) => { const g = elig.filter((r) => r.presence >= a && r.presence < b); return { presenca: `${a * 100}-${Math.min(100, b * 100)}%`, n: g.length, RES: pct(g.map((r) => r.RES), 0.5), OVR: pct(g.map((r) => r.ovrDisplay), 0.5) }; });
const exceptional = Object.fromEntries(POS.map((pos) => { const g = elig.filter((r) => r.pos === pos).sort((a, b) => b.skill - a.skill); const top = g.slice(0, Math.max(1, Math.floor(g.length * 0.02))); return [pos, { n: top.length, OVR_mediana: pct(top.map((r) => r.ovrDisplay), 0.5), EST_mediana: pct(top.map((r) => r.EST), 0.5), ATU_mediana: pct(top.map((r) => r.ATU), 0.5) }]; }));
const vs = peladas.reduce((a, p) => ({ pm: a.pm + p.voteStats.playerMatches, v: a.v + p.voteStats.valid }), { pm: 0, v: 0 });
const errByK = [1, 2, 3, 5, 8].map((k, i, arr) => { const hi = arr[i + 1] ?? 99; const e = peladas.flatMap((p) => p.voteStats.err).filter((x) => x.k >= k && x.k < hi).map((x) => Math.abs(x.e)); return { votos_no_menor_grupo: hi === 99 ? `${k}+` : `${k}-${hi - 1}`, n: e.length, erro_abs_medio: e.reduce((a, b) => a + b, 0) / Math.max(1, e.length) }; });
// Sensibilidade dos parâmetros experimentais (200 peladas, mesma população).
const variants = {
  base: {}, alphaK_75: { alphaK: 75 }, alphaK_300: { alphaK: 300 }, refShrink_1: { refShrink: 1 }, refShrink_6: { refShrink: 6 },
  muC0_2_5: { muC0: 2.5 }, muC0_3_5: { muC0: 3.5 },
  refs_x0_8: { muG0: Object.fromEntries(Object.entries(E.PARAMS.muG0).map(([k, v]) => [k, v * 0.8])), muA0: Object.fromEntries(Object.entries(E.PARAMS.muA0).map(([k, v]) => [k, v * 0.8])) },
  refs_x1_2: { muG0: Object.fromEntries(Object.entries(E.PARAMS.muG0).map(([k, v]) => [k, v * 1.2])), muA0: Object.fromEntries(Object.entries(E.PARAMS.muA0).map(([k, v]) => [k, v * 1.2])) },
};
const sens = {};
for (const [name, over] of Object.entries(variants)) {
  const P = { ...E.PARAMS, ...over };
  const out = [];
  for (const pel of peladas.slice(0, 200)) for (const p of pel.players) { const r = rate(pel, p, P); if (r.eligible) out.push({ pos: p.pos, ovr: r.ovrDisplay }); }
  sens[name] = Object.fromEntries(POS.map((pos) => [pos, pct(out.filter((x) => x.pos === pos).map((x) => x.ovr), 0.5)]));
}

const result = round2({
  aviso: 'Dados sintéticos gerados por supabase/local_db/rating/simulate.mjs. Não são dados reais do aplicativo.',
  configuracao: { peladas: PELADAS, rodadas: ROUNDS, jogadores: rows.length, elegiveis_ovr: elig.length, partidas: peladas.reduce((s, p) => s + p.matches.length, 0), segundos: (Date.now() - t0) / 1000 },
  ovr_por_posicao: byPos, componentes: comps, componentes_mediana_por_posicao: compsByPos, frequencia_ovr: freq,
  cartoes: cardImpact, ausencias: absenceImpact,
  estabilidade_historico_curto: { n: early.length, diferenca_ovr_5a_partida_x_final: summary(early.map((x) => x.diff)) },
  excepcionais_top2pct_por_posicao: exceptional,
  votacao: { cobertura_jogador_partida_com_nota_valida: vs.v / vs.pm, avaliacao_insuficiente: 1 - vs.v / vs.pm, erro_da_nota_por_votos: errByK },
  sensibilidade_mediana_ovr_por_posicao: sens,
});
writeFileSync(join(import.meta.dirname, '..', '..', '..', 'docs', 'v5_simulacao_resultados.json'), JSON.stringify(result, null, 1));
console.log(JSON.stringify(result.configuracao), '\nOVR mediano por posição:', Object.fromEntries(Object.entries(byPos).map(([k, v]) => [k, Math.round(v.p50)])));
