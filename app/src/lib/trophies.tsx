// Sala de Troféus (V4.4; V4.6 com os dois Garçons): as cinco premiações oficiais — Craque da Partida, Rei do Mês,
// Bola Murcha, Garçom da Partida e Garçom do Mês. As contagens
// vêm da tabela oficial de prêmios (a mesma das estatísticas, do álbum e dos avisos); o histórico de cada troféu é
// carregado só quando a pessoa abre (get_trophy_history, paginado). Nada é contado de novo no app.
// Desenho: todos dividem o mesmo pedestal azul com friso dourado, o mesmo tamanho e o mesmo acabamento dourado. Os dois
// Garçons são a mesma escultura (mão dourada, bandeja e bola) com placas diferentes no pedestal.
import { useState } from 'react';
import { View } from 'react-native';
import { Text } from './text';
import Svg, { Circle, Defs, Ellipse, G, LinearGradient, Path, Polygon, Rect, Stop, Text as SvgText } from 'react-native-svg';

import { friendly } from './errors';
import { fmtDate } from './match';
import { TrophyTile } from './domain';
import { supabase } from './supabase';
import { colors } from './theme';
import { Button, Sub } from './ui';

export type TrophyType = 'match_craque' | 'monthly_king' | 'bola_murcha' | 'match_garcom' | 'monthly_garcom';
// Servidor antigo (antes da 049) não manda os Garçons: contam como zero.
export type TrophyCounts = Record<'match_craque' | 'monthly_king' | 'bola_murcha', number> & Partial<Record<'match_garcom' | 'monthly_garcom', number>>;

