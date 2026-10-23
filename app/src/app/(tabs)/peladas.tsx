// V4.6: aba Peladas. A lista completa das minhas peladas, a pelada principal e os dois caminhos para entrar numa
// nova (criar ou convite). Lê a mesma get_player_central da Início (nada é recalculado aqui).
import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useRef, useState } from 'react';
import { Pressable, View } from 'react-native';

import { Crest } from '../../lib/crest';
import { friendly } from '../../lib/errors';
import { supabase } from '../../lib/supabase';
import { Text } from '../../lib/text';
import { colors, positionLabel, type } from '../../lib/theme';
import { Button, Card, EmptyState, ErrorText, Loading, Screen, Sub } from '../../lib/ui';

type Pelada = {
  id: string;
  name: string;
  crest_path: string | null;
  role: 'admin' | 'assistant' | 'player';
  position: string;
  position_code: string | null;
  is_primary: boolean;
  drafts: number;
};

const ROLE = (r: string) => (r === 'admin' ? 'Administrador' : r === 'assistant' ? 'Assistente' : 'Jogador');

export default function Peladas() {
  const router = useRouter();
  const [peladas, setPeladas] = useState<Pelada[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      void reload;
      (async () => {
        const { data, error } = await supabase.rpc('get_player_central');
        if (!alive) return;
        if (error || !data) return setErr('Não foi possível carregar as suas peladas. Verifique a internet e tente de novo.');
        setErr(null);
        setPeladas((data as { peladas: Pelada[] }).peladas);
      })();
      return () => {
        alive = false;
      };
    }, [reload]),
  );

  // Um toque por vez: toque duplo não marca e desmarca em seguida.
  const busy = useRef(false);
  async function principal(p: Pelada) {
    if (busy.current) return;
    busy.current = true;
    try {
      const { error } = await supabase.rpc('set_primary_pelada', { p_pelada: p.is_primary ? null : p.id });
      if (error) return setErr(friendly(error.message));
      setReload((n) => n + 1);
    } finally {
      busy.current = false;
    }
  }

  return (
    <Screen>
      <ErrorText>{err}</ErrorText>
      {err && <Button title="Tentar de novo" kind="secondary" onPress={() => setReload((n) => n + 1)} />}
      {!peladas && !err && <Loading />}
      {peladas && peladas.length === 0 && (
        <Card>
          <EmptyState title="Você ainda não está em nenhuma pelada" hint="Crie a pelada da sua turma ou entre com o convite que recebeu.">
            <Button title="Criar pelada" onPress={() => router.push('/criar-pelada')} />
            <Button title="Entrar com convite" kind="secondary" onPress={() => router.push('/entrar')} />
          </EmptyState>
        </Card>
      )}
      {(peladas ?? []).map((p) => (
        <Card key={p.id}>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={`Abrir ${p.name}`}
            onPress={() => router.push({ pathname: '/pelada/[id]', params: { id: p.id } })}
            style={{ flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 48 }}>
            <Crest path={p.crest_path} name={p.name} size={44} />
            <View style={{ flex: 1, gap: 2 }}>
              <Text style={type.cardTitle} numberOfLines={1}>
                {p.name}
              </Text>
              <Sub>
                {ROLE(p.role)} · {positionLabel(p.position_code ?? p.position)}
                {p.drafts > 0 ? ` · ${p.drafts === 1 ? '1 súmula em rascunho' : `${p.drafts} súmulas em rascunho`}` : ''}
              </Sub>
            </View>
            <Text style={{ color: colors.muted, fontSize: 20 }}>›</Text>
          </Pressable>
          {peladas!.length > 1 && (
            <Pressable
              accessibilityRole="button"
              accessibilityLabel={p.is_primary ? `${p.name} é a pelada principal. Toque para desmarcar.` : `Tornar ${p.name} a pelada principal`}
              onPress={() => principal(p)}
              style={{ minHeight: 44, justifyContent: 'center', alignSelf: 'flex-start', paddingRight: 12 }}>
              <Text style={{ fontSize: 13, fontWeight: '600', color: p.is_primary ? colors.darkGold : colors.blue }}>
                {p.is_primary ? 'Pelada principal' : 'Tornar principal'}
              </Text>
            </Pressable>
          )}
        </Card>
      ))}
      {peladas && peladas.length > 0 && (
        <View style={{ gap: 8, marginTop: 4 }}>
          <Button title="Criar pelada" kind="secondary" onPress={() => router.push('/criar-pelada')} />
          <Button title="Entrar com convite" kind="ghost" onPress={() => router.push('/entrar')} />
        </View>
      )}
    </Screen>
  );
}
