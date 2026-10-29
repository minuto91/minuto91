// V8.4 — E09: toque repetido na aba ativa. A barra avisa; quem está na raiz da aba decide (subir ao topo ou
// atualizar a leitura). Voltar à raiz a partir de uma tela interna é feito pela própria pilha da aba.
const subs = new Set<() => void>();

export function onHomeTabRepress(cb: () => void) {
  subs.add(cb);
  return () => {
    subs.delete(cb);
  };
}

export function emitHomeTabRepress() {
  subs.forEach((f) => f());
}
