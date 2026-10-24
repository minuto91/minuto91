// Central do Jogador 2.0: regras de exibição puras (sem React Native nem Supabase), testadas em tests/central.test.ts.
// Nada aqui calcula OVR, nota ou prazo: só decide o que mostrar a partir dos valores oficiais que o servidor devolve.

/** Votação urgente: aberta e com até 1 hora restante pelo relógio do servidor (Central 2.0, item 9.1). */
export const URGENT_MS = 60 * 60 * 1000;

/** Diferença entre o relógio do servidor e o do aparelho (ms). Sem horário do servidor, 0. */
export function serverOffset(serverTime: string | null | undefined, deviceNow: number = Date.now()) {
  const t = serverTime ? new Date(serverTime).getTime() : NaN;
  return Number.isFinite(t) ? t - deviceNow : 0;
}

export type VoteState = 'urgent' | 'open' | 'closed';

/** Estado de uma votação pelo prazo vigente (já com prorrogações, que o servidor aplica no closes_at). */
export function voteState(closesAt: string, offsetMs: number, deviceNow: number = Date.now()): VoteState {
  const left = new Date(closesAt).getTime() - (deviceNow + offsetMs);
  if (!(left > 0)) return 'closed';
  return left <= URGENT_MS ? 'urgent' : 'open';
}

/** Texto do tempo restante (só exibição; quem decide se ainda dá para votar é o servidor). */
export function leftLabel(closesAt: string, offsetMs: number, deviceNow: number = Date.now()) {
  const ms = new Date(closesAt).getTime() - (deviceNow + offsetMs);
  if (ms <= 0) return 'Prazo encerrado';
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  if (h >= 24) return `Faltam ${Math.floor(h / 24)}d ${h % 24}h`;
  return h > 0 ? `Faltam ${h}h${String(m).padStart(2, '0')}` : `Faltam ${Math.max(1, m)} min`;
}

/** Momento (aparelho) em que a votação entra na última hora ou termina: a Central se reavalia nesse instante. */
export function nextVoteBoundary(closesAts: string[], offsetMs: number, deviceNow: number = Date.now()) {
  const marks = closesAts.flatMap((c) => {
    const close = new Date(c).getTime() - offsetMs;
    return [close - URGENT_MS, close];
  });
  return marks.filter((t) => t > deviceNow).sort((a, b) => a - b)[0] ?? null;
}

export type HistoryRow = { match_id: string | null; ovr_display: number | null; created_at: string };

/**
 * Variação do OVR desde a última publicação, na mesma pelada (o histórico já é de uma única inscrição).
 * Compara o OVR atual com o OVR registrado ao fim da partida anterior à mais recente. Só entram registros
 * oficiais com OVR exibido (antes de 5 partidas não há número) e ligados a uma partida.
 * null = sem publicação anterior comparável (a Central omite a variação).
 */
export function ovrDelta(current: number | null | undefined, rows: HistoryRow[]): number | null {
  if (current === null || current === undefined) return null;
  const perMatch = new Map<string, HistoryRow>();
  for (const r of rows) {
    if (!r.match_id || r.ovr_display === null || r.ovr_display === undefined) continue;
    const seen = perMatch.get(r.match_id);
    if (!seen || seen.created_at < r.created_at) perMatch.set(r.match_id, r);
  }
  const latest = [...perMatch.values()].sort((a, b) => b.created_at.localeCompare(a.created_at));
  if (latest.length < 2) return null;
  return current - (latest[1].ovr_display as number);
}

export const deltaText = (d: number) => (d > 0 ? `+${d}` : d < 0 ? `−${Math.abs(d)}` : '0');
export const deltaA11y = (d: number) =>
  d > 0
    ? `subiu ${d} ${d === 1 ? 'ponto' : 'pontos'} desde a última publicação`
    : d < 0
      ? `caiu ${-d} ${d === -1 ? 'ponto' : 'pontos'} desde a última publicação`
      : 'sem alteração desde a última publicação';

export type MatchRating =
  | { kind: 'rated'; value: number }
  | { kind: 'pending' } // votação aberta ou aguardando a publicação do administrador
  | { kind: 'insufficient' } // publicada, mas sem votos suficientes para nota
  | { kind: 'none' }; // partida sem votação (ou o jogador não jogou)

/**
 * Nota da partida (não é o OVR). Só aparece depois da publicação oficial: antes disso, nada provisório.
 * session = votação da V5 (rating_vote_sessions); legacy = votação antiga já finalizada (013).
 */
export function matchRating(input: {
  played: boolean;
  result: { final_rating: number | null; has_valid_rating: boolean } | null;
  session: { status: string } | null;
  legacyFinalized: boolean;
}): MatchRating {
  if (!input.played) return { kind: 'none' };
  const published = input.session ? input.session.status === 'published' : input.legacyFinalized;
  if (input.session && (input.session.status === 'open' || input.session.status === 'awaiting_publication')) return { kind: 'pending' };
  if (!published) return { kind: 'none' };
  if (input.result?.has_valid_rating && input.result.final_rating !== null) return { kind: 'rated', value: Number(input.result.final_rating) };
  return { kind: 'insufficient' };
}

export const resultOf = (myTeam: 'A' | 'B', a: number, b: number): 'win' | 'draw' | 'loss' => {
  const mine = myTeam === 'A' ? a : b;
  const other = myTeam === 'A' ? b : a;
  return mine > other ? 'win' : mine < other ? 'loss' : 'draw';
};

/** Pelada aberta na Central: a guardada, se o jogador ainda está nela; senão a principal; senão a primeira. */
export function pickPelada<T extends { id: string; is_primary?: boolean }>(peladas: T[], stored: string | null) {
  return peladas.find((p) => p.id === stored) ?? peladas.find((p) => p.is_primary) ?? peladas[0] ?? null;
}

/** Só o que é da pelada escolhida (nunca misturar peladas). */
export const ofPelada = <T extends { pelada_id: string }>(items: T[], peladaId: string | null) =>
  peladaId ? items.filter((i) => i.pelada_id === peladaId) : [];
