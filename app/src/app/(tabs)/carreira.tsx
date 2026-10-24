import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { Pressable, View } from 'react-native';
import { Text } from '../../lib/text';

import { PlayerCard } from '../../lib/arts';
import { Avatar } from '../../lib/avatar';
import { cardOverall, overallLabel, plural, TIER } from '../../lib/career';
import { CareerSummary, latestCard, loadCareerSummary, markGuide, referencePelada, SummaryPelada } from '../../lib/careerv2';
import { friendly } from '../../lib/errors';
import { EvolutionChart, useEvolution } from '../../lib/evolution';
import { fmtDate, fmtRating } from '../../lib/match';
import { TotalsGrid } from '../../lib/profile';
import { useAuth } from '../../lib/session';
import { supabase } from '../../lib/supabase';
import { colors, footLabel, positionLabel } from '../../lib/theme';
import { TrophyRoom } from '../../lib/trophies';
import { Badge, Button, Chips, EmptyState, ErrorState, ListGroup, Loading, Screen, SectionHeader, Sub, Tone } from '../../lib/ui';

type Me = { display_name: string; avatar_path: string | null; dominant_foot: string | null };
type HistoryItem = {
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
  pelada_name: string;
};
type HistoryCursor = { played_at: string; match_id: string };
const RESULT = { win: 'Vitória', draw: 'Empate', loss: 'Derrota' } as const;

