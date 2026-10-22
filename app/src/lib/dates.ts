// Datas no fuso oficial da pelada (A15). toISOString() devolve a data em UTC: no Brasil, depois das 21h
// já seria "amanhã" e a temporada ou o mês podiam virar antes da hora. O fuso da pelada não é editável
// (migração 025) e hoje é sempre America/Sao_Paulo; quem tiver o fuso da pelada pode passá-lo.
export const PELADA_TZ = 'America/Sao_Paulo';

/** Hoje (AAAA-MM-DD) no fuso da pelada. */
export function todayIn(timeZone: string = PELADA_TZ, at: Date = new Date()): string {
  // en-CA formata como AAAA-MM-DD.
  return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(at);
}
