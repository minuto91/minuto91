import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { View } from 'react-native';
import { Text } from '../../lib/text';

import { PlayerCard } from '../../lib/arts';
import { Avatar } from '../../lib/avatar';
import { CareerSummary, latestCard, loadCareerSummary, markGuide, referencePelada, SummaryPelada } from '../../lib/careerv2';
import { friendly } from '../../lib/errors';
import { EvolutionChart, useEvolution } from '../../lib/evolution';
import { fmtRating } from '../../lib/match';
import { type Career, CareerByPelada, loadPlayer, TotalsGrid } from '../../lib/profile';
import { useAuth } from '../../lib/session';
import { useSticky } from '../../lib/sticky';
import { supabase } from '../../lib/supabase';
import { colors, positionLabel } from '../../lib/theme';
import { MatchHistory } from '../../lib/history';
import { MyAwardsList } from '../../lib/myawards';
import { scopedTitles, SeasonTitle, showMyAwards, showOrigin } from '../../lib/v87logic';
import { TrophyRoom } from '../../lib/trophies';
import { Button, Card, Chips, ErrorText, LoadingBlock, Screen, Sub, Title } from '../../lib/ui';

type Me = { display_name: string; avatar_path: string | null; dominant_foot: string | null };

// Minha Carreira (V4.4): a trajetória do jogador num lugar só — foto, nome, posição, pé, Card oficial, estatísticas,
// evolução, Sala de Troféus, álbum e histórico de partidas. "Geral" soma só contadores (jogos, gols, assistências,
// troféus) de todas as peladas; o Card e o overall aparecem sempre com a pelada e a temporada a que pertencem.
// Evolução: escolha uma pelada e uma temporada (mesmos dados oficiais do Card, 033). O perfil (editar) continua em Meu
// perfil; a privacidade fica em Minha conta.
export default function Carreira() {
  const { session } = useAuth();
  const router = useRouter();
  const uid = session?.user.id ?? '';
  const [me, setMe] = useState<Me | null>(null);
  const [career, setCareer] = useState<CareerSummary | null>(null);
  const [byPelada, setByPelada] = useState<Career | null>(null);
  const [titles, setTitles] = useState<SeasonTitle[] | null>(null);
  const [primary, setPrimary] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [reload, setReload] = useState(0);
  const [scope, setScope] = useSticky<string>('carreira:scope', ''); // '' = pelada de referência, 'all' = geral (só números), ou pelada_id (REV-035: lembrado)
  const [season, setSeason] = useSticky<string | null>('carreira:season', null);

  useFocusEffect(
    useCallback(() => {
      if (!uid) return;
      let alive = true;
      void reload;
      (async () => {
        try {
          const [c, { data: p }, { data: st }, mine] = await Promise.all([
            loadCareerSummary(uid),
            supabase.rpc('get_my_profile'),
            supabase.from('user_app_state').select('primary_pelada_id').maybeSingle(),
            loadPlayer(uid).catch(() => null),
          ]);
          if (!alive) return;
          setCareer(c);
          setByPelada(mine?.career ?? null);
          // AD01: Meus Prêmios. Falha aqui não derruba a carreira: o bloco simplesmente não aparece.
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
  const selected: SummaryPelada | null = scope === 'all' ? null : (career.peladas.find((p) => p.pelada_id === scope) ?? ref);
  const cardPelada = selected;
  const latest = cardPelada ? latestCard(cardPelada) : null;
  const seasonRow = selected ? (selected.seasons.find((s) => s.season_id === season) ?? selected.seasons[0] ?? null) : null;
  const totals = selected ? (seasonRow && season ? seasonRow : selected.totals) : career.totals;
  // A posição é sempre de uma pelada: a escolhida ou, no Geral, a de referência (nunca o pé dominante).
  const posPelada = selected ?? ref;
  const position = posPelada ? (posPelada.position_code ?? posPelada.position) : null;

  return (
    <Screen>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
        <Avatar path={me.avatar_path} name={me.display_name} size={72} />
        <View style={{ flex: 1, gap: 2 }}>
          <Title>{me.display_name}</Title>
          <Sub>
            {position ? positionLabel(position) : 'Posição não informada'}
          </Sub>
        </View>
      </View>

      {career.peladas.length > 1 && (
        <Chips
          options={[
            { value: 'all', label: 'Geral' },
            // REV-047: pelada que a pessoa deixou continua na carreira, identificada como encerrada.
            ...career.peladas.map((p) => ({ value: p.pelada_id, label: p.status === 'active' ? p.name : `${p.name} (encerrada)` })),
          ]}
          value={selected?.pelada_id ?? 'all'}
          onChange={(v) => {
            setScope(v);
            setSeason(null);
          }}
        />
      )}

      {cardPelada && <Text style={section}>Card oficial</Text>}
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
          <Button
            title="Abrir o Card completo"
            kind="secondary"
            onPress={() => router.push({ pathname: '/jogador/[id]', params: { id: cardPelada.membership_id } })}
          />
        </View>
      ) : cardPelada ? (
        <Sub>O Card aparece depois da primeira partida finalizada em {cardPelada.name}.</Sub>
      ) : null}

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
          <Sub>Temporadas antigas do Basic ficam de fora.</Sub>
        )}
      </Card>

      {!selected && byPelada?.visible && byPelada.peladas.length > 0 && (
        <>
          <Text style={section}>Por pelada e temporada</Text>
          <CareerByPelada career={byPelada} />
        </>
      )}

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
      <TrophyRoom userId={uid} counts={career.trophies} partial={career.partial} shareName={me.display_name} />

      {showMyAwards(scopedTitles(titles, selected?.pelada_id)) && (
        <>
          <Text style={section}>Meus Prêmios</Text>
          <MyAwardsList items={scopedTitles(titles, selected?.pelada_id)} withOrigin={showOrigin(titles ?? [])} />
        </>
      )}

      <Text style={section}>Álbum</Text>
      <Button title="Abrir meu álbum" kind="secondary" onPress={() => router.push('/album')} />

      {/* REV-020: as artes individuais da retrospectiva também ficam acessíveis daqui. */}
      {career.peladas
        .filter((p) => p.status === 'active' && (!selected || p.pelada_id === selected.pelada_id))
        .map((p) => (
          <Button
            key={p.membership_id}
            title={career.peladas.length > 1 ? `Retrospectiva · ${p.name}` : 'Retrospectiva'}
            kind="ghost"
            onPress={() => router.push({ pathname: '/pelada/[id]/retrospectiva', params: { id: p.pelada_id } })}
          />
        ))}

      <Text style={section}>Últimas partidas</Text>
      <MatchHistory peladaId={selected?.pelada_id ?? null} showPelada={!selected && career.peladas.length > 1} limit={3} />
      <Button
        title="Ver histórico completo"
        kind="ghost"
        onPress={() => router.push({ pathname: '/historico', params: selected ? { pelada: selected.pelada_id } : {} })}
      />
    </Screen>
  );
}

function Evolution({ membershipId, seasonId }: { membershipId: string; seasonId: string }) {
  const { data, error } = useEvolution(membershipId, seasonId);
  if (error) return <Sub>{error}</Sub>;
  if (!data) return <LoadingBlock />;
  return <EvolutionChart evolution={data} />;
}

const section = { fontSize: 19, lineHeight: 25, fontWeight: '700' as const, color: colors.ink, marginTop: 8 };
