// V10.0 — Início do jogador (REV-051 a REV-095): regras puras, sem React nem Supabase (testadas em tests/home.test.ts).
// A tela Início agrega TODAS as peladas do jogador e não depende de "pelada ativa". Nada aqui calcula OVR ou nota:
// só escolhe qual valor oficial mostrar.

export type CardCandidate = {
  pelada_id: string;
  eligible: boolean;
  ovr: number | null;
  /** Partidas oficiais em que entrou (da carreira, nunca do cliente). */
  matches: number;
  /** Data da partida oficial mais recente da pelada (ISO) ou null. */
  last_played_at: string | null;
};

/**
 * REV-055/079/080: o Card exibido é o de maior OVR entre as peladas com Card elegível. Desempate: mais partidas
 * oficiais; partida oficial mais recente; id da pelada (estável). Sem OVR elegível em nenhuma, não há Card (null).
 */
export function pickCard<T extends CardCandidate>(list: T[]): T | null {
  const ok = list.filter((c) => c.eligible && c.ovr !== null);
  if (ok.length === 0) return null;
  return [...ok].sort(
    (a, b) =>
      (b.ovr as number) - (a.ovr as number) ||
      b.matches - a.matches ||
      (b.last_played_at ?? '').localeCompare(a.last_played_at ?? '') ||
      a.pelada_id.localeCompare(b.pelada_id),
  )[0];
}

/** REV-057/067: partida oficial concluída mais recente entre as peladas (empate: id da partida, estável). */
export function pickLastGame<T extends { played_at: string; match_id: string }>(list: T[]): T | null {
  if (list.length === 0) return null;
  return [...list].sort((a, b) => b.played_at.localeCompare(a.played_at) || b.match_id.localeCompare(a.match_id))[0];
}

type Round = { scheduled_at?: string | null; pelada_id: string; match_id?: string | null; composition_id?: string | null; lineup_id?: string | null };

/**
 * REV-056/068: jogo futuro mais próximo entre as peladas. Só entram jogos com data (um confronto sem data não está
 * "marcado") que ainda não passaram. Empate: id da pelada e da partida.
 */
export function pickNextRound<T extends Round>(list: T[], now: number = Date.now()): T | null {
  const future = list.filter((r) => {
    if (!r.scheduled_at) return false;
    const t = new Date(r.scheduled_at).getTime();
    return Number.isFinite(t) && t >= now;
  });
  if (future.length === 0) return null;
  return [...future].sort(
    (a, b) =>
      new Date(a.scheduled_at as string).getTime() - new Date(b.scheduled_at as string).getTime() ||
      a.pelada_id.localeCompare(b.pelada_id) ||
      (a.match_id ?? '').localeCompare(b.match_id ?? ''),
  )[0];
}

/** REV-063: resultado em texto, do ponto de vista do time em que o jogador atuou. Sem time ou sem placar: null. */
export function resultLabel(myTeam: 'A' | 'B' | null, a: number | null, b: number | null): 'VITÓRIA' | 'DERROTA' | 'EMPATE' | null {
  if (a === null || b === null || a === undefined || b === undefined) return null;
  if (a === b) return 'EMPATE';
  if (!myTeam) return null;
  const mine = myTeam === 'A' ? a : b;
  const other = myTeam === 'A' ? b : a;
  return mine > other ? 'VITÓRIA' : 'DERROTA';
}

/** REV-065: só o que o jogador realizou (zeros omitidos). */
export function individualStats(g: { goals?: number | null; assists?: number | null }) {
  const out: { label: string; value: number }[] = [];
  if ((g.goals ?? 0) > 0) out.push({ label: (g.goals as number) === 1 ? 'Gol' : 'Gols', value: g.goals as number });
  if ((g.assists ?? 0) > 0) out.push({ label: (g.assists as number) === 1 ? 'Assistência' : 'Assistências', value: g.assists as number });
  return out;
}

// ---------- Saudação (REV-053 / REV-093 / REV-094) ----------
// As cinco frases aprovadas pelo fundador (04/11/2026).
export const GREETINGS: readonly string[] = [
  'Vamos pra mais um jogo, {nome}!',
  'Bora pro jogo, {nome}!',
  'Bora fazer história, {nome}!',
  'Bola rolando, {nome}!',
  'Hoje é dia de gol, {nome}!',
];
const NO_NAME = (s: string) => s.replace(/,?\s*\{nome\}/, '').replace(/\s+!/, '!');

/** Nome seguro para exibir: nunca null/undefined, e-mail ou id (REV-094). */
export function safeName(name: string | null | undefined): string | null {
  const n = (name ?? '').trim();
  if (!n || n.toLowerCase() === 'null' || n.toLowerCase() === 'undefined' || n.includes('@') || /^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(n)) return null;
  return n.split(/\s+/)[0];
}

/** Sorteia o índice da frase sem repetir o da vez anterior (quando há mais de uma). */
export function pickGreetingIndex(prev: number | null, rand: () => number = Math.random, total: number = GREETINGS.length): number {
  if (total <= 1) return 0;
  const pool = Array.from({ length: total }, (_, i) => i).filter((i) => i !== prev);
  return pool[Math.min(pool.length - 1, Math.floor(rand() * pool.length))];
}

export function greetingText(index: number, name: string | null | undefined): string {
  const phrase = GREETINGS[index] ?? GREETINGS[0];
  const n = safeName(name);
  return n ? phrase.replace('{nome}', n) : NO_NAME(phrase);
}
