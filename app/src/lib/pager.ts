// Estado de uma lista paginada no servidor (V4.5), sem React: usePaged (paging.ts) só liga isto à tela.
// Fica separado para ser testado no Node (supabase/local_db/pager_logic.test.mjs) sem simulador.
//
// Regras (cada uma corrige um caso da V4.4):
//  - Uma página "a mais" por vez: dois pedidos de loadMore seguidos (rolagem + botão, ou onEndReached duas vezes antes
//    da tela atualizar) não buscam a mesma página duas vezes.
//  - Cada carga tem uma geração. Recarregar, trocar o filtro ou sair da tela invalida tudo o que estava a caminho:
//    resposta atrasada de antes nunca entra na lista nova.
//  - Enquanto a primeira página está recarregando, loadMore espera: o cursor antigo não é usado na lista nova.
//  - Itens repetidos (mesma chave) não entram duas vezes (ex.: um lançamento que mudou de data entre duas páginas).
//  - Trocar o filtro limpa a lista (não mostra itens do filtro anterior como se fossem do novo); recarregar com o
//    mesmo filtro mantém a lista na tela até a resposta chegar.
//  - Depois de dispose (tela desmontada) nada mais é avisado.

export type Page<T, C, S = unknown> = { items: T[]; next: C | null; summary?: S | null };

export type PagerState<T, S> = {
  items: T[] | null;
  summary: S | null;
  error: string | null;
  hasMore: boolean;
  loading: boolean;
  loadingMore: boolean;
};

export class Pager<T, C, S = unknown> {
  private fetchPage: ((after: C | null) => Promise<Page<T, C, S>>) | null = null;
  private gen = 0;
  private next: C | null = null;
  private moreGen = -1; // geração do loadMore em andamento (-1 = nenhum)
  private disposed = false;
  private state: PagerState<T, S> = { items: null, summary: null, error: null, hasMore: false, loading: false, loadingMore: false };

  private readonly onChange: (s: PagerState<T, S>) => void;
  private readonly keyOf?: (item: T) => string;
  private readonly describe: (e: unknown) => string;

  constructor(onChange: (s: PagerState<T, S>) => void, keyOf?: (item: T) => string, describe?: (e: unknown) => string) {
    this.onChange = onChange;
    this.keyOf = keyOf;
    this.describe = describe ?? ((e) => (e instanceof Error ? e.message : String(e)));
  }

  get snapshot(): PagerState<T, S> {
    return this.state;
  }

  private set(patch: Partial<PagerState<T, S>>) {
    if (this.disposed) return;
    this.state = { ...this.state, ...patch };
    this.onChange(this.state);
  }

  private dedupe(base: T[], add: T[]): T[] {
    if (!this.keyOf) return [...base, ...add];
    const seen = new Set(base.map(this.keyOf));
    const out = [...base];
    for (const x of add) {
      const k = this.keyOf(x);
      if (!seen.has(k)) {
        seen.add(k);
        out.push(x);
      }
    }
    return out;
  }

  /** Liga (ou troca) a função que busca uma página e carrega a primeira. Filtro novo = lista limpa. */
  load(fetchPage: (after: C | null) => Promise<Page<T, C, S>>): Promise<void> {
    const changed = fetchPage !== this.fetchPage;
    this.fetchPage = fetchPage;
    return this.reload(changed);
  }

  /** Recarrega a primeira página com o filtro atual. */
  async reload(clear = false): Promise<void> {
    const fetchPage = this.fetchPage;
    if (!fetchPage || this.disposed) return;
    const g = ++this.gen;
    this.next = null;
    this.moreGen = -1;
    this.set(clear ? { items: null, summary: null, error: null, hasMore: false, loading: true, loadingMore: false } : { loading: true, loadingMore: false, hasMore: false });
    try {
      const p = await fetchPage(null);
      if (g !== this.gen) return;
      this.next = p.next ?? null;
      this.set({ items: this.dedupe([], p.items), summary: p.summary ?? null, error: null, hasMore: !!this.next, loading: false });
    } catch (e) {
      if (g !== this.gen) return;
      this.set({ error: this.describe(e), loading: false, hasMore: !!this.next });
    }
  }

  /** Próxima página. Ignorado se já houver uma a caminho, se não houver mais, ou durante a recarga. */
  async loadMore(): Promise<void> {
    const fetchPage = this.fetchPage;
    const cursor = this.next;
    if (!fetchPage || cursor === null || this.disposed || this.state.loading || this.moreGen === this.gen) return;
    const g = this.gen;
    this.moreGen = g;
    this.set({ loadingMore: true });
    try {
      const p = await fetchPage(cursor);
      if (g !== this.gen) return;
      this.next = p.next ?? null;
      this.set({ items: this.dedupe(this.state.items ?? [], p.items), hasMore: !!this.next, error: null });
    } catch (e) {
      if (g !== this.gen) return;
      this.set({ error: this.describe(e) });
    } finally {
      if (g === this.gen) {
        this.moreGen = -1;
        this.set({ loadingMore: false });
      }
    }
  }

  /** Troca um item já carregado pela versão nova que o servidor devolveu (sem recarregar a lista). */
  replace(match: (x: T) => boolean, item: T) {
    if (this.state.items) this.set({ items: this.state.items.map((x) => (match(x) ? item : x)) });
  }

  setSummary(update: (s: S | null) => S | null) {
    this.set({ summary: update(this.state.summary) });
  }

  /** Invalida o que está a caminho (ex.: a tela perdeu o foco); a lista na tela fica como está. */
  cancel() {
    this.gen++;
    this.moreGen = -1;
    if (this.state.loading || this.state.loadingMore) this.set({ loading: false, loadingMore: false, hasMore: !!this.next });
  }

  dispose() {
    this.gen++;
    this.disposed = true;
  }
}

/**
 * Lê todas as páginas (uso fora da exportação financeira, que tem chamada própria num único instantâneo).
 * Para no primeiro erro e se o servidor repetir o cursor (nunca entra em laço).
 */
export async function readAllPages<T, C>(
  fetchPage: (after: C | null) => Promise<Page<T, C>>,
  onProgress?: (count: number) => void,
  maxPages = 1000,
): Promise<T[]> {
  const all: T[] = [];
  const seen = new Set<string>();
  let after: C | null = null;
  for (let n = 0; n < maxPages; n++) {
    const p: Page<T, C> = await fetchPage(after);
    all.push(...p.items);
    onProgress?.(all.length);
    if (!p.next) return all;
    const k = JSON.stringify(p.next);
    if (seen.has(k)) throw new Error('PAGING_STUCK');
    seen.add(k);
    after = p.next;
  }
  throw new Error('PAGING_STUCK');
}
