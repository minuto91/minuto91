// Artes oficiais 9:16 (Brand Book 11: fundo branco, azul nos títulos, dourado só nas conquistas,
// logo discreta) e o painel que mostra a arte e compartilha como imagem 1080 x 1920.
// Quem monta cada arte decide se pode: o resultado e a Seleção só para quem vê as notas (RN-098).
import { ReactNode, useRef, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { ATTRIBUTES, Card as CardData, TIER } from './career';
import { friendly } from './errors';
import { fmtRating } from './match';
import { shareViewAsImage } from './share';
import { colors, positionLabel } from './theme';
import { Button, ErrorText } from './ui';

// 9:16 que cabe na tela de um iPhone pequeno (375 - 2 x 20 de margem).
const W = 315;
const H = 560;

export function SharePanel({
  label,
  fileName,
  title,
  children,
}: {
  label: string;
  fileName: string;
  title: string;
  children: ReactNode;
}) {
  const ref = useRef<View>(null);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  async function compartilhar() {
    setBusy(true);
    setMsg(null);
    try {
      await shareViewAsImage(ref, fileName, title);
    } catch (e) {
      setMsg(friendly((e as Error).message));
    }
    setBusy(false);
  }

  if (!open) return <Button title={label} kind="secondary" onPress={() => setOpen(true)} />;
  return (
    <View style={{ gap: 10 }}>
      <View style={{ alignItems: 'center' }}>
        <View ref={ref} collapsable={false} style={s.frame}>
          {children}
          <View style={{ flex: 1 }} />
          <Text style={s.logo}>MINUTO 91</Text>
        </View>
      </View>
      <ErrorText>{msg}</ErrorText>
      <Button title="Compartilhar imagem" onPress={compartilhar} loading={busy} />
      <Button title="Fechar" kind="secondary" onPress={() => setOpen(false)} />
    </View>
  );
}

function Header({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <View style={{ alignItems: 'center', gap: 2 }}>
      <Text style={s.pelada} numberOfLines={1}>
        {title}
      </Text>
      <Text style={s.muted}>{subtitle}</Text>
    </View>
  );
}

// ---------- Resultado da partida (Craque da Partida) ----------

export type ResultArtData = {
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

export function ResultArt({ data }: { data: ResultArtData }) {
  return (
    <>
      <Header title={data.peladaName} subtitle={data.date} />
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
        <View style={s.goldBox}>
          <Text style={s.goldLabel}>CRAQUE DA PARTIDA</Text>
          {data.craque.map((c) => (
            <Text key={c.name} style={s.bigName} numberOfLines={1}>
              {c.name}
              {c.rating !== null ? `  ${fmtRating(c.rating)}` : ''}
            </Text>
          ))}
        </View>
      )}
      {data.garcom.length > 0 && (
        <Text style={s.center} numberOfLines={2}>
          Garçom: {data.garcom.map((g) => g.name).join(', ')} ({data.garcom[0].assists} assist.)
        </Text>
      )}
      {data.top.length > 0 && (
        <View style={{ gap: 5 }}>
          <Text style={s.section}>Notas da rodada</Text>
          {data.top.map((t) => (
            <View key={`${t.pos}-${t.name}`} style={s.row}>
              <Text style={s.rowPos}>{t.pos}º</Text>
              <Text style={s.rowName} numberOfLines={1}>
                {t.name}
              </Text>
              <Text style={s.rowValue}>{fmtRating(t.rating)}</Text>
            </View>
          ))}
        </View>
      )}
    </>
  );
}

// ---------- Seleção da Rodada (4-3-3, sem adaptação: vaga sem candidato fica vazia) ----------

export type SelectionSlot = { position: string; name: string | null; rating: number | null; best: boolean };
export const FORMATION: { position: string; count: number }[] = [
  { position: 'attacker', count: 3 },
  { position: 'midfielder', count: 3 },
  { position: 'defender', count: 4 },
  { position: 'goalkeeper', count: 1 },
];

export function SelectionArt({ peladaName, date, slots }: { peladaName: string; date: string; slots: SelectionSlot[] }) {
  return (
    <>
      <Header title={peladaName} subtitle={date} />
      <Text style={[s.goldLabel, { textAlign: 'center', color: colors.blue }]}>SELEÇÃO DA RODADA</Text>
      <View style={s.field}>
        <View style={s.midline} />
        <View style={s.circle} />
        {FORMATION.map((line) => (
          <View key={line.position} style={s.fieldRow}>
            {slots
              .filter((x) => x.position === line.position)
              .map((x, i) => (
                <View key={`${line.position}-${i}`} style={s.player}>
                  <View
                    style={[
                      s.marker,
                      x.best && { backgroundColor: colors.gold },
                      !x.name && { backgroundColor: colors.white, borderStyle: 'dashed' },
                    ]}
                  />
                  <Text style={s.playerName} numberOfLines={1}>
                    {x.name ?? 'vaga'}
                  </Text>
                  {x.rating !== null && <Text style={s.playerRating}>{fmtRating(x.rating)}</Text>}
                </View>
              ))}
          </View>
        ))}
      </View>
    </>
  );
}

// ---------- Carta do jogador ----------

