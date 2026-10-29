// V8.7: textos e regras de apresentação dos prêmios de temporada (Artilheiro, Maestro, Luva de Ouro) e de Meus Prêmios.
// A autoridade é o servidor (migração 068); aqui só se traduz o que ele devolve, sem inventar regra.

export type SeasonAwardType = 'season_craque' | 'season_top_scorer' | 'season_maestro' | 'season_golden_glove';
export type SeasonCategory = 'top_scorer' | 'maestro' | 'golden_glove';

/** Nomes oficiais (A01: "Chuteira de Ouro" é só a arte, nunca o nome do prêmio). */
export const SEASON_AWARD_LABEL: Record<SeasonAwardType, string> = {
  season_craque: 'Craque da Temporada',
  season_top_scorer: 'Artilheiro da Temporada',
  season_maestro: 'Maestro da Temporada',
  season_golden_glove: 'Luva de Ouro',
};
export const CATEGORY_TYPE: Record<SeasonCategory, SeasonAwardType> = {
  top_scorer: 'season_top_scorer',
  maestro: 'season_maestro',
  golden_glove: 'season_golden_glove',
};
export const CATEGORY_STAT: Record<SeasonCategory, string> = { top_scorer: 'gols', maestro: 'assistências', golden_glove: 'REF' };

export type SeasonTitle = {
  id: string;
  award_type: SeasonAwardType;
  season_id: string;
  season_name: string;
  year: number;
  starts_on: string;
  is_shared: boolean;
  pelada_id: string;
  pelada_name: string;
};

/** "Temporada 2026" -> "2026"; "Temporada 2027/1" -> "2027/1"; outro nome fica como está. */
export function seasonTag(name: string): string {
  const m = /^temporada\s+(.+)$/i.exec(name.trim());
  return (m ? m[1] : name).trim();
}

/** AD01: "Artilheiro da Temporada 2026". Só títulos oficiais de temporada; nome oficial + ano/temporada. */
export function titleLabel(t: Pick<SeasonTitle, 'award_type' | 'season_name'>): string {
  return `${SEASON_AWARD_LABEL[t.award_type]} ${seasonTag(t.season_name)}`;
}

/** Mais recente primeiro (o servidor já ordena; aqui garante a ordem para listas montadas no app). */
export function sortTitles(items: SeasonTitle[]): SeasonTitle[] {
  const ord: Record<SeasonAwardType, number> = { season_craque: 1, season_top_scorer: 2, season_maestro: 3, season_golden_glove: 4 };
  return [...items].sort((a, b) => b.starts_on.localeCompare(a.starts_on) || ord[a.award_type] - ord[b.award_type] || a.pelada_name.localeCompare(b.pelada_name));
}

/** Títulos da pelada escolhida no seletor da carreira (ou todos em "Geral"), já ordenados. */
export const scopedTitles = (items: SeasonTitle[] | null | undefined, peladaId?: string | null): SeasonTitle[] =>
  sortTitles((items ?? []).filter((t) => !peladaId || t.pelada_id === peladaId));

/** AD01: o bloco só aparece com pelo menos um título oficial válido (nunca bloco vazio). */
export const showMyAwards = (items: SeasonTitle[] | null | undefined): boolean => !!items && items.length > 0;

/** Várias peladas: só mostra a origem quando há mais de uma. */
export const showOrigin = (items: SeasonTitle[]): boolean => new Set(items.map((i) => i.pelada_id)).size > 1;

/** B06: partidas mínimas como GOL = max(piso, teto(percentual das partidas oficiais da pelada na temporada)). */
export function gloveRequirement(seasonMatches: number, percent = 50, floor = 5): number {
  return Math.max(floor, Math.ceil((percent * seasonMatches) / 100));
}

/** F01: exceção só reduz (percentual < 50 ou mínimo < 5), com piso absoluto de 3 atuações como GOL. */
export function exceptionParamsError(percent: number, minMatches: number): string | null {
  if (!Number.isInteger(percent) || !Number.isInteger(minMatches)) return 'Use números inteiros.';
  if (percent < 0 || percent > 50) return 'O percentual vai de 0 a 50.';
  if (minMatches < 3) return 'O mínimo absoluto é de 3 atuações como goleiro.';
  if (minMatches > 5) return 'A exceção só pode reduzir o mínimo (até 5).';
  if (percent >= 50 && minMatches >= 5) return 'A exceção precisa reduzir o percentual ou o mínimo de partidas.';
  return null;
}

export type CategoryStatus = 'published' | 'no_winner' | 'awaiting_exception' | 'pending';

export function categoryStatusText(cat: SeasonCategory, status: CategoryStatus, isAdmin: boolean): string {
  switch (status) {
    case 'published':
      return SEASON_AWARD_LABEL[CATEGORY_TYPE[cat]];
    case 'awaiting_exception':
      return isAdmin ? 'Nenhum goleiro elegível. Você pode autorizar uma exceção.' : 'Aguardando decisão da administração.';
    case 'pending':
      return 'Aguardando decisão da administração.';
    case 'no_winner':
      return cat === 'golden_glove' ? 'Sem goleiro elegível nesta temporada.' : 'Ninguém atingiu o mínimo de 1.';
  }
}

/** Valor principal do vencedor para a retrospectiva e as artes (gols, assistências ou REF, sem casas inúteis). */
export function statText(cat: SeasonCategory, value: number | string | null | undefined): string {
  if (value === null || value === undefined) return '';
  const n = Number(value);
  if (cat === 'golden_glove') return `REF ${n.toFixed(1).replace('.', ',')}`;
  return `${n} ${CATEGORY_STAT[cat] === 'gols' ? (n === 1 ? 'gol' : 'gols') : n === 1 ? 'assistência' : 'assistências'}`;
}

/** C03: título compartilhado é identificado, mas cada vencedor recebe o troféu inteiro. */
export const sharedLabel = (isShared: boolean) => (isShared ? 'Título compartilhado' : '');

// Sala de Troféus (C02/F02): estes três tipos têm só o contador acumulado; o detalhe por temporada vive em Meus Prêmios e na Retrospectiva.
export const COUNTER_ONLY = ['season_top_scorer', 'season_maestro', 'season_golden_glove'] as const;

// Retrospectiva (C04/C05): vencedores publicados (só a versão corrente) e a regra de quem tem arte individual.
export type AwardWinner = { membership_id: string; name: string; avatar_path: string | null; value: number | string | null; is_shared: boolean };
export type SeasonAwardsData = Partial<Record<SeasonCategory, { version: number; basis: 'normal' | 'exception'; winners: AwardWinner[] }>>;
export const AWARD_CATEGORIES: SeasonCategory[] = ['top_scorer', 'maestro', 'golden_glove'];

/** Categorias em que a pessoa é vencedora na retrospectiva (vazio = não existe arte individual de títulos). */
export function myAwardTitles(retro: { season_awards?: SeasonAwardsData }, membershipId: string | null | undefined): SeasonCategory[] {
  if (!membershipId) return [];
  return AWARD_CATEGORIES.filter((c) => retro.season_awards?.[c]?.winners.some((w) => w.membership_id === membershipId));
}
