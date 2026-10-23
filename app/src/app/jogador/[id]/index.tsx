import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, View } from 'react-native';
import { Text } from '../../../lib/text';

import { CardArt, PlayerCard, SharePanel } from '../../../lib/arts';
import { Avatar } from '../../../lib/avatar';
import {
  cardAttributes,
  isV2,
  AWARD_LABEL,
  Card as CardData,
  currentSeason,
  fmtMonth,
  loadCard,
  loadReadableSeasons,
  plural,
  Season,
  SeasonStats,
  TIER,
} from '../../../lib/career';
import { EvolutionChart, useEvolution } from '../../../lib/evolution';
import { friendly } from '../../../lib/errors';
import { fmtRating } from '../../../lib/match';
import { ReportLink } from '../../../lib/report';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, footLabel, memberPosition, needsPositionUpdate, Position, positionLabel, positionSector } from '../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, PositionPicker, Screen, Sub, Title } from '../../../lib/ui';

type Membership = {
  id: string;
  pelada_id: string;
  user_id: string | null;
  player_name: string;
  preferred_position: string;
  position_code: string | null;
  status: string;
};

type Profile = { avatar_path: string | null; dominant_foot: string | null };

export default function Carta() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const { session } = useAuth();
  const [blocked, setBlocked] = useState(false);
  const [globalVisible, setGlobalVisible] = useState(false);
  const [member, setMember] = useState<Membership | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [newPos, setNewPos] = useState<Position | null>(null);
  const [posBusy, setPosBusy] = useState(false);
  const [allPos, setAllPos] = useState(false);
  const [posOk, setPosOk] = useState<string | null>(null);
  const [peladaName, setPeladaName] = useState('');
  const [crestPath, setCrestPath] = useState<string | null>(null);
  const [seasons, setSeasons] = useState<Season[]>([]);
  const [seasonId, setSeasonId] = useState<string | null>(null);
  const [card, setCard] = useState<CardData | null>(null);
  const [stats, setStats] = useState<SeasonStats | null>(null);
  const [awards, setAwards] = useState<Record<string, number>>({});
  const [loaded, setLoaded] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const evo = useEvolution(id, seasonId);

  useEffect(() => {
    (async () => {
      const { data: m, error } = await supabase
        .from('pelada_memberships')
        .select('id, pelada_id, user_id, player_name, preferred_position, position_code, status')
        .eq('id', id)
        .maybeSingle();
      if (error || !m) return setMsg(error ? friendly(error.message) : 'Jogador não encontrado.');
      setMember(m as Membership);
      const { data: p } = await supabase.from('peladas').select('name, crest_path').eq('id', m.pelada_id).maybeSingle();
      setPeladaName(p?.name ?? '');
      setCrestPath(p?.crest_path ?? null);
      if (m.user_id) {
        // Foto: pelada em comum, sem bloqueio (RLS). Pé: só se o perfil global for visível (029).
        const [{ data: pr }, { data: gp }] = await Promise.all([
          supabase.from('profiles').select('avatar_path').eq('id', m.user_id).maybeSingle(),
          supabase.rpc('get_player_profile', { p_user: m.user_id }),
        ]);
        if (pr) setProfile({ avatar_path: pr.avatar_path, dominant_foot: gp?.visible ? gp.dominant_foot : null });
        setGlobalVisible(!!gp?.visible);
        const { data: b } = await supabase.from('user_blocks').select('blocked_user_id').eq('blocked_user_id', m.user_id);
        setBlocked((b ?? []).length > 0);
      }
      const ss = await loadReadableSeasons(m.pelada_id); // A06: só as temporadas que o plano libera
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
  const seasonStart = seasons.find((x) => x.id === seasonId)?.starts_on ?? null;
  const photoPath = member.status === 'retired' ? null : profile?.avatar_path;

  // RN-068: a posição do perfil vale a partir da próxima partida; a carta mostra a da última jogada.
  // V4.3: a carta mostra a sigla atual quando é do mesmo setor (mudar de ZAG para LD não muda o Card).
  const current = memberPosition(member);
  const shownCard = card ? { ...card, position_code: member.position_code } : null;
  const pendingPos = card && card.position !== member.preferred_position ? current : null;
  const legacy = needsPositionUpdate(member);

  async function salvarPosicao() {
    if (!member || !newPos) return;
    setPosBusy(true);
    setMsg(null);
    setPosOk(null);
    const { error } = await supabase.rpc('set_my_position', { p_pelada: member.pelada_id, p_position: newPos });
    // V5: depois da primeira partida oficial a troca vira um pedido ao administrador.
    if (error?.message.includes('POSITION_CHANGE_NEEDS_ADMIN')) {
      const req = await supabase.rpc('request_position_change', { p_pelada: member.pelada_id, p_position: newPos });
      setPosBusy(false);
      if (req.error) return setMsg(friendly(req.error.message));
      setNewPos(null);
      return setPosOk(`Pedido enviado ao administrador: ${positionLabel(newPos)}. A posição muda quando ele aprovar.`);
    }
    setPosBusy(false);
    if (error) return setMsg(friendly(error.message));
    setMember({ ...member, preferred_position: positionSector(newPos) ?? member.preferred_position, position_code: newPos });
    setNewPos(null);
    setPosOk(`Posição alterada para ${positionLabel(newPos)}. Vale a partir da próxima partida.`);
  }

  return (
    <Screen>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
        {/* Com carta na tela, a foto já aparece nela. */}
        {!card && <Avatar path={photoPath} name={member.player_name} size={72} />}
        <View style={{ flex: 1, gap: 2 }}>
          <Title>{member.player_name}</Title>
          <Sub>
            {positionLabel(shownCard && !pendingPos ? (shownCard.position_code ?? shownCard.position) : current)}
            {profile?.dominant_foot ? ` · ${footLabel(profile.dominant_foot)}` : ''}
          </Sub>
          {pendingPos && <Sub>Próxima partida: {positionLabel(pendingPos)}</Sub>}
        </View>
      </View>
      {seasons.length > 1 && (
        <Chips options={seasons.map((s) => ({ value: s.id, label: s.name }))} value={seasonId} onChange={(v) => { setLoaded(false); setSeasonId(v); }} />
      )}
      <ErrorText>{msg}</ErrorText>

      {member.status === 'retired' ? (
        <Sub>Aposentado: este registro não tem Card.</Sub>
      ) : !loaded ? (
        <Sub>Carregando...</Sub>
      ) : !card || !tier ? (
        <Card>
          <Body>Ainda sem Card nesta temporada.</Body>
          <Sub>O Card aparece depois da primeira partida finalizada.</Sub>
        </Card>
      ) : (
        <>
          <View style={{ alignItems: 'center' }}>
            <PlayerCard
              card={shownCard!}
              playerName={member.player_name}
              photoPath={photoPath}
              peladaName={peladaName}
              crestPath={crestPath}
              seasonName={seasonName}
              seasonStart={seasonStart}
            />
          </View>
          {card.is_provisional && (
            <Sub>
              {isV2(card)
                ? 'Avaliação em andamento: o OVR aparece a partir da 5ª partida oficial nesta pelada.'
                : `Card provisório: ${card.matches_played} de 5 jogos na temporada.`}
            </Sub>
          )}
          <Card>
            {cardAttributes(card).map((a) => {
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
            <SharePanel label="Compartilhar meu Card" fileName="minuto91-card" title="Meu Card">
              <CardArt peladaName={peladaName} crestPath={crestPath} seasonName={seasonName} seasonStart={seasonStart} playerName={member.player_name} photoPath={photoPath} card={shownCard!} />
            </SharePanel>
          )}
        </>
      )}

      {stats && member.status !== 'retired' && (
        <Card>
          <Body>Números da temporada</Body>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
            <Stat label="Partidas" value={String(stats.matches_played)} />
            <Stat label="Gols" value={String(stats.goals)} />
            <Stat label="Assistências" value={String(stats.assists)} />
            <Stat label="Gols por partida" value={perMatch(stats.goals, stats.matches_played)} />
            <Stat label="Assist. por partida" value={perMatch(stats.assists, stats.matches_played)} />
            <Stat label="Participações em gols" value={String(stats.goals + stats.assists)} />
            <Stat label="Craque da Partida" value={String(stats.craque_awards)} gold={stats.craque_awards > 0} />
            <Stat label="Rei do Mês" value={String(evo.data?.monthly_king.length ?? awards.monthly_king ?? 0)} gold={(evo.data?.monthly_king.length ?? awards.monthly_king ?? 0) > 0} />
          </View>
          {(evo.data?.monthly_king.length ?? 0) > 0 && (
            <Sub>Rei do Mês: {evo.data!.monthly_king.map(fmtMonth).join(', ')}</Sub>
          )}
          {stats.matches_played > 0 && stats.matches_played < 5 && (
            <Sub>Amostra pequena: {plural(stats.matches_played, 'partida', 'partidas')}. As médias ficam mais estáveis com mais jogos.</Sub>
          )}
          <Sub>
            {stats.wins}V {stats.draws}E {stats.losses}D
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

      {card && member.status !== 'retired' && (
        <Card>
          <Body>Evolução na temporada</Body>
          {evo.error ? <Sub>{evo.error}</Sub> : evo.data ? <EvolutionChart evolution={evo.data} /> : <Sub>Carregando...</Sub>}
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

      {isMe && member.status === 'active' && (
        <Card>
          <Body>Minha posição nesta pelada</Body>
          {legacy ? (
            <Text style={{ color: colors.darkGold, fontWeight: '600' }}>
              Atualize sua posição: o Minuto 91 agora tem dez posições. Você está como {positionLabel(member.preferred_position)}; escolha
              a posição específica abaixo. Seu Card, suas estatísticas e o histórico não mudam.
            </Text>
          ) : null}
          <Sub>
            O setor da posição (goleiro, defesa, meio-campo, ataque) define os pesos do seu Card. Trocar dentro do mesmo setor
            (ex.: ZAG para LD) não muda o Card. Trocar de setor vale a partir da próxima partida: as partidas já jogadas
            continuam com a posição da época, e seu overall pode mudar por causa da nova função, não só do desempenho.
          </Sub>
          <PositionPicker value={newPos ?? current} onChange={setNewPos} sector={legacy && !allPos ? positionSector(member.preferred_position) : undefined} />
          {legacy && !allPos && (
            <Pressable onPress={() => setAllPos(true)} accessibilityRole="button" style={{ minHeight: 44, justifyContent: 'center' }}>
              <Text style={{ color: colors.blue, fontWeight: '600' }}>Mudou de setor? Ver todas as posições</Text>
            </Pressable>
          )}
          {newPos && newPos !== member.position_code && (
            <Button title={`Mudar para ${positionLabel(newPos)}`} onPress={salvarPosicao} loading={posBusy} />
          )}
          {posOk && <Text style={{ color: colors.deepBlue, fontWeight: '600' }}>{posOk}</Text>}
        </Card>
      )}

      {member.user_id && member.status !== 'retired' && (isMe || globalVisible) && (
        <Button
          title={isMe ? 'Meu perfil e carreira' : 'Ver perfil e carreira'}
          kind="secondary"
          onPress={() =>
            isMe
              ? router.push('/perfil')
              : router.push({ pathname: '/atleta/[id]', params: { id: member.user_id!, name: member.player_name } })
          }
        />
      )}

      <Button
        title="Ver álbum de figurinhas"
        kind="secondary"
        onPress={() => router.push({ pathname: '/jogador/[id]/album', params: { id } })}
      />
      {member.status !== 'retired' && (
        <Button
          title="Comparar no Duelo"
          kind="secondary"
          onPress={() => router.push({ pathname: '/pelada/[id]/duelo', params: { id: member.pelada_id, a: member.id } })}
        />
      )}

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

// Média por partida com duas casas (pt-BR). Correta desde o primeiro jogo; sem jogos, "–".
const perMatch = (n: number, matches: number) => (matches ? (n / matches).toFixed(2).replace('.', ',') : '–');

function Stat({ label, value, gold }: { label: string; value: string; gold?: boolean }) {
  return (
    <View
      style={{
        flexBasis: '47%',
        flexGrow: 1,
        borderRadius: 10,
        borderWidth: 1,
        borderColor: gold ? colors.gold : colors.line,
        paddingVertical: 8,
        paddingHorizontal: 10,
        gap: 2,
      }}>
      <Text style={{ fontSize: 20, fontWeight: '800', color: gold ? colors.darkGold : colors.deepBlue, fontVariant: ['tabular-nums'] }}>{value}</Text>
      <Text style={{ fontSize: 12, color: colors.muted }}>{label}</Text>
    </View>
  );
}
