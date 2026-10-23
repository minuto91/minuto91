// Vitrine da V5 (só em desenvolvimento, sem login, DADOS SIMULADOS): carta com os atributos do OVR (ATU, EST, PEQ,
// RES, DIS) nas três categorias, carta "em avaliação" (menos de 5 partidas, sem número) e o controle de nota da
// votação (0 a 10, passos de 0,5, começa em 7,0). Serve para conferir o desenho no navegador.
import { useState } from 'react';
import { ScrollView, View } from 'react-native';

import type { Card as CardData } from '../lib/career';
import { PlayerCard } from '../lib/playercard';
import { RatingSlider } from '../lib/ratingvote';
import { Body, Card, Section, Sub, Title } from '../lib/ui';

const base: CardData = {
  id: 'dev',
  position: 'midfielder',
  position_code: 'MEI',
  finishing: 0,
  assisting: 0,
  attendance: 0,
  winning: 0,
  peer_rating: 0,
  overall: 81.4,
  tier: 'ouro',
  is_provisional: false,
  matches_played: 18,
  formula_version: 2,
  atu: 84.2,
  est: 86.9,
  peq: 74.1,
  res: 78.3,
  dis: 88.5,
  ovr_display: 81,
};

export default function DevV5() {
  const [nota, setNota] = useState(7);
  return (
    <ScrollView contentContainerStyle={{ padding: 20, gap: 16, backgroundColor: '#FFFFFF' }}>
      <Title>V5: carta e votação</Title>
      <Sub>Dados simulados.</Sub>
      <Section>Cartas com OVR</Section>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 16 }}>
        <PlayerCard card={base} playerName="Ana Luíza" photoPath={null} peladaName="Pelada de Quinta" seasonName="2026" seasonStart="2026-01-01" photoUrl={null} crestUrl={null} />
        <PlayerCard
          card={{ ...base, tier: 'prata', overall: 71.2, ovr_display: 71, atu: 70.4, est: 72.8, peq: 66.0, res: 82.5, dis: 70, position: 'goalkeeper', position_code: 'GOL' }}
          playerName="Zé Carlos"
          photoPath={null}
          peladaName="Pelada de Quinta"
          seasonName="2026"
          seasonStart="2026-01-01"
          photoUrl={null}
          crestUrl={null}
        />
        <PlayerCard
          card={{ ...base, tier: 'bronze', overall: 61.6, ovr_display: 62, atu: 58.3, est: 63.0, peq: 60.2, res: 55.0, dis: 62, position: 'attacker', position_code: 'CA' }}
          playerName="Rafa"
          photoPath={null}
          peladaName="Pelada de Quinta"
          seasonName="2026"
          seasonStart="2026-01-01"
          photoUrl={null}
          crestUrl={null}
        />
      </View>
      <Section>Em avaliação (3 de 5 partidas)</Section>
      <PlayerCard
        card={{ ...base, tier: 'prata', is_provisional: true, matches_played: 3, ovr_display: null, atu: 72.0, est: 69.1, peq: 70.6, res: 75.0, dis: 70 }}
        playerName="Caio"
        photoPath={null}
        peladaName="Pelada de Quinta"
        seasonName="2026"
        seasonStart="2026-01-01"
        photoUrl={null}
        crestUrl={null}
      />
      <Section>Controle de nota</Section>
      <Card>
        <RatingSlider value={nota} onChange={setNota} />
        <Body>O 7,0 inicial só vale como voto depois de “Confirmar e próximo”.</Body>
      </Card>
    </ScrollView>
  );
}
