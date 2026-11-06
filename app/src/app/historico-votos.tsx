// REV-148 (V10.0): acesso ao "meu histórico de votos" a partir de Meu Perfil. Esta tela só lista as partidas em que a
// própria pessoa votou (get_my_vote_histories, 080); cada linha abre a tela de histórico que já existia
// (partida/[id]/meus-votos), com o mesmo conteúdo e as mesmas regras de sigilo. Nada é gravado aqui.
import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable } from 'react-native';

import { friendly } from '../lib/errors';
import { fmtDate } from '../lib/match';
import { supabase } from '../lib/supabase';
import { Text } from '../lib/text';
import { colors } from '../lib/theme';
import { Block, EmptyState, ErrorText, LoadingBlock, Screen, Sub, Title } from '../lib/ui';

type Row = { match_id: string; played_at: string; pelada_id: string; pelada_name: string; team_a_name: string; team_b_name: string };

export default function HistoricoVotos() {
  const router = useRouter();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    let alive = true;
    (async () => {
      void reload;
      const { data, error } = await supabase.rpc('get_my_vote_histories');
      if (!alive) return;
      if (error) return setErr(friendly(error.message));
      setErr(null);
      setRows((data as Row[]) ?? []);
    })();
    return () => {
      alive = false;
    };
  }, [reload]);

  return (
    <Screen>
      <Title>Meu histórico de votos</Title>
      <Sub>Só você vê esta lista.</Sub>
      <ErrorText>{err}</ErrorText>
      {err && (
        <Pressable accessibilityRole="button" onPress={() => { setErr(null); setRows(null); setReload((n) => n + 1); }} style={{ minHeight: 44, justifyContent: 'center' }}>
          <Text style={{ color: colors.blue, fontWeight: '600' }}>Tentar de novo</Text>
        </Pressable>
      )}
      {!rows && !err && <LoadingBlock />}
      {rows && rows.length === 0 && <EmptyState title="Você ainda não votou em nenhuma partida" />}
      {rows?.map((r) => (
        <Pressable
          key={r.match_id}
          accessibilityRole="button"
          onPress={() => router.push({ pathname: '/partida/[id]/meus-votos', params: { id: r.match_id } })}>
          <Block>
            <Text style={{ color: colors.ink, fontWeight: '700' }}>{r.pelada_name}</Text>
            <Sub>{`${fmtDate(r.played_at)} · ${r.team_a_name} x ${r.team_b_name}`}</Sub>
          </Block>
        </Pressable>
      ))}
    </Screen>
  );
}
