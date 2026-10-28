// Sala de Troféus (V4.4; V7.7 sem o Garçom da Partida, excluído): as quatro premiações oficiais — Craque da Partida,
// Rei do Mês, Bola Murcha e Garçom do Mês. As contagens
// vêm da tabela oficial de prêmios (a mesma das estatísticas, do álbum e dos avisos); o histórico de cada troféu é
// carregado só quando a pessoa abre (get_trophy_history, paginado). Nada é contado de novo no app.
// Desenho: todos dividem o mesmo pedestal azul com friso dourado, o mesmo tamanho e o mesmo acabamento dourado; cada
// troféu tem escultura própria (o Garçom do Mês: mão dourada, bandeja e bola).
import { useState } from 'react';
import { View } from 'react-native';
import { Text } from './text';
import Svg, { Circle, Defs, Ellipse, G, LinearGradient, Path, Polygon, Rect, Stop, Text as SvgText } from 'react-native-svg';

import { Header, SharePanel } from './arts';
import { friendly } from './errors';
import { fmtDate } from './match';
import { TrophyTile } from './domain';
import { supabase } from './supabase';
import { colors } from './theme';
import { Button, LoadingBlock, Sub } from './ui';

export type TrophyType = 'match_craque' | 'monthly_king' | 'bola_murcha' | 'monthly_garcom' | 'top_scorer';
// Servidor antigo (antes da 049) não manda o Garçom do Mês: conta como zero. O Garçom da Partida não existe mais (V7.7).
export type TrophyCounts = Record<'match_craque' | 'monthly_king' | 'bola_murcha', number> & Partial<Record<'monthly_garcom' | 'top_scorer', number>>;

export const TROPHIES: { type: TrophyType; label: string; hint: string }[] = [
  { type: 'match_craque', label: 'Craque da Partida', hint: 'Mais votado como Craque numa partida.' },
  { type: 'monthly_king', label: 'Rei do Mês', hint: 'Melhor do mês na pelada.' },
  { type: 'top_scorer', label: 'Artilheiro do Mês', hint: 'Mais gols oficiais no mês (empate divide o troféu).' },
  { type: 'bola_murcha', label: 'Bola Murcha', hint: 'Escolhido como Bola Murcha numa partida.' },
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
      {type === 'monthly_garcom' && <Garcom gid={gid} />}
      {type === 'top_scorer' && <GoldenBoot gid={gid} />}
      {type !== 'top_scorer' && <Pedestal />}
      {type === 'monthly_garcom' && (
        <SvgText x={50} y={106.6} textAnchor="middle" fontSize={4.2} fontWeight="700" fill={colors.gold} letterSpacing={0.4}>
          MÊS
        </SvgText>
      )}
    </Svg>
  );
}

// REV-001: chuteira dourada, travas e cadarço azuis, sem pedestal; mesma luz e escala dos outros troféus.
function GoldenBoot({ gid }: { gid: string }) {
  return (
    <G>
      <Path
        d="M30 40 C30 36 33 34 37 34 H52 C55 34 57 36 57 39 V58 C57 61 59 63 62 64 L78 69 C84 71 87 75 87 80 V84 C87 87 85 89 82 89 H26 C22 89 20 86 20 83 V74 C20 70 22 67 25 65 C28 63 30 60 30 56 Z"
        fill={`url(#${gid})`}
        stroke={GOLD_DARK}
        strokeWidth={1.3}
        strokeLinejoin="round"
      />
      <Rect x={20} y={86} width={67} height={4} rx={2} fill={colors.deepBlue} />
      {[28, 42, 56, 70, 81].map((x) => (
        <Rect key={x} x={x - 2.5} y={90} width={5} height={6} rx={1.5} fill={colors.blue} />
      ))}
      <Path d="M38 44 L50 41 M38 50 L51 47 M38 56 L52 53" stroke={colors.blue} strokeWidth={2.2} strokeLinecap="round" />
      <Path d="M58 66 C63 70 70 72 78 74" stroke={GOLD_DARK} strokeWidth={1} fill="none" opacity={0.8} />
      <Path d="M33 40 C33 38 35 37 37 37" stroke="#FFFFFF" strokeWidth={2} strokeLinecap="round" opacity={0.6} fill="none" />
    </G>
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
export function TrophyRoom({ userId, counts, partial, shareName }: { userId: string; counts: TrophyCounts; partial?: boolean; shareName?: string }) {
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
      {partial && <Sub>Temporadas disponíveis no seu plano.</Sub>}
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
          {/* REV-033: compartilhar só troféus oficiais da própria pessoa. */}
          {shareName && (counts[open] ?? 0) > 0 && (
            <SharePanel label="Compartilhar" fileName={`minuto91-${open}`} title={TROPHIES.find((t) => t.type === open)!.label}>
              <Header title={shareName} subtitle={TROPHIES.find((t) => t.type === open)!.label} />
              <View style={{ alignItems: 'center' }}>
                <TrophyArt type={open} size={150} />
                <Text style={{ fontSize: 34, fontWeight: '900', color: colors.darkGold }}>{`${counts[open]}×`}</Text>
              </View>
            </SharePanel>
          )}
          {busy && <LoadingBlock />}
          {next && !busy && <Button title="Ver mais" kind="secondary" onPress={() => load(open, next)} />}
        </View>
      )}
    </View>
  );
}
