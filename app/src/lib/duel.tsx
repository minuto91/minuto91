// Duelo de Jogadores (V4.2, Pelada Premium): dois jogadores da mesma pelada lado a lado, só com dados
// oficiais da temporada (get_player_duel, migração 039). Valor ausente aparece como "–" (nunca estimado).
// O Card oficial não é redesenhado: aqui só os números dele, com a categoria.
import { View } from 'react-native';
import { Text } from './text';

import { Header, useArtFormat } from './arts';
import { Avatar } from './avatar';
import { TIER } from './career';
import { fmtRating } from './match';
import { colors, positionLabel } from './theme';

type Side = {
  membership_id: string;
  name: string;
  position: string;
  avatar_path: string | null;
  card: {
    tier: 'bronze' | 'prata' | 'ouro';
    overall: number;
    finishing: number;
    assisting: number;
    attendance: number;
    winning: number;
    peer_rating: number;
    is_provisional: boolean;
  } | null;
  stats: { matches: number; goals: number; assists: number; wins: number; avg_rating: number | null; valid_ratings: number; craque: number };
};
export type Duel = { season_id: string; season_name: string; a: Side; b: Side };

type Row = { label: string; a: number | null; b: number | null; fmt?: (v: number) => string };

export function duelRows(d: Duel): Row[] {
  const r = (v: number | null | undefined) => (v === null || v === undefined ? null : Math.round(Number(v)));
  return [
    { label: 'Overall', a: r(d.a.card?.overall), b: r(d.b.card?.overall) },
    { label: 'FIN', a: r(d.a.card?.finishing), b: r(d.b.card?.finishing) },
    { label: 'GAR', a: r(d.a.card?.assisting), b: r(d.b.card?.assisting) },
    { label: 'PRE', a: r(d.a.card?.attendance), b: r(d.b.card?.attendance) },
    { label: 'PEQ', a: r(d.a.card?.winning), b: r(d.b.card?.winning) },
    { label: 'RES', a: r(d.a.card?.peer_rating), b: r(d.b.card?.peer_rating) },
    { label: 'Partidas', a: d.a.stats.matches, b: d.b.stats.matches },
    { label: 'Gols', a: d.a.stats.goals, b: d.b.stats.goals },
    { label: 'Assistências', a: d.a.stats.assists, b: d.b.stats.assists },
    {
      label: 'Média de nota',
      a: d.a.stats.avg_rating === null ? null : Number(d.a.stats.avg_rating),
      b: d.b.stats.avg_rating === null ? null : Number(d.b.stats.avg_rating),
      fmt: fmtRating,
    },
    { label: 'Craque da Partida', a: d.a.stats.craque, b: d.b.stats.craque },
  ];
}

function Head({ s, align, dense }: { s: Side; align: 'flex-start' | 'flex-end'; dense?: boolean }) {
  const tier = s.card ? TIER[s.card.tier] : null;
  return (
    <View style={{ flex: 1, alignItems: align, gap: dense ? 1 : 4 }}>
      <View style={{ borderRadius: 999, borderWidth: 3, borderColor: tier?.frame ?? colors.line, padding: 2 }}>
        <Avatar path={s.avatar_path} name={s.name} size={dense ? 38 : 56} />
      </View>
      <Text style={{ fontSize: dense ? 13 : 15, fontWeight: '800', color: colors.deepBlue, textAlign: align === 'flex-end' ? 'right' : 'left' }} numberOfLines={dense ? 1 : 2}>
        {s.name}
      </Text>
      {/* Na arte, posição e categoria dividem a linha (cabe na moldura). */}
      <Text style={{ fontSize: dense ? 11 : 12, color: colors.muted }} numberOfLines={1}>
        {positionLabel(s.position)}
        {dense && ' · '}
        {dense && (
          <Text style={{ fontWeight: '800', color: tier?.color ?? colors.muted }}>
            {tier ? `${tier.label}${s.card?.is_provisional ? ' (prov.)' : ''}` : 'sem Card'}
          </Text>
        )}
      </Text>
      {!dense && (
        <Text style={{ fontSize: 12, fontWeight: '800', color: tier?.color ?? colors.muted }}>
          {tier ? `${tier.label}${s.card?.is_provisional ? ' · provisório' : ''}` : 'Sem Card na temporada'}
        </Text>
      )}
    </View>
  );
}

