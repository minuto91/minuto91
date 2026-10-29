// V8.4 — regras puras da Central (sem React nem Supabase), testadas em tests/v84.test.ts.
// E13 personalização, E07 atenção, E05/E06 indicadores por posição. Nada aqui calcula OVR, nota ou prazo.

/** Blocos configuráveis da Central: E04, E05, E06 (reordenam e ocultam) e E08 (só oculta; sempre por último). */
export type BlockId = 'next_round' | 'last_game' | 'career_summary' | 'my_peladas';
export const SPORT_BLOCKS: readonly BlockId[] = ['next_round', 'last_game', 'career_summary'];
export type Layout = { version: number; order: BlockId[]; hidden: BlockId[] };
export const DEFAULT_LAYOUT: Layout = { version: 0, order: [...SPORT_BLOCKS], hidden: [] };

const isBlock = (v: unknown): v is BlockId => v === 'my_peladas' || SPORT_BLOCKS.includes(v as BlockId);

/** Aceita só um layout íntegro do servidor; qualquer dúvida cai no padrão (a Central nunca fica sem blocos). */
export function normalizeLayout(raw: unknown): Layout {
  const r = raw as { version?: unknown; order?: unknown; hidden?: unknown } | null;
  if (!r || !Array.isArray(r.order) || !Array.isArray(r.hidden) || typeof r.version !== 'number') return DEFAULT_LAYOUT;
  const order = r.order as unknown[];
  const okOrder = order.length === 3 && SPORT_BLOCKS.every((b) => order.includes(b));
  const hidden = (r.hidden as unknown[]).filter(isBlock);
  if (!okOrder || hidden.length !== r.hidden.length || new Set(hidden).size !== hidden.length) return DEFAULT_LAYOUT;
  return { version: r.version, order: order as BlockId[], hidden };
}

/** E04–E06 visíveis na ordem escolhida. */
export const visibleSportBlocks = (l: Layout): BlockId[] => l.order.filter((b) => !l.hidden.includes(b));

/** E08: precisa de 2 ou mais peladas acessíveis e de não estar oculto. */
export const showMyPeladas = (l: Layout, accessiblePeladas: number) => accessiblePeladas >= 2 && !l.hidden.includes('my_peladas');

export function moveBlock(order: BlockId[], id: BlockId, dir: -1 | 1): BlockId[] {
  const i = order.indexOf(id);
  const j = i + dir;
  if (i < 0 || j < 0 || j >= order.length) return order;
  const next = [...order];
  [next[i], next[j]] = [next[j], next[i]];
  return next;
}

export const toggleHidden = (hidden: BlockId[], id: BlockId): BlockId[] =>
  hidden.includes(id) ? hidden.filter((h) => h !== id) : [...hidden, id];

export const sameLayout = (a: Layout, b: Layout) =>
  a.order.join() === b.order.join() && [...a.hidden].sort().join() === [...b.hidden].sort().join();

/** E07: 1 pendência principal + até 2 secundárias; o resto fica atrás de "Ver todas as pendências". */
export function splitAttention<T extends { rank: number }>(items: T[]) {
  const sorted = items
    .map((it, i) => ({ it, i }))
    .sort((a, b) => a.it.rank - b.it.rank || a.i - b.i)
    .map((x) => x.it);
  return { primary: sorted[0] ?? null, secondary: sorted.slice(1, 3), rest: sorted.slice(3), total: sorted.length };
}

export type PositionGroup = 'gk' | 'def' | 'mid' | 'att';
const GROUPS: Record<string, PositionGroup> = {
  GOL: 'gk', goalkeeper: 'gk',
  ZAG: 'def', LD: 'def', LE: 'def', defender: 'def',
  VOL: 'mid', MEI: 'mid', midfielder: 'mid',
  CA: 'att', PD: 'att', PE: 'att', ATA: 'att', attacker: 'att',
};
export const positionGroup = (p: string | null | undefined): PositionGroup | null => (p ? (GROUPS[p] ?? null) : null);

export type StatCell = { label: string; value: number };
export type LastGameFacts = {
  goals: number;
  assists: number;
  hard_saves: number | null;
  my_team: 'A' | 'B';
  team_a_score: number;
  team_b_score: number;
};

/**
 * E05: até 2 estatísticas oficiais da posição. Só entram números que o servidor já publicou: gols/assistências da
 * súmula, defesas difíceis (goleiro, só com registro confirmado: null = não registrado) e os gols sofridos
 * (placar oficial). Zero real aparece como 0; dado ausente não aparece.
 */
export function lastGameStats(position: string | null, g: LastGameFacts): StatCell[] {
  const against = g.my_team === 'A' ? g.team_b_score : g.team_a_score;
  const goals: StatCell = { label: g.goals === 1 ? 'Gol' : 'Gols', value: g.goals };
  const assists: StatCell = { label: 'Assist.', value: g.assists };
  switch (positionGroup(position)) {
    case 'gk': {
      const out: StatCell[] = [{ label: 'Gols sofridos', value: against }];
      if (g.hard_saves !== null) out.push({ label: 'Defesas difíceis', value: g.hard_saves });
      return out;
    }
    case 'def':
    case 'mid':
      return [assists, goals];
    default:
      return [goals, assists];
  }
}

export type CareerTotals = { matches_played: number; wins: number; draws: number; losses: number; goals: number; assists: number };

/** E06: até 4 indicadores oficiais, "Jogos" sempre primeiro; os demais seguem a posição. */
export function careerStats(position: string | null, t: CareerTotals): StatCell[] {
  const jogos: StatCell = { label: 'Jogos', value: t.matches_played };
  const v: StatCell = { label: 'Vitórias', value: t.wins };
  const g: StatCell = { label: 'Gols', value: t.goals };
  const a: StatCell = { label: 'Assist.', value: t.assists };
  switch (positionGroup(position)) {
    case 'gk':
      return [jogos, v, { label: 'Empates', value: t.draws }, { label: 'Derrotas', value: t.losses }];
    case 'def':
      return [jogos, v, a, g];
    case 'mid':
      return [jogos, a, g, v];
    case 'att':
      return [jogos, g, a, v];
    default:
      return [jogos, v, g, a];
  }
}
