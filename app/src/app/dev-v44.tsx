// Vitrine da V4.4: só em desenvolvimento (fora do __DEV__ não mostra nada). Sala de Troféus (os três troféus com o
// mesmo pedestal), e uma lista virtualizada com 2.000 cobranças, com DADOS SIMULADOS, para conferir o desenho e a
// rolagem sem gravar nada no banco. Nunca lê o Supabase. Não é teste de integração.
import { useState } from 'react';
import { View } from 'react-native';
import { Text } from '../lib/text';

import { StatusBadge } from '../lib/financeui';
import { formatBRL } from '../lib/money';
import { colors } from '../lib/theme';
import { TROPHIES, TrophyArt, TrophyType } from '../lib/trophies';
import { Body, Card, Chips, ListScreen, Sub, Title } from '../lib/ui';

type Row = { id: string; name: string; due: number; paid: number; status: 'pending' | 'partial' | 'paid' };
const ROWS: Row[] = Array.from({ length: 2000 }, (_, i) => {
  const due = 1000 + ((i * 37) % 9000);
  const status = i % 10 === 0 ? 'pending' : i % 10 === 1 ? 'partial' : 'paid';
  return { id: String(i), name: `Jogador ${(i % 40) + 1}`, due, paid: status === 'pending' ? 0 : status === 'partial' ? Math.floor(due / 2) : due, status };
});
const COUNTS: Record<TrophyType, number> = { match_craque: 7, monthly_king: 2, bola_murcha: 0, monthly_garcom: 1, top_scorer: 2, monthly_goalkeeper: 1, season_craque: 1, season_top_scorer: 1, season_maestro: 1, season_golden_glove: 1 };

export default function DevV44() {
  const [page, setPage] = useState(1);
  if (!__DEV__) return null;
  const shown = ROWS.slice(0, page * 30);
  const header = (
    <>
      <Title>Vitrine V4.4</Title>
      <Sub>DADOS SIMULADOS. Não é teste de integração.</Sub>
      <Card>
        <Body>Sala de Troféus</Body>
        <View style={{ flexDirection: 'row', justifyContent: 'space-between', gap: 8 }}>
          {TROPHIES.map((t) => (
            <View
              key={t.type}
              style={{ flex: 1, alignItems: 'center', borderWidth: 1, borderColor: colors.line, borderRadius: 14, paddingVertical: 10, gap: 4 }}>
              <TrophyArt type={t.type} size={84} dim={COUNTS[t.type] === 0} />
              <Text style={{ fontSize: 12, fontWeight: '700', color: colors.deepBlue, textAlign: 'center' }}>{t.label}</Text>
              <Text style={{ fontSize: 18, fontWeight: '900', color: COUNTS[t.type] ? colors.darkGold : colors.muted }}>× {COUNTS[t.type]}</Text>
            </View>
          ))}
        </View>
        <Sub>Os três no mesmo pedestal e tamanho. Bola Murcha apagada = ainda não conquistado.</Sub>
      </Card>
      <View style={{ flexDirection: 'row', justifyContent: 'space-around' }}>
        {TROPHIES.map((t) => (
          <TrophyArt key={t.type} type={t.type} size={110} />
        ))}
      </View>
      <Chips options={[{ value: 'open', label: 'Em aberto' }, { value: 'partial', label: 'Parciais' }]} value="open" onChange={() => {}} />
      <Sub>
        Lista virtualizada: {ROWS.length} cobranças simuladas, carregadas de 30 em 30 ao rolar ({shown.length} carregadas).
      </Sub>
    </>
  );
  return (
    <ListScreen
      header={header}
      data={shown}
      keyExtractor={(r) => r.id}
      onEndReached={() => setPage((p) => (p * 30 < ROWS.length ? p + 1 : p))}
      renderItem={(r) => (
        <Card>
          <View style={{ flexDirection: 'row', alignItems: 'flex-start', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Body>{r.name}</Body>
              <Sub>Avulso · cobrança {Number(r.id) + 1}</Sub>
            </View>
            <StatusBadge status={r.status} />
          </View>
          <Text style={{ color: colors.ink }}>
            Devido {formatBRL(r.due)} · pago {formatBRL(r.paid)}
          </Text>
        </Card>
      )}
    />
  );
}
