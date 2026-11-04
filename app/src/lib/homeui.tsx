// V10.0 — blocos do Início do jogador (REV-051 a REV-095): cabeçalho com saudação e sino, Próximo Jogo e Último Jogo.
// Só apresentação: os valores (placar, nota, OVR) vêm prontos do servidor e nada é calculado aqui.
import { Pressable, View } from 'react-native';
import Svg, { Path } from 'react-native-svg';

import { matchRating } from './centrallogic';
import type { HomeLastGame, NextRoundItem } from './centraldata';
import { box } from './central';
import { hair } from './domain';
import { Crest } from './crest';
import { individualStats, resultLabel } from './homelogic';
import { fmtDate } from './match';
import { Text } from './text';
import { colors, type } from './theme';
import { Button } from './ui';

const fmtRating = (v: number) => v.toFixed(1).replace('.', ',');

function Bell({ color }: { color: string }) {
  const p = { stroke: color, strokeWidth: 1.9, fill: 'none', strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const };
  return (
    <Svg width={24} height={24} viewBox="0 0 24 24">
      <Path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15z" {...p} />
      <Path d="M10 20.5a2.2 2.2 0 0 0 4 0" {...p} />
    </Svg>
  );
}

/** REV-053/054: saudação esportiva e sino com indicador de não lidas (ponto dourado). Sem foto de perfil neste bloco. */
export function GreetingHeader({ text, unread, onBell }: { text: string; unread: boolean; onBell: () => void }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
      <Text style={{ flex: 1, fontSize: 20, lineHeight: 26, fontWeight: '700', color: colors.ink }} numberOfLines={2} accessibilityRole="header">
        {text}
      </Text>
      <Pressable
        onPress={onBell}
        accessibilityRole="button"
        accessibilityLabel={unread ? 'Notificações, há avisos novos' : 'Notificações'}
        style={({ pressed }) => ({ width: 48, height: 48, borderRadius: 24, alignItems: 'center', justifyContent: 'center', backgroundColor: pressed ? colors.bg : 'transparent' })}>
        <Bell color={colors.blue} />
        {unread && (
          <View
            accessibilityElementsHidden
            importantForAccessibility="no"
            style={{ position: 'absolute', top: 10, right: 11, width: 10, height: 10, borderRadius: 5, backgroundColor: colors.gold, borderWidth: 2, borderColor: colors.white }}
          />
        )}
      </Pressable>
    </View>
  );
}

/** REV-056/062: pelada, confronto (o time do jogador em negrito), data, horário e local. */
export function NextGameCard({ round, crestPath, stale, onPress }: { round: NextRoundItem; crestPath?: string | null; stale: boolean; onPress: () => void }) {
  const when = round.scheduled_at ? new Date(round.scheduled_at) : null;
  const ok = !!when && !Number.isNaN(when.getTime());
  const day = ok ? when!.toLocaleDateString('pt-BR', { weekday: 'short', day: '2-digit', month: '2-digit' }) : null;
  const time = ok ? when!.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }) : null;
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`Próximo jogo na pelada ${round.pelada_name}: ${round.team_name} contra ${round.opponent_name}. ${[day, time, round.location].filter(Boolean).join(', ')}. Ver partida.`}
      style={({ pressed }) => ({ ...box, flexDirection: 'row', gap: 14, alignItems: 'center', opacity: pressed ? 0.9 : 1 })}>
      <Crest path={crestPath} name={round.pelada_name} size={56} />
      <View style={{ flex: 1, minWidth: 0, gap: 3 }}>
        <Text style={type.meta} numberOfLines={1}>{round.pelada_name}</Text>
        <Text style={{ fontSize: 16, lineHeight: 21, color: colors.ink }} numberOfLines={2}>
          <Text style={{ fontWeight: '800' }}>{round.team_name}</Text>
          <Text style={{ fontWeight: '400' }}>{` × ${round.opponent_name}`}</Text>
        </Text>
        <Text style={type.meta} numberOfLines={2}>{[day, time, round.location].filter(Boolean).join(' · ')}</Text>
        {stale ? <Text style={type.meta}>Informação anterior: confirme na partida.</Text> : null}
      </View>
      <Text style={{ color: colors.muted, fontSize: 18 }}>›</Text>
    </Pressable>
  );
}

/**
 * REV-057/063-072: última partida oficial concluída entre todas as peladas. Mostra pelada e data, o resultado em texto,
 * o time do jogador em negrito e só o que ele realizou. Sem nota publicada, sem nota; relacionado sem entrada ou sem
 * participação ganham mensagem própria (nunca se presume participação). O botão leva à Seleção da Rodada.
 */
