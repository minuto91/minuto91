import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { View } from 'react-native';

import { SharePanel } from '../../../lib/arts';
import { loadReadableSeasons, Season } from '../../../lib/career';
import { Skeleton } from '../../../lib/central';
import { todayIn } from '../../../lib/dates';
import { friendly } from '../../../lib/errors';
import { useEvolution } from '../../../lib/evolution';
import { ArtId, AWARD_CATEGORIES, COLLECTIVE, INDIVIDUAL, myAwardTitles, OfficialRetro, RetroArt, RetroTop } from '../../../lib/retroarts';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { Text } from '../../../lib/text';
import { colors, type } from '../../../lib/theme';
import { CATEGORY_TYPE, SEASON_AWARD_LABEL, sharedLabel, statText } from '../../../lib/v87logic';
import { Button, Chips, EmptyState, ErrorText, Screen, Section, Sub, Title } from '../../../lib/ui';

// REV-019 / REV-026: retrospectiva oficial da temporada, Premium, só depois do fim do calendário E da consolidação
// (súmulas e votações resolvidas). A versão vem do servidor (nova versão se uma correção mudar os dados).
// Oito telas navegáveis; as artes (REV-020) ficam no fim, coletivas e individuais.
type Consolidation = { calendar_closed: boolean; pending_matches: number; pending_votes: number; ready: boolean; premium: boolean };
const SCREENS = ['Capa', 'Números', 'Artilheiro e garçom', 'Craque', 'Seleção da Rodada', 'Partidas memoráveis', 'Recordes', 'Prêmios da temporada', 'Encerramento'];

