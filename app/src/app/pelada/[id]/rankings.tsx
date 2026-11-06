import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, View } from 'react-native';
import { Text } from '../../../lib/text';

import { Avatar, prefetchAvatars } from '../../../lib/avatar';
import { AWARD_LABEL, currentSeason, fmtMonth, loadSeasons, Season, TIER } from '../../../lib/career';
import { friendly } from '../../../lib/errors';
import { fmtRating, loadMembers, Member } from '../../../lib/match';
import { supabase } from '../../../lib/supabase';
import { useSticky } from '../../../lib/sticky';
import { colors } from '../../../lib/theme';
import { Block, Body, Button, Chips, EmptyState, ErrorText, LoadingBlock, Screen, Sub } from '../../../lib/ui';
import { RankingRow } from '../../../lib/domain';

// Em destaque: Artilharia, Assistências e Overall. As demais classificações oficiais continuam em "Mais".
const MAIN = [
  { value: 'goals', label: 'Artilharia' },
  { value: 'assists', label: 'Assistências' },
  { value: 'overall', label: 'Overall' },
] as const;
const MORE = [
  { value: 'avg_rating', label: 'Média de nota' },
  { value: 'matches', label: 'Jogos' },
  { value: 'wins', label: 'Vitórias' },
] as const;
type Metric = (typeof MAIN)[number]['value'] | (typeof MORE)[number]['value'];

const UNIT: Record<Metric, [string, string]> = {
  goals: ['gol', 'gols'],
  assists: ['assist.', 'assist.'],
  overall: ['', ''],
  avg_rating: ['', ''],
  matches: ['jogo', 'jogos'],
  wins: ['vitória', 'vitórias'],
};
const PAGE = 30;

type Row = { rank_position: number; membership_id: string; metric_value: number };
type Holders = { value: number | null; membership_ids: string[] | null } | null;
type Records = {
  biggest_win: { match_id: string; team_a_score: number; team_b_score: number }[] | null;
  most_goals_in_match: Holders;
  best_final_rating: Holders;
  best_win_streak: Holders;
  best_unbeaten_streak: Holders;
  best_high_rating_streak: Holders;
};
type MonthAward = { membership_id: string; award_type: string; period_month: string };

