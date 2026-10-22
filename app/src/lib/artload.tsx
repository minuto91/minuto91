// A25: a arte só é capturada depois que as imagens dela (foto, escudo) carregaram. Cada imagem dentro de
// um <ArtImagesProvider> se registra como pendente e avisa quando carregou ou falhou; fora de uma arte,
// useArtImage não faz nada. Se uma imagem não carregar no prazo, a captura segue assim mesmo (a foto
// cai nas iniciais e o escudo no padrão), em vez de travar o compartilhamento.
import { createContext, ReactNode, useContext, useEffect, useState } from 'react';

type Tracker = { add: (k: string) => void; done: (k: string) => void; idle: (timeoutMs: number) => Promise<boolean> };

const Ctx = createContext<Tracker | null>(null);

export function ArtImagesProvider({ children, tracker }: { children: ReactNode; tracker: Tracker }) {
  return <Ctx.Provider value={tracker}>{children}</Ctx.Provider>;
}

/** Cria o rastreador de uma arte (guardar em useRef no componente que captura). */
export function createTracker(): Tracker {
  const pending = new Set<string>();
  const finished = new Set<string>();
  return {
    add: (k) => {
      if (!finished.has(k)) pending.add(k);
    },
    done: (k) => {
      finished.add(k);
      pending.delete(k);
    },
    // true = todas carregaram; false = venceu o prazo com alguma pendente.
    idle: async (timeoutMs) => {
      const end = Date.now() + timeoutMs;
      while (pending.size > 0 && Date.now() < end) await new Promise((r) => setTimeout(r, 100));
      return pending.size === 0;
    },
  };
}

export function useArtTracker() {
  return useState(createTracker)[0];
}

/** Registra uma imagem da arte. Chamar `done` no onLoad e no onError da imagem. */
export function useArtImage(url: string | null) {
  const t = useContext(Ctx);
  useEffect(() => {
    if (!t || !url) return;
    t.add(url);
    return () => t.done(url);
  }, [t, url]);
  return { done: () => url && t?.done(url) };
}