export function HomeLastGameCard({ game, stale, onPress, onSelection }: { game: HomeLastGame; stale: boolean; onPress: () => void; onSelection: () => void }) {
  const rating = matchRating({
    played: game.participation === 'played',
    result: { final_rating: game.final_rating, has_valid_rating: game.has_valid_rating },
    session: game.rating_session_status ? { status: game.rating_session_status } : null,
    legacyFinalized: game.legacy_finalized,
  });
  const scored = game.team_a_score !== null && game.team_b_score !== null;
  const result = resultLabel(game.my_team, game.team_a_score, game.team_b_score);
  const stats = game.participation === 'played' ? individualStats(game) : [];
  const note = game.participation === 'played' && rating.kind === 'rated' ? fmtRating(rating.value) : null;
  const side = (name: string, mine: boolean, align: 'left' | 'right') => (
    <View style={{ flex: 1, minWidth: 0, alignItems: align === 'right' ? 'flex-end' : 'flex-start' }}>
      <Text style={{ fontSize: 16, lineHeight: 21, fontWeight: mine ? '800' : '400', color: mine ? colors.blue : colors.muted, textAlign: align }} numberOfLines={2}>
        {name}
      </Text>
    </View>
  );
  const status =
    game.participation === 'listed' ? 'Você estava relacionado, mas sem entrada confirmada em campo.' : game.participation === 'none' ? 'Você não participou desta partida.' : null;
  return (
    <View style={{ ...box }}>
      <Pressable
        onPress={onPress}
        accessibilityRole="button"
        accessibilityLabel={`Último jogo na pelada ${game.pelada_name}, ${fmtDate(game.played_at)}. ${game.team_a_name} ${scored ? `${game.team_a_score} a ${game.team_b_score}` : 'contra'} ${game.team_b_name}.${result ? ` ${result}.` : ''} Ver partida.`}
        style={({ pressed }) => ({ gap: 10, opacity: pressed ? 0.9 : 1 })}>
        <Text style={{ fontSize: 11, lineHeight: 14, fontWeight: '800', letterSpacing: 0.9, color: colors.muted }} numberOfLines={1}>
          {`${fmtDate(game.played_at).toUpperCase()} · ${game.pelada_name.toUpperCase()}${stale ? ' · PODE ESTAR DESATUALIZADO' : ''}`}
        </Text>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
          {side(game.team_a_name, game.my_team === 'A', 'right')}
          <Text style={{ fontSize: scored ? 28 : 15, lineHeight: scored ? 34 : 20, fontWeight: '900', color: colors.ink, fontVariant: ['tabular-nums'] }}>
            {scored ? `${game.team_a_score}–${game.team_b_score}` : '×'}
          </Text>
          {side(game.team_b_name, game.my_team === 'B', 'left')}
        </View>
        {result ? <Text style={{ textAlign: 'center', fontSize: 12, fontWeight: '800', letterSpacing: 1, color: result === 'VITÓRIA' ? '#0B6B3A' : result === 'DERROTA' ? '#9A3412' : colors.muted }}>{result}</Text> : null}
        {status ? <Text style={type.caption}>{status}</Text> : null}
        {(stats.length > 0 || note) && (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 16, borderTopWidth: 1, borderTopColor: hair, paddingTop: 10 }}>
            {note && (
              <View accessible accessibilityLabel={`Sua nota: ${note}`}>
                <Text style={{ fontSize: 24, lineHeight: 30, fontWeight: '800', color: colors.ink, fontVariant: ['tabular-nums'] }}>{note}</Text>
                <Text style={{ fontSize: 11, fontWeight: '800', letterSpacing: 0.8, color: colors.muted }}>SUA NOTA</Text>
              </View>
            )}
            {stats.map((s) => (
              <View key={s.label} accessible accessibilityLabel={`${s.value} ${s.label}`}>
                <Text style={{ fontSize: 24, lineHeight: 30, fontWeight: '800', color: colors.ink, fontVariant: ['tabular-nums'] }}>{s.value}</Text>
                <Text style={{ fontSize: 11, fontWeight: '800', letterSpacing: 0.8, color: colors.muted }}>{s.label.toUpperCase()}</Text>
              </View>
            ))}
          </View>
        )}
      </Pressable>
      <View style={{ alignItems: 'flex-end' }}>
        <Button title="Seleção da Rodada" kind="secondary" size="sm" block={false} onPress={onSelection} />
      </View>
    </View>
  );
}
