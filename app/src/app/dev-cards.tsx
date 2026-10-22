// Vitrine de Cards: só em desenvolvimento (fora do __DEV__ não mostra nada). Mesmo jogador e mesmos
// valores nas três categorias, para comparar só o desenho; também sem foto, nome longo, escudos de
// formatos diferentes (transparentes) e o tamanho pequeno do Elenco. Valores de exemplo, nunca do banco.
import { Image } from 'expo-image';
import { useLocalSearchParams } from 'expo-router';
import { useRef, useState } from 'react';
import { ScrollView, Text, View } from 'react-native';
import { captureRef } from 'react-native-view-shot';

import { CardArt } from '../lib/arts';
import { Card as CardData } from '../lib/career';
import { CrestSwatch, PlayerCard } from '../lib/playercard';
import { colors } from '../lib/theme';
import { Button } from '../lib/ui';

const svg = (body: string, w = 100, h = 100) =>
  `data:image/svg+xml;utf8,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="${w * 4}" height="${h * 4}" viewBox="0 0 ${w} ${h}">${body}</svg>`)}`;

// Escudos de teste com fundo transparente: tradicional, redondo, triangular e irregular (largo).
const CRESTS = {
  tradicional: svg(
    '<path d="M50 3 L92 14 L92 52 Q92 82 50 97 Q8 82 8 52 L8 14 Z" fill="#111" stroke="#E0A040" stroke-width="5"/><text x="50" y="58" font-size="26" font-weight="900" fill="#fff" text-anchor="middle" font-family="Arial">RFC</text>',
  ),
  redondo: svg('<circle cx="50" cy="50" r="46" fill="#0B3D91" stroke="#fff" stroke-width="6"/><circle cx="50" cy="50" r="18" fill="#F2C230"/>'),
  triangular: svg('<path d="M50 4 L96 92 L4 92 Z" fill="#B3121F"/><path d="M50 30 L76 80 L24 80 Z" fill="#fff"/>'),
  irregular: svg('<path d="M4 30 Q30 2 60 10 Q96 0 116 26 Q104 60 60 58 Q20 62 4 30 Z" fill="#1E7B3A"/>', 120, 64),
};

const base: CardData = {
  id: 'dev',
  position: 'midfielder',
  finishing: 82,
  assisting: 68,
  attendance: 85,
  winning: 78,
  peer_rating: 80,
  overall: 87,
  tier: 'ouro',
  is_provisional: false,
  matches_played: 12,
};

export default function DevCards() {
  const { foto } = useLocalSearchParams<{ foto?: string }>();
  const ref = useRef<View>(null);
  const [shot, setShot] = useState<string | null>(null);
  if (!__DEV__) return null;
  const gerar = async () => setShot(await captureRef(ref, { format: 'png', result: 'data-uri', width: 1080, height: 1920 }));
  // Na web, a foto de teste também pode vir do sessionStorage (data URL grande demais para a URL).
  let stored: string | null = null;
  try {
    stored = typeof sessionStorage !== 'undefined' ? sessionStorage.getItem('m91-dev-foto') : null;
  } catch {}
  const photo = foto ?? stored;
  const tiers = ['bronze', 'prata', 'ouro'] as const;
  return (
    <ScrollView contentContainerStyle={{ padding: 16, gap: 24, backgroundColor: colors.white }}>
      <Text style={{ fontSize: 18, fontWeight: '800', color: colors.deepBlue }}>Vitrine de Cards (desenvolvimento)</Text>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 16 }}>
        {tiers.map((t) => (
          <PlayerCard
            key={t}
            card={{ ...base, tier: t }}
            playerName="Marcelo"
            photoPath={null}
            photoUrl={photo}
            peladaName="Resenha FC"
            crestUrl={CRESTS.tradicional}
            seasonName="Temporada 2026"
          />
        ))}
      </View>
      <Text style={{ fontWeight: '700' }}>Sem foto, nome longo, provisório, escudos de outros formatos</Text>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 16 }}>
        <PlayerCard card={{ ...base, tier: 'bronze', overall: 58, is_provisional: true }} playerName="Joaquim Bernardes da Silva Neto" photoPath={null} photoUrl={null} peladaName="Pelada do Zé" crestUrl={CRESTS.redondo} seasonName="Temporada personalizada de inverno" />
        <PlayerCard card={{ ...base, tier: 'prata', overall: 71, position: 'goalkeeper' }} playerName="Zé" photoPath={null} photoUrl={photo} peladaName="Pelada do Zé" crestUrl={CRESTS.triangular} seasonName="2026" />
        <PlayerCard card={{ ...base, tier: 'ouro', position: 'attacker' }} playerName="Ana Luíza" photoPath={null} photoUrl={photo} peladaName="Quinta FC" crestUrl={null} seasonName="Temporada 2026" />
      </View>
      <Text style={{ fontWeight: '700' }}>Tamanho do Elenco (160 px)</Text>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 12 }}>
        {tiers.map((t) => (
          <PlayerCard key={t} card={{ ...base, tier: t }} playerName="Marcelo Henrique" photoPath={null} photoUrl={photo} peladaName="Resenha FC" crestUrl={CRESTS.irregular} seasonName="Temporada 2026" width={160} />
        ))}
      </View>
      <Text style={{ fontWeight: '700' }}>Exportação 1080 × 1920 (mesma captura do compartilhar)</Text>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 16, alignItems: 'flex-start' }}>
        <View ref={ref} collapsable={false} style={{ width: 315, height: 560, backgroundColor: colors.white, padding: 20, gap: 16 }}>
          <CardArt
            card={base}
            playerName="Marcelo"
            photoPath={null}
            photoUrl={photo}
            peladaName="Resenha FC"
            crestUrl={CRESTS.tradicional}
            seasonName="Temporada 2026"
          />
          <View style={{ flex: 1 }} />
          <Text style={{ textAlign: 'center', fontSize: 11, fontWeight: '800', letterSpacing: 3, color: colors.blue, opacity: 0.6 }}>MINUTO 91</Text>
        </View>
        <View style={{ gap: 8 }}>
          <Button title="Gerar imagem" onPress={gerar} />
          {shot && <Image source={{ uri: shot }} style={{ width: 315, height: 560, borderWidth: 1, borderColor: colors.line }} />}
        </View>
      </View>
      <Text style={{ fontWeight: '700' }}>Prévia do escudo (configurações)</Text>
      <View style={{ flexDirection: 'row', gap: 8 }}>
        {tiers.map((t) => (
          <CrestSwatch key={t} tier={t} crestUrl={CRESTS.irregular} peladaName="Resenha FC" width={92} />
        ))}
      </View>
    </ScrollView>
  );
}
