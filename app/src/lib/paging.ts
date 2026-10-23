// Listas paginadas no servidor (V4.4): o servidor devolve { items, next } com um cursor estável; a primeira página
// pode trazer um resumo do filtro inteiro (ex.: total em aberto), para a tela nunca somar só o que já carregou.
// V4.5: o estado e as regras de concorrência ficam em pager.ts (testado no Node); aqui só a ligação com a tela.
import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';

import { friendly } from './errors';
import { Page, Pager, PagerState } from './pager';

export type { Page } from './pager';
export { readAllPages } from './pager';

/**
 * fetchPage deve vir de useCallback com os filtros nas dependências: quando ele muda, a lista recomeça da primeira
 * página (vazia). Respostas atrasadas de um filtro antigo, de uma recarga anterior ou de quando a tela estava sem foco
 * são ignoradas; uma página a mais por vez. keyOf evita item repetido entre páginas.
 */
export function usePaged<T, C, S = unknown>(fetchPage: (after: C | null) => Promise<Page<T, C, S>>, keyOf?: (item: T) => string) {
  const [state, setState] = useState<PagerState<T, S>>({ items: null, summary: null, error: null, hasMore: false, loading: false, loadingMore: false });
  const [pager] = useState(() => new Pager<T, C, S>(setState, keyOf, (e) => friendly(e instanceof Error ? e.message : String((e as { message?: string })?.message ?? e))));

  useFocusEffect(
    useCallback(() => {
      void pager.load(fetchPage);
      return () => pager.cancel();
    }, [pager, fetchPage]),
  );

  return {
    items: state.items,
    summary: state.summary,
    setSummary: (update: (s: S | null) => S | null) => pager.setSummary(update),
    error: state.error,
    hasMore: state.hasMore,
    loading: state.loading,
    loadingMore: state.loadingMore,
    loadMore: () => void pager.loadMore(),
    /** Troca um item já carregado pela versão nova que o servidor devolveu (sem recarregar a lista). */
    replace: (match: (x: T) => boolean, item: T) => pager.replace(match, item),
    refresh: () => void pager.reload(),
  };
}
