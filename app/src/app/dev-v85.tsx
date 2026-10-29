// Vitrine da V8.5 (só em desenvolvimento, sem login, DADOS SIMULADOS): imagens de escalação (lista e campo, inclusive
// várias páginas), campo ilustrativo com área neutra, sobreposição e Próxima Rodada. ?n=quantidade de participantes.
// Nada aqui lê o banco.
import { useLocalSearchParams } from 'expo-router';
import { ScrollView, View } from 'react-native';

import { NextRoundCard } from '../lib/central';
import { colors } from '../lib/theme';
import { Card, Sub, Title } from '../lib/ui';
import { autoPositions, type CompMember, displayNames, nameHints, overlaps, paginateField, paginateList, summaryText } from '../lib/v85';
import { FieldArt, FieldDrawing, ListArt } from '../lib/v85art';

const POS = ['GOL', 'ZAG', 'ZAG', 'LD', 'LE', 'VOL', 'MEI', 'MEI', 'CA', 'PD', 'ATA', null];
const NAMES = ['Rafael Abreu', 'João Silva', 'João Silva', 'Carlos Eduardo Albuquerque Souza', 'Pedro', 'Lucas Nascimento', 'Bruno', 'Thiago Mendes', 'Felipe', 'André Luiz', 'Marcos', 'Visitante'];

function sample(n: number): CompMember[] {
  return Array.from({ length: n }, (_, i) => {
    const pos = POS[i % POS.length];
    return {
      pid: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`,
      membership_id: i % 12 === 11 ? null : `m${i}`,
      guest: i % 12 === 11,
      name: n > 12 && i >= 12 ? `${NAMES[i % NAMES.length]} ${Math.floor(i / 12)}` : NAMES[i % NAMES.length],
      position: pos,
      group: pos === 'CA' || pos === 'PD' ? 'ATA' : (pos ?? 'none'),
      team: i % 2 ? 'B' : 'A',
      captain: i === 0 || i === 1,
      eligible: true,
    } as CompMember;
  });
}

export default function DevV85() {
  const { n } = useLocalSearchParams<{ n?: string }>();
  const ms = sample(Math.min(100, Math.max(2, Number(n) || 12)));
  const hints = nameHints(ms);
  const names = displayNames(ms);
  const pos = autoPositions(ms, { [ms[ms.length - 1].pid]: { x: 108, y: 50 } });
  const lp = paginateList(ms);
  const fp = paginateField(ms);
  const s = summaryText({
    cost: 1,
    size_a: ms.filter((m) => m.team === 'A').length,
    size_b: ms.filter((m) => m.team === 'B').length,
    by_group: [
      { group: 'GOL', a: 1, b: 0 },
      { group: 'ZAG', a: 1, b: 1 },
    ],
  }, 1);
  return (
    <ScrollView style={{ backgroundColor: colors.white }} contentContainerStyle={{ padding: 16, gap: 16, maxWidth: 560, width: '100%', alignSelf: 'center' }}>
      <Title>Vitrine V8.5</Title>
      <Sub>{`${ms.length} participantes · ${lp.length} imagem(ns) de lista · ${fp.length} de campo · ${overlaps(pos).length} sobreposição(ões)`}</Sub>
      <Sub>{s.headline}</Sub>
      <NextRoundCard
        round={{ lineup_id: null, match_id: 'x', composition_id: 'y', pelada_id: 'p', pelada_name: 'Pelada de Quinta', label: 'Rodada 2 de 4', team_name: 'Azul', opponent_name: 'Dourado', scheduled_at: '2026-11-05T23:00:00Z', location: 'Arena Central', rescheduled: true }}
        more={1}
        stale={false}
        onPress={() => {}}
      />
      <Card>
        <FieldDrawing members={ms} positions={pos} names={names} flagged={new Set(overlaps(pos).flat())} />
      </Card>
      {lp.map((p) => (
        <View key={p.page} style={{ width: 315, alignSelf: 'center', borderWidth: 1, borderColor: colors.line, borderRadius: 12, padding: 14 }}>
          <ListArt title="Pelada de Quinta" subtitle="Rodada 2 de 4 · 05/11 20:00" teamA="Azul" teamB="Dourado" A={p.A} B={p.B} page={p.page} pages={p.pages} names={names} hints={hints} versionLabel="Rodada 2 · versão 3" />
        </View>
      ))}
      {fp.map((f, i) => (
        <View key={i} style={{ width: 315, alignSelf: 'center', borderWidth: 1, borderColor: colors.line, borderRadius: 12, padding: 14 }}>
          <FieldArt title="Pelada de Quinta" subtitle="Rodada 2 de 4" members={f} positions={pos} names={names} teamA="Azul" teamB="Dourado" page={i + 1} pages={fp.length} versionLabel="versão 3" />
        </View>
      ))}
    </ScrollView>
  );
}
