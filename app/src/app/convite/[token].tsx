import AsyncStorage from '@react-native-async-storage/async-storage';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';

import { friendly } from '../../lib/errors';
import { useAuth } from '../../lib/session';
import { supabase } from '../../lib/supabase';
import { Position } from '../../lib/theme';
import { Button, ErrorText, PositionPicker, Screen, Sub, Title } from '../../lib/ui';

export default function Convite() {
  const { token } = useLocalSearchParams<{ token: string }>();
  const { session, loading, onboarded } = useAuth();
  const router = useRouter();
  const [pos, setPos] = useState<Position | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  // Abriu o link sem estar logado: guarda o convite e o login leva de volta.
  useEffect(() => {
    if (!loading && !session && token) AsyncStorage.setItem('pending_invite', String(token));
  }, [loading, session, token]);

  async function entrar() {
    if (!pos) return setMsg('Escolha sua posição.');
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc('join_pelada', {
      p_invite_token: String(token).trim(),
      p_position: pos,
    });
    if (error) {
      setBusy(false);
      return setMsg(friendly(error.message));
    }
    // O banco devolve a associação; abrimos a lista para localizar a pelada.
    router.replace('/');
  }

  if (!session || !onboarded)
    return (
      <Screen>
        <Title>Você foi convidado</Title>
        <Sub>Entre ou crie sua conta para aceitar o convite. Ele fica guardado.</Sub>
        <Button title="Entrar ou criar conta" onPress={() => router.replace('/login')} />
      </Screen>
    );

  return (
    <Screen>
      <Title>Você foi convidado</Title>
      <Sub>Escolha sua posição nessa pelada. Você pode mudar depois.</Sub>
      <PositionPicker value={pos} onChange={setPos} />
      <ErrorText>{msg}</ErrorText>
      <Button title="Entrar na pelada" onPress={entrar} loading={busy} />
    </Screen>
  );
}
