// Vitrine da V4.2: só em desenvolvimento (fora do __DEV__ não mostra nada). Duelo, escalação e resultado de
// sorteio com DADOS SIMULADOS, para conferir o desenho sem gravar nada no banco. Nunca lê o Supabase.
import { useLocalSearchParams } from 'expo-router';
import { ScrollView, Text, View } from 'react-native';

import { ArtFormat, SharePanel } from '../lib/arts';
import { Duel, DuelArt, DuelView } from '../lib/duel';
import { LineupBoard, LineupPlayer, positionCounts } from '../lib/lineup';
import { colors, positionLabel } from '../lib/theme';
import { Card, Sub } from '../lib/ui';

const duel: Duel = {
  season_id: 'dev',
  season_name: 'Temporada 2026',
  a: {
    membership_id: 'a',
    name: 'Rafa Abreu',
    position: 'midfielder',
    avatar_path: null,
    card: { tier: 'ouro', overall: 82.4, finishing: 71, assisting: 88, attendance: 92, winning: 75, peer_rating: 81, is_provisional: false },
    stats: { matches: 18, goals: 9, assists: 14, wins: 11, avg_rating: 7.8, valid_ratings: 15, craque: 4 },
  },
  b: {
    membership_id: 'b',
    name: 'Bruno "Paredão" Lima',
    position: 'defender',
    avatar_path: null,
    card: { tier: 'prata', overall: 74.1, finishing: 22, assisting: 35, attendance: 96, winning: 80, peer_rating: 79, is_provisional: false },
    stats: { matches: 19, goals: 2, assists: 3, wins: 12, avg_rating: null, valid_ratings: 0, craque: 1 },
  },
};

// 16 jogadores: 2 goleiros, 5 defensores, 5 meias, 4 atacantes -> sorteio 8 x 8 (1x1, 3x2, 2x3, 2x2).
const names = ['Tião', 'Guga', 'Dudu', 'Lelo', 'Biel', 'Caio', 'Nando', 'Pipo', 'Rafa', 'Teco', 'Vini', 'Zeca', 'Juca', 'Leo', 'Maicon', 'Pedrão'];
const pos = ['goalkeeper', 'goalkeeper', 'defender', 'defender', 'defender', 'defender', 'defender', 'midfielder', 'midfielder', 'midfielder', 'midfielder', 'midfielder', 'attacker', 'attacker', 'attacker', 'attacker'];
const team = ['A', 'B', 'A', 'B', 'A', 'B', 'A', 'B', 'A', 'B', 'A', 'B', 'A', 'B', 'B', 'A'] as const;
const players: LineupPlayer[] = names.map((n, i) => ({ key: n, name: n, position: pos[i], team: team[i] }));

export default function DevV42() {
  const { formato } = useLocalSearchParams<{ formato?: ArtFormat }>();
  if (!__DEV__) return null;
  return (
    <ScrollView contentContainerStyle={{ padding: 16, gap: 18, backgroundColor: colors.white }}>
      <Text style={{ fontSize: 18, fontWeight: '800', color: colors.deepBlue }}>Vitrine V4.2 (dados simulados)</Text>
      <Text style={{ fontWeight: '700' }}>Duelo de Jogadores</Text>
      <Card>
        <DuelView duel={duel} />
      </Card>
      <Text style={{ fontWeight: '700' }}>Sorteio: 16 jogadores, regra por posição</Text>
      <Card>
        <LineupBoard teamA="Time Azul" teamB="Time Dourado" players={players} />
        <View style={{ gap: 2, marginTop: 6 }}>
          {positionCounts(players).map((c) => (
            <Text key={c.position} style={{ color: colors.muted, fontSize: 13 }}>
              {positionLabel(c.position)}: {c.a} x {c.b}
            </Text>
          ))}
          <Sub>Total: 8 x 8 · Overall somado: 1.012 x 1.009</Sub>
        </View>
      </Card>
      <Text style={{ fontWeight: '700' }}>Escalação depois do jogo (grátis)</Text>
      <Card>
        <LineupBoard teamA="Time A" teamB="Time B" players={players} score={{ a: 5, b: 3 }} />
      </Card>
      <Text style={{ fontWeight: '700' }}>Arte do Duelo ({formato === 'post' ? '4:5' : '9:16'})</Text>
      <SharePanel label="Abrir arte do Duelo" fileName="dev-duelo" title="Duelo">
        <DuelArt duel={duel} peladaName="Pelada de Quinta" crestPath={null} />
      </SharePanel>
    </ScrollView>
  );
}
