// Evolução do Card na temporada (V4.1). Dados de get_player_evolution (033): os snapshots oficiais que o
// servidor grava a cada partida finalizada (014), sem partidas anuladas, com o mesmo acesso dos rankings
// (temporadas antigas no Premium da pelada). Nada é estimado: com menos de 2 registros não há gráfico.
import { useEffect, useState } from 'react';
import { Text, useWindowDimensions, View } from 'react-native';
import Svg, { Circle, Line, Path, Text as SvgText } from 'react-native-svg';

import { ATTRIBUTES } from './career';
import { friendly } from './errors';
import { supabase } from './supabase';
import { colors } from './theme';
import { Chips, Sub } from './ui';

type Values = { overall: number; finishing: number; assisting: number; attendance: number; winning: number; peer_rating: number };
export type EvoPoint = Values & { match_id: string; played_at: string; played: boolean; tier: string; position: string; is_provisional: boolean };
export type Evolution = { points: EvoPoint[]; current: (Values & { is_provisional: boolean }) | null; monthly_king: string[]; craque: number };

export function useEvolution(membershipId: string, seasonId: string | null) {
  const [data, setData] = useState<Evolution | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!seasonId) return;
    let alive = true;
    (async () => {
      const { data: d, error: e } = await supabase.rpc('get_player_evolution', { p_membership: membershipId, p_season: seasonId });
      if (!alive) return;
      if (e) {
        setData(null);
        setError(
          e.message.includes('PREMIUM_REQUIRED')
            ? 'O histórico de temporadas mais antigas fica no Premium da pelada.'
            : e.code === 'PGRST202'
              ? 'Histórico ainda indisponível neste servidor (falta a migração 033).'
              : friendly(e.message),
        );
        return;
      }
      setError(null);
      setData(d as Evolution);
    })();
    return () => {
      alive = false;
    };
  }, [membershipId, seasonId]);
  return { data, error };
}

const SERIES = [{ value: 'overall', label: 'Overall' }, ...ATTRIBUTES.map((a) => ({ value: a.key, label: a.code }))] as const;
type Series = (typeof SERIES)[number]['value'];
const shortDate = (iso: string) => new Date(iso).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' });

export function EvolutionChart({ evolution }: { evolution: Evolution }) {
  const { width } = useWindowDimensions();
  const [series, setSeries] = useState<Series>('overall');
  const points = evolution.points;
  const label = series === 'overall' ? 'Overall' : ATTRIBUTES.find((a) => a.key === series)!.label;

  if (points.length < 2) {
    return (
      <Sub>
        {points.length === 0
          ? 'Ainda sem histórico nesta temporada.'
          : 'O gráfico aparece a partir da segunda partida finalizada da temporada.'}
      </Sub>
    );
  }

  const values = points.map((p) => Number(p[series]));
  const w = Math.min(width, 520) - 40 - 30; // tela - margens - padding do cartão
  const h = 150;
  const padL = 30;
  const padR = 12;
  const padT = 14;
  const padB = 22;
  // Escala com folga em volta dos valores reais (0 a 100), para a variação ficar visível.
  const lo = Math.max(0, Math.floor((Math.min(...values) - 5) / 5) * 5);
  const hi = Math.min(100, Math.ceil((Math.max(...values) + 5) / 5) * 5);
  const x = (i: number) => padL + (i * (w - padL - padR)) / (points.length - 1);
  const y = (v: number) => padT + ((hi - v) * (h - padT - padB)) / Math.max(1, hi - lo);
  const d = values.map((v, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(' ');
  const first = values[0];
  const last = values[values.length - 1];
  const diff = Math.round(last) - Math.round(first);

  return (
    <View style={{ gap: 8 }}>
      <Chips options={SERIES} value={series} onChange={setSeries} />
      <Text style={{ color: colors.ink, fontWeight: '700' }}>
        {label}: {Math.round(first)} → {Math.round(last)}{' '}
        <Text style={{ color: diff > 0 ? colors.blue : diff < 0 ? colors.danger : colors.muted, fontWeight: '700' }}>
          ({diff > 0 ? `+${diff}` : diff})
        </Text>
      </Text>
      <Svg width={w} height={h} accessibilityLabel={`Gráfico de ${label}: de ${Math.round(first)} para ${Math.round(last)} em ${points.length} partidas`}>
        {[lo, Math.round((lo + hi) / 2), hi].map((v) => (
          <Line key={v} x1={padL} x2={w - padR} y1={y(v)} y2={y(v)} stroke={colors.line} strokeWidth={1} />
        ))}
        {[lo, hi].map((v) => (
          <SvgText key={v} x={padL - 6} y={y(v) + 4} fontSize={10} fill={colors.muted} textAnchor="end">
            {v}
          </SvgText>
        ))}
        <Path d={d} stroke={colors.blue} strokeWidth={2.5} fill="none" strokeLinejoin="round" strokeLinecap="round" />
        {values.map((v, i) => (
          // Partida em que o jogador não entrou: ponto vazado (o Card muda pela Presença de todos).
          <Circle
            key={points[i].match_id}
            cx={x(i)}
            cy={y(v)}
            r={3.5}
            stroke={colors.blue}
            strokeWidth={1.5}
            fill={points[i].played ? colors.blue : colors.white}
          />
        ))}
        <SvgText x={padL} y={h - 6} fontSize={10} fill={colors.muted}>
          {shortDate(points[0].played_at)}
        </SvgText>
        <SvgText x={w - padR} y={h - 6} fontSize={10} fill={colors.muted} textAnchor="end">
          {shortDate(points[points.length - 1].played_at)}
        </SvgText>
      </Svg>
      <Sub>
        {points.length} registros, de {shortDate(points[0].played_at)} a {shortDate(points[points.length - 1].played_at)}: o Card
        depois de cada partida finalizada da temporada. Ponto vazado = partida sem este jogador.
        {points.some((p) => p.is_provisional) ? ' Valores com menos de 5 jogos são do Card provisório.' : ''}
      </Sub>
    </View>
  );
}
