// V10.0 (REV-118): disposição dos 11 no campo para 4-3-3 e 4-4-2. Só desenho: a escolha dos jogadores e da formação é do
// servidor (migração 084); aqui a sigla decide apenas de que lado do campo cada um aparece (PE esquerda, CA/ATA centro,
// PD direita; LE esquerda, LD direita; MEI nas pontas e VOL no centro), nunca quem entra.
export type Sector = 'goalkeeper' | 'defender' | 'midfielder' | 'attacker';
export type SelRow = { sector: Sector; code: string | null; rank: number };

export const FORMATIONS = {
  '4-3-3': { attacker: 3, midfielder: 3, defender: 4, goalkeeper: 1 },
  '4-4-2': { attacker: 2, midfielder: 4, defender: 4, goalkeeper: 1 },
} as const;
export type FormationName = keyof typeof FORMATIONS;
export const isFormation = (f: unknown): f is FormationName => f === '4-3-3' || f === '4-4-2';

const SIDE: Record<string, number> = { LE: 0, PE: 0, ZAG: 1, CA: 1, ATA: 1, VOL: 1, MEI: 1, PD: 2, LD: 2 };
const sideOf = (code: string | null) => (code ? (SIDE[code] ?? 1) : 1);

/** Ordem esquerda → direita de uma linha. No meio, MEI ficam nas pontas e VOL no centro. */
export function orderLine<T extends SelRow>(sector: Sector, rows: T[]): T[] {
  const byRank = [...rows].sort((a, b) => a.rank - b.rank);
  if (sector === 'midfielder') {
    const vol = byRank.filter((r) => r.code === 'VOL');
    const rest = byRank.filter((r) => r.code !== 'VOL');
    const half = Math.ceil(rest.length / 2);
    return [...rest.slice(0, half), ...vol, ...rest.slice(half)];
  }
  return byRank.map((r, i) => ({ r, i })).sort((a, b) => sideOf(a.r.code) - sideOf(b.r.code) || a.i - b.i).map((x) => x.r);
}

/** As 11 vagas da formação, da linha de ataque ao goleiro; vaga sem jogador vem com row = null. */
export function arrange<T extends SelRow>(rows: T[], formation: FormationName): { sector: Sector; row: T | null }[] {
  const lines: Sector[] = ['attacker', 'midfielder', 'defender', 'goalkeeper'];
  return lines.flatMap((sector) => {
    const mine = orderLine(sector, rows.filter((r) => r.sector === sector)).slice(0, FORMATIONS[formation][sector]);
    return Array.from({ length: FORMATIONS[formation][sector] }, (_, i) => ({ sector, row: mine[i] ?? null }));
  });
}
