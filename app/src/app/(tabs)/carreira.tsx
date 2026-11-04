import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Pressable, View } from 'react-native';
import { Text } from '../../lib/text';

import { PlayerCard } from '../../lib/arts';
import { Avatar } from '../../lib/avatar';
import { CareerSummary, latestCard, loadCareerSummary, markGuide, referencePelada, SummaryPelada } from '../../lib/careerv2';
import { avgLabel, orderPeladas, recentTrophies, visiblePosition, yearOptions } from '../../lib/careerlogic';
import { friendly } from '../../lib/errors';
import { EvolutionChart, useEvolution } from '../../lib/evolution';
import { TotalsGrid } from '../../lib/profile';
import { useAuth } from '../../lib/session';
import { useSticky } from '../../lib/sticky';
import { supabase } from '../../lib/supabase';
import { colors, positionLabel } from '../../lib/theme';
import { MatchHistory } from '../../lib/history';
import { SeasonTitle } from '../../lib/v87logic';
import { TROPHIES, TrophyArt, type TrophyType } from '../../lib/trophies';
import { Button, Card, Chips, ErrorText, LoadingBlock, Screen, Sub, Title } from '../../lib/ui';

type Me = { display_name: string; avatar_path: string | null; dominant_foot: string | null };

// Minha Carreira (V10.0, REV-123/124): UMA página contínua, sem escolha entre "Geral" e pelada. Com uma pelada mostra a
// carreira completa direto; com várias, cada pelada tem o seu bloco identificado (Card oficial, Estatísticas e Evolução),
// a de origem (vinda do Início) primeiro. Troféus e Álbum valem para a pessoa toda. Nada de "Evolução geral": a evolução
// é sempre por pelada e temporada. O perfil continua em Meu perfil; a privacidade, em Minha conta.
export default function Carreira() {
  const { session } = useAuth();
  const router = useRouter();
  const { pelada: originParam } = useLocalSearchParams<{ pelada?: string }>();
  const uid = session?.user.id ?? '';
  const [me, setMe] = useState<Me | null>(null);
  const [career, setCareer] = useState<CareerSummary | null>(null);
  const [titles, setTitles] = useState<SeasonTitle[] | null>(null);
  const [primary, setPrimary] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

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
          // Meus Troféus: falha aqui não derruba a carreira; a seção usa só os contadores.
          const t = await supabase.rpc('get_player_season_titles', { p_user: uid });
          if (alive) setTitles(t.error || !(t.data as { visible?: boolean } | null)?.visible ? null : ((t.data as { items: SeasonTitle[] }).items ?? []));
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

  const peladas = useMemo(() => (career && career.visible ? orderPeladas(career.peladas, originParam || null) : []), [career, originParam]);

  if (!career || !me) {
    return (
      <Screen>
        <ErrorText>{err}</ErrorText>
        {err ? <Button title="Tentar de novo" kind="secondary" onPress={() => setReload((n) => n + 1)} /> : <LoadingBlock />}
      </Screen>
    );
  }
  if (!career.visible) return <Screen><Sub>Carreira indisponível.</Sub></Screen>;

  const ref = referencePelada(career.peladas, primary);
  const headPelada = peladas.find((p) => p.status === 'active') ?? ref;
  const position = headPelada ? (headPelada.position_code ?? headPelada.position) : null;
  const trophies = recentTrophies(titles, career.trophies as Record<string, number | undefined>, TROPHIES);
  const many = peladas.length > 1;

  return (
    <Screen>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
        <Avatar path={me.avatar_path} name={me.display_name} size={72} />
        <View style={{ flex: 1, gap: 2 }}>
          <Title>{me.display_name}</Title>
          <Sub>{position ? visiblePosition(positionLabel(position)) : 'Posição não informada'}</Sub>
        </View>
      </View>

      {peladas.map((p) => (
        <PeladaCareer key={p.pelada_id} p={p} me={me} many={many} />
      ))}

      {/* REV-126: seção compacta com até três troféus; o acervo completo fica na página "Meus Troféus". */}
      <Text style={section}>Meus Troféus</Text>
      {trophies.length === 0 ? (
        <Sub>Você ainda não tem troféus.</Sub>
      ) : (
        <View style={{ flexDirection: 'row', justifyContent: 'space-around', gap: 8 }}>
          {trophies.map((t) => (
            <View key={t.key} style={{ flex: 1, alignItems: 'center', gap: 4, maxWidth: 120 }} accessibilityLabel={TROPHIES.find((x) => x.type === t.type)?.label ?? t.label}>
              <TrophyArt type={t.type as TrophyType} size={72} />
              <Text style={{ fontSize: 12, color: colors.muted, textAlign: 'center' }} numberOfLines={2}>
                {TROPHIES.find((x) => x.type === t.type)?.label ?? t.label}
              </Text>
            </View>
          ))}
        </View>
      )}
      <View style={{ alignItems: 'flex-end' }}>
        <Button title="Sala de Troféus" kind="secondary" size="sm" block={false} onPress={() => router.push('/meus-trofeus')} />
      </View>

      <Text style={section}>Álbum</Text>
      <Button title="Abrir meu álbum" kind="secondary" onPress={() => router.push('/album')} />

      <Text style={section}>Últimas partidas</Text>
      <MatchHistory peladaId={null} showPelada={many} limit={3} />
      <Button title="Ver histórico completo" kind="ghost" onPress={() => router.push({ pathname: '/historico', params: {} })} />
    </Screen>
  );
}