// Minha Carreira (V4.4): a trajetória do jogador num lugar só — foto, nome, posição, pé, Card oficial, estatísticas,
// evolução, Sala de Troféus, álbum e histórico de partidas. "Geral" soma só contadores (jogos, gols, assistências,
// troféus) de todas as peladas; o Card e o overall aparecem sempre com a pelada e a temporada a que pertencem.
// Evolução: escolha uma pelada e uma temporada (mesmos dados oficiais do Card, 033). O perfil (editar e privacidade)
// continua em Meu perfil.
export default function Carreira() {
  const { session } = useAuth();
  const router = useRouter();
  const uid = session?.user.id ?? '';
  const [me, setMe] = useState<Me | null>(null);
  const [career, setCareer] = useState<CareerSummary | null>(null);
  const [primary, setPrimary] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [reload, setReload] = useState(0);
  const [scope, setScope] = useState<string>('all'); // 'all' ou pelada_id
  const [season, setSeason] = useState<string | null>(null);

  useFocusEffect(
    useCallback(() => {
      if (!uid) return;
      let alive = true;
      void reload;
      (async () => {
        try {
          const [c, { data: p }, { data: st }] = await Promise.all([
            loadCareerSummary(uid),
            supabase.rpc('get_my_profile'),
            supabase.from('user_app_state').select('primary_pelada_id').maybeSingle(),
          ]);
          if (!alive) return;
          setCareer(c);
          setMe(p as Me);
          setPrimary((st as { primary_pelada_id: string | null } | null)?.primary_pelada_id ?? null);
          setErr(null);
        } catch (e) {
          if (alive) setErr(friendly((e as Error).message));
        }
      })();
      return () => {
        alive = false;
      };
    }, [uid, reload]),
  );

  // Guia inicial: abrir Minha Carreira conta como passo visto.
  useEffect(() => {
    markGuide('career').catch(() => {});
  }, []);

  if (!career || !me) {
    return (
      <Screen>
        {err ? <ErrorState message={err} onRetry={() => setReload((n) => n + 1)} /> : <Loading label="Carregando sua carreira..." />}
      </Screen>
    );
  }
  if (!career.visible)
    return (
      <Screen>
        <EmptyState title="Carreira indisponível" hint="Os dados da carreira não estão disponíveis para esta conta agora." />
      </Screen>
    );

  const ref = referencePelada(career.peladas, primary);
  const selected: SummaryPelada | null = scope === 'all' ? null : (career.peladas.find((p) => p.pelada_id === scope) ?? null);
  const cardPelada = selected ?? ref;
  const latest = cardPelada ? latestCard(cardPelada) : null;
  const seasonRow = selected ? (selected.seasons.find((s) => s.season_id === season) ?? selected.seasons[0] ?? null) : null;
  const totals = selected ? (seasonRow && season ? seasonRow : selected.totals) : career.totals;
  const position = cardPelada ? (cardPelada.position_code ?? cardPelada.position) : null;
  const ovr = latest ? cardOverall(latest.card) : null;
  const tier = latest && ovr !== null ? TIER[latest.card.tier] : null;

  return (
    <Screen>
      {/* V6.0: cabeçalho da carreira (foto, nome, posição, pelada, OVR e categoria) em faixa azul. */}
      <View style={hero}>
        <Avatar path={me.avatar_path} name={me.display_name} size={76} />
        <View style={{ flex: 1, minWidth: 0, gap: 3 }}>
          <Text style={{ fontSize: 24, lineHeight: 30, fontWeight: '800', color: colors.white }} numberOfLines={2} accessibilityRole="header">
            {me.display_name}
          </Text>
          <Text style={{ fontSize: 14, color: '#CFDCF5' }} numberOfLines={2}>
            {[position ? positionLabel(position) : 'Posição não informada', cardPelada?.name, me.dominant_foot ? footLabel(me.dominant_foot) : null]
              .filter(Boolean)
              .join(' · ')}
          </Text>
        </View>
        {ovr !== null && tier ? (
          <View style={{ alignItems: 'center' }} accessible accessibilityLabel={`OVR ${ovr}, ${tier.label}`}>
            <Text style={{ fontSize: 36, lineHeight: 40, fontWeight: '900', color: colors.white, fontVariant: ['tabular-nums'] }}>{ovr}</Text>
            <View style={{ marginTop: 2, paddingHorizontal: 8, paddingVertical: 2, borderRadius: 11, backgroundColor: tier.bg }}>
              <Text style={{ fontSize: 12, fontWeight: '800', color: tier.deep }}>{tier.label}</Text>
            </View>
          </View>
        ) : null}
      </View>

      <Button title="Editar perfil e privacidade" kind="ghost" onPress={() => router.push('/perfil')} />

      {career.peladas.length > 1 && (
        <Chips
          options={[{ value: 'all', label: 'Geral' }, ...career.peladas.map((p) => ({ value: p.pelada_id, label: p.name }))]}
          value={scope}
          onChange={(v) => {
            setScope(v);
            setSeason(null);
          }}
        />
      )}

      <SectionHeader title="Card oficial" />
      {latest && cardPelada ? (
        <View style={{ alignItems: 'center', gap: 10, paddingVertical: 20, borderRadius: 20, backgroundColor: colors.bg }}>
          <PlayerCard
            card={{ ...latest.card, id: `${cardPelada.membership_id}-${latest.season.season_id}` }}
            playerName={me.display_name}
            photoPath={me.avatar_path}
            peladaName={cardPelada.name}
            crestPath={cardPelada.crest_path}
            seasonName={latest.season.name}
            seasonStart={latest.season.starts_on}
          />
          <Sub>
            {overallLabel(latest.card)}
            {latest.card.is_provisional ? ' (provisório)' : ''} · {latest.season.name}
          </Sub>
          {scope === 'all' && career.peladas.length > 1 && <Sub>O Card é de cada pelada. Escolha outra pelada acima para ver o Card dela.</Sub>}
          <Button
            title="Abrir o Card completo"
            kind="secondary"
            onPress={() => router.push({ pathname: '/jogador/[id]', params: { id: cardPelada.membership_id } })}
          />
        </View>
      ) : (
        <EmptyState
          title="Seu Card ainda não saiu"
          hint={`O Card aparece depois da primeira partida finalizada ${cardPelada ? `em ${cardPelada.name}` : 'numa pelada'}.`}
        />
      )}

      <SectionHeader title="Estatísticas" />
      <View style={{ gap: 10 }}>
        <Sub>
          {selected
            ? season && seasonRow
              ? `${selected.name} · ${seasonRow.name}`
              : `${selected.name} · ${selected.hidden_seasons > 0 ? 'temporadas disponíveis' : 'todas as temporadas'}`
            : career.partial
              ? 'Geral · todas as peladas (temporadas disponíveis)'
              : 'Geral · todas as peladas'}
        </Sub>
        {selected && selected.seasons.length > 0 && (
          <Chips
            options={[{ value: '', label: 'Todas' }, ...selected.seasons.map((s) => ({ value: s.season_id, label: s.name }))]}
            value={season ?? ''}
            onChange={(v) => setSeason(v || null)}
          />
        )}
        <TotalsGrid totals={totals} />
        {selected && season && seasonRow && (
          <Sub>Média de nota na temporada: {seasonRow.avg_final_rating !== null ? fmtRating(Number(seasonRow.avg_final_rating)) : '–'}</Sub>
        )}
        {career.partial && !selected && (
          <Sub>Temporadas antigas de peladas no Básico ficam de fora; o histórico completo é da Pelada Premium de cada pelada.</Sub>
        )}
      </View>

      <SectionHeader title="Evolução" />
      {selected ? (
        selected.seasons.length > 0 ? (
          <Evolution membershipId={selected.membership_id} seasonId={season ?? selected.seasons[0].season_id} />
        ) : (
          <Sub>Sem partidas finalizadas nas temporadas disponíveis.</Sub>
        )
      ) : (
        <Sub>A evolução é por pelada e temporada. Escolha uma pelada acima{career.peladas.length > 1 ? '' : ' (ou abra o Card)'}.</Sub>
      )}
      {!selected && career.peladas.length === 1 && (
        <Button title={`Ver evolução em ${career.peladas[0].name}`} kind="secondary" onPress={() => setScope(career.peladas[0].pelada_id)} />
      )}

      {/* Conquistas: troféus (únicos, prêmios) e figurinhas (colecionáveis e marcos) seguem separados. */}
      <SectionHeader title="Conquistas" />
      <Text style={{ fontSize: 16, fontWeight: '700', color: colors.ink }}>Sala de Troféus</Text>
      <TrophyRoom userId={uid} counts={career.trophies} partial={career.partial} />
      <ListGroup
        title="Álbum de Figurinhas"
        items={career.peladas
          .filter((p) => p.status === 'active' && (!selected || p.pelada_id === selected.pelada_id))
          .map((p) => ({
            icon: 'card' as const,
            title: p.name,
            sub: 'Colecionáveis e marcos da carreira',
            onPress: () => router.push({ pathname: '/jogador/[id]/album', params: { id: p.membership_id } }),
          }))}
      />

      <SectionHeader title="Histórico de partidas" />
      <MatchHistory peladaId={selected?.pelada_id ?? null} showPelada={!selected && career.peladas.length > 1} />
    </Screen>
  );
}

