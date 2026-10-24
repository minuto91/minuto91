// Vitrine da V7.7 (só em desenvolvimento, sem login, DADOS SIMULADOS): carta com os atributos definitivos
// (DEF, LET ou REF, APR, RES, DIS) nas três categorias, goleiro com REF no lugar de LET e carta "em avaliação"
// (menos de 5 partidas, sem número). Serve para conferir o desenho no navegador.
import { ScrollView, View } from 'react-native';

import type { Card as CardData } from '../lib/career';
import { PlayerCard } from '../lib/playercard';
import { Section, Sub, Title } from '../lib/ui';

const base: CardData = {
  id: 'dev',
  position: 'attacker',
  position_code: 'CA',
  finishing: 0,
  assisting: 0,
  attendance: 0,
  winning: 0,
  peer_rating: 0,
  overall: 83.6,
  tier: 'ouro',
  is_provisional: false,
  matches_played: 18,
  formula_version: 3,
  def: 72.4,
  sec: 91.6,
  apr: 78.1,
  res: 80.3,
  dis: 88.5,
  sec_code: 'LET',
  ovr_display: 84,
};
const common = { photoPath: null, peladaName: 'Pelada de Quinta', seasonName: '2026', seasonStart: '2026-01-01', photoUrl: null, crestUrl: null };

export default function DevV77Route() {
  return __DEV__ ? <DevV77 /> : null;
}

function DevV77() {
  return (
    <ScrollView contentContainerStyle={{ padding: 20, gap: 16, backgroundColor: '#FFFFFF' }}>
      <Title>V7.7: cartas</Title>
      <Sub>Dados simulados.</Sub>
      <Section>Linha (LET) e goleiro (REF)</Section>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 16 }}>
        <PlayerCard card={base} playerName="Rafa" {...common} />
        <PlayerCard
          card={{ ...base, tier: 'prata', overall: 72.3, ovr_display: 72, def: 76.2, sec: 69.8, apr: 70.1, res: 74.0, dis: 79.4, sec_code: 'REF', position: 'goalkeeper', position_code: 'GOL' }}
          playerName="Zé Carlos"
          {...common}
        />
        <PlayerCard
          card={{ ...base, tier: 'bronze', overall: 62.1, ovr_display: 62, def: 61.0, sec: 60.4, apr: 64.2, res: 58.0, dis: 62, position: 'defender', position_code: 'ZAG' }}
          playerName="Bia"
          {...common}
        />
      </View>
      <Section>Em avaliação (3 de 5 partidas)</Section>
      <PlayerCard card={{ ...base, tier: 'prata', is_provisional: true, matches_played: 3, ovr_display: null, overall: 71 }} playerName="Caio" {...common} />
    </ScrollView>
  );
}
