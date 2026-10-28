// REV-035: filtros e abas lembrados enquanto o app está aberto. Ao sair de uma tela e voltar (ou abrir de novo a
// mesma pelada), a pessoa encontra a mesma aba, temporada e filtro. Só memória: nada vai para o servidor nem para o disco.
import { useState } from 'react';

const store = new Map<string, unknown>();

export function useSticky<T>(key: string, initial: T) {
  const [value, setValue] = useState<T>(() => (store.has(key) ? (store.get(key) as T) : initial));
  const set = (v: T) => {
    store.set(key, v);
    setValue(v);
  };
  return [value, set] as const;
}