export default function Retrospectiva() {
  const { id, season: seasonParam } = useLocalSearchParams<{ id: string; season?: string }>();
  const router = useRouter();
  const { session } = useAuth();
  const uid = session?.user.id;
  const [seasons, setSeasons] = useState<Season[]>([]);
  const [seasonId, setSeasonId] = useState<string | null>(seasonParam ?? null);
  const [pelada, setPelada] = useState<{ name: string; crest_path: string | null } | null>(null);
  const [me, setMe] = useState<{ id: string; player_name: string } | null>(null);
  const [myPhoto, setMyPhoto] = useState<string | null>(null);
  const [cons, setCons] = useState<Consolidation | null>(null);
  const [retro, setRetro] = useState<{ seasonId: string; data: OfficialRetro } | null>(null);
  const [page, setPage] = useState(0);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const today = todayIn();
      const [ss, { data: p }, { data: m }] = await Promise.all([
        loadReadableSeasons(id),
        supabase.from('peladas').select('name, crest_path').eq('id', id).maybeSingle(),
        supabase.from('pelada_memberships').select('id, player_name').eq('pelada_id', id).eq('user_id', uid ?? '').maybeSingle(),
      ]);
      if (!alive) return;
      const started = ss.filter((s) => s.starts_on <= today);
      setSeasons(started);
      setSeasonId((cur) => cur ?? started.find((s) => s.ends_on < today)?.id ?? started[0]?.id ?? null);
      setPelada(p);
      setMe(m);
      const { data: prof } = await supabase.rpc('get_my_profile');
      if (alive) setMyPhoto((prof as { avatar_path?: string | null } | null)?.avatar_path ?? null);
    })().catch((e) => alive && setMsg(friendly((e as Error).message)));
    return () => {
      alive = false;
    };
  }, [id, uid]);

  useEffect(() => {
    if (!seasonId) return;
    let alive = true;
    (async () => {
      const { data: c, error } = await supabase.rpc('get_season_consolidation', { p_season: seasonId });
      if (!alive) return;
      if (error) return setMsg(friendly(error.message));
      setCons(c as Consolidation);
      if (!(c as Consolidation).ready || !(c as Consolidation).premium) return;
      const { data, error: e2 } = await supabase.rpc('get_season_retrospective_official', { p_season: seasonId });
      if (!alive) return;
      if (e2) return setMsg(friendly(e2.message));
      setRetro({ seasonId, data: data as OfficialRetro });
    })();
    return () => {
      alive = false;
    };
  }, [seasonId]);

  const evo = useEvolution(me?.id ?? '', me ? seasonId : null);
  const data = retro && retro.seasonId === seasonId ? retro.data : null;
  const name = pelada?.name ?? '';

  return (
    <Screen>
      <Title>Retrospectiva</Title>
      {seasons.length > 1 && (
        <Chips options={seasons.map((s) => ({ value: s.id, label: s.name }))} value={seasonId} onChange={(v) => { setMsg(null); setCons(null); setPage(0); setSeasonId(v); }} />
      )}
      <ErrorText>{msg}</ErrorText>

      {!cons && !msg && <Skeleton height={220} />}
      {cons && !cons.premium && (
        <EmptyState title="Retrospectiva da Pelada Premium" hint="R$ 29,90/mês por pelada.">
          <Button title="Conhecer o Premium" kind="secondary" onPress={() => router.push({ pathname: '/pelada/[id]/premium', params: { id } })} />
        </EmptyState>
      )}
      {cons && cons.premium && !cons.ready && (
        <EmptyState
          title={cons.calendar_closed ? 'Temporada em consolidação' : 'Temporada em andamento'}
          hint={
            cons.calendar_closed
              ? `Falta resolver ${[cons.pending_matches ? `${cons.pending_matches} partida(s)` : null, cons.pending_votes ? `${cons.pending_votes} votação(ões)` : null].filter(Boolean).join(' e ')}.`
              : 'A retrospectiva sai depois do encerramento.'
          }
        />
      )}

      {cons?.ready && cons.premium && !data && !msg && <Skeleton height={220} />}
      {data && (
        <>
          <View style={{ flexDirection: 'row', gap: 4 }}>
            {SCREENS.map((s, i) => (
              <View key={s} style={{ flex: 1, height: 3, borderRadius: 2, backgroundColor: i <= page ? colors.blue : colors.line }} />
            ))}
          </View>
          <View style={{ minHeight: 280, borderWidth: 1, borderColor: colors.line, borderRadius: 16, padding: 20, gap: 12, justifyContent: 'center' }}>
            <Text style={[type.meta, { textAlign: 'center' }]}>{SCREENS[page].toUpperCase()}</Text>
            <ScreenBody page={page} r={data} peladaName={name} />
          </View>
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Button title="Anterior" kind="secondary" disabled={page === 0} onPress={() => setPage(page - 1)} />
            </View>
            <View style={{ flex: 1 }}>
              <Button title="Próxima" disabled={page === SCREENS.length - 1} onPress={() => setPage(page + 1)} />
            </View>
          </View>
          <Sub>{`Versão oficial ${data.version}`}</Sub>

          <Section>Artes da pelada</Section>
          {COLLECTIVE.filter((a) => a.id !== 'P07' || AWARD_CATEGORIES.some((c) => data.season_awards?.[c]?.winners.length)).map((a) => (
            <ArtShare key={a.id} id={a.id} label={a.label} r={data} name={name} crest={pelada?.crest_path ?? null} />
          ))}
          {data.me && me && (
            <>
              <Section>Minhas artes</Section>
              {INDIVIDUAL.filter((a) => a.id !== 'I06' || myAwardTitles(data, me.id).length > 0).map((a) => (
                <ArtShare
                  key={a.id}
                  id={a.id}
                  label={a.label}
                  r={data}
                  name={name}
                  crest={pelada?.crest_path ?? null}
                  playerName={me.player_name}
                  myMembershipId={me.id}
                  myPhotoPath={myPhoto}
                  evolution={(evo.data?.points ?? []).map((p) => p.overall).filter((v): v is number => v !== null)}
                />
              ))}
            </>
          )}
        </>
      )}
    </Screen>
  );
}

function ArtShare(props: {
  id: ArtId; label: string; r: OfficialRetro; name: string; crest: string | null; playerName?: string; evolution?: number[];
  myMembershipId?: string | null; myPhotoPath?: string | null;
}) {
  return (
    <SharePanel label={`${props.id} · ${props.label}`} fileName={`minuto91-${props.id.toLowerCase()}`} title={props.label}>
      <RetroArt
        id={props.id}
        retro={props.r}
        peladaName={props.name}
        crestPath={props.crest}
        playerName={props.playerName}
        evolution={props.evolution}
        myMembershipId={props.myMembershipId}
        myPhotoPath={props.myPhotoPath}
      />
    </SharePanel>
  );
}

