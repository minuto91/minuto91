// Escalação visual: os dois times com foto ou iniciais. Time com formação registrada (4-3-3 ou 4-4-2, V4.3)
// aparece num campo estilizado; os outros, na lista organizada por posição (nunca se inventa formação).
// Usada depois do jogo (súmula oficial, grátis) e antes do jogo (escalação da Pelada Premium).
import { Pressable, View } from 'react-native';
import { Text } from './text';

import { Header, useArtFormat } from './arts';
import { Avatar } from './avatar';
import { Formation, outOfPosition, SLOTS, slotLabel } from './formation';
import { colors, positionLabel, positionRank, positionShort } from './theme';

export type LineupPlayer = {
  key: string;
  team: 'A' | 'B';
  name: string;
  position: string | null;
  avatar_path?: string | null;
  guest?: boolean;
  /** Espaço tático quando o time tem formação. */
  slot?: string | null;
};
export type TeamFormations = { A?: Formation | null; B?: Formation | null };

export const sortLineup = (ps: LineupPlayer[]) =>
  [...ps].sort((a, b) => positionRank(a.position) - positionRank(b.position) || a.name.localeCompare(b.name, 'pt-BR'));

/** Quantos de cada posição em cada time (para conferir o equilíbrio). */
export function positionCounts(ps: LineupPlayer[]) {
  const keys = [...new Set(ps.map((p) => p.position ?? 'none'))].sort((a, b) => positionRank(a) - positionRank(b));
  return keys.map((k) => ({
    position: k,
    a: ps.filter((p) => p.team === 'A' && (p.position ?? 'none') === k).length,
    b: ps.filter((p) => p.team === 'B' && (p.position ?? 'none') === k).length,
  }));
}

/** Primeiro nome + inicial do sobrenome ("Ana Luíza Souza" -> "Ana S."). */
export const shortName = (n: string) => {
  const parts = n.trim().split(/\s+/);
  return parts.length > 1 ? `${parts[0]} ${parts[parts.length - 1][0]}.` : parts[0];
};

function Column({ name, players, accent, compact }: { name: string; players: LineupPlayer[]; accent: string; compact?: boolean }) {
  return (
    <View style={{ flex: 1, gap: compact ? 4 : 6 }}>
      <View style={{ borderBottomWidth: 3, borderBottomColor: accent, paddingBottom: 4 }}>
        <Text style={{ fontSize: compact ? 13 : 15, fontWeight: '800', color: colors.deepBlue }} numberOfLines={1}>
          {name}
        </Text>
        <Text style={{ fontSize: 11, color: colors.muted }}>
          {players.length} {players.length === 1 ? 'jogador' : 'jogadores'}
        </Text>
      </View>
      {sortLineup(players).map((p) => (
        <View key={p.key} style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
          <Avatar path={p.avatar_path} name={p.name} size={compact ? 22 : 28} />
          <Text style={{ flex: 1, fontSize: compact ? 11 : 13, color: colors.ink }} numberOfLines={1}>
            {p.name}
            {p.guest ? ' (conv.)' : ''}
          </Text>
          <Text style={{ fontSize: 10, fontWeight: '800', color: colors.muted }}>{positionShort(p.position)}</Text>
        </View>
      ))}
    </View>
  );
}

/**
 * Campo de um time na formação. Toque num jogador seleciona; toque em outro troca os dois de lugar (onPressSlot).
 * Jogador fora da posição sugerida: a sigla dele aparece em dourado escuro (indicação discreta).
 */
