import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { Pressable, View } from 'react-native';
import { Text } from '../../lib/text';

import { PlayerCard } from '../../lib/arts';
import { Avatar } from '../../lib/avatar';
import { overallLabel, plural } from '../../lib/career';
import { CareerSummary, latestCard, loadCareerSummary, markGuide, referencePelada, SummaryPelada } from '../../lib/careerv2';
import { friendly } from '../../lib/errors';
import { EvolutionChart, useEvolution } from '../../lib/evolution';
import { fmtDate, fmtRating } from '../../lib/match';
import { TotalsGrid } from '../../lib/profile';
import { useAuth } from '../../lib/session';
import { supabase } from '../../lib/supabase';
import { colors, footLabel, positionLabel } from '../../lib/theme';
import { TrophyRoom } from '../../lib/trophies';
import { Body, Button, Card, Chips, ErrorText, Screen, Sub, Title } from '../../lib/ui';

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
        <ErrorText>{err}</ErrorText>
        {err ? <Button title="Tentar de novo" kind="secondary" onPress={() => setReload((n) => n + 1)} /> : <Sub>Carregando...</Sub>}
      </Screen>
    );
  }
  if (!career.visible) return <Screen><Sub>Carreira indisponível.</Sub></Screen>;

  const ref = referencePelada(career.peladas, primary);
  const selected: SummaryPelada | null = scope === 'all' ? null : (career.peladas.find((p) => p.pelada_id === scope) ?? null);
  const cardPelada = selected ?? ref;
  const latest = cardPelada ? latestCard(cardPelada) : null;
  const seasonRow = selected ? (selected.seasons.find((s) => s.season_id === season) ?? selected.seasons[0] ?? null) : null;
  const totals = selected ? (seasonRow && season ? seasonRow : selected.totals) : career.totals;
  const position = cardPelada ? (cardPelada.position_code ?? cardPelada.position) : null;

  return (
    <Screen>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
        <Avatar path={me.avatar_path} name={me.display_name} size={72} />
        <View style={{ flex: 1, gap: 2 }}>
          <Title>{me.display_name}</Title>
          <Sub>
            {position ? positionLabel(position) : 'Posição não informada'}
            {cardPelada && career.peladas.length > 1 ? ` em ${cardPelada.name}` : ''}
            {me.dominant_foot ? ` · ${footLabel(me.dominant_foot)}` : ''}
          </Sub>
        </View>
      </View>
      <Button title="Editar perfil e privacidade" kind="secondary" onPress={() => router.push('/perfil')} />

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

      <Text style={section}>Card oficial</Text>
      {latest && cardPelada ? (
        <View style={{ alignItems: 'center', gap: 6 }}>
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
            {latest.card.is_provisional ? ' (provisório)' : ''} · {cardPelada.name} · {latest.season.name}
          </Sub>
          {scope === 'all' && career.peladas.length > 1 && <Sub>O Card é de cada pelada. Escolha outra pelada acima para ver o Card dela.</Sub>}
          <Button
            title="Abrir o Card completo"
            kind="secondary"
            onPress={() => router.push({ pathname: '/jogador/[id]', params: { id: cardPelada.membership_id } })}
          />
        </View>
      ) : (
        <Sub>O Card aparece depois da primeira partida finalizada {cardPelada ? `em ${cardPelada.name}` : 'numa pelada'}.</Sub>
      )}

      <Text style={section}>Estatísticas</Text>
      <Card>
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
      </Card>

      <Text style={section}>Evolução</Text>
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

      <Text style={section}>Sala de Troféus</Text>
      <TrophyRoom userId={uid} counts={career.trophies} partial={career.partial} />

      <Text style={section}>Álbum de Figurinhas</Text>
      <Sub>O álbum guarda colecionáveis e marcos (ex.: 5 e 10 vezes Craque da Partida). Os troféus acima são os prêmios conquistados.</Sub>
      {career.peladas
        .filter((p) => p.status === 'active' && (!selected || p.pelada_id === selected.pelada_id))
        .map((p) => (
          <Button
            key={p.membership_id}
            title={`Álbum · ${p.name}`}
            kind="secondary"
            onPress={() => router.push({ pathname: '/jogador/[id]/album', params: { id: p.membership_id } })}
          />
        ))}

      <Text style={section}>Histórico de partidas</Text>
      <MatchHistory peladaId={selected?.pelada_id ?? null} showPelada={!selected && career.peladas.length > 1} />
    </Screen>
  );
}

function Evolution({ membershipId, seasonId }: { membershipId: string; seasonId: string }) {
  const { data, error } = useEvolution(membershipId, seasonId);
  if (error) return <Sub>{error}</Sub>;
  if (!data) return <Sub>Carregando...</Sub>;
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

  if (msg) return <ErrorText>{msg}</ErrorText>;
  if (!items) return <Sub>Carregando...</Sub>;
  if (items.length === 0) return <Sub>Nenhuma partida finalizada ainda.</Sub>;
  return (
    <View style={{ gap: 8 }}>
      {items.map((m) => (
        <Pressable
          key={m.match_id}
          accessibilityRole="button"
          onPress={() => router.push({ pathname: '/partida/[id]', params: { id: m.match_id } })}
          style={{ backgroundColor: colors.bg, borderRadius: 12, padding: 12, gap: 2 }}>
          <Body>
            {m.team_a_name} {m.team_a_score} x {m.team_b_score} {m.team_b_name}
          </Body>
          <Sub>
            {fmtDate(m.played_at)}
            {showPelada ? ` · ${m.pelada_name}` : ''} · {RESULT[m.match_result]}
            {m.goals ? ` · ${plural(m.goals, 'gol', 'gols')}` : ''}
            {m.assists ? ` · ${plural(m.assists, 'assistência', 'assistências')}` : ''}
          </Sub>
        </Pressable>
      ))}
      {next && <Button title="Ver mais partidas" kind="secondary" onPress={more} loading={busy} />}
    </View>
  );
}

const section = { fontSize: 19, lineHeight: 25, fontWeight: '700' as const, color: colors.deepBlue, marginTop: 8 };