const top = (list: RetroTop[], unit: string) =>
  list.length === 0 ? '—' : list.filter((t) => (t.rank ?? 1) === (list[0].rank ?? 1) && t.value === list[0].value).map((t) => t.name).join(', ') + ` · ${list[0].value} ${unit}`;

function Line({ k, v }: { k: string; v: string }) {
  return (
    <View style={{ alignItems: 'center', gap: 2 }}>
      <Text style={[type.meta, { color: colors.darkGold }]}>{k}</Text>
      <Text style={[type.body, { textAlign: 'center', fontWeight: '700' }]}>{v}</Text>
    </View>
  );
}

function ScreenBody({ page, r, peladaName }: { page: number; r: OfficialRetro; peladaName: string }) {
  const big = { fontSize: 40, fontWeight: '900' as const, color: colors.blue, textAlign: 'center' as const };
  switch (page) {
    case 0:
      return (
        <>
          <Text style={big}>{r.season.name}</Text>
          <Text style={[type.body, { textAlign: 'center' }]}>{peladaName}</Text>
        </>
      );
    case 1:
      return (
        <>
          <Line k="PARTIDAS" v={String(r.matches)} />
          <Line k="GOLS" v={String(r.goals)} />
          <Line k="MESES COM REI" v={String(r.kings.length)} />
        </>
      );
    case 2:
      return (
        <>
          <Line k="ARTILHEIRO" v={top(r.scorers, 'gols')} />
          <Line k="GARÇOM" v={top(r.assisters, 'assistências')} />
        </>
      );
    case 3:
      return r.craques.length > 0 ? <Line k="MAIS VEZES CRAQUE DA PARTIDA" v={top(r.craques, '×')} /> : <Sub>Sem Craque oficial nesta temporada.</Sub>;
    case 4:
      return r.selection_leaders.length > 0 ? (
        <>
          {r.selection_leaders.slice(0, 5).map((t) => (
            <Line key={t.membership_id} k={`${t.value}× NA SELEÇÃO`} v={t.name} />
          ))}
        </>
      ) : (
        <Sub>Sem Seleção da Rodada publicada.</Sub>
      );
    case 5:
      return (
        <>
          {r.biggest_win && <Line k="MAIOR GOLEADA" v={`${r.biggest_win.team_a_name} ${r.biggest_win.team_a_score}–${r.biggest_win.team_b_score} ${r.biggest_win.team_b_name}`} />}
          {r.most_goals && <Line k="MAIS GOLS" v={`${r.most_goals.team_a_name} ${r.most_goals.team_a_score}–${r.most_goals.team_b_score} ${r.most_goals.team_b_name}`} />}
          {!r.biggest_win && !r.most_goals && <Sub>Sem partidas memoráveis.</Sub>}
        </>
      );
    case 6: {
      const rec = (r.records ?? {}) as Record<string, { value: number | null } | null>;
      const rows = [
        ['MAIS GOLS NUMA PARTIDA', rec.most_goals_in_match?.value],
        ['MAIOR SEQUÊNCIA DE VITÓRIAS', rec.best_win_streak?.value],
        ['MAIOR INVENCIBILIDADE', rec.best_unbeaten_streak?.value],
      ].filter(([, v]) => v !== null && v !== undefined) as [string, number][];
      return rows.length ? <>{rows.map(([k, v]) => <Line key={k} k={k} v={String(v)} />)}</> : <Sub>Sem recordes registrados.</Sub>;
    }
    case 7: {
      const cats = AWARD_CATEGORIES.filter((c) => r.season_awards?.[c]?.winners.length);
      return cats.length ? (
        <>
          {cats.map((c) => (
            <Line
              key={c}
              k={SEASON_AWARD_LABEL[CATEGORY_TYPE[c]].toUpperCase()}
              v={`${r.season_awards![c]!.winners.map((w) => `${w.name} · ${statText(c, w.value)}`).join(', ')}${r.season_awards![c]!.winners.length > 1 ? ` (${sharedLabel(true).toLowerCase()})` : ''}`}
            />
          ))}
          {r.season_awards?.golden_glove && <Sub>A REF da Luva de Ouro usa as últimas 20 partidas do goleiro e pode incluir temporadas anteriores.</Sub>}
        </>
      ) : (
        <Sub>Sem prêmios de temporada publicados.</Sub>
      );
    }
    default:
      return <Text style={[big, { fontSize: 26 }]}>Até a próxima temporada</Text>;
  }
}
