// V8.5: as duas imagens oficiais da escalação (REV-50): lista integral por equipe e campo ilustrativo.
// Ambas saem da MESMA versão oficial (get_share_payload) e passam pela conferência de integridade antes de
// liberar o arquivo (REV-65). Capitão com "C" discreto (REV-68), convidado com marcação discreta (REV-66),
// sem foto → avatar neutro (REV-69), homônimos diferenciados sem mudar o nome (REV-70), nomes longos com quebra
// e abreviação só inequívoca (REV-67). Muitas pessoas → várias imagens numeradas (REV-60).
import { useRef } from 'react';
import { View } from 'react-native';

import { Header, useArtFormat } from './arts';
import { Avatar } from './avatar';
import { Text } from './text';
import { colors, positionShort } from './theme';
import { type CompMember, isOutside, type Point, type Positions } from './v85';

type Names = Record<string, string>;

function Badge({ m }: { m: CompMember }) {
  return (
    <>
      {m.captain && (
        <View style={{ marginLeft: 4, paddingHorizontal: 4, borderRadius: 4, backgroundColor: colors.deepBlue, borderWidth: 1, borderColor: colors.gold }}>
          <Text style={{ fontSize: 9, fontWeight: '800', color: colors.white }}>C</Text>
        </View>
      )}
      {m.guest && <Text style={{ marginLeft: 4, fontSize: 9, color: colors.muted }}>conv.</Text>}
    </>
  );
}

function Row({ m, names, hints, compact }: { m: CompMember; names: Names; hints: Names; compact: boolean }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, minHeight: compact ? 18 : 24 }}>
      <Avatar path={m.guest ? null : m.avatar_path} name={m.name} size={compact ? 16 : 22} />
      <View style={{ flex: 1 }}>
        <View style={{ flexDirection: 'row', alignItems: 'center' }}>
          <Text style={{ flexShrink: 1, fontSize: compact ? 10 : 12, color: colors.ink }} numberOfLines={2}>
            {names[m.pid] ?? m.name}
          </Text>
          <Badge m={m} />
        </View>
        {hints[m.pid] && <Text style={{ fontSize: 8, color: colors.muted }}>{hints[m.pid]}</Text>}
      </View>
      <Text style={{ fontSize: compact ? 9 : 10, color: colors.muted, fontWeight: '700' }}>{m.position ? positionShort(m.position) : '—'}</Text>
    </View>
  );
}

export function ListArt({
  title,
  subtitle,
  crestPath,
  teamA,
  teamB,
  A,
  B,
  page,
  pages,
  names,
  hints,
  versionLabel,
}: {
  title: string;
  subtitle: string;
  crestPath?: string | null;
  teamA: string;
  teamB: string;
  A: CompMember[];
  B: CompMember[];
  page: number;
  pages: number;
  names: Names;
  hints: Names;
  versionLabel: string;
}) {
  const compact = useArtFormat() === 'post' || Math.max(A.length, B.length) > 10;
  const col = (name: string, ms: CompMember[], accent: string) => (
    <View style={{ flex: 1, gap: compact ? 2 : 4 }}>
      <View style={{ borderBottomWidth: 3, borderBottomColor: accent, paddingBottom: 3 }}>
        <Text style={{ fontSize: 13, fontWeight: '800', color: colors.deepBlue }} numberOfLines={1}>
          {name}
        </Text>
      </View>
      {ms.map((m) => (
        <Row key={m.pid} m={m} names={names} hints={hints} compact={compact} />
      ))}
    </View>
  );
  return (
    <View style={{ gap: 10 }}>
      <Header title={title} subtitle={subtitle} crestPath={crestPath} />
      <View style={{ flexDirection: 'row', gap: 12 }}>
        {col(teamA, A, colors.blue)}
        {col(teamB, B, colors.gold)}
      </View>
      <Text style={{ textAlign: 'center', fontSize: 9, color: colors.muted }}>
        {pages > 1 ? `Imagem ${page} de ${pages} · ` : ''}
        {versionLabel}
      </Text>
    </View>
  );
}

