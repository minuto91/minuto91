// REV-138 (V10.0): placar primeiro e um registro por gol. Lógica pura, sem React nem Supabase.
// O banco guarda só totais (gols e assistências por jogador; gol contra com o jogador responsável); o pareamento
// gol ↔ assistência existe apenas na tela, e é refeito a partir dos totais ao reabrir a súmula.
export type GoalTeam = 'A' | 'B';

/** Um gol do placar. team = time que marcou (beneficiado). */
export type GoalRec = {
  id: string;
  team: GoalTeam;
  /** Gol contra: o jogador ADVERSÁRIO responsável (culprit); sem gol individual nem assistência. */
  own: boolean;
  /** Autor (key do jogador do time) quando não é gol contra. */
  author: string | null;
  /** Jogador do time que assistiu (key), ou null = sem assistência. */
  assist: string | null;
  /** Gol contra: key do adversário responsável. */
  culprit: string | null;
};

export type GoalPlayer = { key: string; team: GoalTeam; goals: number; assists: number };
export type GoalExtras = { unattributed: Record<GoalTeam, number>; ownGoals: Record<GoalTeam, number> };

let seq = 0;
export const newGoal = (team: GoalTeam): GoalRec => ({
  id: `g${Date.now().toString(36)}${seq++}`,
  team,
  own: false,
  author: null,
  assist: null,
  culprit: null,
});

export const scoreOf = (goals: GoalRec[]): Record<GoalTeam, number> => ({
  A: goals.filter((g) => g.team === 'A').length,
  B: goals.filter((g) => g.team === 'B').length,
});

/** Muda o placar de um time: aumentar acrescenta registros vazios; diminuir tira os últimos (a tela confirma antes). */
export function resizeGoals(goals: GoalRec[], team: GoalTeam, n: number): GoalRec[] {
  const mine = goals.filter((g) => g.team === team);
  const other = goals.filter((g) => g.team !== team);
  const next =
    n <= mine.length ? mine.slice(0, Math.max(0, n)) : [...mine, ...Array.from({ length: n - mine.length }, () => newGoal(team))];
  return team === 'A' ? [...next, ...other] : [...other, ...next];
}

/** Registros já preenchidos que seriam perdidos ao reduzir o placar de um time para n. */
export const filledLost = (goals: GoalRec[], team: GoalTeam, n: number) =>
  goals
    .filter((g) => g.team === team)
    .slice(Math.max(0, n))
    .filter((g) => g.author || g.culprit || g.assist).length;

/** Pendências: cada gol precisa de autor (ou gol contra com o adversário responsável); autor não assiste o próprio gol. */
export function goalProblems(goals: GoalRec[]): string[] {
  const out: string[] = [];
  goals.forEach((g, i) => {
    if (g.own) {
      if (!g.culprit) out.push(`Gol ${i + 1}: escolha o adversário do gol contra.`);
    } else if (!g.author) out.push(`Gol ${i + 1}: escolha o autor.`);
    if (!g.own && g.author && g.assist && g.author === g.assist) out.push(`Gol ${i + 1}: o autor não pode assistir o próprio gol.`);
  });
  return out;
}

/**
 * Reconstrói os registros a partir do que o banco guarda. Assistências são ligadas aos gols do mesmo time em ordem,
 * evitando que o autor assista o próprio gol; o que sobrar sem par continua guardado (nunca se perde assistência).
 * culprits = key do responsável por cada gol contra (um item por gol).
 */
export function goalsFromSheet(
  players: GoalPlayer[],
  extras: GoalExtras,
  culprits: string[],
  teamOf: (key: string) => GoalTeam | undefined,
): GoalRec[] {
  const out: GoalRec[] = [];
  for (const t of ['A', 'B'] as GoalTeam[]) {
    const mine: GoalRec[] = [];
    for (const p of players.filter((x) => x.team === t)) {
      for (let i = 0; i < p.goals; i++) mine.push({ ...newGoal(t), author: p.key });
    }
    const own = culprits.filter((k) => teamOf(k) && teamOf(k) !== t);
    for (const c of own) mine.push({ ...newGoal(t), own: true, culprit: c });
    const loose = Math.max(0, extras.ownGoals[t] - own.length);
    for (let i = 0; i < loose; i++) mine.push({ ...newGoal(t), own: true });
    for (let i = 0; i < extras.unattributed[t]; i++) mine.push(newGoal(t));
    const pool = players.filter((x) => x.team === t).flatMap((p) => Array.from({ length: p.assists }, () => p.key));
    for (const a of pool) {
      const slot = mine.find((g) => !g.own && !g.assist && g.author !== a) ?? mine.find((g) => !g.own && !g.assist);
      if (slot) slot.assist = a;
    }
    out.push(...mine);
  }
  return out;
}

/** Totais para gravar: gols/assistências por jogador, gols contra com responsável e gols sem autor (que bloqueiam a publicação). */
export function goalsToSheet(goals: GoalRec[]) {
  const goalsBy: Record<string, number> = {};
  const assistsBy: Record<string, number> = {};
  const culprits: string[] = [];
  const ownLoose: Record<GoalTeam, number> = { A: 0, B: 0 };
  const unattributed: Record<GoalTeam, number> = { A: 0, B: 0 };
  for (const g of goals) {
    if (g.own) {
      if (g.culprit) culprits.push(g.culprit);
      else ownLoose[g.team] += 1;
    } else if (g.author) {
      goalsBy[g.author] = (goalsBy[g.author] ?? 0) + 1;
      if (g.assist) assistsBy[g.assist] = (assistsBy[g.assist] ?? 0) + 1;
    } else unattributed[g.team] += 1;
  }
  return { goalsBy, assistsBy, culprits, ownLoose, unattributed };
}
