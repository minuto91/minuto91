// Listas paginadas no servidor (V4.4): o servidor devolve { items, next } com um cursor estável; a primeira página
// pode trazer um resumo do filtro inteiro (ex.: total em aberto), para a tela nunca somar só o que já carregou.
import { useFocusEffect } from 'expo-router';
import { useCallback, useRef, useState } from 'react';

import { friendly } from './errors';

export type Page<T, C, S = unknown> = { items: T[]; next: C | null; summary?: S | null };

/**
 * fetchPage deve vir de useCallback com os filtros nas dependências: quando ele muda, a lista recomeça da primeira
 * página. Respostas atrasadas de um filtro antigo são ignoradas.
 */
export function usePaged<T, C, S = unknown>(fetchPage: (after: C | null) => Promise<Page<T, C, S>>) {
  const [items, setItems] = useState<T[] | null>(null);
  const [next, setNext] = useState<C | null>(null);
  const [summary, setSummary] = useState<S | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loadingMore, setLoadingMore] = useState(false);
  const [reload, setReload] = useState(0);
  const gen = useRef(0);

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      const g = ++gen.current;
      void reload;
      (async () => {
        try {
          const p = await fetchPage(null);
          if (!alive || g !== gen.current) return;
          setItems(p.items);
          setNext(p.next ?? null);
          setSummary(p.summary ?? null);
          setError(null);
        } catch (e) {
          if (alive && g === gen.current) setError(friendly((e as Error).message));
        }
      })();
      return () => {
        alive = false;
      };
    }, [fetchPage, reload]),
  );

  async function loadMore() {
    if (!next || loadingMore) return;
    const g = gen.current;
    setLoadingMore(true);
    try {
      const p = await fetchPage(next);
      if (g !== gen.current) return;
      setItems((xs) => [...(xs ?? []), ...p.items]);
      setNext(p.next ?? null);
    } catch (e) {
      if (g === gen.current) setError(friendly((e as Error).message));
    } finally {
      setLoadingMore(false);
    }
  }

  /** Troca um item já carregado pela versão nova que o servidor devolveu (sem recarregar a lista). */
  function replace(match: (x: T) => boolean, item: T) {
    setItems((xs) => (xs ? xs.map((x) => (match(x) ? item : x)) : xs));
  }

  return {
    items,
    summary,
    setSummary,
    error,
    hasMore: !!next,
    loadingMore,
    loadMore,
    replace,
    refresh: () => setReload((n) => n + 1),
  };
}

/** Lê todas as páginas (exportação). Para no primeiro erro: nada parcial é entregue como se fosse completo. */
export async function readAllPages<T, C>(
  fetchPage: (after: C | null) => Promise<Page<T, C>>,
  onProgress?: (count: number) => void,
): Promise<T[]> {
  const all: T[] = [];
  let after: C | null = null;
  for (;;) {
    const p: Page<T, C> = await fetchPage(after);
    all.push(...p.items);
    onProgress?.(all.length);
    if (!p.next) return all;
    after = p.next;
  }
}
