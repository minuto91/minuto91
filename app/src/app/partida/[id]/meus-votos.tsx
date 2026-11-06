// V7.7 (053): histórico das minhas notas e escolhas nesta partida. Cada mudança é uma versão guardada no servidor,
// com data e hora; a que vale é a última válida. Só o próprio eleitor vê (nem a administração tem acesso), também
// depois da publicação e mesmo depois de sair da pelada. Depois do prazo é só leitura.
import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { View } from 'react-native';

import { friendly } from '../../../lib/errors';
import { fmtDate, fmtRating, fmtTime } from '../../../lib/match';
import { supabase } from '../../../lib/supabase';
import { Text } from '../../../lib/text';
import { colors } from '../../../lib/theme';
import { Block, ErrorText, Loading, Screen, Sub, Title } from '../../../lib/ui';

type Version = {
  kind: 'rating' | 'craque' | 'bola_murcha';
  target_membership_id: string | null;
  target_name: string | null;
  rating: number | null;
  at: string;
  during_reopening: boolean;
  current: boolean;
};

const KIND_LABEL = { rating: 'Nota', craque: 'Craque', bola_murcha: 'Bola Murcha' } as const;

export default function MeusVotos() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [data, setData] = useState<{ read_only: boolean; versions: Version[] } | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data: d, error } = await supabase.rpc('get_my_rating_vote_history', { p_match: id });
      if (!alive) return;
      if (error) return setErr(friendly(error.message));
      setData(d as { read_only: boolean; versions: Version[] });
    })();
    return () => {
      alive = false;
    };
  }, [id]);

  if (err) return <Screen><ErrorText>{err}</ErrorText></Screen>;
  if (!data) return <Screen><Loading /></Screen>;
  const versions = [...data.versions].reverse(); // mais recente primeiro
  return (
    <Screen>
      <Title>Meus votos</Title>
      <Sub>
        Só você vê esta lista. {data.read_only ? 'A votação terminou: só leitura.' : 'Você pode mudar até o fim do prazo; vale a última versão.'}
      </Sub>
      {versions.length === 0 ? (
        <Sub>Você ainda não registrou nada nesta votação.</Sub>
      ) : (
        <Block>
          {versions.map((x, i) => (
            <View
              key={`${x.at}-${i}`}
              style={{ paddingVertical: 8, borderBottomWidth: i < versions.length - 1 ? 1 : 0, borderBottomColor: colors.line, gap: 2 }}>
              <Text style={{ color: colors.ink, fontWeight: x.current ? '700' : '400' }}>
                {KIND_LABEL[x.kind]} · {x.target_name ?? 'em branco'}
                {x.kind === 'rating' && x.rating !== null ? ` · ${fmtRating(Number(x.rating))}` : ''}
              </Text>
              <Sub>
                {fmtDate(x.at)} às {fmtTime(x.at)}
                {x.current ? ' · vale esta' : ' · substituída'}
                {x.during_reopening ? ' · na reabertura' : ''}
              </Sub>
            </View>
          ))}
        </Block>
      )}
    </Screen>
  );
}
