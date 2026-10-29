// V8.4 — E15: proteções de navegação sem React (testadas em tests/v84.test.ts).

/** Trava toques repetidos no mesmo destino (E15-16/26, E12): o segundo toque dentro da janela é ignorado. */
export function createNavLock(windowMs = 700, clock: () => number = Date.now) {
  let lastKey = '';
  let lastAt = -Infinity;
  return (key: string) => {
    const now = clock();
    if (key === lastKey && now - lastAt < windowMs) return false;
    lastKey = key;
    lastAt = now;
    return true;
  };
}

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
// Destinos que um aviso do servidor pode abrir. Fora disso: Central (E15-17/33).
const SAFE = new RegExp(
  `^/(partida/${UUID}(/(votar|meus-votos))?|pelada/${UUID}(/(retrospectiva|rankings|partidas|elenco))?|jogador/${UUID}|album|conta|notificacoes)?$`,
  'i',
);
const PARAM = new RegExp(`^${UUID}$`, 'i');

/** Caminho vindo de push/aviso: só rotas do próprio app com ID válido (E15-06/23/32/33). */
export const isSafePath = (p: unknown): p is string => typeof p === 'string' && SAFE.test(p);

/** Parâmetro de rota que precisa ser UUID (E15-32): inválido não abre conteúdo nenhum. */
export const validParam = (v: string | string[] | undefined): string | null => {
  const s = Array.isArray(v) ? v[0] : v;
  return s && PARAM.test(s) ? s : null;
};

/**
 * Push tocado (E15-17/20): com o app encerrado (partida a frio) a Central entra primeiro, para o "voltar"
 * terminar nela; com o app aberto o destino empilha sobre a tela atual. Caminho inseguro: só a Central, e só a frio.
 */
export function planPushOpen(path: unknown, cold: boolean): string[] {
  if (!isSafePath(path) || path === '' || path === '/') return cold ? ['/'] : [];
  return cold ? ['/', path] : [path];
}
