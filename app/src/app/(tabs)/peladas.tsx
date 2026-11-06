// V4.6: aba Peladas. A lista completa das minhas peladas e os dois caminhos para entrar numa
// nova (criar ou convite). Lê a mesma get_player_central da Início (nada é recalculado aqui).
import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, View } from 'react-native';

import { Crest } from '../../lib/crest';
import { supabase } from '../../lib/supabase';
import { Text } from '../../lib/text';
import { colors, positionLabel, type } from '../../lib/theme';
import { Icon } from '../../lib/icons';
import { Button, Divider, EmptyState, ErrorText, Loading, Screen, Sub } from '../../lib/ui';

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
  // REV-142: PREMIUM dourado só nas peladas com acesso Premium ativo no servidor (assinatura ou teste válido).
  const [premium, setPremium] = useState<Record<string, boolean>>({});
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
        const list = (data as { peladas: Pelada[] }).peladas;
        setPeladas(list);
        const ents = await Promise.all(
          list.map(async (p) => {
            const { data: e, error: ee } = await supabase.rpc('get_pelada_entitlement', { p_pelada: p.id });
            return [p.id, !ee && !!(e as { is_premium?: boolean } | null)?.is_premium] as const;
          }),
        );
        if (alive) setPremium(Object.fromEntries(ents));
      })();
      return () => {
        alive = false;
      };
    }, [reload]),
  );

  return (
    <Screen>
      <ErrorText>{err}</ErrorText>
      {err && <Button title="Tentar de novo" kind="secondary" onPress={() => setReload((n) => n + 1)} />}
      {!peladas && !err && <Loading />}
      {peladas && peladas.length === 0 && (
        <EmptyState title="Você ainda não está em nenhuma pelada" hint="Crie a pelada da sua turma ou entre com o convite que recebeu.">
          <Button title="Criar pelada" onPress={() => router.push('/criar-pelada')} />
          <Button title="Entrar com convite" kind="secondary" onPress={() => router.push('/entrar')} />
        </EmptyState>
      )}
      {(peladas ?? []).map((p, i) => (
        <View key={p.id}>
          {i > 0 ? <Divider /> : null}
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={`Abrir ${p.name}`}
            onPress={() => router.push({ pathname: '/pelada/[id]', params: { id: p.id } })}
            style={{ flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 64, paddingVertical: 8 }}>
            <Crest path={p.crest_path} name={p.name} size={44} />
            <View style={{ flex: 1, gap: 2 }}>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                <Text style={[type.cardTitle, { flexShrink: 1 }]} numberOfLines={1}>
                  {p.name}
                </Text>
                {premium[p.id] && (
                  <Text accessibilityLabel="Pelada Premium" style={{ fontSize: 10, fontWeight: '800', letterSpacing: 0.8, color: colors.darkGold, borderWidth: 1, borderColor: colors.gold, borderRadius: 6, paddingHorizontal: 5, paddingVertical: 1 }}>
                    PREMIUM
                  </Text>
                )}
              </View>
              <Sub>
                {ROLE(p.role)} · {positionLabel(p.position_code ?? p.position)}
                {p.drafts > 0 ? ` · ${p.drafts === 1 ? '1 súmula em rascunho' : `${p.drafts} súmulas em rascunho`}` : ''}
              </Sub>
            </View>
            <Icon name="chevron" size={20} color={colors.muted} />
          </Pressable>
        </View>
      ))}
      {peladas && peladas.length > 0 && (
        <View style={{ gap: 8, marginTop: 4 }}>
          <Button title="Criar Pelada" kind="gold" block onPress={() => router.push('/criar-pelada')} />
          <Button title="Entrar com convite" kind="ghost" block onPress={() => router.push('/entrar')} />
        </View>
      )}
    </Screen>
  );
}
