// REV-044: rascunho temporário de formulários importantes, só no aparelho, por usuário + pelada + formulário.
// Nunca envia nada ao servidor: publicar, votar ou pagar continua exigindo a ação explícita da pessoa.
import AsyncStorage from '@react-native-async-storage/async-storage';
import { useEffect, useRef, useState } from 'react';

const PREFIX = 'm91.draft.v1';
const TTL_MS = 7 * 24 * 3600 * 1000; // rascunho velho é descartado

export const draftKey = (userId: string | null | undefined, form: string, peladaId?: string | null) =>
  `${PREFIX}:${userId ?? 'anon'}:${peladaId ?? '-'}:${form}`;

type Stored<T> = { savedAt: number; value: T };

export async function loadDraft<T>(key: string): Promise<T | null> {
  try {
    const raw = await AsyncStorage.getItem(key);
    if (!raw) return null;
    const s = JSON.parse(raw) as Stored<T>;
    if (!s || Date.now() - s.savedAt > TTL_MS) {
      await AsyncStorage.removeItem(key);
      return null;
    }
    return s.value;
  } catch {
    return null;
  }
}

export async function saveDraft<T>(key: string, value: T) {
  try {
    await AsyncStorage.setItem(key, JSON.stringify({ savedAt: Date.now(), value } satisfies Stored<T>));
  } catch {
    // Sem espaço ou armazenamento indisponível: o formulário segue funcionando, só sem recuperação.
  }
}

export async function clearDraft(key: string) {
  try {
    await AsyncStorage.removeItem(key);
  } catch {}
}

/**
 * Estado com rascunho: grava (com atraso curto) a cada mudança e, na abertura, oferece o rascunho guardado.
 * `pending` = rascunho encontrado esperando "Continuar" ou "Descartar rascunho".
 */
export function useDraft<T>(key: string | null, initial: T) {
  const [value, setValue] = useState<T>(initial);
  const [pending, setPending] = useState<T | null>(null);
  const ready = useRef(false);

  useEffect(() => {
    ready.current = false;
    if (!key) return;
    let alive = true;
    loadDraft<T>(key).then((d) => {
      if (!alive) return;
      if (d) setPending(d);
      else ready.current = true;
    });
    return () => {
      alive = false;
    };
  }, [key]);

  useEffect(() => {
    if (!key || !ready.current) return;
    const t = setTimeout(() => saveDraft(key, value), 400);
    return () => clearTimeout(t);
  }, [key, value]);

  return {
    value,
    setValue,
    pending,
    resume: () => {
      if (pending) setValue(pending);
      setPending(null);
      ready.current = true;
    },
    discard: async () => {
      setPending(null);
      ready.current = true;
      if (key) await clearDraft(key);
    },
    clear: async () => {
      ready.current = false;
      if (key) await clearDraft(key);
    },
  };
}