/** Desenho do campo com a área neutra em volta (fora do campo não é banco nem reserva, REV-53). */
export function FieldDrawing({
  members,
  positions,
  names,
  selected,
  onPressPoint,
  onPressPlayer,
  height = 360,
  flagged = new Set<string>(),
}: {
  members: CompMember[];
  positions: Positions;
  names: Names;
  selected?: string | null;
  onPressPoint?: (p: Point) => void;
  onPressPlayer?: (pid: string) => void;
  height?: number;
  flagged?: Set<string>;
}) {
  const boxW = useRef(1);
  // Caixa externa = −15..115 %; o campo ocupa 0..100 dentro dela.
  const toBox = (v: number) => ((v + 15) / 130) * 100;
  return (
    <View
      onStartShouldSetResponder={() => !!onPressPoint}
      onResponderRelease={(e) => {
        if (!onPressPoint) return;
        const { locationX, locationY } = e.nativeEvent;
        onPressPoint({ x: (locationX / boxW.current) * 130 - 15, y: (locationY / height) * 130 - 15 });
      }}
      onLayout={(e) => (boxW.current = e.nativeEvent.layout.width)}
      style={{ height, backgroundColor: colors.bg, borderRadius: 12, overflow: 'hidden' }}>
      <View
        pointerEvents="none"
        style={{
          position: 'absolute',
          left: `${toBox(0)}%`,
          top: `${toBox(0)}%`,
          width: `${(100 / 130) * 100}%`,
          height: `${(100 / 130) * 100}%`,
          backgroundColor: '#2E8B57',
          borderRadius: 6,
          borderWidth: 2,
          borderColor: colors.white,
        }}>
        <View style={{ position: 'absolute', top: '50%', left: 0, right: 0, height: 2, backgroundColor: colors.white, opacity: 0.8 }} />
        <View style={{ position: 'absolute', top: '42%', left: '40%', width: '20%', height: '16%', borderRadius: 100, borderWidth: 2, borderColor: colors.white, opacity: 0.8 }} />
      </View>
      {members.map((m) => {
        const p = positions[m.pid];
        if (!p) return null;
        return (
          <View
            key={m.pid}
            onStartShouldSetResponder={() => !!onPressPlayer}
            onResponderRelease={() => onPressPlayer?.(m.pid)}
            style={{ position: 'absolute', left: `${toBox(p.x)}%`, top: `${toBox(p.y)}%`, transform: [{ translateX: -30 }, { translateY: -12 }], width: 60, alignItems: 'center' }}>
            <View
              style={{
                width: 18,
                height: 18,
                borderRadius: 9,
                backgroundColor: m.team === 'A' ? colors.blue : colors.gold,
                borderWidth: 2,
                borderColor: selected === m.pid ? colors.ink : flagged.has(m.pid) ? colors.danger : colors.white,
                alignItems: 'center',
                justifyContent: 'center',
              }}>
              {m.captain && <Text style={{ fontSize: 8, fontWeight: '800', color: colors.white }}>C</Text>}
            </View>
            <Text style={{ fontSize: 9, color: isOutside(p) ? colors.ink : colors.white, fontWeight: '700', textAlign: 'center' }} numberOfLines={2}>
              {names[m.pid] ?? m.name}
              {m.guest ? ' ·c' : ''}
            </Text>
          </View>
        );
      })}
    </View>
  );
}

export function FieldArt({
  title,
  subtitle,
  crestPath,
  members,
  positions,
  names,
  teamA,
  teamB,
  page,
  pages,
  versionLabel,
}: {
  title: string;
  subtitle: string;
  crestPath?: string | null;
  members: CompMember[];
  positions: Positions;
  names: Names;
  teamA: string;
  teamB: string;
  page: number;
  pages: number;
  versionLabel: string;
}) {
  const post = useArtFormat() === 'post';
  return (
    <View style={{ gap: 8 }}>
      <Header title={title} subtitle={subtitle} crestPath={crestPath} />
      <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
        <Text style={{ fontSize: 11, fontWeight: '800', color: colors.blue }}>● {teamA} (embaixo)</Text>
        <Text style={{ fontSize: 11, fontWeight: '800', color: colors.darkGold }}>● {teamB} (em cima)</Text>
      </View>
      <FieldDrawing members={members} positions={positions} names={names} height={post ? 250 : 380} />
      <Text style={{ textAlign: 'center', fontSize: 9, color: colors.muted }}>
        Campo ilustrativo{pages > 1 ? ` · imagem ${page} de ${pages}` : ''} · {versionLabel}
      </Text>
    </View>
  );
}