export default function Rankings() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [members, setMembers] = useState<Member[]>([]);
  const [photos, setPhotos] = useState<Record<string, string | null>>({});
  const [seasons, setSeasons] = useState<Season[]>([]);
  const [seasonId, setSeasonId] = useState<string | null>(null);
  const [metric, setMetric] = useSticky<Metric>(`rankings:${id}:metric`, 'goals');
  const [rows, setRows] = useState<Row[] | null>(null);
  const [tiers, setTiers] = useState<Record<string, keyof typeof TIER>>({});
  const [records, setRecords] = useState<Records | null>(null);
  const [month, setMonth] = useState<MonthAward[]>([]);
  const [limit, setLimit] = useState(PAGE);
  const [msg, setMsg] = useState<string | null>(null);
  const [locked, setLocked] = useState(false);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [ms, ss, { data: aw }] = await Promise.all([
        loadMembers(id),
        loadSeasons(id),
        supabase
          .from('awards')
          .select('membership_id, award_type, period_month')
          .eq('pelada_id', id)
          .eq('status', 'active')
          .not('period_month', 'is', null)
          .order('period_month', { ascending: false })
          .limit(20),
      ]);
      // Fotos só de quem o RLS deixa ver (pelada em comum, sem bloqueio nos dois sentidos); senão, iniciais.
      const uids = ms.map((m) => m.user_id).filter((u): u is string => !!u);
      const { data: pr } = uids.length ? await supabase.from('profiles').select('id, avatar_path').in('id', uids) : { data: [] };
      await prefetchAvatars((pr ?? []).map((p) => p.avatar_path as string | null)); // V4.4: fotos assinadas em lote
      if (!alive) return;
      setMembers(ms);
      setPhotos(Object.fromEntries((pr ?? []).map((p) => [p.id as string, p.avatar_path as string | null])));
      setSeasons(ss);
      setSeasonId(currentSeason(ss)?.id ?? null);
      if (!ss.length) setRows([]);
      const latest = (aw ?? [])[0]?.period_month;
      setMonth(((aw ?? []) as MonthAward[]).filter((a) => a.period_month === latest));
    })().catch((e) => alive && setMsg(friendly((e as Error).message)));
    return () => {
      alive = false;
    };
  }, [id]);

  // Recordes e categorias dependem só da temporada.
  useEffect(() => {
    if (!seasonId) return;
    let alive = true;
    (async () => {
      const [{ data: rec }, { data: cs }] = await Promise.all([
        supabase.rpc('get_season_records', { p_season: seasonId }),
        supabase.from('player_cards').select('membership_id, tier').eq('season_id', seasonId),
      ]);
      if (!alive) return;
      setRecords((rec as Records | null) ?? null);
      setTiers(Object.fromEntries((cs ?? []).map((c) => [c.membership_id as string, c.tier as keyof typeof TIER])));
    })();
    return () => {
      alive = false;
    };
  }, [seasonId]);

  useEffect(() => {
    if (!seasonId) return;
    let alive = true; // ignora respostas que chegarem depois de trocar o filtro
    (async () => {
      const { data: r, error } = await supabase.rpc('get_season_ranking', { p_season: seasonId, p_metric: metric });
      if (!alive) return;
      if (error) {
        setRows([]);
        // Grátis: temporada atual e a anterior (RN-083).
        // REV-018: Média, Jogos e Vitórias são Premium (verificado no servidor); no Basic, temporadas antigas também.
        if (error.message.includes('PREMIUM_REQUIRED')) return setLocked(true);
        return setMsg(friendly(error.message));
      }
      setMsg(null);
      setLocked(false);
      setRows((r ?? []) as Row[]);
      setLimit(PAGE);
    })();
    return () => {
      alive = false;
    };
  }, [seasonId, metric]);

  const member = (m: string) => members.find((x) => x.id === m);
  const nameOf = (m: string) => member(m)?.player_name ?? 'Jogador';

  // Posição oficial do servidor (empatados dividem: 1, 1, 3). Entre empatados, ordem alfabética estável.
  const sorted = [...(rows ?? [])].sort(
    (a, b) => Number(a.rank_position) - Number(b.rank_position) || nameOf(a.membership_id).localeCompare(nameOf(b.membership_id), 'pt-BR'),
  );
  const tied = (r: Row) => sorted.filter((x) => Number(x.rank_position) === Number(r.rank_position)).length > 1;

  const fmt = (v: number) =>
    metric === 'avg_rating' ? fmtRating(Number(v)) : metric === 'overall' ? String(Math.round(Number(v))) : String(v);
  const unit = (v: number) => UNIT[metric][Number(v) === 1 ? 0 : 1];
  const holders = (h: Holders, f: (v: number) => string = String) =>
    h?.value && h.membership_ids?.length ? `${f(Number(h.value))} — ${h.membership_ids.map(nameOf).join(', ')}` : '–';
  const openCard = (m: string) => router.push({ pathname: '/jogador/[id]', params: { id: m } });
  const pick = (v: Metric) => {
    if (v === metric) return;
    setRows(null);
    setMetric(v);
  };
  const isMore = MORE.some((m) => m.value === metric);

  return (
    <Screen>
      {seasons.length > 1 && (
        <Chips
          options={seasons.map((s) => ({ value: s.id, label: s.name }))}
          value={seasonId}
          onChange={(v) => {
            setRows(null);
            setSeasonId(v);
          }}
        />
      )}

      {/* Classificações principais: abas largas. */}
      <View style={{ flexDirection: 'row', backgroundColor: colors.bg, borderRadius: 12, padding: 4, gap: 4 }}>
        {MAIN.map((m) => {
          const on = metric === m.value;
          return (
            <Pressable
              key={m.value}
              accessibilityRole="tab"
              accessibilityState={{ selected: on }}
              onPress={() => pick(m.value)}
              style={{ flex: 1, paddingVertical: 10, borderRadius: 9, alignItems: 'center', backgroundColor: on ? colors.blue : 'transparent' }}>
              <Text style={{ fontWeight: '700', fontSize: 14, color: on ? colors.white : colors.deepBlue }} numberOfLines={1}>
                {m.label}
              </Text>
            </Pressable>
          );
        })}
      </View>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <Text style={{ color: colors.darkGold, fontSize: 13, fontWeight: '700' }}>Premium</Text>
        <Chips options={MORE} value={isMore ? metric : null} onChange={pick} />
      </View>
      <ErrorText>{msg}</ErrorText>
      {locked && (
        <EmptyState title={isMore ? 'Ranking da Pelada Premium' : 'Temporada da Pelada Premium'} hint="R$ 29,90/mês por pelada.">
          <Button title="Conhecer o Premium" kind="secondary" onPress={() => router.push({ pathname: '/pelada/[id]/premium', params: { id } })} />
        </EmptyState>
      )}

      {rows === null ? (
        <LoadingBlock />
      ) : sorted.length === 0 ? (
        !msg && <Sub>Ainda sem dados nesta temporada.</Sub>
      ) : (
        <View>
          {sorted.slice(0, limit).map((r) => {
            const m = member(r.membership_id);
            const tier = tiers[r.membership_id] ? TIER[tiers[r.membership_id]] : null;
            return (
              <RankingRow
                key={r.membership_id}
                position={Number(r.rank_position)}
                name={nameOf(r.membership_id)}
                avatar={<Avatar path={m?.user_id && m.status !== 'retired' ? photos[m.user_id] : null} name={nameOf(r.membership_id)} size={36} />}
                badge={
                  tier ? (
                    <View style={{ paddingHorizontal: 6, paddingVertical: 1, borderRadius: 6, backgroundColor: tier.bg, borderWidth: 1, borderColor: tier.frame }}>
                      <Text style={{ fontSize: 12, fontWeight: '800', color: tier.deep }}>{tier.label.toUpperCase()}</Text>
                    </View>
                  ) : undefined
                }
                tied={tied(r)}
                value={fmt(r.metric_value)}
                unit={unit(r.metric_value) || undefined}
                onPress={() => openCard(r.membership_id)}
              />
            );
          })}
          {sorted.length > limit && (
            <View style={{ marginTop: 10 }}>
              <Button title={`Ver mais (${sorted.length - limit})`} kind="secondary" onPress={() => setLimit(limit + PAGE)} />
            </View>
          )}
        </View>
      )}

      {month.length > 0 && (
        <Block>
          <Body>Prêmios de {fmtMonth(month[0].period_month)}</Body>
          {['monthly_king', 'top_scorer', 'monthly_garcom', 'most_improved'].map((t) => {
            const who = month.filter((a) => a.award_type === t).map((a) => nameOf(a.membership_id));
            return who.length ? (
              <Sub key={t}>
                {AWARD_LABEL[t]}: {who.join(', ')}
              </Sub>
            ) : null;
          })}
        </Block>
      )}

      {records && (
        <Block>
          <Body>Recordes da temporada</Body>
          <Sub>
            Maior goleada:{' '}
            {records.biggest_win?.length ? records.biggest_win.map((b) => `${b.team_a_score} x ${b.team_b_score}`).join(', ') : '–'}
          </Sub>
          <Sub>Mais gols numa partida: {holders(records.most_goals_in_match)}</Sub>
          <Sub>Maior nota: {holders(records.best_final_rating, fmtRating)}</Sub>
          <Sub>Mais vitórias seguidas: {holders(records.best_win_streak)}</Sub>
          <Sub>Mais jogos sem perder: {holders(records.best_unbeaten_streak)}</Sub>
          <Sub>Mais notas 8+ seguidas: {holders(records.best_high_rating_streak)}</Sub>
        </Block>
      )}
    </Screen>
  );
}
