import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Text, View } from 'react-native';

import { CardArt, SharePanel } from '../../../lib/arts';
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
import { ReportLink } from '../../../lib/report';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, positionLabel } from '../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Screen, Sub, Title } from '../../../lib/ui';

type Membership = {
  id: string;
  pelada_id: string;
  user_id: string | null;
  player_name: string;
  preferred_position: string;
  status: string;
};

export default function Carta() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const { session } = useAuth();
  const [blocked, setBlocked] = useState(false);
  const [member, setMember] = useState<Membership | null>(null);
  const [peladaName, setPeladaName] = useState('');
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
        .select('id, pelada_id, user_id, player_name, preferred_position, status')
        .eq('id', id)
        .maybeSingle();
      if (error || !m) return setMsg(error ? friendly(error.message) : 'Jogador não encontrado.');
      setMember(m as Membership);
      const { data: p } = await supabase.from('peladas').select('name').eq('id', m.pelada_id).maybeSingle();
      setPeladaName(p?.name ?? '');
      if (m.user_id) {
        const { data: b } = await supabase.from('user_blocks').select('blocked_user_id').eq('blocked_user_id', m.user_id);
        setBlocked((b ?? []).length > 0);
      }
      const ss = await loadSeasons(m.pelada_id);
      setSeasons(ss);
      setSeasonId(currentSeason(ss)?.id ?? null);
    })().catch((e) => setMsg(friendly((e as Error).message)));
  }, [id]);

  useEffect(() => {
    if (!seasonId) return;
    let alive = true; // ignora respostas que chegarem depois de trocar a temporada
    (async () => {
      try {
        const [r, { data: aw }] = await Promise.all([
          loadCard(id, seasonId),
          supabase.from('awards').select('award_type').eq('membership_id', id).eq('season_id', seasonId).eq('status', 'active'),
        ]);
        if (!alive) return;
        const count: Record<string, number> = {};
        for (const a of aw ?? []) count[a.award_type] = (count[a.award_type] ?? 0) + 1;
        setCard(r.card);
        setStats(r.stats);
        setAwards(count);
      } catch (e) {
        if (alive) setMsg(friendly((e as Error).message));
      }
      if (alive) setLoaded(true);
    })();
    return () => {
      alive = false;
    };
  }, [id, seasonId]);

  if (!member) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }

  const tier = card ? TIER[card.tier] : null;
  const isMe = !!member.user_id && member.user_id === session?.user.id;
  const seasonName = seasons.find((x) => x.id === seasonId)?.name ?? '';

  return (
    <Screen>
      <Title>{member.player_name}</Title>
      <Sub>{positionLabel(card?.position ?? member.preferred_position)}</Sub>
      {seasons.length > 1 && (
        <Chips options={seasons.map((s) => ({ value: s.id, label: s.name }))} value={seasonId} onChange={(v) => { setLoaded(false); setSeasonId(v); }} />
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
          {/* Só a própria carta: compartilhar a de outro jogador fica com ele (privacidade, Doc 03 36.3). */}
          {isMe && (
            <SharePanel label="Compartilhar minha carta" fileName="minuto91-carta" title="Minha carta">
              <CardArt peladaName={peladaName} seasonName={seasonName} playerName={member.player_name} card={card} />
            </SharePanel>
          )}
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

      {member.user_id && member.user_id !== session?.user.id && (
        <View style={{ gap: 10, marginTop: 12 }}>
          <ReportLink peladaId={member.pelada_id} targetType="member_name" targetId={member.id} label="Denunciar apelido" />
          <ReportLink peladaId={member.pelada_id} targetType="profile" targetId={member.user_id} label="Denunciar foto ou perfil" />
          <Button
            title={blocked ? 'Desbloquear jogador' : 'Bloquear jogador'}
            kind="secondary"
            onPress={async () => {
              const { error } = await supabase.rpc(blocked ? 'unblock_user' : 'block_user', { p_user: member.user_id });
              if (error) return setMsg(friendly(error.message));
              setBlocked(!blocked);
            }}
          />
          {blocked && <Sub>Você não vê mais a foto e o perfil deste jogador. Gols e notas continuam na súmula.</Sub>}
        </View>
      )}
    </Screen>
  );
}