// Bloco de uma pelada: Card oficial (o próprio Card abre o Card completo), Estatísticas com filtro por ano e Evolução.
function PeladaCareer({ p, me, many }: { p: SummaryPelada; me: Me; many: boolean }) {
  const router = useRouter();
  const [season, setSeason] = useSticky<string | null>(`carreira:season:${p.pelada_id}`, null);
  const latest = latestCard(p);
  const seasonRow = p.seasons.find((s) => s.season_id === season) ?? null;
  const totals = seasonRow ?? p.totals;
  const avg = seasonRow ? seasonRow.avg_final_rating : null;
  const position = p.position_code ?? p.position;
  const evoSeason = seasonRow?.season_id ?? p.seasons[0]?.season_id ?? null;
  const openCard = () => router.push({ pathname: '/jogador/[id]', params: { id: p.membership_id } });
  return (
    <View style={{ gap: 10 }}>
      {many && (
        <>
          <Text style={section}>{p.status === 'active' ? p.name : `${p.name} (encerrada)`}</Text>
          <Sub>{visiblePosition(positionLabel(position))}</Sub>
        </>
      )}

      <Text style={sub}>Card oficial</Text>
      {latest ? (
        <Pressable onPress={openCard} accessibilityRole="button" accessibilityLabel={`Abrir o Card completo, ${p.name}`} style={{ alignItems: 'center' }}>
          <PlayerCard
            card={{ ...latest.card, id: `${p.membership_id}-${latest.season.season_id}` }}
            playerName={me.display_name}
            photoPath={me.avatar_path}
            peladaName={p.name}
            crestPath={p.crest_path}
            seasonName={latest.season.name}
            seasonStart={latest.season.starts_on}
          />
        </Pressable>
      ) : (
        <Sub>Seu Card oficial será desbloqueado após 5 partidas oficiais.</Sub>
      )}

      <Text style={sub}>Estatísticas</Text>
      <Card>
        {p.seasons.length > 0 && (
          <Chips
            small
            options={[{ value: '', label: 'Geral' }, ...yearOptions(p.seasons)]}
            value={season ?? ''}
            onChange={(v) => setSeason(v || null)}
          />
        )}
        {/* REV-131: média de notas como indicador da grade; a fórmula e os valores são os de sempre. */}
        <TotalsGrid totals={totals} avgRating={avgLabel(season ? avg : (seasonAvg(p)))} />
      </Card>

      <Text style={sub}>Evolução</Text>
      {evoSeason ? <Evolution membershipId={p.membership_id} seasonId={evoSeason} /> : <Sub>Sem partidas finalizadas nas temporadas disponíveis.</Sub>}
    </View>
  );
}

// Média da pelada em "Geral": média das temporadas ponderada pelas notas válidas (a mesma média oficial, só reunida).
function seasonAvg(p: SummaryPelada): number | null {
  let w = 0;
  let s = 0;
  for (const x of p.seasons) {
    if (x.avg_final_rating !== null && x.valid_ratings > 0) {
      w += x.valid_ratings;
      s += Number(x.avg_final_rating) * x.valid_ratings;
    }
  }
  return w > 0 ? s / w : null;
}

function Evolution({ membershipId, seasonId }: { membershipId: string; seasonId: string }) {
  const { data, error } = useEvolution(membershipId, seasonId);
  if (error) return <Sub>{error}</Sub>;
  if (!data) return <LoadingBlock />;
  return <EvolutionChart evolution={data} />;
}

const section = { fontSize: 19, lineHeight: 25, fontWeight: '700' as const, color: colors.ink, marginTop: 8 };
const sub = { fontSize: 16, lineHeight: 22, fontWeight: '700' as const, color: colors.ink, marginTop: 4 };