export function FormationField({
  name,
  formation,
  players,
  accent,
  compact,
  tight,
  selected,
  onPressPlayer,
}: {
  name: string;
  formation: Formation;
  players: LineupPlayer[];
  accent: string;
  compact?: boolean;
  /** Meio campo estreito (arte com os dois times lado a lado). */
  tight?: boolean;
  selected?: string | null;
  onPressPlayer?: (key: string) => void;
}) {
  const slots = SLOTS[formation];
  const token = tight ? 18 : compact ? 26 : 34;
  const nameSize = tight ? 7 : compact ? 9 : 11;
  const bySlot = new Map(players.filter((p) => p.slot).map((p) => [p.slot as string, p]));
  return (
    <View style={{ gap: 4 }}>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-end', borderBottomWidth: 3, borderBottomColor: accent, paddingBottom: 4 }}>
        <Text style={{ fontSize: compact ? 13 : 15, fontWeight: '800', color: colors.deepBlue, flex: 1 }} numberOfLines={1}>
          {name}
        </Text>
        <Text style={{ fontSize: compact ? 11 : 13, fontWeight: '800', color: colors.darkGold }}>{formation}</Text>
      </View>
      <View
        accessibilityLabel={`${name} em ${formation}`}
        style={{ width: '100%', aspectRatio: tight ? 0.62 : compact ? 1.25 : 0.95, backgroundColor: '#EAF1FB', borderRadius: 10, borderWidth: 2, borderColor: colors.blue, overflow: 'hidden' }}>
        {/* Linhas do campo: meio-campo em cima, área e gol embaixo. */}
        <View style={{ position: 'absolute', left: 0, right: 0, top: 0, height: 0, borderTopWidth: 2, borderColor: colors.white }} />
        <View style={{ position: 'absolute', left: '35%', width: '30%', top: '-12%', aspectRatio: 1, borderRadius: 999, borderWidth: 2, borderColor: colors.white }} />
        <View style={{ position: 'absolute', left: '22%', width: '56%', bottom: 0, height: '20%', borderWidth: 2, borderBottomWidth: 0, borderColor: colors.white }} />
        <View style={{ position: 'absolute', left: '38%', width: '24%', bottom: 0, height: '8%', borderWidth: 2, borderBottomWidth: 0, borderColor: colors.white }} />
        {slots.map((s) => {
          const p = bySlot.get(s.id);
          const off = p ? outOfPosition(s, p.position) : false;
          const on = !!p && selected === p.key;
          const content = (
            <View style={{ alignItems: 'center', width: token * 2.4 }}>
              {p ? (
                <View style={{ borderRadius: 999, borderWidth: on ? 3 : 2, borderColor: on ? colors.gold : colors.white }}>
                  <Avatar path={p.avatar_path} name={p.name} size={token} />
                </View>
              ) : (
                <View style={{ width: token, height: token, borderRadius: token / 2, borderWidth: 2, borderStyle: 'dashed', borderColor: colors.muted }} />
              )}
              <Text style={{ fontSize: nameSize, fontWeight: '700', color: colors.ink }} numberOfLines={1}>
                {p ? shortName(p.name) : slotLabel(s)}
              </Text>
              {p && (
                <Text style={{ fontSize: nameSize - 1, fontWeight: '800', color: off ? colors.darkGold : colors.blue }} numberOfLines={1}>
                  {positionShort(p.position)}
                  {off ? ` · ${slotLabel(s)}` : ''}
                </Text>
              )}
            </View>
          );
          return (
            <View key={s.id} style={{ position: 'absolute', left: `${s.x}%`, top: `${s.y}%`, transform: [{ translateX: -token * 1.2 }, { translateY: -token / 2 }] }}>
              {onPressPlayer && p ? (
                <Pressable
                  onPress={() => onPressPlayer(p.key)}
                  accessibilityRole="button"
                  accessibilityState={{ selected: on }}
                  accessibilityLabel={`${p.name}, ${positionLabel(p.position)}, no espaço ${slotLabel(s)}${on ? ', selecionado' : ''}`}
                  hitSlop={4}>
                  {content}
                </Pressable>
              ) : (
                content
              )}
            </View>
          );
        })}
      </View>
    </View>
  );
}

const hasFormation = (f: Formation | null | undefined, ps: LineupPlayer[]) => !!f && ps.length === 11 && ps.every((p) => !!p.slot);

/** Quadro da escalação. score opcional (só depois do jogo). formations: só os times que têm formação registrada. */
export function LineupBoard({
  teamA,
  teamB,
  players,
  score,
  compact,
  formations,
  sideBySide,
}: {
  teamA: string;
  teamB: string;
  players: LineupPlayer[];
  score?: { a: number; b: number } | null;
  compact?: boolean;
  formations?: TeamFormations;
  /** Arte: os dois campos lado a lado, para caber em 9:16 e 4:5. */
  sideBySide?: boolean;
}) {
  const a = players.filter((p) => p.team === 'A');
  const b = players.filter((p) => p.team === 'B');
  const fa = hasFormation(formations?.A, a) ? formations!.A! : null;
  const fb = hasFormation(formations?.B, b) ? formations!.B! : null;
  return (
    <View style={{ gap: 8 }}>
      {score && (
        <Text style={{ textAlign: 'center', fontSize: compact ? 26 : 30, fontWeight: '800', color: colors.blue }}>
          {score.a} x {score.b}
        </Text>
      )}
      {fa && fb && sideBySide ? (
        <View style={{ flexDirection: 'row', gap: 8 }}>
          <View style={{ flex: 1 }}>
            <FormationField name={teamA} formation={fa} players={a} accent={colors.blue} compact tight />
          </View>
          <View style={{ flex: 1 }}>
            <FormationField name={teamB} formation={fb} players={b} accent={colors.gold} compact tight />
          </View>
        </View>
      ) : fa || fb ? (
        <View style={{ gap: 12 }}>
          {fa ? <FormationField name={teamA} formation={fa} players={a} accent={colors.blue} compact={compact} /> : <Column name={teamA} players={a} accent={colors.blue} compact={compact} />}
          {fb ? <FormationField name={teamB} formation={fb} players={b} accent={colors.gold} compact={compact} /> : <Column name={teamB} players={b} accent={colors.gold} compact={compact} />}
        </View>
      ) : (
        <View style={{ flexDirection: 'row', gap: 12 }}>
          <Column name={teamA} players={a} accent={colors.blue} compact={compact} />
          <Column name={teamB} players={b} accent={colors.gold} compact={compact} />
        </View>
      )}
    </View>
  );
}

/** Arte vertical da escalação (Stories 9:16 ou post 4:5). */
export function LineupArt({
  peladaName,
  crestPath,
  subtitle,
  teamA,
  teamB,
  players,
  score,
  formations,
}: {
  peladaName: string;
  crestPath?: string | null;
  subtitle: string;
  teamA: string;
  teamB: string;
  players: LineupPlayer[];
  score?: { a: number; b: number } | null;
  formations?: TeamFormations;
}) {
  const post = useArtFormat() === 'post';
  const withField = !!(formations?.A || formations?.B);
  return (
    <>
      <Header title={peladaName} subtitle={subtitle} crestPath={crestPath} />
      <Text style={{ textAlign: 'center', fontSize: 14, fontWeight: '700', color: colors.darkGold }}>Escalação</Text>
      <LineupBoard
        teamA={teamA}
        teamB={teamB}
        players={players}
        score={score}
        formations={formations}
        sideBySide
        compact={post || withField || players.length > 16}
      />
    </>
  );
}
