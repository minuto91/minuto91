// REV-045: busca por nome sem diferença de acentos nem maiúsculas; o campo só aparece em listas longas.
export const SEARCH_MIN_ITEMS = 12;

export const normalizeName = (s: string) =>
  s
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .trim();

export function matchesName(name: string, query: string) {
  const q = normalizeName(query);
  return q === '' || normalizeName(name).includes(q);
}

export const showSearch = (count: number) => count >= SEARCH_MIN_ITEMS;
