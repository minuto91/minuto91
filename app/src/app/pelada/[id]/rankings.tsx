import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { AWARD_LABEL, currentSeason, fmtMonth, loadSeasons, Season } from '../../../lib/career';
import { friendly } from '../../../lib/errors';
import { fmtRating, loadMembers, Member } from '../../../lib/match';
import { supabase } from '../../../lib/supabase';
import { colors } from '../../../lib/theme';
import { Body, Card, Chips, ErrorText, Screen, Sub, Title } from '../../../lib/ui';

const METRICS = [
  { value: 'overall', label: 'Overall' },
  { value: 'goals', label: 'Gols' },
  { value: 'assists', label: 'Assistências' },
  { value: 'avg_rating', label: 'Média de nota' },
  { value: 'matches', label: 'Jogos' },
  { value: 'wins', label: 'Vitórias' },
] as const;
type Metric = (typeof METRICS)[number]['value'];

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
  const [seasons, setSeasons] = useState<Season[]>([]);
  const [seasonId, setSeasonId] = useState<string | null>(null);
  const [metric, setMetric] = useState<Metric>('overall');
  const [rows, setRows] = useState<Row[] | null>(null);
  const [records, setRecords] = useState<Records | null>(null);
  const [month, setMonth] = useState<MonthAward[]>([]);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
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
      setMembers(ms);
      setSeasons(ss);
      setSeasonId(currentSeason(ss)?.id ?? null);
      const latest = (aw ?? [])[0]?.period_month;
      setMonth(((aw ?? []) as MonthAward[]).filter((a) => a.period_month === latest));
    })().catch((e) => setMsg(friendly((e as Error).message)));
  }, [id]);

  useEffect(() => {
    if (!seasonId) return;
    let alive = true; // ignora respostas que chegarem depois de trocar o filtro
    (async () => {
      const [{ data: r, error: e1 }, { data: rec, error: e2 }] = await Promise.all([
        supabase.rpc('get_season_ranking', { p_season: seasonId, p_metric: metric }),
        supabase.rpc('get_season_records', { p_season: seasonId }),
      ]);
      if (!alive) return;
      const e = e1 ?? e2;
      if (e) {
        setRows([]);
        setRecords(null);
        // Grátis: temporada atual e a anterior (RN-083).
        return setMsg(e.message.includes('PREMIUM_REQUIRED') ? 'Temporadas mais antigas ficam no Premium.' : friendly(e.message));
      }
      setMsg(null);
      setRows((r ?? []) as Row[]);
      setRecords(rec as Records);
    })();
    return () => {
      alive = false;
    };
  }, [seasonId, metric]);

  const nameOf = (m: string) => members.find((x) => x.id === m)?.player_name ?? 'Jogador';
  const fmt = (v: number) =>
    metric === 'avg_rating' ? fmtRating(Number(v)) : metric === 'overall' ? String(Math.round(Number(v))) : String(v);
  const holders = (h: Holders, f: (v: number) => string = String) =>
    h?.value && h.membership_ids?.length ? `${f(Number(h.value))} — ${h.membership_ids.map(nameOf).join(', ')}` : '–';
  const openCard = (m: string) => router.push({ pathname: '/jogador/[id]', params: { id: m } });

  return (
    <Screen>
      <Title>Rankings</Title>
      {seasons.length > 1 && (
        <Chips options={seasons.map((s) => ({ value: s.id, label: s.name }))} value={seasonId} onChange={(v) => { setRows(null); setSeasonId(v); }} />
      )}
      <Chips options={METRICS} value={metric} onChange={(v) => { setRows(null); setMetric(v); }} />
      <ErrorText>{msg}</ErrorText>

      {rows === null ? (
        <Sub>Carregando...</Sub>
      ) : rows.length === 0 ? (
        !msg && <Sub>Ainda sem dados nesta temporada.</Sub>
      ) : (
        <Card>
          {rows.map((r) => (
            <Pressable key={r.membership_id} onPress={() => openCard(r.membership_id)}>
              <View style={{ flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 6 }}>
                <Text style={{ color: colors.ink }}>
                  {r.rank_position}º {nameOf(r.membership_id)}
                </Text>
                <Text style={{ color: colors.deepBlue, fontWeight: '800' }}>{fmt(r.metric_value)}</Text>
              </View>
            </Pressable>
          ))}
        </Card>
      )}

      {month.length > 0 && (
        <Card>
          <Body>Prêmios de {fmtMonth(month[0].period_month)}</Body>
          {['monthly_king', 'top_scorer', 'top_assist', 'most_improved'].map((t) => {
            const who = month.filter((a) => a.award_type === t).map((a) => nameOf(a.membership_id));
            return who.length ? (
              <Sub key={t}>
                {AWARD_LABEL[t]}: {who.join(', ')}
              </Sub>
            ) : null;
          })}
        </Card>
      )}

      {records && (
        <Card>
          <Body>Recordes da temporada</Body>
          <Sub>
            Maior goleada:{' '}
            {records.biggest_win?.length
              ? records.biggest_win.map((b) => `${b.team_a_score} x ${b.team_b_score}`).join(', ')
              : '–'}
          </Sub>
          <Sub>Mais gols numa partida: {holders(records.most_goals_in_match)}</Sub>
          <Sub>Maior nota: {holders(records.best_final_rating, fmtRating)}</Sub>
          <Sub>Mais vitórias seguidas: {holders(records.best_win_streak)}</Sub>
          <Sub>Mais jogos sem perder: {holders(records.best_unbeaten_streak)}</Sub>
          <Sub>Mais notas 8+ seguidas: {holders(records.best_high_rating_streak)}</Sub>
        </Card>
      )}
    </Screen>
  );
}
