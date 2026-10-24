// V6.1 — componentes visuais de domínio (placar, faixa de números, OVR, tarefa pendente). Só apresentação: os valores
// chegam prontos de quem chama; nenhuma regra ou fórmula mora aqui. Cada um tem rótulo acessível próprio.
import { type ReactNode } from 'react';
import { Pressable, View } from 'react-native';

import { Text } from './text';
import { colors, radius } from './theme';

export const hair = '#E6EBF3';

// ---------------------------------------------------------------------------------------------------------------
// StatStrip: números lado a lado separados por filetes verticais (sem cartão).
// ---------------------------------------------------------------------------------------------------------------
export type StatItem = { value: ReactNode; label: string; a11y?: string; gold?: boolean };

export function StatStrip({ items, size = 'md' }: { items: StatItem[]; size?: 'sm' | 'md' }) {
  // Quatro números ou mais: corpo menor, para "100%" caber inteiro em 320 px.
  const big = size === 'md' && items.length < 4 ? 22 : 18;
  return (
    <View style={{ flexDirection: 'row' }}>
      {items.map((s, i) => (
        <View
          key={s.label}
          accessible
          accessibilityLabel={s.a11y ?? `${s.label}: ${typeof s.value === 'string' || typeof s.value === 'number' ? s.value : ''}`}
          style={{
            flex: 1,
            minWidth: 0,
            paddingLeft: i ? 12 : 0,
            borderLeftWidth: i ? 1 : 0,
            borderLeftColor: hair,
          }}>
          <Text
            style={{ fontSize: big, lineHeight: big + 4, fontWeight: '800', color: s.gold ? colors.darkGold : colors.deepBlue, fontVariant: ['tabular-nums'] }}
            numberOfLines={typeof s.value === 'object' ? 2 : 1}>
            {s.value}
          </Text>
          <Text style={{ fontSize: 12, lineHeight: 16, color: colors.muted }} numberOfLines={2}>
            {s.label}
          </Text>
        </View>
      ))}
    </View>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// MatchScore: placar editorial em faixa azul-escura. O time do jogador ganha peso e o marcador "você".
// ---------------------------------------------------------------------------------------------------------------
export function MatchScore({
  a,
  b,
  scoreA,
  scoreB,
  mine,
  top,
  light,
}: {
  a: string;
  b: string;
  scoreA: number | null;
  scoreB: number | null;
  mine: 'A' | 'B' | null;
  top?: ReactNode;
  /** Versão clara (confronto ainda sem placar), para não pesar ao lado do último jogo. */
  light?: boolean;
}) {
  const fg = light ? colors.deepBlue : colors.white;
  const dim = light ? colors.muted : '#C9D6EE';
  const side = (name: string, me: boolean, align: 'left' | 'right') => (
    <View style={{ flex: 1, minWidth: 0, alignItems: align === 'right' ? 'flex-end' : 'flex-start', gap: 2 }}>
      <Text
        style={{ fontSize: 16, lineHeight: 21, fontWeight: me ? '800' : '500', color: me ? fg : dim, textAlign: align }}
        numberOfLines={2}>
        {name}
      </Text>
      {me && <Text style={{ fontSize: 11, fontWeight: '700', letterSpacing: 0.6, color: light ? colors.blue : '#9DB8E8' }}>VOCÊ</Text>}
    </View>
  );
  const scored = scoreA !== null && scoreB !== null;
  return (
    <View
      style={{ backgroundColor: light ? colors.bg : colors.deepBlue, borderRadius: radius.card, paddingHorizontal: 16, paddingVertical: 14, gap: 10 }}
      accessible
      accessibilityLabel={scored ? `${a} ${scoreA} a ${scoreB} ${b}` : `${a} contra ${b}`}>
      {top}
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        {side(a, mine === 'A', 'right')}
        <Text style={{ fontSize: scored ? 34 : 15, lineHeight: scored ? 40 : 20, fontWeight: '900', color: fg, fontVariant: ['tabular-nums'] }}>
          {scored ? `${scoreA}–${scoreB}` : '×'}
        </Text>
        {side(b, mine === 'B', 'left')}
      </View>
    </View>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// PlayerOVR: número do OVR (dourado conforme o nível) com o rótulo pequeno; a variação vem ao lado.
// ---------------------------------------------------------------------------------------------------------------
export function PlayerOVR({ ovr, color, narrow, aside }: { ovr: number; color: string; narrow?: boolean; aside?: ReactNode }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'flex-end', gap: 8, flexWrap: 'wrap' }}>
      <View accessible accessibilityLabel={`OVR ${ovr}`}>
        <Text style={{ fontSize: 11, fontWeight: '700', color: colors.muted, letterSpacing: 0.8 }}>OVR</Text>
        <Text style={{ fontSize: narrow ? 40 : 48, lineHeight: narrow ? 44 : 52, fontWeight: '900', color, fontVariant: ['tabular-nums'] }}>{ovr}</Text>
      </View>
      {aside ? <View style={{ paddingBottom: 8 }}>{aside}</View> : null}
    </View>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// VotePendingRow: tarefa compacta (marcador, título, prazo e ação), sem cartão por item.
// ---------------------------------------------------------------------------------------------------------------
export function VotePendingRow({
  title,
  detail,
  action,
  tone,
  first,
  onPress,
}: {
  title: string;
  detail?: string;
  action: string;
  tone: 'blue' | 'gold';
  first?: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`${title}${detail ? `. ${detail}` : ''}. ${action}`}
      style={({ pressed }) => ({
        flexDirection: 'row',
        alignItems: 'center',
        gap: 12,
        minHeight: 56,
        paddingVertical: 10,
        borderTopWidth: first ? 0 : 1,
        borderTopColor: hair,
        opacity: pressed ? 0.6 : 1,
      })}>
      <View
        style={{
          width: 20,
          height: 20,
          borderRadius: 10,
          borderWidth: 2,
          borderColor: tone === 'blue' ? colors.blue : colors.line,
          alignItems: 'center',
          justifyContent: 'center',
        }}>
        {tone === 'blue' && <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: colors.blue }} />}
      </View>
      <View style={{ flex: 1, minWidth: 0, gap: 1 }}>
        <Text style={{ fontSize: 15, lineHeight: 20, fontWeight: '600', color: colors.ink }} numberOfLines={2}>
          {title}
        </Text>
        {detail ? (
          <Text style={{ fontSize: 13, lineHeight: 18, color: colors.muted }} numberOfLines={2}>
            {detail}
          </Text>
        ) : null}
      </View>
      <Text style={{ fontSize: 14, fontWeight: '700', color: colors.blue }}>{action} ›</Text>
    </Pressable>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// RankingRow: posição, foto, nome, nível do Card e o número do ranking, separados por filete (sem cartão).
// A posição e o empate chegam do servidor; aqui só se desenha.
// ---------------------------------------------------------------------------------------------------------------
export function RankingRow({
  position,
  name,
  avatar,
  badge,
  tied,
  value,
  unit,
  onPress,
}: {
  position: number;
  name: string;
  avatar: ReactNode;
  badge?: ReactNode;
  tied?: boolean;
  value: string;
  unit?: string;
  onPress: () => void;
}) {
  const first = position === 1;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`${position}º lugar${tied ? ', empatado' : ''}: ${name}, ${value}${unit ? ` ${unit}` : ''}`}
      onPress={onPress}
      style={({ pressed }) => ({
        flexDirection: 'row',
        alignItems: 'center',
        gap: 10,
        minHeight: 56,
        paddingVertical: 8,
        borderBottomWidth: 1,
        borderBottomColor: hair,
        opacity: pressed ? 0.6 : 1,
      })}>
      <View
        style={{
          width: 32,
          height: 32,
          borderRadius: 16,
          alignItems: 'center',
          justifyContent: 'center',
          borderWidth: first ? 2 : 0,
          borderColor: colors.gold,
        }}>
        <Text style={{ fontWeight: '800', fontSize: 15, color: first ? colors.darkGold : colors.deepBlue, fontVariant: ['tabular-nums'] }}>{position}º</Text>
      </View>
      {avatar}
      <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
        <Text style={{ fontSize: 15, color: colors.ink, fontWeight: first ? '700' : '500' }} numberOfLines={1}>
          {name}
        </Text>
        {(badge || tied) && (
          <View style={{ flexDirection: 'row', gap: 6, alignItems: 'center' }}>
            {badge}
            {tied && <Text style={{ fontSize: 12, color: colors.muted }}>empatado</Text>}
          </View>
        )}
      </View>
      <View style={{ alignItems: 'flex-end' }}>
        <Text style={{ color: colors.deepBlue, fontWeight: '800', fontSize: 18, fontVariant: ['tabular-nums'] }}>{value}</Text>
        {unit ? <Text style={{ color: colors.muted, fontSize: 12 }}>{unit}</Text> : null}
      </View>
      <Text style={{ color: colors.muted, fontSize: 18 }}>›</Text>
    </Pressable>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// TrophyTile: troféu com a quantidade. Conquistado = dourado; nunca conquistado = apagado sobre o cinza-claro.
// ---------------------------------------------------------------------------------------------------------------
export function TrophyTile({
  art,
  label,
  count,
  open,
  onPress,
}: {
  art: ReactNode;
  label: string;
  count: number;
  open: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`${label}: ${count} ${count === 1 ? 'vez' : 'vezes'}. Toque para ver o histórico.`}
      accessibilityState={{ expanded: open }}
      onPress={onPress}
      style={({ pressed }) => ({
        width: '31%',
        minWidth: 96,
        alignItems: 'center',
        paddingVertical: 10,
        borderRadius: radius.card,
        borderWidth: open ? 2 : 0,
        borderColor: colors.gold,
        backgroundColor: count ? '#FBF6EA' : colors.bg,
        opacity: pressed ? 0.7 : 1,
        gap: 4,
      })}>
      {art}
      <Text style={{ fontSize: 12, fontWeight: '700', color: colors.deepBlue, textAlign: 'center' }} numberOfLines={2}>
        {label}
      </Text>
      <Text style={{ fontSize: 18, fontWeight: '900', color: count ? colors.darkGold : colors.muted, fontVariant: ['tabular-nums'] }}>× {count}</Text>
    </Pressable>
  );
}