export function CardArt({
  peladaName,
  seasonName,
  playerName,
  card,
}: {
  peladaName: string;
  seasonName: string;
  playerName: string;
  card: CardData;
}) {
  const tier = TIER[card.tier];
  return (
    <>
      <Header title={peladaName} subtitle={seasonName} />
      <View style={[s.card, { borderColor: tier.color }]}>
        <Text style={s.overall}>{Math.round(card.overall)}</Text>
        <Text style={[s.goldLabel, { color: tier.color }]}>{tier.label.toUpperCase()}</Text>
        <Text style={s.bigName} numberOfLines={1}>
          {playerName}
        </Text>
        <Text style={s.muted}>
          {positionLabel(card.position)}
          {card.is_provisional ? ' · provisória' : ''}
        </Text>
      </View>
      <View style={{ gap: 7 }}>
        {ATTRIBUTES.map((a) => {
          const v = Math.max(0, Math.min(100, Number(card[a.key])));
          return (
            <View key={a.key} style={{ gap: 3 }}>
              <View style={s.row}>
                <Text style={s.rowName}>{a.label}</Text>
                <Text style={s.rowValue}>{Math.round(v)}</Text>
              </View>
              <View style={s.barBg}>
                <View style={[s.bar, { width: `${v}%` }]} />
              </View>
            </View>
          );
        })}
      </View>
    </>
  );
}

// ---------- Figurinha conquistada ----------

export function StickerArt({
  peladaName,
  playerName,
  collection,
  sticker,
  level,
  criteria,
  date,
}: {
  peladaName: string;
  playerName: string;
  collection: string;
  sticker: string;
  level: number;
  criteria: string;
  date: string;
}) {
  return (
    <>
      <Header title={peladaName} subtitle={playerName} />
      <Text style={[s.goldLabel, { textAlign: 'center' }]}>FIGURINHA CONQUISTADA</Text>
      <View style={s.sticker}>
        <Text style={s.muted}>{collection}</Text>
        <View style={s.emblem}>
          <Text style={{ fontSize: 56, color: colors.gold }}>★</Text>
        </View>
        <Text style={[s.bigName, { textAlign: 'center' }]} numberOfLines={2}>
          {sticker}
        </Text>
        <View style={{ flexDirection: 'row', gap: 5 }}>
          {[1, 2, 3, 4, 5, 6].map((n) => (
            <View key={n} style={[s.dot, n <= level && { backgroundColor: colors.gold, borderColor: colors.gold }]} />
          ))}
        </View>
        <Text style={s.center}>{criteria}</Text>
        <Text style={s.muted}>Conquistada em {date}</Text>
      </View>
    </>
  );
}

const s = StyleSheet.create({
  frame: {
    width: W,
    height: H,
    backgroundColor: colors.white,
    paddingHorizontal: 20,
    paddingVertical: 26,
    gap: 16,
    borderWidth: 1,
    borderColor: colors.line,
  },
  logo: { textAlign: 'center', fontSize: 11, fontWeight: '800', letterSpacing: 3, color: colors.blue, opacity: 0.6 },
  pelada: { fontSize: 18, fontWeight: '800', color: colors.deepBlue },
  muted: { fontSize: 12, color: colors.muted },
  center: { fontSize: 13, fontWeight: '600', color: colors.ink, textAlign: 'center' },
  scoreRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8 },
  team: { flex: 1, fontSize: 13, fontWeight: '700', color: colors.ink, textAlign: 'center' },
  score: { fontSize: 36, fontWeight: '800', color: colors.blue },
  goldBox: { alignItems: 'center', gap: 4, paddingVertical: 12, borderRadius: 12, borderWidth: 2, borderColor: colors.gold },
  goldLabel: { fontSize: 11, fontWeight: '800', letterSpacing: 2, color: colors.darkGold },
  bigName: { fontSize: 20, fontWeight: '800', color: colors.deepBlue },
  section: { fontSize: 12, fontWeight: '800', color: colors.blue, marginBottom: 2 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  rowPos: { width: 26, fontSize: 13, fontWeight: '700', color: colors.muted },
  rowName: { flex: 1, fontSize: 14, color: colors.ink },
  rowValue: { fontSize: 14, fontWeight: '800', color: colors.deepBlue },
  // Campo abstrato: linhas azul-claro, sem gramado (Brand Book 7.3).
  field: {
    height: 370,
    borderWidth: 2,
    borderColor: '#DCE7FA',
    borderRadius: 10,
    justifyContent: 'space-around',
    paddingVertical: 8,
  },
  midline: { position: 'absolute', left: 0, right: 0, top: '50%', height: 2, backgroundColor: '#DCE7FA' },
  circle: {
    position: 'absolute',
    left: '50%',
    top: '50%',
    width: 70,
    height: 70,
    marginLeft: -35,
    marginTop: -35,
    borderRadius: 35,
    borderWidth: 2,
    borderColor: '#DCE7FA',
  },
  fieldRow: { flexDirection: 'row', justifyContent: 'space-around' },
  player: { alignItems: 'center', width: 64, gap: 2 },
  marker: { width: 22, height: 22, borderRadius: 11, backgroundColor: colors.blue, borderWidth: 2, borderColor: colors.blue },
  playerName: { fontSize: 11, fontWeight: '700', color: colors.ink, maxWidth: 64 },
  playerRating: { fontSize: 11, fontWeight: '800', color: colors.deepBlue },
  card: { alignItems: 'center', gap: 2, paddingVertical: 16, borderRadius: 16, borderWidth: 3 },
  overall: { fontSize: 60, fontWeight: '900', color: colors.deepBlue },
  barBg: { height: 7, borderRadius: 4, backgroundColor: colors.line },
  bar: { height: 7, borderRadius: 4, backgroundColor: colors.blue },
  sticker: { alignItems: 'center', gap: 10, paddingVertical: 18, borderRadius: 16, borderWidth: 2, borderColor: colors.gold },
  emblem: {
    width: 110,
    height: 110,
    borderRadius: 55,
    borderWidth: 3,
    borderColor: colors.gold,
    alignItems: 'center',
    justifyContent: 'center',
  },
  dot: { width: 10, height: 10, borderRadius: 5, borderWidth: 1, borderColor: colors.line },
});
