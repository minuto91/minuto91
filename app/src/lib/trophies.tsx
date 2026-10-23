// Sala de Troféus (V4.4): só as três premiações oficiais — Craque da Partida, Rei do Mês e Bola Murcha. As contagens
// vêm da tabela oficial de prêmios (a mesma das estatísticas, do álbum e dos avisos); o histórico de cada troféu é
// carregado só quando a pessoa abre (get_trophy_history, paginado). Nada é contado de novo no app.
// Desenho: os três dividem o mesmo pedestal azul com friso dourado, o mesmo tamanho e o mesmo acabamento dourado.
import { useState } from 'react';
import { Pressable, Text, View } from 'react-native';
import Svg, { Circle, Defs, Ellipse, G, LinearGradient, Path, Polygon, Rect, Stop } from 'react-native-svg';

import { friendly } from './errors';
import { fmtDate } from './match';
import { supabase } from './supabase';
import { colors } from './theme';
import { Button, Sub } from './ui';

export type TrophyType = 'match_craque' | 'monthly_king' | 'bola_murcha';
export type TrophyCounts = Record<TrophyType, number>;

export const TROPHIES: { type: TrophyType; label: string; hint: string }[] = [
  { type: 'match_craque', label: 'Craque da Partida', hint: 'Mais votado como Craque numa partida.' },
  { type: 'monthly_king', label: 'Rei do Mês', hint: 'Melhor do mês na pelada.' },
  { type: 'bola_murcha', label: 'Bola Murcha', hint: 'Escolhido como Bola Murcha numa partida.' },
];

const GOLD_LIGHT = '#F3D98B';
const GOLD_DARK = '#A97C1F';

function Pedestal() {
  return (
    <G>
      <Rect x={31} y={86} width={38} height={5} rx={2} fill={colors.gold} />
      <Path d="M34 91 H66 L71 110 H29 Z" fill={colors.deepBlue} />
      <Rect x={33} y={98} width={34} height={2.5} fill={colors.gold} opacity={0.9} />
      <Rect x={22} y={109} width={56} height={9} rx={3} fill={colors.blue} />
    </G>
  );
}

/** O troféu desenhado (mesmo pedestal e tamanho para os três). */
export function TrophyArt({ type, size = 96, dim = false }: { type: TrophyType; size?: number; dim?: boolean }) {
  const gid = `gold-${type}`;
  return (
    <Svg width={size} height={size * 1.2} viewBox="0 0 100 120" opacity={dim ? 0.35 : 1}>
      <Defs>
        <LinearGradient id={gid} x1="0" y1="0" x2="1" y2="1">
          <Stop offset="0" stopColor={GOLD_LIGHT} />
          <Stop offset="0.55" stopColor={colors.gold} />
          <Stop offset="1" stopColor={GOLD_DARK} />
        </LinearGradient>
      </Defs>
      {type === 'match_craque' && (
        <G>
          <Circle cx={50} cy={58} r={26} fill={`url(#${gid})`} stroke={GOLD_DARK} strokeWidth={1.2} />
          <Polygon points="50,47 59,53.5 55.5,64 44.5,64 41,53.5" fill={colors.deepBlue} opacity={0.85} />
          <Path d="M50 47 V33 M59 53.5 L73 49 M55.5 64 L63 76 M44.5 64 L37 76 M41 53.5 L27 49" stroke={GOLD_DARK} strokeWidth={1.4} />
          <Path d="M36 42 C40 37 45 35 50 35" stroke="#FFFFFF" strokeWidth={2} strokeLinecap="round" opacity={0.6} fill="none" />
        </G>
      )}
      {type === 'monthly_king' && (
        <G>
          <Path
            d="M24 80 L20 44 L36 58 L50 34 L64 58 L80 44 L76 80 Z"
            fill={`url(#${gid})`}
            stroke={GOLD_DARK}
            strokeWidth={1.2}
            strokeLinejoin="round"
          />
          <Rect x={24} y={74} width={52} height={8} rx={2} fill={GOLD_DARK} />
          <Circle cx={20} cy={42} r={3.5} fill={`url(#${gid})`} stroke={GOLD_DARK} strokeWidth={1} />
          <Circle cx={50} cy={32} r={4} fill={`url(#${gid})`} stroke={GOLD_DARK} strokeWidth={1} />
          <Circle cx={80} cy={42} r={3.5} fill={`url(#${gid})`} stroke={GOLD_DARK} strokeWidth={1} />
          <Circle cx={50} cy={64} r={4.5} fill={colors.blue} />
          <Circle cx={35} cy={67} r={3} fill={colors.blue} />
          <Circle cx={65} cy={67} r={3} fill={colors.blue} />
        </G>
      )}
      {type === 'bola_murcha' && (
        <G>
          {/* a mesma bola dourada (gomo azul e costuras), murcha: achatada e afundada no meio, com vincos */}
          <Path
            d="M24 86 C21 76 24 64 33 59 C39 56 44 60 47 65 C49 68 51 68 53 65 C56 60 61 56 67 59 C76 64 79 76 76 86 Z"
            fill={`url(#${gid})`}
            stroke={GOLD_DARK}
            strokeWidth={1.2}
            strokeLinejoin="round"
          />
          <Polygon points="44,73 52,71 56,77 51,83 44,81" fill={colors.deepBlue} opacity={0.85} />
          <Path d="M44 73 L33 66 M52 71 L60 62 M56 77 L71 76 M44 81 L29 80" stroke={GOLD_DARK} strokeWidth={1.3} fill="none" />
          <Path d="M47 65 C46 68 45 70 44 73 M38 61 C37 64 36 66 35 68 M65 61 C66 64 67 66 68 69" stroke={GOLD_DARK} strokeWidth={1} fill="none" opacity={0.8} />
          <Path d="M28 70 C29 65 31 62 34 60" stroke="#FFFFFF" strokeWidth={2} strokeLinecap="round" opacity={0.55} fill="none" />
          <Ellipse cx={50} cy={86} rx={27} ry={1.6} fill={GOLD_DARK} opacity={0.5} />
        </G>
      )}
      <Pedestal />
    </Svg>
  );
}

