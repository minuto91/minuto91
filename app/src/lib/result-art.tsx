// Arte oficial 9:16 do resultado da partida (Brand Book 11: fundo branco, azul nos títulos,
// dourado só nas conquistas, logo discreta). Só é montada para quem vê o resultado detalhado:
// o servidor não entrega as notas a quem não votou (RN-034/RN-098).
import { forwardRef } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { fmtRating } from './match';
import { colors } from './theme';

export const ART_WIDTH = 360;
export const ART_HEIGHT = 640;

export type ArtData = {
  peladaName: string;
  date: string;
  teamA: string;
  teamB: string;
  scoreA: number;
  scoreB: number;
  craque: { name: string; rating: number | null }[];
  garcom: { name: string; assists: number }[];
  top: { pos: number; name: string; rating: number }[];
};

export const ResultArt = forwardRef<View, { data: ArtData }>(function ResultArt({ data }, ref) {
  return (
    <View ref={ref} collapsable={false} style={s.art}>
      <View style={{ alignItems: 'center', gap: 2 }}>
        <Text style={s.pelada} numberOfLines={1}>
          {data.peladaName}
        </Text>
        <Text style={s.muted}>{data.date}</Text>
      </View>

      <View style={s.scoreRow}>
        <Text style={s.team} numberOfLines={1}>
          {data.teamA}
        </Text>
        <Text style={s.score}>
          {data.scoreA} x {data.scoreB}
        </Text>
        <Text style={s.team} numberOfLines={1}>
          {data.teamB}
        </Text>
      </View>

      {data.craque.length > 0 && (
        <View style={s.craque}>
          <Text style={s.craqueLabel}>CRAQUE DA PARTIDA</Text>
          {data.craque.map((c) => (
            <Text key={c.name} style={s.craqueName} numberOfLines={1}>
              {c.name}
              {c.rating !== null ? `  ${fmtRating(c.rating)}` : ''}
            </Text>
          ))}
        </View>
      )}

      {data.garcom.length > 0 && (
        <Text style={s.garcom} numberOfLines={2}>
          Garçom: {data.garcom.map((g) => g.name).join(', ')} ({data.garcom[0].assists} assist.)
        </Text>
      )}

      {data.top.length > 0 && (
        <View style={s.list}>
          <Text style={s.listTitle}>Notas da rodada</Text>
          {data.top.map((t) => (
            <View key={`${t.pos}-${t.name}`} style={s.row}>
              <Text style={s.rowPos}>{t.pos}º</Text>
              <Text style={s.rowName} numberOfLines={1}>
                {t.name}
              </Text>
              <Text style={s.rowRating}>{fmtRating(t.rating)}</Text>
            </View>
          ))}
        </View>
      )}

      <View style={{ flex: 1 }} />
      <Text style={s.logo}>MINUTO 91</Text>
    </View>
  );
});

const s = StyleSheet.create({
  art: {
    width: ART_WIDTH,
    height: ART_HEIGHT,
    backgroundColor: colors.white,
    paddingHorizontal: 24,
    paddingVertical: 32,
    gap: 18,
    borderRadius: 4,
    borderWidth: 1,
    borderColor: colors.line,
  },
  pelada: { fontSize: 20, fontWeight: '800', color: colors.deepBlue },
  muted: { fontSize: 13, color: colors.muted },
  scoreRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10 },
  team: { flex: 1, fontSize: 14, fontWeight: '700', color: colors.ink, textAlign: 'center' },
  score: { fontSize: 40, fontWeight: '800', color: colors.blue },
  craque: {
    alignItems: 'center',
    gap: 4,
    paddingVertical: 14,
    borderRadius: 12,
    borderWidth: 2,
    borderColor: colors.gold,
  },
  craqueLabel: { fontSize: 12, fontWeight: '800', letterSpacing: 2, color: colors.darkGold },
  craqueName: { fontSize: 22, fontWeight: '800', color: colors.deepBlue },
  garcom: { fontSize: 14, fontWeight: '600', color: colors.ink, textAlign: 'center' },
  list: { gap: 6 },
  listTitle: { fontSize: 13, fontWeight: '800', color: colors.blue, marginBottom: 2 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  rowPos: { width: 28, fontSize: 14, fontWeight: '700', color: colors.muted },
  rowName: { flex: 1, fontSize: 15, color: colors.ink },
  rowRating: { fontSize: 15, fontWeight: '800', color: colors.deepBlue },
  logo: { textAlign: 'center', fontSize: 12, fontWeight: '800', letterSpacing: 3, color: colors.blue, opacity: 0.6 },
});
