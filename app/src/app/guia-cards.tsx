import { useRouter } from 'expo-router';
import { useEffect } from 'react';
import { View } from 'react-native';

import { ATTRIBUTES_V3_KEEPER, ATTRIBUTES_V3_LINE, TIER } from '../lib/career';
import { markGuide } from '../lib/careerv2';
import { TROPHIES, TrophyArt } from '../lib/trophies';
import { Block, Body, Button, Screen, Sub } from '../lib/ui';

// Guia inicial (V4.4), passo "Entender Cards e premiações": uma tela curta, sem formulário. Abrir conta como visto.
// Só descreve o que o app já faz (as fórmulas oficiais não mudam e não são detalhadas aqui).
export default function GuiaCards() {
  const router = useRouter();
  useEffect(() => {
    markGuide('cards').catch(() => {});
  }, []);
  return (
    <Screen>
      <Block>
        <Body>Seu Card</Body>
        <Sub>
          Cada pelada tem o seu Card, por temporada. O overall vem dos números oficiais das partidas e das notas que os colegas dão
          na votação, sempre depois que a partida é finalizada.
        </Sub>
        <Sub>
          Atributos: {ATTRIBUTES_V3_LINE.map((a) => a.label).join(', ')}. Goleiro: {ATTRIBUTES_V3_KEEPER.map((a) => a.label).join(', ')}. O peso
          de cada um depende da posição. OVR a partir da 5ª partida oficial.
        </Sub>
        <Sub>
          Resenha: frequência nas partidas e quem ficou depois do jogo, segundo os colegas. Disciplina: começa em 70, amarelo tira 8,
          vermelho tira 20 e cada partida sem cartão recupera um pouco. Faltar não diminui Defesa, Letalidade, Reflexo nem
          Aproveitamento.
        </Sub>
        <Sub>
          Categorias: {TIER.bronze.label}, {TIER.prata.label} e {TIER.ouro.label}. Nas primeiras partidas o Card aparece como provisório.
        </Sub>
      </Block>
      <Block>
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
      </Block>
      <Block>
        <Body>Álbum de Figurinhas</Body>
        <Sub>Marcos que você acumula jogando, em todas as peladas.</Sub>
      </Block>
      <Button title="Ver Minha Carreira" onPress={() => router.replace('/carreira')} />
    </Screen>
  );
}