export const TROPHIES: { type: TrophyType; label: string; hint: string }[] = [
  { type: 'match_craque', label: 'Craque da Partida', hint: 'Mais votado como Craque numa partida.' },
  { type: 'monthly_king', label: 'Rei do Mês', hint: 'Melhor do mês na pelada.' },
  { type: 'bola_murcha', label: 'Bola Murcha', hint: 'Escolhido como Bola Murcha numa partida.' },
  { type: 'match_garcom', label: 'Garçom da Partida', hint: 'Mais assistências na partida (mínimo 1; empate premia todos).' },
  { type: 'monthly_garcom', label: 'Garçom do Mês', hint: 'Mais assistências no mês (mínimo 2; desempate pela média e pelas partidas com assistência).' },
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

// Escultura Garçom: braço e mão dourados, palma para cima, segurando a bandeja circular na horizontal; bola dourada com
// gomos azuis centralizada sobre a bandeja. Mesma luz (brilho no alto à esquerda) e escala dos outros troféus.
function Garcom({ gid }: { gid: string }) {
  const tray = `${gid}-tray`;
  return (
    <G>
      <Defs>
        <LinearGradient id={tray} x1="0" y1="0" x2="0" y2="1">
          <Stop offset="0" stopColor="#F7E3A6" />
          <Stop offset="1" stopColor={GOLD_DARK} />
        </LinearGradient>
      </Defs>
      <Path d="M45.5 86 L46.5 72 C46.6 70.5 47.4 69.6 48.6 69.6 H51.4 C52.6 69.6 53.4 70.5 53.5 72 L54.5 86 Z" fill={`url(#${gid})`} stroke={GOLD_DARK} strokeWidth={0.9} />
      <Rect x={45.4} y={76} width={9.2} height={3.2} rx={1} fill={GOLD_DARK} />
      <Path
        d="M47 70 C44.5 69.5 41 68.4 37.5 66.9 C36.2 66.3 36.4 64.9 37.7 64.9 L41.5 65.2 C40.4 64.2 39.6 63.1 40.2 62.4 C40.8 61.7 42.6 62.5 44.4 63.6 L45.2 62 C46.2 61.2 48.2 61.1 50 61.1 C52.6 61.1 55.4 61.3 58.6 61.8 C60.4 62.1 61.7 62.4 62.3 63 C62.9 63.7 62.2 64.6 60.8 65 C58.5 65.6 56.6 66.4 55 67.4 C54 68 53.5 69.1 53.2 70 Z"
        fill={`url(#${gid})`}
        stroke={GOLD_DARK}
        strokeWidth={0.9}
        strokeLinejoin="round"
      />
      <Path d="M44.6 63.6 C46 63 48 62.9 50 63" stroke={GOLD_DARK} strokeWidth={0.6} fill="none" opacity={0.8} />
      <Path d="M49 64.5 C51.5 64.4 54.2 64.4 57 64.7" stroke={GOLD_DARK} strokeWidth={0.5} fill="none" opacity={0.7} />
      <Ellipse cx={50} cy={59.6} rx={30} ry={5.2} fill={GOLD_DARK} />
      <Ellipse cx={50} cy={58.2} rx={30} ry={5.2} fill={`url(#${tray})`} stroke={GOLD_DARK} strokeWidth={0.9} />
      <Ellipse cx={50} cy={58} rx={26} ry={3.9} fill="none" stroke="#FFF3CC" strokeWidth={0.7} opacity={0.8} />
      <Ellipse cx={50} cy={57.6} rx={9} ry={1.6} fill="#7A5A12" opacity={0.35} />
      <Circle cx={50} cy={45} r={12.5} fill={`url(#${gid})`} stroke={GOLD_DARK} strokeWidth={1} />
      <Polygon points="50,39.8 54.4,43 52.7,48.1 47.3,48.1 45.6,43" fill={colors.blue} />
      <Path d="M50 39.8 V33 M54.4 43 L61.4 40.8 M52.7 48.1 L56.4 54.2 M47.3 48.1 L43.6 54.2 M45.6 43 L38.6 40.8" stroke={GOLD_DARK} strokeWidth={1} />
      <Polygon points="61.4,40.8 62.4,44.6 60.6,46.4" fill={colors.deepBlue} opacity={0.8} />
      <Polygon points="38.6,40.8 37.6,44.6 39.4,46.4" fill={colors.deepBlue} opacity={0.8} />
      <Path d="M41.5 37 C43.5 34.6 46.4 33.4 49 33.3" stroke="#FFFFFF" strokeWidth={1.6} strokeLinecap="round" opacity={0.6} fill="none" />
      <Path d="M24 57.2 C26 54.6 32 53.4 38 53.2" stroke="#FFFFFF" strokeWidth={1.1} strokeLinecap="round" opacity={0.55} fill="none" />
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
      {(type === 'match_garcom' || type === 'monthly_garcom') && <Garcom gid={gid} />}
      <Pedestal />
      {(type === 'match_garcom' || type === 'monthly_garcom') && (
        <SvgText x={50} y={106.6} textAnchor="middle" fontSize={4.2} fontWeight="700" fill={colors.gold} letterSpacing={0.4}>
          {type === 'match_garcom' ? 'PARTIDA' : 'MÊS'}
        </SvgText>
      )}
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

/** Sala de Troféus: os cinco troféus com a quantidade; tocar abre o histórico daquele troféu (sob demanda). */
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
    if ((counts[type] ?? 0) > 0) load(type, null);
  }

  return (
    <View style={{ gap: 12 }}>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'center', gap: 8 }}>
        {TROPHIES.map((t) => {
          const n = counts[t.type] ?? 0;
          const on = open === t.type;
          return (
            <TrophyTile
              key={t.type}
              art={<TrophyArt type={t.type} size={72} dim={n === 0} />}
              label={t.label}
              count={n}
              open={on}
              onPress={() => toggle(t.type)}
            />
          );
        })}
      </View>
      {partial && <Sub>Contagem das temporadas disponíveis. O histórico completo de cada pelada é da Pelada Premium.</Sub>}
      {open && (
        <View style={{ borderWidth: 1, borderColor: colors.line, borderRadius: 12, padding: 12, gap: 6 }}>
          <Text style={{ fontWeight: '800', color: colors.deepBlue }}>{TROPHIES.find((t) => t.type === open)!.label}</Text>
          <Sub>{TROPHIES.find((t) => t.type === open)!.hint}</Sub>
          {(counts[open] ?? 0) === 0 && <Sub>Ainda não conquistado.</Sub>}
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
