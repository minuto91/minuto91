// V8.4 — E16: estado de carregamento de cada bloco da Central, sem React nem rede (testado em tests/v84.test.ts).
// Regras: vazio confirmado ≠ erro ≠ offline ≠ acesso negado; dado anterior autorizado pode ficar, sinalizado como
// desatualizado (falha informativa); nada disso habilita escrita; resposta velha nunca sobrescreve resposta nova.

export type BlockStatus =
  | 'loading'
  | 'loaded'
  | 'empty_confirmed'
  | 'error'
  | 'offline_cached'
  | 'offline_uncached'
  | 'access_denied'
  | 'session_expired';

export type BlockState<T> = {
  status: BlockStatus;
  data: T | null;
  /** Há dado anterior que não foi confirmado agora (falha ou sem rede). */
  stale: boolean;
  refreshing: boolean;
  /** Instante (ms) da última confirmação REAL do servidor para este dado; null se nunca (E16-44). */
  syncedAt: number | null;
  error: string | null;
};

export const initialBlock = <T>(): BlockState<T> => ({ status: 'loading', data: null, stale: false, refreshing: false, syncedAt: null, error: null });

export type FailureKind = 'offline' | 'denied' | 'session' | 'other';

/** Classifica o erro do Supabase/fetch sem expor códigos internos para a pessoa. */
export function classifyError(e: unknown): FailureKind {
  const x = e as { message?: string; code?: string; status?: number } | null;
  const msg = `${x?.message ?? ''}`.toLowerCase();
  if (x?.status === 401 || /jwt expired|auth_required|invalid jwt|not authenticated/.test(msg) || x?.code === 'PGRST301') return 'session';
  if (x?.status === 403 || x?.code === '42501' || /pelada_not_found|permission denied|access_denied|not_a_member/.test(msg)) return 'denied';
  if (/network request failed|failed to fetch|fetch failed|networkerror|load failed|timeout|timed out|offline/.test(msg) || x?.status === 0) return 'offline';
  return 'other';
}

export type BlockEvent<T> =
  | { type: 'start' }
  | { type: 'success'; data: T | null; empty?: boolean; now: number }
  | { type: 'failure'; kind: FailureKind; message: string }
  | { type: 'seed'; data: T; syncedAt: number }; // cache autorizado lido do aparelho (nunca é "confirmado agora")

export function reduceBlock<T>(prev: BlockState<T>, ev: BlockEvent<T>): BlockState<T> {
  switch (ev.type) {
    case 'seed':
      // O cache só preenche enquanto nada melhor chegou; fica marcado como não confirmado.
      return prev.data !== null || prev.status !== 'loading'
        ? prev
        : { ...prev, status: 'loaded', data: ev.data, stale: true, syncedAt: ev.syncedAt };
    case 'start':
      return prev.data !== null || prev.status === 'empty_confirmed'
        ? { ...prev, refreshing: true }
        : { ...initialBlock<T>(), status: 'loading' };
    case 'success':
      return {
        status: ev.empty || ev.data === null ? 'empty_confirmed' : 'loaded',
        data: ev.empty ? null : ev.data,
        stale: false,
        refreshing: false,
        syncedAt: ev.now,
        error: null,
      };
    case 'failure': {
      const has = prev.data !== null;
      if (ev.kind === 'denied') return { ...initialBlock<T>(), status: 'access_denied', error: ev.message };
      if (ev.kind === 'session') return { ...initialBlock<T>(), status: 'session_expired', error: ev.message };
      if (ev.kind === 'offline') {
        return has
          ? { ...prev, status: 'offline_cached', stale: true, refreshing: false, error: null }
          : { ...initialBlock<T>(), status: 'offline_uncached' };
      }
      // Falha comum: o dado anterior permanece, sinalizado; sem dado, erro localizado com "tentar de novo".
      return has
        ? { ...prev, status: 'loaded', stale: true, refreshing: false, error: ev.message }
        : { ...initialBlock<T>(), status: 'error', error: ev.message };
    }
  }
}

export type Pass = { scope: string; id: number; epoch: number };

/**
 * Porteiro de respostas (E16-17/25/40/41): cada pedido recebe um passe; só o passe mais recente do escopo
 * (usuário + pelada + bloco) pode aplicar o resultado. Trocar de pelada, sair da conta ou pedir de novo invalida os antigos.
 */
export function createGate() {
  const latest = new Map<string, number>();
  let epoch = 0;
  let counter = 0;
  return {
    take(scope: string): Pass {
      const id = ++counter;
      latest.set(scope, id);
      return { scope, id, epoch };
    },
    isCurrent(p: Pass) {
      return p.epoch === epoch && latest.get(p.scope) === p.id;
    },
    /** Logout / troca de conta: nenhum passe emitido antes continua válido. */
    reset() {
      epoch++;
      latest.clear();
    },
  };
}

/** "Atualizado há 5 min" só quando houver instante real de sincronização (E16-44). */
export function syncedLabel(syncedAt: number | null, now: number): string | null {
  if (syncedAt === null) return null;
  const min = Math.max(0, Math.floor((now - syncedAt) / 60_000));
  if (min < 1) return 'Atualizado agora há pouco';
  if (min < 60) return `Atualizado há ${min} min`;
  const h = Math.floor(min / 60);
  if (h < 24) return `Atualizado há ${h} h`;
  return `Atualizado há ${Math.floor(h / 24)} d`;
}

/** Resultado de uma atualização com vários blocos: sucesso total só se todos confirmaram (E16-18/39). */
export function refreshOutcome(results: ('ok' | 'fail')[]): 'complete' | 'partial' | 'failed' {
  const ok = results.filter((r) => r === 'ok').length;
  return ok === results.length ? 'complete' : ok === 0 ? 'failed' : 'partial';
}

// ---------------------------------------------------------------------------------------------------------------
// Cache autorizado no aparelho (E16-19/23/26/27): segregado por usuário, nunca é fonte oficial nem habilita escrita.
// ---------------------------------------------------------------------------------------------------------------
export type KV = {
  getItem(k: string): Promise<string | null>;
  setItem(k: string, v: string): Promise<void>;
  removeItem(k: string): Promise<void>;
  getAllKeys(): Promise<readonly string[]>;
};

const PREFIX = 'm91:central:v1:';

export function createCache(storage: KV) {
  const key = (uid: string, scope: string) => `${PREFIX}${uid}:${scope}`;
  return {
    async get<T>(uid: string, scope: string): Promise<{ at: number; data: T } | null> {
      if (!uid) return null;
      try {
        const raw = await storage.getItem(key(uid, scope));
        if (!raw) return null;
        const v = JSON.parse(raw) as { at?: number; data?: T };
        return typeof v.at === 'number' && v.data !== undefined ? { at: v.at, data: v.data } : null;
      } catch {
        return null;
      }
    },
    async set<T>(uid: string, scope: string, data: T, at: number) {
      if (!uid) return;
      try {
        await storage.setItem(key(uid, scope), JSON.stringify({ at, data }));
      } catch {
        /* cache é só conforto */
      }
    },
    async remove(uid: string, scope: string) {
      try {
        await storage.removeItem(key(uid, scope));
      } catch {
        /* idem */
      }
    },
    /** Logout / troca de conta: apaga tudo o que for da Central (de qualquer usuário). */
    async clearAll() {
      try {
        const keys = (await storage.getAllKeys()).filter((k) => k.startsWith(PREFIX));
        await Promise.all(keys.map((k) => storage.removeItem(k)));
      } catch {
        /* idem */
      }
    },
  };
}
