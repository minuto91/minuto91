import AsyncStorage from '@react-native-async-storage/async-storage';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';

import { friendly } from '../../lib/errors';
import { extractInviteToken } from '../../lib/invite';
import { useAuth } from '../../lib/session';
import { supabase } from '../../lib/supabase';
import { Position } from '../../lib/theme';
import { Body, Button, Card, ErrorText, PositionPicker, Screen, Sub, Title } from '../../lib/ui';

type Preview = { valid: boolean; pelada_name?: string; already_member?: boolean; pelada_id?: string | null };

export default function Convite() {
  const { token: raw } = useLocalSearchParams<{ token: string }>();
  const token = extractInviteToken(String(raw ?? '')) ?? String(raw ?? '').trim();
  const { session, loading, onboarded } = useAuth();
  const router = useRouter();
  const [pos, setPos] = useState<Position | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [preview, setPreview] = useState<Preview | null>(null);

  // Abriu o link sem estar logado: guarda o convite e o login (ou o cadastro) leva de volta.
  useEffect(() => {
    if (!loading && !session && token) AsyncStorage.setItem('pending_invite', token);
  }, [loading, session, token]);

  // Com login: mostra de qual pelada é o convite (034). Banco sem a 034: segue sem a prévia.
  useEffect(() => {
    if (!session || !onboarded || !token) return;
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc('get_invite_preview', { p_token: token });
      if (!alive) return;
      if (error) return setPreview({ valid: true });
      const p = data as Preview;
      if (p.valid && p.already_member && p.pelada_id) {
        router.replace({ pathname: '/pelada/[id]', params: { id: p.pelada_id } });
        return;
      }
      setPreview(p);
    })();
    return () => {
      alive = false;
    };
  }, [session, onboarded, token, router]);

  async function entrar() {
    if (!pos) return setMsg('Escolha sua posição.');
    setBusy(true);
    setMsg(null);
    const { data: membership, error } = await supabase.rpc('join_pelada', { p_invite_token: token, p_position: pos });
    if (error) {
      setBusy(false);
      return setMsg(friendly(error.message));
    }
    // A RPC devolve a associação; com ela, abrimos direto a pelada.
    const { data: m } = await supabase.from('pelada_memberships').select('pelada_id').eq('id', String(membership)).maybeSingle();
    setBusy(false);
    if (m?.pelada_id) router.replace({ pathname: '/pelada/[id]', params: { id: m.pelada_id } });
    else router.replace('/');
  }

  if (!session || !onboarded)
    return (
      <Screen>
        <Title>Você foi convidado</Title>
        <Sub>Entre ou crie sua conta para aceitar o convite. Ele fica guardado e abre de novo depois do cadastro.</Sub>
        <Button title="Entrar ou criar conta" onPress={() => router.replace('/login')} />
      </Screen>
    );

  if (preview && !preview.valid)
    return (
      <Screen>
        <Title>Convite inválido</Title>
        <Sub>Este convite expirou, foi cancelado ou já atingiu o limite de entradas. Peça um novo ao administrador da pelada.</Sub>
        <Button title="Voltar ao início" kind="secondary" onPress={() => router.replace('/')} />
      </Screen>
    );

  return (
    <Screen>
      <Title>Você foi convidado</Title>
      {preview?.pelada_name ? (
        <Card>
          <Sub>Pelada</Sub>
          <Body>{preview.pelada_name}</Body>
        </Card>
      ) : null}
      <Sub>Escolha sua posição nessa pelada. Você pode mudar depois.</Sub>
      <PositionPicker value={pos} onChange={setPos} />
      <ErrorText>{msg}</ErrorText>
      <Button title="Entrar na pelada" onPress={entrar} loading={busy} disabled={!preview} />
    </Screen>
  );
}