/**
 * Comparação lado a lado: o maior valor de cada linha fica em destaque (azul forte e barra dourada).
 * dense = artes (cabem na moldura); only = linhas a mostrar (o 4:5 leva overall, FIN, GAR, RES, gols, assistências e Craque).
 */
export function DuelView({ duel, dense, only }: { duel: Duel; dense?: boolean; only?: string[] }) {
  const rows = duelRows(duel).filter((r) => !only || only.includes(r.label));
  return (
    <View style={{ gap: dense ? 3 : 10 }}>
      <View style={{ flexDirection: 'row', alignItems: 'flex-start', gap: 8, marginBottom: dense ? 4 : 0 }}>
        <Head s={duel.a} align="flex-start" dense={dense} />
        <Text style={{ alignSelf: 'center', fontSize: 16, fontWeight: '900', color: colors.darkGold }}>VS</Text>
        <Head s={duel.b} align="flex-end" dense={dense} />
      </View>
      {rows.map((r) => {
        const max = Math.max(r.a ?? 0, r.b ?? 0, 1);
        const lead = r.a !== null && r.b !== null && r.a !== r.b ? (r.a > r.b ? 'a' : 'b') : null;
        const val = (v: number | null) => (v === null ? '–' : r.fmt ? r.fmt(v) : String(v));
        const bar = (v: number | null, win: boolean, dir: 'row' | 'row-reverse') => (
          <View style={{ flex: 1, height: dense ? 4 : 6, borderRadius: 3, backgroundColor: colors.bg, flexDirection: dir }}>
            <View style={{ width: `${((v ?? 0) / max) * 100}%`, borderRadius: 3, backgroundColor: win ? colors.gold : '#C9D6EE' }} />
          </View>
        );
        const a11y = `${r.label}: ${duel.a.name} ${val(r.a)}, ${duel.b.name} ${val(r.b)}`;
        if (dense) {
          // Arte: tudo numa linha (valor, barra, rótulo, barra, valor) para caber na moldura.
          return (
            <View key={r.label} accessible accessibilityLabel={a11y} style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
              <Text style={[num, { width: 30, fontSize: 13 }, lead === 'a' && lead_]}>{val(r.a)}</Text>
              {bar(r.a, lead === 'a', 'row-reverse')}
              <Text style={{ width: 72, textAlign: 'center', fontSize: 10, fontWeight: '700', color: colors.muted }} numberOfLines={1}>
                {r.label === 'Craque da Partida' ? 'Craques' : r.label}
              </Text>
              {bar(r.b, lead === 'b', 'row')}
              <Text style={[num, { width: 30, fontSize: 13, textAlign: 'right' }, lead === 'b' && lead_]}>{val(r.b)}</Text>
            </View>
          );
        }
        return (
          <View key={r.label} accessible accessibilityLabel={a11y} style={{ gap: 3 }}>
            <View style={{ flexDirection: 'row', alignItems: 'center' }}>
              <Text style={[num, dense && { fontSize: 13 }, lead === 'a' && lead_]}>{val(r.a)}</Text>
              <Text style={{ flex: 1, textAlign: 'center', fontSize: dense ? 10 : 12, fontWeight: '700', color: colors.muted }}>{r.label}</Text>
              <Text style={[num, dense && { fontSize: 13 }, { textAlign: 'right' }, lead === 'b' && lead_]}>{val(r.b)}</Text>
            </View>
            <View style={{ flexDirection: 'row', gap: 6 }}>
              {bar(r.a, lead === 'a', 'row-reverse')}
              {bar(r.b, lead === 'b', 'row')}
            </View>
          </View>
        );
      })}
    </View>
  );
}

const num = { width: 52, fontSize: 16, fontWeight: '700' as const, color: colors.ink };
const lead_ = { color: colors.deepBlue, fontWeight: '900' as const };

/** Arte vertical do Duelo (só compartilha quando a pessoa toca). */
export function DuelArt({ duel, peladaName, crestPath }: { duel: Duel; peladaName: string; crestPath?: string | null }) {
  const post = useArtFormat() === 'post';
  return (
    <>
      <Header title={peladaName} subtitle={duel.season_name} crestPath={crestPath} />
      <Text style={{ textAlign: 'center', fontSize: 14, fontWeight: '700', color: colors.darkGold }}>Duelo</Text>
      <DuelView duel={duel} dense only={post ? ['Overall', 'FIN', 'GAR', 'RES', 'Gols', 'Assistências', 'Craque da Partida'] : undefined} />
    </>
  );
}
