// Vitrine da V4.3: só em desenvolvimento (fora do __DEV__ não mostra nada). Dez posições, Card com a sigla nova,
// formações 4-3-3 e 4-4-2 com troca por toque, e o painel do Financeiro, com DADOS SIMULADOS, para conferir o
// desenho sem gravar nada no banco. Nunca lê o Supabase. Não é teste de integração.
import { useState } from 'react';
import { ScrollView, View } from 'react-native';
import { Text } from '../lib/text';

import { PlayerCard, SharePanel } from '../lib/arts';
import { Card as CardData } from '../lib/career';
import { Stat } from '../lib/financeui';
import { autoAssign, swapSlots } from '../lib/formation';
import { FormationField, LineupArt, LineupBoard, LineupPlayer } from '../lib/lineup';
import { formatBRL } from '../lib/money';
import { colors, positionLabel, positionShort } from '../lib/theme';
import { Card, PositionPicker, Sub } from '../lib/ui';

const A = [
  ['Tião', 'GOL'],
  ['Guga', 'LE'],
  ['Dudu', 'ZAG'],
  ['Lelo', 'ZAG'],
  ['Biel', 'LD'],
  ['Caio', 'MEI'],
  ['Nando', 'VOL'],
  ['Pipo', 'midfielder'], // cadastro antigo (Meio-campista), ainda sem sigla
  ['Rafa', 'PE'],
  ['Teco', 'CA'],
  ['Vini', 'GOL'], // goleiro jogando na linha: fica fora da posição sugerida
];
const B = [
  ['Zeca', 'GOL'],
  ['Juca', 'LE'],
  ['Leo', 'ZAG'],
  ['Maicon', 'ZAG'],
  ['Pedrão', 'LD'],
  ['Kiko', 'MEI'],
  ['Bruno', 'VOL'],
  ['Tuca', 'VOL'],
  ['Marcão', 'MEI'],
  ['Dinho', 'CA'],
  ['Fê', 'ATA'],
];
const base: LineupPlayer[] = [
  ...A.map(([n, p]) => ({ key: `a-${n}`, name: n, position: p, team: 'A' as const })),
  ...B.map(([n, p]) => ({ key: `b-${n}`, name: n, position: p, team: 'B' as const })),
];
const card: CardData = {
  id: 'dev',
  position: 'defender',
  position_code: 'LD',
  finishing: 22,
  assisting: 41,
  attendance: 95,
  winning: 78,
  peer_rating: 80,
  overall: 72.6,
  tier: 'prata',
  is_provisional: false,
  matches_played: 14,
};

export default function DevV43() {
  const [pos, setPos] = useState<string | null>('LD');
  const [slots, setSlots] = useState<Record<string, string>>(() => ({
    ...autoAssign(base.filter((p) => p.team === 'A'), '4-3-3'),
    ...autoAssign(base.filter((p) => p.team === 'B'), '4-4-2'),
  }));
  const [picked, setPicked] = useState<string | null>(null);
  if (!__DEV__) return null;
  const players = base.map((p) => ({ ...p, slot: slots[p.key] ?? null }));
  const tap = (k: string) => {
    if (!picked) return setPicked(k);
    if (picked === k || picked[0] !== k[0]) return setPicked(picked === k ? null : k);
    setSlots((s) => swapSlots(s, picked, k));
    setPicked(null);
  };
  return (
    <ScrollView contentContainerStyle={{ padding: 16, gap: 18, backgroundColor: colors.white }}>
      <Text style={{ fontSize: 18, fontWeight: '800', color: colors.deepBlue }}>Vitrine V4.3 (DADOS SIMULADOS)</Text>

      <Text style={{ fontWeight: '700' }}>Dez posições oficiais</Text>
      <Card>
        <PositionPicker value={pos} onChange={setPos} />
        <Sub>
          Escolhida: {positionShort(pos)} · {positionLabel(pos)}
        </Sub>
        <Sub>Cadastro antigo (Defensor) escolhe só dentro do setor:</Sub>
        <PositionPicker value={null} onChange={setPos} sector="defender" />
      </Card>

      <Text style={{ fontWeight: '700' }}>Card com a sigla nova (layout e fórmulas inalterados)</Text>
      <View style={{ alignItems: 'center' }}>
        <PlayerCard card={card} playerName="Biel Santos" photoPath={null} photoUrl={null} peladaName="Pelada do Zé" crestUrl={null} seasonName="Temporada 2026" />
      </View>

      <Text style={{ fontWeight: '700' }}>Formações: Time A 4-3-3 e Time B 4-4-2 (toque em dois do mesmo time para trocar)</Text>
      <Card>
        <FormationField name="Azul" formation="4-3-3" players={players.filter((p) => p.team === 'A')} accent={colors.blue} selected={picked} onPressPlayer={tap} />
        <FormationField name="Dourado" formation="4-4-2" players={players.filter((p) => p.team === 'B')} accent={colors.gold} selected={picked} onPressPlayer={tap} />
      </Card>
      <Text style={{ fontWeight: '700' }}>Time com 10 jogadores: sem formação, lista por posição</Text>
      <Card>
        <LineupBoard teamA="Azul" teamB="Dourado" players={players.filter((p) => p.key !== 'a-Vini')} formations={{ A: '4-3-3', B: '4-4-2' }} />
      </Card>
      <SharePanel label="Arte da escalação" fileName="dev-escalacao" title="Escalação">
        <LineupArt peladaName="Pelada do Zé" subtitle="Final · quinta 22/10" teamA="Azul" teamB="Dourado" players={players} formations={{ A: '4-3-3', B: '4-4-2' }} />
      </SharePanel>

      <Text style={{ fontWeight: '700' }}>Financeiro (painel)</Text>
      <View style={{ borderRadius: 14, backgroundColor: colors.deepBlue, padding: 16, gap: 4 }}>
        <Text style={{ color: colors.white, opacity: 0.8, fontSize: 13, fontWeight: '600' }}>Saldo atual (recebido − pago)</Text>
        <Text style={{ color: colors.white, fontSize: 32, fontWeight: '900' }}>{formatBRL(184550)}</Text>
        <Text style={{ color: colors.gold, fontSize: 12, fontWeight: '700' }}>Projeção com pendências: {formatBRL(214550)}</Text>
      </View>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
        <Stat label="Receitas do mês" cents={96000} />
        <Stat label="Despesas do mês" cents={72000} tone="ink" />
        <Stat label="A receber" cents={45000} tone="gold" hint={`${formatBRL(15000)} vencido`} />
        <Stat label="Despesas pendentes" cents={15000} tone="danger" />
      </View>
    </ScrollView>
  );
}