type Item = {
  id: string;
  match_id: string | null;
  period_month: string | null;
  is_shared: boolean;
  pelada_name: string;
  season_name: string;
  played_at: string | null;
  team_a_name: string | null;
  team_b_name: string | null;
  team_a_score: number | null;
  team_b_score: number | null;
};
type Cursor = { at: string; id: string };

const monthName = (iso: string) => new Date(`${iso}T12:00:00`).toLocaleDateString('pt-BR', { month: 'long', year: 'numeric' });

/** Sala de Troféus: os três troféus com a quantidade; tocar abre o histórico daquele troféu (sob demanda). */
export function TrophyRoom({ userId, counts, partial }: { userId: string; counts: TrophyCounts; partial?: boolean }) {
  const [open, setOpen] = useState<TrophyType | null>(null);
  const [items, setItems] = useState<Item[]>([]);
  const [next, setNext] = useState<Cursor | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  async function load(type: TrophyType, after: Cursor | null) {
    setBusy(true);
    setMsg(null);
    const { data, error } = await supabase.rpc('get_trophy_history', { p_user: userId, p_type: type, p_after: after, p_limit: 20 });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    const page = data as { visible: boolean; items: Item[]; next: Cursor | null };
    setItems((xs) => (after ? [...xs, ...(page.items ?? [])] : (page.items ?? [])));
    setNext(page.next ?? null);
  }

  function toggle(type: TrophyType) {
    if (open === type) return setOpen(null);
    setOpen(type);
    setItems([]);
    setNext(null);
    if (counts[type] > 0) load(type, null);
  }

  return (
    <View style={{ gap: 12 }}>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', gap: 8 }}>
        {TROPHIES.map((t) => {
          const n = counts[t.type] ?? 0;
          const on = open === t.type;
          return (
            <Pressable
              key={t.type}
              accessibilityRole="button"
              accessibilityLabel={`${t.label}: ${n} ${n === 1 ? 'vez' : 'vezes'}. Toque para ver o histórico.`}
              accessibilityState={{ expanded: on }}
              onPress={() => toggle(t.type)}
              style={{
                flex: 1,
                alignItems: 'center',
                paddingVertical: 10,
                borderRadius: 14,
                borderWidth: on ? 2 : 1,
                borderColor: on ? colors.gold : colors.line,
                backgroundColor: colors.white,
                gap: 4,
              }}>
              <TrophyArt type={t.type} size={72} dim={n === 0} />
              <Text style={{ fontSize: 12, fontWeight: '700', color: colors.deepBlue, textAlign: 'center' }} numberOfLines={2}>
                {t.label}
              </Text>
              <Text style={{ fontSize: 18, fontWeight: '900', color: n ? colors.darkGold : colors.muted, fontVariant: ['tabular-nums'] }}>× {n}</Text>
            </Pressable>
          );
        })}
      </View>
      {partial && <Sub>Contagem das temporadas disponíveis. O histórico completo de cada pelada é da Pelada Premium.</Sub>}
      {open && (
        <View style={{ borderWidth: 1, borderColor: colors.line, borderRadius: 12, padding: 12, gap: 6 }}>
          <Text style={{ fontWeight: '800', color: colors.deepBlue }}>{TROPHIES.find((t) => t.type === open)!.label}</Text>
          <Sub>{TROPHIES.find((t) => t.type === open)!.hint}</Sub>
          {counts[open] === 0 && <Sub>Ainda não conquistado.</Sub>}
          {msg && <Text style={{ color: colors.danger }}>{msg}</Text>}
          {items.map((it) => (
            <View key={it.id} style={{ paddingVertical: 6, borderTopWidth: 1, borderTopColor: colors.line }}>
              <Text style={{ color: colors.ink, fontWeight: '600' }}>
                {it.played_at ? fmtDate(it.played_at) : it.period_month ? monthName(it.period_month) : ''}
                {it.is_shared ? ' · dividido' : ''}
              </Text>
              <Sub>
                {it.pelada_name} · {it.season_name}
                {it.team_a_name ? ` · ${it.team_a_name} ${it.team_a_score} x ${it.team_b_score} ${it.team_b_name}` : ''}
              </Sub>
            </View>
          ))}
          {busy && <Sub>Carregando...</Sub>}
          {next && !busy && <Button title="Ver mais" kind="secondary" onPress={() => load(open, next)} />}
        </View>
      )}
    </View>
  );
}
