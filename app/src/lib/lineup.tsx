// Escalação visual (V4.2): os dois times lado a lado, jogadores agrupados pela posição cadastrada, com foto
// ou iniciais. Não desenha formação tática (não há dado para isso): só a lista organizada por posição.
// Usada depois do jogo (súmula oficial, grátis) e antes do jogo (escalação da Pelada Premium).
import { Text, View } from 'react-native';

import { Header, useArtFormat } from './arts';
import { Avatar } from './avatar';
import { colors } from './theme';

export type LineupPlayer = { key: string; team: 'A' | 'B'; name: string; position: string | null; avatar_path?: string | null; guest?: boolean };

export const POS_ORDER = ['goalkeeper', 'defender', 'midfielder', 'attacker'];
export const POS_SHORT: Record<string, string> = { goalkeeper: 'GOL', defender: 'DEF', midfielder: 'MEI', attacker: 'ATA' };
const posRank = (p: string | null) => (p && POS_ORDER.includes(p) ? POS_ORDER.indexOf(p) : 9);

export const sortLineup = (ps: LineupPlayer[]) =>
  [...ps].sort((a, b) => posRank(a.position) - posRank(b.position) || a.name.localeCompare(b.name, 'pt-BR'));

/** Quantos de cada posição em cada time (para conferir o equilíbrio). */
export function positionCounts(ps: LineupPlayer[]) {
  const keys = [...new Set(ps.map((p) => p.position ?? 'none'))].sort((a, b) => posRank(a) - posRank(b));
  return keys.map((k) => ({
    position: k,
    a: ps.filter((p) => p.team === 'A' && (p.position ?? 'none') === k).length,
    b: ps.filter((p) => p.team === 'B' && (p.position ?? 'none') === k).length,
  }));
}

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
          <Text style={{ fontSize: 10, fontWeight: '800', color: colors.muted }}>{p.position ? (POS_SHORT[p.position] ?? '–') : '–'}</Text>
        </View>
      ))}
    </View>
  );
}

/** Quadro da escalação. score opcional (só depois do jogo). */
export function LineupBoard({
  teamA,
  teamB,
  players,
  score,
  compact,
}: {
  teamA: string;
  teamB: string;
  players: LineupPlayer[];
  score?: { a: number; b: number } | null;
  compact?: boolean;
}) {
  return (
    <View style={{ gap: 8 }}>
      {score && (
        <Text style={{ textAlign: 'center', fontSize: compact ? 26 : 30, fontWeight: '800', color: colors.blue }}>
          {score.a} x {score.b}
        </Text>
      )}
      <View style={{ flexDirection: 'row', gap: 12 }}>
        <Column name={teamA} players={players.filter((p) => p.team === 'A')} accent={colors.blue} compact={compact} />
        <Column name={teamB} players={players.filter((p) => p.team === 'B')} accent={colors.gold} compact={compact} />
      </View>
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
}: {
  peladaName: string;
  crestPath?: string | null;
  subtitle: string;
  teamA: string;
  teamB: string;
  players: LineupPlayer[];
  score?: { a: number; b: number } | null;
}) {
  const post = useArtFormat() === 'post';
  return (
    <>
      <Header title={peladaName} subtitle={subtitle} crestPath={crestPath} />
      <Text style={{ textAlign: 'center', fontSize: 11, fontWeight: '800', letterSpacing: 2, color: colors.darkGold }}>ESCALAÇÃO</Text>
      <LineupBoard teamA={teamA} teamB={teamB} players={players} score={score} compact={post || players.length > 16} />
    </>
  );
}
