// Artes oficiais 9:16 (Brand Book 11: fundo branco, azul nos títulos, dourado só nas conquistas,
// logo discreta) e o painel que mostra a arte e compartilha como imagem 1080 x 1920.
// Quem monta cada arte decide se pode: o resultado e a Seleção só para quem vê as notas (RN-098).
import { Image } from 'expo-image';
import { ReactNode, useRef, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { initials, useAvatarUrl } from './avatar';
import { CrestView, useCrestUrl } from './crest';
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
// Fundo na cor da categoria e moldura que evolui (bronze simples, prata com filete, ouro com filete e
// ornamentos), brilho metálico discreto, sem partículas nem 3D. A foto é a protagonista e o escudo da
// pelada fica pequeno ao lado do overall. Mesmo layout nas três categorias.
// A foto é quadrada (no compartilhamento pela web o html2canvas não respeita "cover").
// width muda a escala inteira (o Elenco usa cartas menores); textos nunca ficam abaixo de 9 px.

const POS_CODE: Record<string, string> = { goalkeeper: 'GOL', defender: 'DEF', midfielder: 'MEI', attacker: 'ATA' };
export const CARD_W = 275;

export function PlayerCard({
  card,
  playerName,
  photoPath,
  peladaName,
  crestPath,
  seasonName,
  width = CARD_W,
}: {
  card: CardData;
  playerName: string;
  photoPath: string | null | undefined;
  peladaName: string;
  crestPath?: string | null;
  seasonName: string;
  width?: number;
}) {
  const t = TIER[card.tier];
  const photo = useAvatarUrl(photoPath);
  const crest = useCrestUrl(crestPath);
  const k = width / CARD_W;
  const px = (n: number) => Math.round(n * k * 10) / 10;
  const font = (n: number) => Math.max(9, px(n));
  const compact = width < 200; // no Elenco: sem rodapé
  const photoSide = px(168);
  const overall = Math.round(card.overall);
  const outer = Math.max(2, px(t.level === 3 ? 4 : 3));
  const gap = px(t.level === 1 ? 0 : 3);

  return (
    <View
      accessibilityLabel={`Carta ${t.label} de ${playerName}, overall ${overall}, ${positionLabel(card.position)}${card.is_provisional ? ', provisória' : ''}`}
      style={{ width, borderRadius: px(18), borderWidth: outer, borderColor: t.frame, backgroundColor: t.bg, padding: gap }}>
      <View
        style={{
          borderRadius: px(t.level === 1 ? 15 : 13),
          borderWidth: t.level === 1 ? 0 : 1,
          borderColor: t.frame,
          overflow: 'hidden',
          backgroundColor: t.bg,
          paddingBottom: px(compact ? 8 : 12),
        }}>
        {/* Brilho metálico: uma faixa clara em diagonal, mais visível conforme a categoria. */}
        <View
          pointerEvents="none"
          style={{
            position: 'absolute',
            top: -px(60),
            left: px(40),
            width: px(70),
            height: px(520),
            backgroundColor: colors.white,
            opacity: t.sheen,
            transform: [{ rotate: '24deg' }],
          }}
        />
        {t.level === 3 && (
          <>
            <View style={[s.ornament, { top: px(4), left: '50%', marginLeft: -px(5), width: px(10), height: px(10), backgroundColor: t.frame }]} />
            <View style={[s.ornament, { bottom: px(4), left: '50%', marginLeft: -px(5), width: px(10), height: px(10), backgroundColor: t.frame }]} />
          </>
        )}

        <View style={{ flexDirection: 'row', alignItems: 'flex-start', paddingTop: px(16), paddingHorizontal: px(10), gap: px(8) }}>
          <View style={{ alignItems: 'center', width: px(58), gap: px(4) }}>
            <Text style={{ fontSize: font(38), fontWeight: '800', color: colors.deepBlue, lineHeight: font(42) }}>{overall}</Text>
            <Text style={{ fontSize: font(13), fontWeight: '800', color: t.deep, letterSpacing: 1 }}>{POS_CODE[card.position] ?? card.position}</Text>
            <View style={{ height: 1, width: px(30), backgroundColor: t.frame, marginVertical: px(4) }} />
            <CrestView url={crest} name={peladaName} size={Math.max(18, px(30))} />
          </View>
          <View
            style={{
              borderRadius: px(14),
              borderWidth: Math.max(1, px(t.level === 3 ? 2 : 1.5)),
              borderColor: t.frame,
              backgroundColor: colors.white,
              padding: px(3),
            }}>
            {photo ? (
              <Image
                source={{ uri: photo }}
                style={{ width: photoSide, height: photoSide, borderRadius: px(11) }}
                contentFit="cover"
                accessibilityLabel={`Foto de ${playerName}`}
              />
            ) : (
              <View
                style={{ width: photoSide, height: photoSide, borderRadius: px(11), backgroundColor: colors.bg, alignItems: 'center', justifyContent: 'center' }}>
                <Text style={{ fontSize: font(56), fontWeight: '800', color: colors.deepBlue, opacity: 0.85 }}>{initials(playerName)}</Text>
              </View>
            )}
          </View>
        </View>

        <Text
          style={{ fontSize: font(22), fontWeight: '800', color: colors.deepBlue, textAlign: 'center', marginTop: px(10), paddingHorizontal: px(12) }}
          numberOfLines={1}
          adjustsFontSizeToFit
          minimumFontScale={0.7}>
          {playerName}
        </Text>
        <Text style={{ fontSize: font(12), fontWeight: '600', color: t.deep, textAlign: 'center', marginTop: px(2) }} numberOfLines={1}>
          {compact ? '' : `${positionLabel(card.position)} · `}
          {t.label.toUpperCase()}
          {card.is_provisional ? ' · provisória' : ''}
        </Text>
        <View style={{ height: 1, marginHorizontal: px(22), marginVertical: px(compact ? 8 : 12), backgroundColor: t.frame }} />
        <View style={{ flexDirection: 'row', justifyContent: 'space-around', paddingHorizontal: px(8) }}>
          {ATTRIBUTES.map((a) => (
            <View key={a.key} style={{ alignItems: 'center', minWidth: px(44) }} accessibilityLabel={`${a.label} ${Math.round(Number(card[a.key]))}`}>
              <Text style={{ fontSize: font(20), fontWeight: '800', color: colors.deepBlue }}>{Math.round(Number(card[a.key]))}</Text>
              <Text style={{ fontSize: font(10), fontWeight: '700', color: t.deep, letterSpacing: compact ? 0 : 1 }}>{a.code}</Text>
            </View>
          ))}
        </View>
        {!compact && (
          <View style={{ flexDirection: 'row', justifyContent: 'space-between', gap: px(8), marginTop: px(14), paddingHorizontal: px(14) }}>
            <Text style={{ flexShrink: 1, fontSize: font(10), fontWeight: '700', color: t.deep }} numberOfLines={1}>
              {peladaName}
            </Text>
            {!!seasonName && (
              <Text style={{ flexShrink: 1, fontSize: font(10), fontWeight: '700', color: t.deep }} numberOfLines={1}>
                {seasonName}
              </Text>
            )}
          </View>
        )}
      </View>
    </View>
  );
}

export function CardArt(props: {
  peladaName: string;
  crestPath?: string | null;
  seasonName: string;
  playerName: string;
  photoPath: string | null | undefined;
  card: CardData;
}) {
  return (
    <>
      {/* Centraliza a carta na altura da arte (o painel põe um espaço flexível antes da logo). */}
      <View style={{ flex: 1 }} />
      <Text style={[s.goldLabel, { textAlign: 'center', color: colors.blue }]}>CARTA DA TEMPORADA</Text>
      <View style={{ alignItems: 'center' }}>
        <PlayerCard {...props} />
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
  ornament: { position: 'absolute', transform: [{ rotate: '45deg' }] },
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
