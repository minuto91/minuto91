import { useLocalSearchParams } from 'expo-router';

import { MatchHistory } from '../lib/history';
import { Screen, Title } from '../lib/ui';

// REV-003: histórico completo da carreira, paginado. `pelada` opcional filtra por uma pelada.
export default function Historico() {
  const { pelada } = useLocalSearchParams<{ pelada?: string }>();
  return (
    <Screen>
      <Title>Histórico</Title>
      <MatchHistory peladaId={pelada ?? null} showPelada={!pelada} />
    </Screen>
  );
}
