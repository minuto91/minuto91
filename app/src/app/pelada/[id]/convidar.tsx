import * as Clipboard from 'expo-clipboard';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Linking, Pressable, Share, View } from 'react-native';
import Svg, { Rect } from 'react-native-svg';
import { Text } from '../../../lib/text';

import { confirm } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { inviteLink, inviteMessage, whatsappUrl } from '../../../lib/invite';
import { supabase } from '../../../lib/supabase';
import { colors } from '../../../lib/theme';
import { Button, ErrorText, Screen, Sub, Title } from '../../../lib/ui';

// Convidar jogadores (só o admin; o banco recusa os demais). Abre já com um convite novo.
// novo=1: veio da criação da pelada (mostra "Pelada criada" e o atalho para a pelada).
export default function Convidar() {
  const { id, novo } = useLocalSearchParams<{ id: string; novo?: string }>();
  const router = useRouter();
  const [name, setName] = useState('');
  const [token, setToken] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [round, setRound] = useState(0); // novo convite depois de revogar

  useEffect(() => {
    let alive = true;
    (async () => {
      const [{ data: p }, { data: t, error }] = await Promise.all([
        supabase.from('peladas').select('name').eq('id', id).maybeSingle(),
        supabase.rpc('create_pelada_invite', { p_pelada: id }),
      ]);
      if (!alive) return;
      setName(p?.name ?? '');
      if (error) return setMsg(friendly(error.message));
      setToken(String(t));
    })();
    return () => {
      alive = false;
    };
  }, [id, round]);

  const message = token ? inviteMessage(name, token) : '';

  async function copy(what: 'link' | 'codigo') {
    if (!token) return;
    await Clipboard.setStringAsync(what === 'link' ? inviteLink(token) : token);
    setCopied(what === 'link' ? 'Link copiado.' : 'Código copiado.');
  }

  function regenerate() {
    confirm(
      'Gerar novo link?',
      'Todos os convites já enviados desta pelada param de funcionar. Quem já entrou continua na pelada.',
      'Gerar novo',
      async () => {
        setBusy(true);
        setMsg(null);
        const { error } = await supabase.rpc('revoke_pelada_invites', { p_pelada: id });
        setBusy(false);
        if (error) return setMsg(friendly(error.message));
        setToken(null);
        setCopied(null);
        setRound((n) => n + 1);
      },
    );
  }

  const goPelada = () => router.replace({ pathname: '/pelada/[id]', params: { id } });

  return (
    <Screen>
      {novo === '1' ? (
        <>
          <Title>Pelada criada</Title>
          <Sub>Agora chame a turma.</Sub>
        </>
      ) : (
        <>
          <Title>Convidar jogadores</Title>
          {name ? <Sub>{name}</Sub> : null}
        </>
      )}
      <ErrorText>{msg}</ErrorText>

      {token ? (
        <>
          <Button title="Enviar no WhatsApp" onPress={() => Linking.openURL(whatsappUrl(message))} />
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Button title="Copiar link" kind="secondary" onPress={() => copy('link')} />
            </View>
            <View style={{ flex: 1 }}>
              <Button title="Outros apps" kind="secondary" onPress={() => Share.share({ message })} />
            </View>
          </View>
          {/* REV-016: código visualmente curto; copiar leva sempre o token inteiro. Validade e limite: servidor. */}
          <Pressable
            onPress={() => copy('codigo')}
            accessibilityRole="button"
            accessibilityLabel="Copiar código do convite"
            style={{ minHeight: 48, flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 14, borderWidth: 1, borderColor: colors.line, borderRadius: 12 }}>
            <Text style={{ flex: 1, fontFamily: 'monospace', fontSize: 15, color: colors.ink }} numberOfLines={1}>
              {`${token.slice(0, 6)}…${token.slice(-4)}`}
            </Text>
            <CopyIcon />
          </Pressable>
          {copied && <Text style={{ color: colors.ink, fontWeight: '600' }}>{copied}</Text>}
          <Button title="Gerar novo link (cancela os anteriores)" kind="secondary" onPress={regenerate} loading={busy} />
        </>
      ) : (
        !msg && <Sub>Gerando convite...</Sub>
      )}

      {novo === '1' && <Button title="Ir para a pelada" kind={token ? 'secondary' : 'primary'} onPress={goPelada} />}
    </Screen>
  );
}

const CopyIcon = () => (
  <Svg width={20} height={20} viewBox="0 0 24 24" accessibilityElementsHidden>
    <Rect x={8} y={8} width={12} height={12} rx={2.5} fill="none" stroke={colors.blue} strokeWidth={2} />
    <Rect x={4} y={4} width={12} height={12} rx={2.5} fill="none" stroke={colors.blue} strokeWidth={2} />
  </Svg>
);
