// Vitrine da V4.6 (só em desenvolvimento, sem login, DADOS SIMULADOS): Cards com o ano no rodapé, os cinco troféus,
// as nove ilustrações do álbum com os seis acabamentos, a Seleção da Rodada no campo verde (fotos simuladas e bordas
// das cores dos times) e a peça de compartilhamento. Serve para conferir o desenho no navegador.
import { ScrollView, View } from 'react-native';

import { SelectionArt, SharePanel } from '../lib/arts';
import { BrandSignature } from '../lib/brand';
import type { Card as CardData } from '../lib/career';
import { PlayerCard } from '../lib/playercard';
import { FieldPlayer, SelectionField, TeamLegend, teamHex } from '../lib/selection';
import { StickerArtCode, StickerTile } from '../lib/stickers';
import { Text } from '../lib/text';
import { colors, type } from '../lib/theme';
import { TROPHIES, TrophyArt } from '../lib/trophies';
import { Button, Card, Section, Sub, Title } from '../lib/ui';

// "Foto" simulada: silhueta em SVG (nenhuma pessoa real).
const face = (bg: string, skin: string, shirt: string) =>
  `data:image/svg+xml;utf8,${encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><rect width="40" height="40" fill="${bg}"/><circle cx="20" cy="16" r="7.5" fill="${skin}"/><path d="M6 40 C7 29 13 25 20 25 C27 25 33 29 34 40 Z" fill="${shirt}"/></svg>`,
  )}`;
const FACES = [face('#D9E4F7', '#C68E62', '#1255C6'), face('#F7E3CF', '#8D5A3B', '#F08A24'), face('#E3E7EE', '#E0B48C', '#103675')];

const base: CardData = {
  id: 'dev',
  position: 'midfielder',
  finishing: 82,
  assisting: 68,
  attendance: 85,
  winning: 78,
  peer_rating: 80,
  overall: 84,
  tier: 'ouro',
  is_provisional: false,
  matches_played: 12,
};

const A = teamHex('azul');
const B = teamHex('laranja');
const PLAYERS: FieldPlayer[] = [
  ['Gui', 'PE', 'attacker', A, 0],
  ['Joaquim', 'CA', 'attacker', B, -1],
  ['Paulinho', 'PD', 'attacker', A, 1],
  ['Ana Luíza', 'MEI', 'midfielder', A, 2],
  ['Digão', 'VOL', 'midfielder', B, 0],
  ['Caio', 'MEI', 'midfielder', B, 1],
  ['Rafa', 'LE', 'defender', B, 2],
  ['Tião', 'ZAG', 'defender', A, 0],
  ['Bruno Henrique', 'ZAG', 'defender', B, 1],
  ['Léo', 'LD', 'defender', A, 2],
  ['Zé Carlos', 'GOL', 'goalkeeper', null, 0],
].map(([name, pos, position, color, f], i) => ({
  key: String(i),
  name: name as string,
  posLabel: pos as string,
  position: position as FieldPlayer['position'],
  teamColor: color as string | null,
  photoUrl: (f as number) >= 0 ? FACES[f as number] : null,
}));
const TEAMS = [
  { name: 'Time Azul', color: A },
  { name: 'Time Laranja', color: B },
];

const ARTS: { art: StickerArtCode; name: string; level: number; sub: string }[] = [
  { art: 'craque', name: 'Craque III', level: 3, sub: '10 títulos' },
  { art: 'artilheiro', name: 'Artilheiro III', level: 3, sub: '25 gols' },
  { art: 'garcom', name: 'Garçom III', level: 3, sub: '25 assistências' },
  { art: 'presenca', name: 'Presença III', level: 3, sub: '25 partidas' },
  { art: 'pe_quente', name: 'Pé Quente III', level: 3, sub: '10 vitórias seguidas' },
  { art: 'invencivel', name: 'Invencível III', level: 3, sub: '15 sem perder' },
  { art: 'nota_alta', name: 'Nota Alta III', level: 3, sub: '10 notas 8+' },
  { art: 'rei_do_mes', name: 'Rei do Mês III', level: 3, sub: '5 títulos' },
  { art: 'selecao', name: 'Seleção III', level: 3, sub: '10 convocações' },
];

export default function DevV46() {
  if (!__DEV__) return null;
  return (
    <ScrollView contentContainerStyle={{ padding: 20, gap: 14, backgroundColor: colors.white }}>
      <Title>Vitrine V4.6</Title>
      <Sub>Dados simulados. Sem login e sem servidor.</Sub>

      <Section>Cards (rodapé com o ano)</Section>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 16, justifyContent: 'center' }}>
        {(['bronze', 'prata', 'ouro'] as const).map((tier, i) => (
          <PlayerCard
            key={tier}
            card={{ ...base, tier, overall: [58, 71, 84][i], position: (['midfielder', 'goalkeeper', 'attacker'] as const)[i] }}
            playerName={['Joaquim Bernardes', 'Zé Carlos', 'Ana Luíza'][i]}
            photoPath={null}
            photoUrl={FACES[i]}
            peladaName="Pelada do Zé"
            seasonName="Temporada 2026"
            seasonStart="2026-01-01"
            width={250}
          />
        ))}
      </View>

      <Section>Sala de Troféus</Section>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8, justifyContent: 'center' }}>
        {TROPHIES.map((t, i) => (
          <View key={t.type} style={{ width: '31%', minWidth: 96, alignItems: 'center', gap: 4, paddingVertical: 10, borderRadius: 14, borderWidth: 1, borderColor: colors.line }}>
            <TrophyArt type={t.type} size={72} dim={i === 2} />
            <Text style={{ fontSize: 12, fontWeight: '700', color: colors.deepBlue, textAlign: 'center' }}>{t.label}</Text>
            <Text style={{ fontSize: 18, fontWeight: '900', color: colors.darkGold }}>× {[7, 2, 0, 4, 1][i]}</Text>
          </View>
        ))}
      </View>

      <Section>Álbum — nove ilustrações (Ouro)</Section>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 10, justifyContent: 'center' }}>
        {ARTS.map((a) => (
          <StickerTile key={a.art} art={a.art} level={a.level} title={a.name} sub={a.sub} width={104} />
        ))}
      </View>
      <Section>Acabamentos por nível (Artilheiro)</Section>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 10, justifyContent: 'center' }}>
        {[1, 2, 3, 4, 5, 6].map((l) => (
          <StickerTile key={l} art="artilheiro" level={l} title={`Artilheiro ${l === 6 ? 'Lendário' : ['I', 'II', 'III', 'IV', 'V'][l - 1]}`} sub={['1 gol', '10 gols', '25 gols', '50 gols', '100 gols', '200 gols'][l - 1]} locked={l === 4} width={104} />
        ))}
      </View>

      <Section>Seleção da Rodada</Section>
      <Card>
        <View style={{ alignItems: 'center', gap: 10 }}>
          <SelectionField players={PLAYERS} width={300} />
          <TeamLegend teams={TEAMS} />
        </View>
      </Card>
      <SharePanel label="Imagem de compartilhamento" fileName="minuto91-selecao-dev" title="Seleção da Rodada">
        <SelectionArt peladaName="Pelada do Zé" date="18/10/2026" matchLabel="Time Azul 4 x 3 Time Laranja" players={PLAYERS} teams={TEAMS} />
      </SharePanel>

      <Section>Botões e assinatura</Section>
      <Button title="Primário" onPress={() => {}} />
      <Button title="Secundário" kind="secondary" onPress={() => {}} />
      <Button title="Discreto" kind="ghost" onPress={() => {}} />
      <Button title="Destrutivo" kind="danger" onPress={() => {}} />
      <View style={{ alignItems: 'center', paddingVertical: 8 }}>
        <BrandSignature size={28} />
      </View>
      <Text style={type.caption}>Assinatura 91’ provisória, conforme o Brand Book, até a arte final do fundador.</Text>
    </ScrollView>
  );
}
