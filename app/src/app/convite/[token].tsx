import AsyncStorage from '@react-native-async-storage/async-storage';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { HOME , Position } from '../../lib/theme';

import { friendly } from '../../lib/errors';
import { extractInviteToken } from '../../lib/invite';
import { useAuth } from '../../lib/session';
import { supabase } from '../../lib/supabase';
import { Body, Button, Card, ErrorText, PositionPicker, Screen, Sub, Title } from '../../lib/ui';

type Preview = {
  valid: boolean;
  reason?: 'not_found' | 'expired' | 'used_up' | 'revoked' | 'pelada_inactive';
  pelada_name?: string | null;
  already_member?: boolean;
  pelada_id?: string | null;
  membership_status?: 'left' | 'suspended' | 'retired' | null;
  can_join?: boolean;
  needs_position?: boolean;
};

const REASON: Record<NonNullable<Preview['reason']>, string> = {
  expired: 'Este convite expirou.',
  used_up: 'Este convite já foi usado o número máximo de vezes.',
  revoked: 'Este convite foi cancelado pelo administrador.',
  not_found: 'Não encontramos este convite. Confira se o código ou o link veio completo.',
  pelada_inactive: 'Esta pelada não está mais ativa.',
};

// Convite (V4.1; V4.4 mais simples): mostra de qual pelada é, explica por que um convite não funciona (expirado, já
// usado, cancelado), leva direto à pelada quem já é membro (sem duplicar) e deixa quem saiu voltar sem escolher a
// posição de novo. Sem login, o convite fica guardado e abre de novo depois do cadastro. A regra de entrada continua
// no servidor (join_pelada): ninguém entra numa pelada sem convite válido.
export default function Convite() {
  const { token: raw } = useLocalSearchParams<{ token: string }>();
  const token = extractInviteToken(String(raw ?? '')) ?? String(raw ?? '').trim();
  const { session, loading, onboarded } = useAuth();
  const router = useRouter();
  const [pos, setPos] = useState<Position | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [joined, setJoined] = useState<{ peladaId: string; name: string } | null>(null);

  // Abriu o link sem estar logado: guarda o convite e o login (ou o cadastro) leva de volta.
  useEffect(() => {
    if (!loading && !session && token) AsyncStorage.setItem('pending_invite', token);
  }, [loading, session, token]);

  // Com login: mostra de qual pelada é o convite (034/045). Banco sem a 034: segue sem a prévia.
  useEffect(() => {
    if (!session || !onboarded || !token) return;
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc('get_invite_preview', { p_token: token });
      if (!alive) return;
      if (error) return setPreview({ valid: true, can_join: true, needs_position: true });
      const p = data as Preview;
      // Já é membro ou o convite não serve: não fica mais como pendência na Central.
      if (!p.valid || p.already_member) AsyncStorage.removeItem('pending_invite').catch(() => {});
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
    const needsPosition = preview?.needs_position !== false;
    if (needsPosition && !pos) return setMsg('Escolha sua posição.');
    setBusy(true);
    setMsg(null);
    const { data: membership, error } = await supabase.rpc('join_pelada', { p_invite_token: token, p_position: needsPosition ? pos : null });
    if (error) {
      setBusy(false);
      return setMsg(friendly(error.message));
    }
    await AsyncStorage.removeItem('pending_invite').catch(() => {});
    // A RPC devolve a associação; com ela, abrimos a pelada.
    const { data: m } = await supabase.from('pelada_memberships').select('pelada_id').eq('id', String(membership)).maybeSingle();
    const { data: me } = await supabase.rpc('get_my_profile');
    setBusy(false);
    const profile = me as { avatar_path?: string | null; dominant_foot?: string | null } | null;
    if (m?.pelada_id && profile && (!profile.avatar_path || !profile.dominant_foot)) {
      setJoined({ peladaId: m.pelada_id, name: preview?.pelada_name ?? 'pelada' });
      return;
    }
    if (m?.pelada_id) router.replace({ pathname: '/pelada/[id]', params: { id: m.pelada_id } });
    else router.replace(HOME);
  }

  if (!session || !onboarded)
    return (
      <Screen>
        <Title>Você foi convidado</Title>
        <Sub>Entre ou crie sua conta para aceitar.</Sub>
        <Button title="Entrar ou criar conta" onPress={() => router.replace('/login')} />
      </Screen>
    );

  if (joined)
    return (
      <Screen>
        <Title>Você entrou em {joined.name}</Title>
        <Sub>Complete seu perfil: foto e pé dominante.</Sub>
        <Button title="Completar meu perfil" onPress={() => router.replace('/perfil')} />
        <Button title="Agora não, abrir a pelada" kind="secondary" onPress={() => router.replace({ pathname: '/pelada/[id]', params: { id: joined.peladaId } })} />
      </Screen>
    );

  if (preview && !preview.valid)
    return (
      <Screen>
        <Title>Convite indisponível</Title>
        {preview.pelada_name ? (
          <Card>
            <Sub>Pelada</Sub>
            <Body>{preview.pelada_name}</Body>
          </Card>
        ) : null}
        <Sub>{REASON[preview.reason ?? 'not_found']}</Sub>
        <Sub>Peça um novo convite ao administrador da pelada.</Sub>
        <Button title="Voltar à Central" kind="secondary" onPress={() => router.replace(HOME)} />
      </Screen>
    );

  if (preview && preview.can_join === false)
    return (
      <Screen>
        <Title>Não é possível entrar</Title>
        <Sub>
          {preview.membership_status === 'suspended'
            ? 'Sua participação nesta pelada está suspensa. Fale com o administrador.'
            : 'Você não pode voltar a esta pelada.'}
        </Sub>
        <Button title="Voltar à Central" kind="secondary" onPress={() => router.replace(HOME)} />
      </Screen>
    );

  const rejoin = preview?.needs_position === false;
  return (
    <Screen>
      <Title>{rejoin ? 'Voltar para a pelada' : 'Você foi convidado'}</Title>
      {preview?.pelada_name ? (
        <Card>
          <Sub>Pelada</Sub>
          <Body>{preview.pelada_name}</Body>
        </Card>
      ) : null}
      {rejoin ? (
        <Sub>Seu histórico continua guardado.</Sub>
      ) : (
        <>
          <Sub>Escolha sua posição nessa pelada. Você pode mudar depois.</Sub>
          <PositionPicker value={pos} onChange={setPos} />
        </>
      )}
      <ErrorText>{msg}</ErrorText>
      <Button title={rejoin ? 'Voltar para a pelada' : 'Entrar na pelada'} onPress={entrar} loading={busy} disabled={!preview} />
    </Screen>
  );
}
