// V8.7 / AD01: lista de "Meus Prêmios" de Minha Carreira. O bloco (título + lista) só existe com pelo menos um título
// oficial de temporada válido: quem monta a tela decide por showMyAwards (nunca bloco vazio). Uma linha por conquista, nome
// oficial + ano/temporada, mais recente primeiro; títulos de anos diferentes nunca viram contador. Origem (pelada) só quando a
// pessoa tem títulos em mais de uma. Prêmios de mês, rodada e partida não entram. A lista vem pronta do servidor
// (get_player_season_titles), que já aplica privacidade, escopo de carreira, revogações, restaurações e saída/retorno.
import { View } from 'react-native';

import { Text } from './text';
import { colors } from './theme';
import { TrophyArt } from './trophies';
import { Card, Sub } from './ui';
import { SeasonTitle, sharedLabel, titleLabel } from './v87logic';

export function MyAwardsList({ items, withOrigin }: { items: SeasonTitle[]; withOrigin: boolean }) {
  return (
    <Card>
      {items.map((t, i) => (
        <View key={t.id} style={{ flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 8, borderTopWidth: i === 0 ? 0 : 1, borderTopColor: colors.line }}>
          <TrophyArt type={t.award_type} size={34} />
          <View style={{ flex: 1, gap: 2 }}>
            <Text style={{ fontWeight: '800', color: colors.deepBlue, fontSize: 15 }}>{titleLabel(t)}</Text>
            <Sub>{[withOrigin ? t.pelada_name : null, sharedLabel(t.is_shared) || null].filter(Boolean).join(' · ')}</Sub>
          </View>
        </View>
      ))}
    </Card>
  );
}
