// V8.6: textos e regras de apresentação do Craque da Temporada. A autoridade é o servidor (migração 063);
// aqui só se traduz o estado devolvido por get_season_craque, sem inventar regra.
export type CraqueStatus =
  | 'not_started'
  | 'awaiting_open'
  | 'round1'
  | 'round2'
  | 'awaiting_admin'
  | 'published'
  | 'no_winner'
  | 'tie_blocked';

export type CraqueCandidate = { membership_id: string; name: string | null; slot: string; substitute: boolean; ovr: number | null; finalist: boolean };

export const SLOT_LABEL: Record<string, string> = { ovr: 'Maior OVR', goals: 'Artilheiro', craque: 'Mais Craques da Partida' };

export function candidateReason(c: Pick<CraqueCandidate, 'slot' | 'substitute'>): string {
  const base = SLOT_LABEL[c.slot] ?? c.slot;
  return c.substitute ? `${base} (vaga repetida: próximo maior OVR)` : base;
}

export function statusTitle(status: CraqueStatus, round: number | null, reason?: string | null): string {
  switch (status) {
    case 'not_started':
      return 'Votação ainda não aberta';
    case 'awaiting_open':
      return 'Votação a reabrir (candidatos corrigidos)';
    case 'round1':
    case 'round2':
      return round === 2 ? 'Segundo turno em andamento' : 'Primeiro turno em andamento';
    case 'awaiting_admin':
      return 'Apuração encerrada: aguardando o administrador';
    case 'published':
      return 'Craque da Temporada';
    case 'tie_blocked':
      return 'Empate sem regra definida: aguardando decisão do produto';
    case 'no_winner':
      return reason === 'sem_quorum'
        ? 'Sem prêmio: a votação não atingiu o quórum'
        : reason === 'candidato_unico'
          ? 'Sem prêmio: só um candidato elegível'
          : 'Sem prêmio: nenhum candidato elegível';
  }
}

/** Tempo restante legível ("2 d 3 h", "45 min"); nunca negativo. */
export function remaining(closesAt: string | null | undefined, now: number): string | null {
  if (!closesAt) return null;
  const ms = Math.max(0, new Date(closesAt).getTime() - now);
  const min = Math.floor(ms / 60000);
  if (min < 1) return 'menos de 1 min';
  const d = Math.floor(min / 1440);
  const h = Math.floor((min % 1440) / 60);
  if (d > 0) return `${d} d ${h} h`;
  if (h > 0) return `${h} h ${min % 60} min`;
  return `${min} min`;
}

/** Quórum: ceil(50% dos habilitados) (V14), no mínimo um voto. */
export function quorum(electors: number): number {
  return Math.max(Math.ceil(electors / 2), 1);
}

/** Voto próprio só no primeiro turno com exatamente dois candidatos (V24/V30). */
export function canVoteSelf(round: number, candidateCount: number): boolean {
  return round === 1 && candidateCount === 2;
}
