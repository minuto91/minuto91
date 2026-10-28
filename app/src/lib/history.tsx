// REV-003: histórico de partidas da carreira. A Minha Carreira mostra as 3 mais recentes; a página própria pagina.
// Ícones aprovados: gol = bola tradicional azul; assistência = chuteira azul com travas; cartões = retângulos.
import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, View } from 'react-native';
import Svg, { Circle, Path, Polygon, Rect } from 'react-native-svg';

import { friendly } from './errors';
import { fmtDate } from './match';
import { supabase } from './supabase';
import { Text } from './text';
import { colors, radius, type } from './theme';
import { Button, EmptyState, ErrorText } from './ui';
import { Skeleton } from './central';

export type HistoryItem = {
  match_id: string;
  played_at: string;
  team_a_name: string;
  team_b_name: string;
  team_a_score: number;
  team_b_score: number;
  my_team: 'A' | 'B' | null;
  match_result: 'win' | 'draw' | 'loss';
  goals: number;
  assists: number;
  yellow_cards?: number;
  red_cards?: number;
  pelada_name: string;
  pelada_active?: boolean;
};
type Cursor = { played_at: string; match_id: string };
const RESULT = { win: 'V', draw: 'E', loss: 'D' } as const;
const RESULT_LABEL = { win: 'Vitória', draw: 'Empate', loss: 'Derrota' } as const;

export function BallIcon({ size = 14 }: { size?: number }) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" accessibilityLabel="gol">
      <Circle cx={12} cy={12} r={10.5} fill={colors.white} stroke={colors.blue} strokeWidth={1.8} />
      <Polygon points="12,7.5 16.3,10.6 14.7,15.6 9.3,15.6 7.7,10.6" fill={colors.blue} />
      <Path d="M12 7.5 V2 M16.3 10.6 L21.6 8.9 M14.7 15.6 L18 20 M9.3 15.6 L6 20 M7.7 10.6 L2.4 8.9" stroke={colors.blue} strokeWidth={1.3} />
    </Svg>
  );
}

export function BootIcon({ size = 14 }: { size?: number }) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" accessibilityLabel="assistência">
      <Path d="M5 5 H11 V12 C11 13 12 14 13 14.3 L19 16 C21 16.5 22 17.6 22 19 V19.5 H3 C2.4 19.5 2 19 2 18.4 V15 C2 13.7 3 13 4 12.4 C4.7 12 5 11.3 5 10.5 Z" fill={colors.blue} />
      {[5, 9.5, 14, 19].map((x) => (
        <Rect key={x} x={x - 1} y={20} width={2} height={2.5} rx={0.6} fill={colors.blue} />
      ))}
    </Svg>
  );
}

export const CardIcon = ({ color, size = 14 }: { color: string; size?: number }) => (
  <View style={{ width: size * 0.7, height: size, borderRadius: 2, backgroundColor: color }} />
);

function Stat({ icon, n }: { icon: React.ReactNode; n: number }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
      {icon}
      {n > 1 && <Text style={{ fontSize: 13, fontWeight: '700', color: colors.ink }}>{n}</Text>}
    </View>
  );
}

export function HistoryRow({ m, showPelada }: { m: HistoryItem; showPelada: boolean }) {
  const router = useRouter();
  const mine = (t: 'A' | 'B') => (m.my_team === t ? { fontWeight: '800' as const } : null);
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`${RESULT_LABEL[m.match_result]}, ${m.team_a_name} ${m.team_a_score} a ${m.team_b_score} ${m.team_b_name}, ${fmtDate(m.played_at)}`}
      onPress={() => router.push({ pathname: '/partida/[id]', params: { id: m.match_id } })}
      style={{ minHeight: 56, flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: colors.line }}>
      <View
        style={{
          width: 28, height: 28, borderRadius: 14, alignItems: 'center', justifyContent: 'center',
          backgroundColor: m.match_result === 'win' ? colors.blue : m.match_result === 'draw' ? colors.bg : colors.white,
          borderWidth: 1, borderColor: m.match_result === 'loss' ? colors.line : colors.blue,
        }}>
        <Text style={{ fontSize: 12, fontWeight: '800', color: m.match_result === 'win' ? colors.white : colors.blue }}>{RESULT[m.match_result]}</Text>
      </View>
      <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
        <Text style={type.body} numberOfLines={1}>
          <Text style={mine('A')}>{m.team_a_name}</Text> {m.team_a_score}–{m.team_b_score} <Text style={mine('B')}>{m.team_b_name}</Text>
        </Text>
        <Text style={type.caption} numberOfLines={1}>
          {fmtDate(m.played_at)}
          {showPelada ? ` · ${m.pelada_name}` : ''}
          {m.pelada_active === false ? ' · participação encerrada' : ''}
        </Text>
      </View>
      <View style={{ flexDirection: 'row', gap: 8, alignItems: 'center' }}>
        {m.goals > 0 && <Stat icon={<BallIcon />} n={m.goals} />}
        {m.assists > 0 && <Stat icon={<BootIcon />} n={m.assists} />}
        {(m.yellow_cards ?? 0) > 0 && <Stat icon={<CardIcon color="#F2C230" />} n={m.yellow_cards!} />}
        {(m.red_cards ?? 0) > 0 && <Stat icon={<CardIcon color={colors.danger} />} n={m.red_cards!} />}
      </View>
    </Pressable>
  );
}

/** limit = só as N mais recentes (sem paginação); sem limit = página completa com "Carregar mais". */
export function MatchHistory({ peladaId, showPelada, limit }: { peladaId: string | null; showPelada: boolean; limit?: number }) {
  const [items, setItems] = useState<HistoryItem[] | null>(null);
  const [next, setNext] = useState<Cursor | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [retry, setRetry] = useState(0);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc('get_my_match_history', { p_pelada: peladaId, p_after: null, p_limit: limit ?? 20 });
      if (!alive) return;
      if (error) return setMsg(friendly(error.message));
      const p = data as { items: HistoryItem[]; next: Cursor | null };
      setMsg(null);
      setItems(p.items);
      setNext(p.next);
    })();
    return () => {
      alive = false;
    };
  }, [peladaId, limit, retry]);

  async function more() {
    if (!next || busy) return;
    setBusy(true);
    const { data, error } = await supabase.rpc('get_my_match_history', { p_pelada: peladaId, p_after: next, p_limit: 20 });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    const p = data as { items: HistoryItem[]; next: Cursor | null };
    setItems((xs) => [...(xs ?? []), ...p.items]);
    setNext(p.next);
  }

  if (msg && !items)
    return (
      <View style={{ gap: 8 }}>
        <ErrorText>{msg}</ErrorText>
        <Button title="Tentar de novo" kind="secondary" onPress={() => setRetry((n) => n + 1)} />
      </View>
    );
  if (!items)
    return (
      <View style={{ gap: 10 }}>
        {Array.from({ length: limit ?? 4 }, (_, i) => (
          <Skeleton key={i} height={44} style={{ borderRadius: radius.md }} />
        ))}
      </View>
    );
  if (items.length === 0) return <EmptyState title="Nenhuma partida ainda" />;
  return (
    <View>
      {items.map((m) => (
        <HistoryRow key={m.match_id} m={m} showPelada={showPelada} />
      ))}
      {!limit && next && <Button title="Carregar mais" kind="ghost" onPress={more} loading={busy} />}
      {msg && <ErrorText>{msg}</ErrorText>}
    </View>
  );
}
