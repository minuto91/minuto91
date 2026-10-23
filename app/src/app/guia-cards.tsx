import { useRouter } from 'expo-router';
import { useEffect } from 'react';
import { View } from 'react-native';

import { ATTRIBUTES_V2, TIER } from '../lib/career';
import { markGuide } from '../lib/careerv2';
import { TROPHIES, TrophyArt } from '../lib/trophies';
import { Body, Button, Card, Screen, Sub, Title } from '../lib/ui';

// Guia inicial (V4.4), passo "Entender Cards e premiações": uma tela curta, sem formulário. Abrir conta como visto.
// Só descreve o que o app já faz (as fórmulas oficiais não mudam e não são detalhadas aqui).
export default function GuiaCards() {
  const router = useRouter();
  useEffect(() => {
    markGuide('cards').catch(() => {});
  }, []);
  return (
    <Screen>
      <Title>Cards e premiações</Title>
      <Card>
        <Body>Seu Card</Body>
        <Sub>
          Cada pelada tem o seu Card, por temporada. O overall vem dos números oficiais das partidas e das notas que os colegas dão
          na votação, sempre depois que a partida é finalizada.
        </Sub>
        <Sub>Atributos: {ATTRIBUTES_V2.map((a) => a.label).join(', ')}. OVR a partir da 5ª partida oficial.</Sub>
        <Sub>
          Categorias: {TIER.bronze.label}, {TIER.prata.label} e {TIER.ouro.label}. Nas primeiras partidas o Card aparece como provisório.
        </Sub>
      </Card>
      <Card>
        <Body>Sala de Troféus</Body>
        <Sub>As três premiações oficiais, com quantas vezes você ganhou cada uma e quando:</Sub>
        <View style={{ flexDirection: 'row', justifyContent: 'space-around' }}>
          {TROPHIES.map((t) => (
            <View key={t.type} style={{ alignItems: 'center', width: '32%' }}>
              <TrophyArt type={t.type} size={64} />
              <Sub>{t.label}</Sub>
            </View>
          ))}
        </View>
      </Card>
      <Card>
        <Body>Álbum de Figurinhas</Body>
        <Sub>Colecionáveis e marcos que você acumula jogando (por exemplo, 5 e 10 vezes Craque da Partida). É separado dos troféus.</Sub>
      </Card>
      <Button title="Ver Minha Carreira" onPress={() => router.replace('/carreira')} />
    </Screen>
  );
}
