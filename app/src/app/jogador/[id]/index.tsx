import { useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { Text, View } from 'react-native';

import {
  ATTRIBUTES,
  AWARD_LABEL,
  Card as CardData,
  currentSeason,
  loadCard,
  loadSeasons,
  plural,
  Season,
  SeasonStats,
  TIER,
} from '../../../lib/career';
import { friendly } from '../../../lib/errors';
import { fmtRating } from '../../../lib/match';
import { supabase } from '../../../lib/supabase';
import { colors, positionLabel } from '../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Screen, Sub, Title } from '../../../lib/ui';

type Membership = { id: string; pelada_id: string; player_name: string; preferred_position: string; status: string };

export default function Carta() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [member, setMember] = useState<Membership | null>(null);
  const [seasons, setSeasons] = useState<Season[]>([]);
  const [seasonId, setSeasonId] = useState<string | null>(null);
  const [card, setCard] = useState<CardData | null>(null);
  const [stats, setStats] = useState<SeasonStats | null>(null);
  const [awards, setAwards] = useState<Record<string, number>>({});
  const [loaded, setLoaded] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const { data: m, error } = await supabase
        .from('pelada_memberships')
        .select('id, pelada_id, player_name, preferred_position, status')
        .eq('id', id)
        .maybeSingle();
      if (error || !m) return setMsg(error ? friendly(error.message) : 'Jogador não encontrado.');
      setMember(m as Membership);
      const ss = await loadSeasons(m.pelada_id);
      setSeasons(ss);
      setSeasonId(currentSeason(ss)?.id ?? null);
    })().catch((e) => setMsg(friendly((e as Error).message)));
  }, [id]);

  const load = useCallback(async () => {
    if (!seasonId) return;
    setLoaded(false);
    try {
      const r = await loadCard(id, seasonId);
      setCard(r.card);
      setStats(r.stats);
      const { data: aw } = await supabase
        .from('awards')
        .select('award_type')
        .eq('membership_id', id)
        .eq('season_id', seasonId)
        .eq('status', 'active');
      const count: Record<string, number> = {};
      for (const a of aw ?? []) count[a.award_type] = (count[a.award_type] ?? 0) + 1;
      setAwards(count);
    } catch (e) {
      setMsg(friendly((e as Error).message));
    }
    setLoaded(true);
  }, [id, seasonId]);

  useEffect(() => {
    load();
  }, [load]);

  if (!member) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }

  const tier = card ? TIER[card.tier] : null;

  return (
    <Screen>
      <Title>{member.player_name}</Title>
      <Sub>{positionLabel(card?.position ?? member.preferred_position)}</Sub>
      {seasons.length > 1 && (
        <Chips options={seasons.map((s) => ({ value: s.id, label: s.name }))} value={seasonId} onChange={setSeasonId} />
      )}
      <ErrorText>{msg}</ErrorText>

      {member.status === 'retired' ? (
        <Sub>Aposentado: este registro não tem carta.</Sub>
      ) : !loaded ? (
        <Sub>Carregando...</Sub>
      ) : !card || !tier ? (
        <Card>
          <Body>Ainda sem carta nesta temporada.</Body>
          <Sub>A carta aparece depois da primeira partida finalizada.</Sub>
        </Card>
      ) : (
        <>
          <View
            style={{
              borderWidth: 3,
              borderColor: tier.color,
              borderRadius: 16,
              backgroundColor: colors.white,
              padding: 18,
              alignItems: 'center',
              gap: 4,
            }}>
            <Text style={{ fontSize: 56, fontWeight: '900', color: colors.deepBlue }}>{Math.round(card.overall)}</Text>
            <Text style={{ fontSize: 16, fontWeight: '800', color: tier.color }}>{tier.label.toUpperCase()}</Text>
            {card.is_provisional && (
              <Sub>Provisória: {card.matches_played} de 5 jogos</Sub>
            )}
          </View>
          <Card>
            {ATTRIBUTES.map((a) => {
              const v = Number(card[a.key]);
              return (
                <View key={a.key} style={{ gap: 4, marginBottom: 6 }}>
                  <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
                    <Text style={{ color: colors.ink, fontWeight: '600' }}>{a.label}</Text>
                    <Text style={{ color: colors.deepBlue, fontWeight: '800' }}>{Math.round(v)}</Text>
                  </View>
                  <View style={{ height: 8, borderRadius: 4, backgroundColor: colors.line }}>
                    <View style={{ height: 8, borderRadius: 4, width: `${Math.max(0, Math.min(100, v))}%`, backgroundColor: colors.blue }} />
                  </View>
                </View>
              );
            })}
          </Card>
        </>
      )}

      {stats && member.status !== 'retired' && (
        <Card>
          <Body>Temporada</Body>
          <Sub>
            {plural(stats.matches_played, 'jogo', 'jogos')} · {stats.wins}V {stats.draws}E {stats.losses}D
          </Sub>
          <Sub>
            {plural(stats.goals, 'gol', 'gols')} · {plural(stats.assists, 'assistência', 'assistências')}
            {stats.red_cards ? ` · ${plural(stats.red_cards, 'vermelho', 'vermelhos')}` : ''}
          </Sub>
          <Sub>
            Média de nota: {stats.avg_final_rating !== null ? fmtRating(Number(stats.avg_final_rating)) : '–'} (
            {plural(stats.valid_ratings, 'jogo com nota', 'jogos com nota')}) · {plural(stats.high_ratings, 'nota 8+', 'notas 8+')}
          </Sub>
          <Sub>
            Agora: {plural(stats.current_win_streak, 'vitória seguida', 'vitórias seguidas')} ·{' '}
            {plural(stats.current_unbeaten_streak, 'jogo sem perder', 'jogos sem perder')}. Recorde:{' '}
            {plural(stats.best_win_streak, 'vitória seguida', 'vitórias seguidas')}.
          </Sub>
        </Card>
      )}

      {Object.keys(awards).length > 0 && (
        <Card>
          <Body>Prêmios na temporada</Body>
          {Object.entries(awards).map(([k, n]) => (
            <Sub key={k}>
              {AWARD_LABEL[k] ?? k}: {n}
            </Sub>
          ))}
        </Card>
      )}

      <Button
        title="Ver álbum de figurinhas"
        kind="secondary"
        onPress={() => router.push({ pathname: '/jogador/[id]/album', params: { id } })}
      />
    </Screen>
  );
}
