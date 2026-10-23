import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { View } from 'react-native';
import { Text } from '../../../lib/text';

import { RetroPeladaArt, RetroPlayerArt, RetroRankingsArt, SharePanel } from '../../../lib/arts';
import { fmtMonth, loadReadableSeasons, plural, Season } from '../../../lib/career';
import { todayIn } from '../../../lib/dates';
import { friendly } from '../../../lib/errors';
import { fmtDate } from '../../../lib/match';
import { PlayerCard } from '../../../lib/playercard';
import { loadRetro, Retro, Top } from '../../../lib/retro';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors } from '../../../lib/theme';
import { Body, Card, Chips, ErrorText, Screen, Sub, Title } from '../../../lib/ui';

// Datas da temporada vêm sem hora (AAAA-MM-DD): meio-dia evita cair no dia anterior pelo fuso.
const fmtDay = (d: string) => new Date(`${d}T12:00:00`).toLocaleDateString('pt-BR');
const MIN_MATCHES = 3; // com menos que isso a retrospectiva avisa que tem poucos dados

// Retrospectiva da temporada: a história da pelada e a sua temporada nela, com artes para compartilhar.
// Acesso igual ao dos rankings (RN-083): grátis vê a temporada atual e a anterior; o Premium da pelada vê
// todas e libera a arte especial (rankings da temporada). As estatísticas básicas nunca são bloqueadas.
export default function Retrospectiva() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const uid = session?.user.id;
  const [seasons, setSeasons] = useState<Season[]>([]);
  const [seasonId, setSeasonId] = useState<string | null>(null);
  const [premium, setPremium] = useState(false);
  const [pelada, setPelada] = useState<{ name: string; crest_path: string | null } | null>(null);
  const [me, setMe] = useState<{ id: string; player_name: string } | null>(null);
  const [photo, setPhoto] = useState<string | null>(null);
  // A14: o resultado guarda a temporada a que pertence; ao trocar de temporada, nada da anterior aparece
  // (nem na tela nem na arte) até a nova chegar.
  const [loadedRetro, setLoadedRetro] = useState<{ seasonId: string; data: Retro } | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const today = todayIn();
      const [ss, { data: ent }, { data: p }, { data: m }, { data: pr }] = await Promise.all([
        loadReadableSeasons(id),
        supabase.rpc('get_pelada_entitlement', { p_pelada: id }),
        supabase.from('peladas').select('name, crest_path').eq('id', id).maybeSingle(),
        supabase.from('pelada_memberships').select('id, player_name').eq('pelada_id', id).eq('user_id', uid ?? '').maybeSingle(),
        supabase.from('profiles').select('avatar_path').eq('id', uid ?? '').maybeSingle(),
      ]);
      if (!alive) return;
      const started = ss.filter((s) => s.starts_on <= today);
      setPremium(!!ent?.is_premium);
      // O servidor já devolve só as liberadas (grátis: atual e anterior); o corte fica como segurança.
      const visible = ent?.is_premium ? started : started.slice(0, 2);
      setSeasons(visible);
      setSeasonId(visible[0]?.id ?? null);
      setPelada(p);
      setMe(m);
      setPhoto(pr?.avatar_path ?? null);
    })().catch((e) => alive && setMsg(friendly((e as Error).message)));
    return () => {
      alive = false;
    };
  }, [id, uid]);

  useEffect(() => {
    if (!seasonId) return;
    let alive = true;
    (async () => {
      const r = await loadRetro(id, seasonId, me?.id ?? null);
      if (alive) setLoadedRetro({ seasonId, data: r });
    })().catch((e) => alive && setMsg(friendly((e as Error).message)));
    return () => {
      alive = false;
    };
  }, [id, seasonId, me?.id]);

  const season = seasons.find((s) => s.id === seasonId);
  const retro = loadedRetro && loadedRetro.seasonId === seasonId ? loadedRetro.data : null;
  const today = todayIn();
  const partial = !!season && season.ends_on >= today;
  const name = pelada?.name ?? '';
  const p = retro?.pelada;

  return (
    <Screen>
      <Title>Retrospectiva</Title>
      <ErrorText>{msg}</ErrorText>
      {seasons.length > 1 && (
        <Chips options={seasons.map((s) => ({ value: s.id, label: s.name }))} value={seasonId ?? ''} onChange={(v) => { setMsg(null); setSeasonId(v); }} />
      )}
      {!premium && <Sub>Temporadas mais antigas aparecem na Pelada Premium.</Sub>}
      {season && (
        <Sub>
          {fmtDay(season.starts_on)} a {fmtDay(season.ends_on)}
          {partial ? ' · temporada em andamento: números parciais' : ' · temporada encerrada'}
        </Sub>
      )}
      {!retro && !msg && <Sub>Carregando...</Sub>}

      {p && p.matches === 0 && (
        <Card>
          <Body>Ainda não há partidas finalizadas nesta temporada.</Body>
          <Sub>A retrospectiva aparece depois da primeira partida finalizada.</Sub>
        </Card>
      )}

      {p && p.matches > 0 && (
        <>
          {p.matches < MIN_MATCHES && <Sub>Poucas partidas até agora: a retrospectiva fica mais completa com o tempo.</Sub>}
          <Text style={section}>A temporada da pelada</Text>
          <Card>
            <Body>
              {plural(p.matches, 'partida', 'partidas')} · {plural(p.goals, 'gol', 'gols')}
            </Body>
            {p.biggestWin && (
              <Sub>
                Maior placar: {p.biggestWin.team_a_name} {p.biggestWin.team_a_score} x {p.biggestWin.team_b_score}{' '}
                {p.biggestWin.team_b_name} ({fmtDate(p.biggestWin.played_at)})
              </Sub>
            )}
            {p.mostGoals && p.mostGoals.id !== p.biggestWin?.id && (
              <Sub>
                Jogo com mais gols: {p.mostGoals.team_a_score} x {p.mostGoals.team_b_score} ({fmtDate(p.mostGoals.played_at)})
              </Sub>
            )}
          </Card>
          <TopCard title="Artilharia" rows={p.scorers} unit={['gol', 'gols']} />
          <TopCard title="Garçons" rows={p.assisters} unit={['assistência', 'assistências']} />
          <TopCard title="Craque da Partida" rows={p.craques} unit={['vez', 'vezes']} />
          <TopCard title="Mais presentes" rows={p.presence} unit={['jogo', 'jogos']} />
          {p.kings.length > 0 && (
            <Card>
              <Body>Reis do Mês</Body>
              {p.kings.map((k) => (
                <Sub key={k.month}>
                  {fmtMonth(k.month)}: {k.names.join(', ')}
                </Sub>
              ))}
            </Card>
          )}
          {p.bolaMurcha.length > 0 && (
            <Card>
              <Body>Bola Murcha</Body>
              <Sub>Quem mais recebeu na temporada (fica só aqui, não vai para as artes).</Sub>
              {p.bolaMurcha.map((r) => (
                <Sub key={r.membershipId}>
                  {r.name}: {plural(r.value, 'vez', 'vezes')}
                </Sub>
              ))}
            </Card>
          )}

          <SharePanel label="Compartilhar retrospectiva da pelada" fileName="minuto91-retrospectiva" title="Retrospectiva da pelada">
            <RetroPeladaArt peladaName={name} crestPath={pelada?.crest_path} seasonName={season?.name ?? ''} partial={partial} retro={p} />
          </SharePanel>
          {premium ? (
            <SharePanel label="Compartilhar rankings da temporada" fileName="minuto91-rankings-temporada" title="Rankings da temporada">
              <RetroRankingsArt peladaName={name} crestPath={pelada?.crest_path} seasonName={season?.name ?? ''} partial={partial} retro={p} />
            </SharePanel>
          ) : (
            <Sub>A arte especial com os rankings da temporada é da Pelada Premium.</Sub>
          )}

          <Text style={section}>Sua temporada</Text>
          {!retro?.me && <Sub>Você não jogou nenhuma partida finalizada nesta temporada.</Sub>}
          {retro?.me && me && (
            <>
              <Card>
                <Body>
                  {plural(retro.me.matches, 'jogo', 'jogos')} · {plural(retro.me.goals, 'gol', 'gols')} ·{' '}
                  {plural(retro.me.assists, 'assistência', 'assistências')}
                </Body>
                <Sub>
                  {plural(retro.me.wins, 'vitória', 'vitórias')} · {plural(retro.me.draws, 'empate', 'empates')} ·{' '}
                  {plural(retro.me.losses, 'derrota', 'derrotas')}
                </Sub>
                {retro.me.craque > 0 && <Sub>Craque da Partida: {plural(retro.me.craque, 'vez', 'vezes')}</Sub>}
                {retro.me.kings > 0 && <Sub>Rei do Mês: {plural(retro.me.kings, 'vez', 'vezes')}</Sub>}
              </Card>
              {retro.me.card && (
                <View style={{ alignItems: 'center' }}>
                  <PlayerCard
                    card={retro.me.card}
                    playerName={me.player_name}
                    photoPath={photo}
                    peladaName={name}
                    crestPath={pelada?.crest_path}
                    seasonName={season?.name ?? ''}
                    seasonStart={season?.starts_on}
                    width={220}
                  />
                </View>
              )}
              <SharePanel label="Compartilhar minha temporada" fileName="minuto91-minha-temporada" title="Minha temporada">
                <RetroPlayerArt
                  peladaName={name}
                  crestPath={pelada?.crest_path}
                  seasonName={season?.name ?? ''}
                  partial={partial}
                  playerName={me.player_name}
                  photoPath={photo}
                  me={retro.me}
                />
              </SharePanel>
            </>
          )}
        </>
      )}
    </Screen>
  );
}

function TopCard({ title, rows, unit }: { title: string; rows: Top[]; unit: [string, string] }) {
  if (!rows.length) return null;
  return (
    <Card>
      <Body>{title}</Body>
      {rows.map((r) => (
        <Sub key={r.membershipId}>
          {r.rank}. {r.name}: {plural(r.value, unit[0], unit[1])}
        </Sub>
      ))}
    </Card>
  );
}

const section = { fontSize: 19, lineHeight: 25, fontWeight: '700' as const, color: colors.deepBlue, marginTop: 10 };
