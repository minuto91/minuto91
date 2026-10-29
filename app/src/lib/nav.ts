// V8.4 — E15: navegação a partir das telas. Um toque por destino (toque duplo não empilha duas vezes) e um aviso
// leve de alteração não salva ao sair de formulários. Quem decide o acesso ao destino é sempre o destino (RLS).
import { type Href, useNavigation, useRouter } from 'expo-router';
import { useCallback, useEffect, useRef } from 'react';
import { Alert } from 'react-native';

import { createNavLock } from './navguard';

/** Abre um destino empilhando sobre a tela atual (o "voltar" retorna à origem). Ignora o segundo toque seguido. */
export function useGo() {
  const router = useRouter();
  const lock = useRef(createNavLock()).current;
  return useCallback(
    (href: Href) => {
      const key = typeof href === 'string' ? href : JSON.stringify(href);
      if (lock(key)) router.push(href);
    },
    [router, lock],
  );
}

// O tipo do navegador não declara beforeRemove (evento do React Navigation); aqui só o que se usa.
type RemoveEvent = { preventDefault: () => void; data: { action: unknown } };
type Nav = {
  addListener: (type: 'beforeRemove', cb: (e: RemoveEvent) => void) => () => void;
  dispatch: (action: unknown) => void;
};

/** E15-27/E09: avisa antes de descartar alterações não salvas ao voltar de uma tela de formulário. */
export function useUnsavedGuard(dirty: boolean) {
  const navigation = useNavigation() as unknown as Nav;
  useEffect(() => {
    if (!dirty) return;
    return navigation.addListener('beforeRemove', (e) => {
      e.preventDefault();
      Alert.alert('Descartar alterações?', 'Você tem alterações que ainda não foram salvas.', [
        { text: 'Continuar editando', style: 'cancel' },
        { text: 'Descartar', style: 'destructive', onPress: () => navigation.dispatch(e.data.action) },
      ]);
    });
  }, [dirty, navigation]);
}