function Evolution({ membershipId, seasonId }: { membershipId: string; seasonId: string }) {
  const { data, error } = useEvolution(membershipId, seasonId);
  if (error) return <ErrorState message={error} />;
  if (!data) return <Loading label="Carregando evolução..." />;
  return <EvolutionChart evolution={data} />;
}

function MatchHistory({ peladaId, showPelada }: { peladaId: string | null; showPelada: boolean }) {
  const router = useRouter();
  const [items, setItems] = useState<HistoryItem[] | null>(null);
  const [next, setNext] = useState<HistoryCursor | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc('get_my_match_history', { p_pelada: peladaId, p_after: null, p_limit: 10 });
      if (!alive) return;
      if (error) return setMsg(friendly(error.message));
      const p = data as { items: HistoryItem[]; next: HistoryCursor | null };
      setMsg(null);
      setItems(p.items);
      setNext(p.next);
    })();
    return () => {
      alive = false;
    };
  }, [peladaId]);

  async function more() {
    if (!next) return;
    setBusy(true);
    const { data, error } = await supabase.rpc('get_my_match_history', { p_pelada: peladaId, p_after: next, p_limit: 20 });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    const p = data as { items: HistoryItem[]; next: HistoryCursor | null };
    setItems((xs) => [...(xs ?? []), ...p.items]);
    setNext(p.next);
  }

  if (msg) return <ErrorState message={msg} />;
  if (!items) return <Loading label="Carregando partidas..." />;
  if (items.length === 0) return <EmptyState title="Nenhuma partida finalizada ainda" hint="Suas partidas aparecem aqui depois de publicadas." />;
  return (
    <View style={{ gap: 12 }}>
      <ListGroup>
        {items.map((m, n) => (
          <Pressable
            key={m.match_id}
            accessibilityRole="button"
            accessibilityLabel={`${RESULT[m.match_result]}: ${m.team_a_name} ${m.team_a_score} x ${m.team_b_score} ${m.team_b_name}, ${fmtDate(m.played_at)}`}
            onPress={() => router.push({ pathname: '/partida/[id]', params: { id: m.match_id } })}
            style={({ pressed }) => ({
              paddingHorizontal: 14,
              paddingVertical: 12,
              gap: 4,
              borderTopWidth: n ? 1 : 0,
              borderTopColor: colors.divider,
              backgroundColor: pressed ? colors.bg : colors.white,
            })}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
              <Text style={{ flex: 1, fontSize: 15, fontWeight: '600', color: colors.ink }} numberOfLines={1}>
                {m.team_a_name}{' '}
                <Text style={{ color: colors.deepBlue, fontWeight: '800', fontVariant: ['tabular-nums'] }}>
                  {m.team_a_score} x {m.team_b_score}
                </Text>{' '}
                {m.team_b_name}
              </Text>
              <Badge label={RESULT[m.match_result]} tone={RESULT_TONE[m.match_result]} />
            </View>
            <Sub>
              {fmtDate(m.played_at)}
              {showPelada ? ` · ${m.pelada_name}` : ''}
              {m.goals ? ` · ${plural(m.goals, 'gol', 'gols')}` : ''}
              {m.assists ? ` · ${plural(m.assists, 'assistência', 'assistências')}` : ''}
            </Sub>
          </Pressable>
        ))}
      </ListGroup>
      {next && <Button title="Ver mais partidas" kind="secondary" onPress={more} loading={busy} />}
    </View>
  );
}

const RESULT_TONE: Record<HistoryItem['match_result'], Tone> = { win: 'success', draw: 'neutral', loss: 'danger' };
const hero = {
  flexDirection: 'row' as const,
  alignItems: 'center' as const,
  gap: 14,
  padding: 18,
  borderRadius: 20,
  backgroundColor: colors.deepBlue,
  borderBottomWidth: 3,
  borderBottomColor: colors.gold,
};
