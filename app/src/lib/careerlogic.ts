// V10.0 — Minha Carreira em página contínua (REV-123 a REV-132): regras puras, testadas em tests/career10.test.ts.
import type { SeasonTitle } from './v87logic';

// Mais recente primeiro; empate: ordem fixa dos títulos e nome da pelada (mesma regra de sortTitles, v87logic).
const TITLE_ORDER: Record<string, number> = { season_craque: 1, season_top_scorer: 2, season_maestro: 3, season_golden_glove: 4 };
const sortTitles = (items: SeasonTitle[]) =>
  [...items].sort((a, b) => b.starts_on.localeCompare(a.starts_on) || (TITLE_ORDER[a.award_type] ?? 9) - (TITLE_ORDER[b.award_type] ?? 9) || a.pelada_name.localeCompare(b.pelada_name));

/** REV-131: o filtro de temporada mostra só o ano (ex.: "2026"); se dois filtros caírem no mesmo ano, o nome desempata. */
export function yearOptions(seasons: { season_id: string; name: string; starts_on: string }[]) {
  const years = seasons.map((s) => (s.starts_on ?? '').slice(0, 4) || s.name);
  return seasons.map((s, i) => ({
    value: s.season_id,
    label: years.filter((y) => y === years[i]).length > 1 ? `${years[i]} · ${s.name}` : years[i],
  }));
}

/** REV-125: texto visível "Meio-campo" no lugar de "Meio-campista" (identificadores internos não mudam). */
export const visiblePosition = (label: string) => label.replace(/Meio-campistas?/g, (m) => (m.endsWith('s') ? 'Meio-campos' : 'Meio-campo'));

/** Média de notas para o indicador: "–" quando não há nota válida (nunca zero inventado). */
export const avgLabel = (v: number | string | null | undefined) =>
  v === null || v === undefined || Number.isNaN(Number(v)) ? '–' : Number(v).toFixed(1).replace('.', ',');

export type Trophy = { key: string; type: string; label: string };

/**
 * REV-126: até três troféus para a seção compacta. Com data oficial só existem os títulos de temporada (mais recente
 * primeiro); os demais troféus são contadores sem data, então só completam as vagas, na ordem fixa da Sala de Troféus.
 * Zero troféus: lista vazia (a tela mostra "Você ainda não tem troféus.").
 */
export function recentTrophies(
  titles: SeasonTitle[] | null | undefined,
  counts: Record<string, number | undefined> | null | undefined,
  order: { type: string; label: string }[],
  max = 3,
): Trophy[] {
  const out: Trophy[] = sortTitles(titles ?? [])
    .slice(0, max)
    .map((t) => ({ key: t.id, type: t.award_type, label: t.award_type }));
  const taken = new Set(out.map((t) => t.type));
  for (const o of order) {
    if (out.length >= max) break;
    if (taken.has(o.type)) continue;
    if ((counts?.[o.type] ?? 0) > 0) out.push({ key: `c:${o.type}`, type: o.type, label: o.label });
  }
  return out.slice(0, max);
}

/** Ordem dos blocos de peladas na página: a pelada de origem (vinda do Início) primeiro; as demais em ordem estável. */
export function orderPeladas<T extends { pelada_id: string; name: string; status: string; totals?: { matches_played: number } }>(list: T[], firstId: string | null | undefined): T[] {
  return [...list].sort(
    (a, b) =>
      Number(b.pelada_id === firstId) - Number(a.pelada_id === firstId) ||
      Number(b.status === 'active') - Number(a.status === 'active') ||
      (b.totals?.matches_played ?? 0) - (a.totals?.matches_played ?? 0) ||
      a.name.localeCompare(b.name),
  );
}
