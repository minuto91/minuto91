import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { useWindowDimensions, View } from 'react-native';
import { Text } from '../../../lib/text';

import { AnnulledBadge, AnnulMatch, MatchStatusTimeline, RestoreMatch } from '../../../lib/annul';
import {
  FORMATION,
  PostGameArt,
  PostGameArtData,
  ResultArt,
  ResultArtData,
  SelectionArt,
  SharePanel,
} from '../../../lib/arts';
import { friendly } from '../../../lib/errors';
import { Formation } from '../../../lib/formation';
import { LineupArt, LineupBoard, LineupPlayer, TeamFormations } from '../../../lib/lineup';
import {
  fmtDate,
  fmtRating,
  fmtTime,
  Guest,
  loadGuests,
  loadMatch,
  loadMembers,
  loadSheet,
  Match,
  Member,
  SheetPlayer,
  scoreLine,
  STATUS_LABEL,
  Team,
  TeamExtras,
} from '../../../lib/match';
import { HardSaves } from '../../../lib/ratingadmin';
import { RatingVotePanel } from '../../../lib/ratingvote';
import { ReportLink } from '../../../lib/report';
import { FieldPlayer, SelectionField, TeamColorPicker, TeamLegend, teamHex } from '../../../lib/selection';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, positionLabel } from '../../../lib/theme';
import { Body, Button, Card, ErrorText, Screen, Sub } from '../../../lib/ui';
import { MatchScore } from '../../../lib/domain';

type Session = {
  id: string;
  status: string;
  closes_at: string;
  eligible_voter_count: number;
  is_valid: boolean | null;
};
type Result = { membership_id: string; final_rating: number | null; has_valid_rating: boolean };
type Award = { membership_id: string; award_type: string; is_shared: boolean };
type SelectionPlayer = { membership_id: string; slot_position: string; rank_order: number };

export default function Partida() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session: auth } = useAuth();
  const uid = auth?.user.id;
  const router = useRouter();
  const { width: screenW } = useWindowDimensions();
  const [match, setMatch] = useState<Match | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [guests, setGuests] = useState<Guest[]>([]);
  const [players, setPlayers] = useState<SheetPlayer[]>([]);
  const [extras, setExtras] = useState<TeamExtras | null>(null);
  const [voting, setVoting] = useState<Session | null>(null);
  const [eligible, setEligible] = useState<string[]>([]);
  const [voted, setVoted] = useState<string[]>([]);
  const [results, setResults] = useState<Result[]>([]);
  const [awards, setAwards] = useState<Award[]>([]);
  const [statusKey, setStatusKey] = useState(0);
  const [peladaName, setPeladaName] = useState('');
  const [crestPath, setCrestPath] = useState<string | null>(null);
  const [myPhoto, setMyPhoto] = useState<string | null>(null);
  const [selection, setSelection] = useState<SelectionPlayer[] | null>(null);
  // V4.6 (049): cor de cada time nesta partida (escolhida na súmula); sem cor = borda neutra.
  const [teamColors, setTeamColors] = useState<{ A: string | null; B: string | null }>({ A: null, B: null });
  // Escalação depois do jogo (grátis, V4.2): os dois times da súmula oficial.
  const [lineup, setLineup] = useState<{ team_a_name: string; team_b_name: string; players: LineupPlayer[]; formations: TeamFormations } | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const m = await loadMatch(id);
      if (!m) return setMsg('Partida não encontrada.');
      const [ms, gs, sheet, { data: ss }, { data: pl }] = await Promise.all([
        loadMembers(m.pelada_id),
        loadGuests(m.pelada_id),
        loadSheet(id),
        supabase
          .from('voting_sessions')
          .select('id, status, closes_at, eligible_voter_count, is_valid')
          .eq('match_id', id)
          .neq('status', 'cancelled')
          .order('created_at', { ascending: false })
          .limit(1),
        supabase.from('peladas').select('name, crest_path').eq('id', m.pelada_id).maybeSingle(),
      ]);
      // Banco sem a 049 (colunas novas) não quebra a tela: fica sem cor.
      const { data: tc } = await supabase.from('matches').select('team_a_color, team_b_color').eq('id', id).maybeSingle();
      setTeamColors({ A: teamHex(tc?.team_a_color), B: teamHex(tc?.team_b_color) });
      setPeladaName(pl?.name ?? '');
      setCrestPath(pl?.crest_path ?? null);
      // Foto da própria pessoa, para a arte pós-jogo.
      if (uid) {
        const { data: pr } = await supabase.from('profiles').select('avatar_path').eq('id', uid).maybeSingle();
        setMyPhoto(pr?.avatar_path ?? null);
      }
      const s = (ss?.[0] ?? null) as Session | null;
      setMatch(m);
      setMembers(ms);
      setGuests(gs);
      setPlayers(sheet.players);
      setExtras(sheet.extras);
      setVoting(s);
      if (s) {
        // Só colunas liberadas: quem pode votar e quem já votou (sem horários nem notas).
        const [{ data: el }, { data: rc }] = await Promise.all([
          supabase.from('voting_eligible_members').select('membership_id').eq('session_id', s.id),
          supabase.from('vote_receipts').select('membership_id').eq('session_id', s.id),
        ]);
        setEligible((el ?? []).map((x) => x.membership_id));
        setVoted((rc ?? []).map((x) => x.membership_id));
      }
      if (m.status === 'finalized' || m.status === 'voting_open') {
        const { data: lu } = await supabase.rpc('get_match_lineup', { p_match: id });
        // Formação só quando foi registrada e ainda corresponde à súmula oficial (o servidor confere); nunca inventada.
        const l = lu as {
          team_a_name: string;
          team_b_name: string;
          team_a_formation: Formation | null;
          team_b_formation: Formation | null;
          players: { team: 'A' | 'B'; membership_id: string | null; guest: boolean; name: string; position: string | null; avatar_path: string | null; slot: string | null }[];
        } | null;
        setLineup(
          l
            ? {
                team_a_name: l.team_a_name,
                team_b_name: l.team_b_name,
                formations: { A: l.team_a_formation, B: l.team_b_formation },
                players: l.players.map((p, i) => ({ key: p.membership_id ?? `g${i}`, team: p.team, name: p.name, position: p.position, avatar_path: p.avatar_path, guest: p.guest, slot: p.slot })),
              }
            : null,
        );
      } else setLineup(null);
      if (m.status === 'finalized') {
        const [{ data: rs }, { data: aw }, { data: sel }] = await Promise.all([
          supabase
            .from('match_player_results')
            .select('membership_id, final_rating, has_valid_rating')
            .eq('match_id', id),
          supabase.from('awards').select('membership_id, award_type, is_shared').eq('match_id', id).eq('status', 'active'),
          supabase.from('round_selections').select('id').eq('match_id', id).eq('status', 'published').maybeSingle(),
        ]);
        if (sel) {
          const { data: sp } = await supabase
            .from('round_selection_players')
            .select('membership_id, slot_position, rank_order')
            .eq('selection_id', sel.id);
          setSelection((sp ?? []) as SelectionPlayer[]);
        } else setSelection(null);
        setResults((rs ?? []) as Result[]);
        setAwards((aw ?? []) as Award[]);
      }
      setStatusKey((k) => k + 1); // linha do tempo da anulação/restauração (get_match_status_history)
      setMsg(null);
    } catch (e) {
      setMsg(friendly((e as Error).message));
    }
  }, [id, uid]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  async function encerrar() {
    setBusy(true);
    const { error } = await supabase.rpc('finalize_voting_session', { p_session: voting!.id });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    load();
  }

  if (!match || !extras) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }

  const nameOf = (membershipId: string) => members.find((m) => m.id === membershipId)?.player_name ?? 'Jogador';
  const playerName = (p: SheetPlayer) =>
    p.membership_id ? nameOf(p.membership_id) : (guests.find((g) => g.id === p.guest_id)?.display_name ?? 'Convidado');
  const me = members.find((m) => m.user_id === auth?.user.id);
  const isAdmin = me?.role === 'admin';
  const isStaff = isAdmin || me?.role === 'assistant';
  const open = match.status === 'voting_open' && voting?.status === 'open';
  const expired = open && new Date(voting!.closes_at) <= new Date();
  const iAmVoter = !!me && eligible.includes(me.id);
  const iVoted = !!me && voted.includes(me.id);
  const pending = eligible.filter((m) => !voted.includes(m));
  const awardNames = (type: string) =>
    awards
      .filter((a) => a.award_type === type)
      .map((a) => nameOf(a.membership_id))
      .join(', ');
  const ranked = results
    .filter((r) => r.has_valid_rating && r.final_rating !== null)
    .sort((a, b) => b.final_rating! - a.final_rating!);
  const posOf = (r: Result) => 1 + ranked.filter((x) => Number(x.final_rating) > Number(r.final_rating)).length;
  const ratingOf = (membershipId: string) => {
    const r = results.find((x) => x.membership_id === membershipId);
    return r?.has_valid_rating && r.final_rating !== null ? Number(r.final_rating) : null;
  };
  const date = new Date(match.played_at).toLocaleDateString('pt-BR');
  // Arte da partida: só finalizada (nada provisório). Qualquer membro pode gerar; as notas só aparecem
  // para quem as vê (o servidor não as entrega a quem não votou), então ranked fica vazio para os outros.
  const art: ResultArtData | null =
    match.status === 'finalized'
      ? {
          peladaName,
          crestPath,
          date,
          teamA: match.team_a_name,
          teamB: match.team_b_name,
          scoreA: match.team_a_score ?? 0,
          scoreB: match.team_b_score ?? 0,
          players: players.length,
          craque: awards
            .filter((a) => a.award_type === 'match_craque')
            .map((a) => ({ name: nameOf(a.membership_id), rating: ratingOf(a.membership_id) })),
          scorers: players
            .filter((p) => p.goals > 0)
            .sort((a, b) => b.goals - a.goals)
            .map((p) => ({ name: playerName(p), goals: p.goals })),
          top: ranked.slice(0, 5).map((r) => ({ pos: posOf(r), name: nameOf(r.membership_id), rating: Number(r.final_rating) })),
        }
      : null;
  // Arte pós-jogo: só a própria, de quem jogou a partida finalizada. Nota só se oficial e visível.
  const mySheet = me ? players.find((p) => p.membership_id === me.id) : undefined;
  const postGame: PostGameArtData | null =
    match.status === 'finalized' && me && mySheet
      ? {
          peladaName,
          crestPath,
          date,
          playerName: me.player_name,
          photoPath: myPhoto,
          teamA: match.team_a_name,
          teamB: match.team_b_name,
          scoreA: match.team_a_score ?? 0,
          scoreB: match.team_b_score ?? 0,
          myTeam: mySheet.team,
          goals: mySheet.goals,
          assists: mySheet.assists,
          rating: ratingOf(me.id),
          craque: awards.some((a) => a.award_type === 'match_craque' && a.membership_id === me.id),
        }
      : null;
  // Seleção 4-3-3 sem adaptação: cada linha pega os melhores daquela posição; o que faltar fica vago. Foto e sigla vêm
  // da escalação oficial da partida; a borda é a cor do time em que o jogador jogou nesta partida.
  const fieldPlayers: FieldPlayer[] = FORMATION.flatMap((line) => {
    const inLine = (selection ?? [])
      .filter((x) => x.slot_position === line.position)
      .sort((a, b) => a.rank_order - b.rank_order);
    return Array.from({ length: line.count }, (_, i): FieldPlayer => {
      const x = inLine[i];
      const pos = line.position as FieldPlayer['position'];
      if (!x) return { key: `${line.position}-${i}`, position: pos, name: null };
      const lp = lineup?.players.find((l) => l.key === x.membership_id);
      const team = players.find((p) => p.membership_id === x.membership_id)?.team ?? lp?.team ?? null;
      return {
        key: x.membership_id,
        position: pos,
        name: nameOf(x.membership_id),
        posLabel: lp?.position && lp.position.length <= 3 ? lp.position : null,
        photoPath: lp?.avatar_path ?? null,
        teamColor: team ? teamColors[team] : null,
      };
    });
  });
  const teamsLegend = [
    { name: match.team_a_name, color: teamColors.A },
    { name: match.team_b_name, color: teamColors.B },
  ];
  const matchGuests = guests.filter((g) => players.some((p) => p.guest_id === g.id));
  // V7.7: partida anulada mostra só data, equipes, rodada, status e linha do tempo (o banco já não entrega o resto).
  const annulled = match.status === 'annulled';
  const finalScore = match.team_a_score !== null && match.team_b_score !== null ? { a: match.team_a_score, b: match.team_b_score } : null;

  return (
    <Screen>
      {/* V6.2: placar editorial no topo (mesmo componente da Central e da pelada). */}
      <MatchScore
        a={match.team_a_name}
        b={match.team_b_name}
        scoreA={match.team_a_score}
        scoreB={match.team_b_score}
        mine={null}
        top={
          <Text style={{ fontSize: 12, fontWeight: '700', letterSpacing: 0.4, color: '#9DB8E8' }} numberOfLines={2}>
            {fmtDate(match.played_at).toUpperCase()} · {(STATUS_LABEL[match.status] ?? match.status).toUpperCase()}
            {match.sheet_version > 1 && !annulled ? ` · SÚMULA V${match.sheet_version}` : ''}
          </Text>
        }
      />
      <ErrorText>{msg}</ErrorText>

      {match.status === 'draft' && isStaff && (
        <Button title="Editar súmula" onPress={() => router.push({ pathname: '/partida/[id]/sumula', params: { id } })} />
      )}

      {/* V5: avaliação dos jogadores (abrir, votar, acompanhar e publicar). */}
      {match.status === 'finalized' && <RatingVotePanel matchId={match.id} />}
      {match.status === 'finalized' && isStaff && (
        <HardSaves
          matchId={match.id}
          keepers={players
            .filter((p) => p.participant_id && (p.position === 'GOL' || p.position === 'goalkeeper'))
            .map((p) => ({ participant_id: p.participant_id!, name: p.membership_id ? nameOf(p.membership_id) : (guests.find((g) => g.id === p.guest_id)?.display_name ?? 'Convidado') }))}
        />
      )}

      {open && (
        <Card>
          <Body>
            {expired
              ? 'O prazo da votação acabou.'
              : `Votação até ${fmtTime(voting!.closes_at)} de ${fmtDate(voting!.closes_at)}.`}
          </Body>
          <Sub>
            {voted.length} de {voting!.eligible_voter_count} já votaram.
            {pending.length > 0 ? ` Falta: ${pending.map(nameOf).join(', ')}.` : ''}
          </Sub>
          {iAmVoter && !expired && (
            <Button
              title={iVoted ? 'Editar meu voto' : 'Votar'}
              onPress={() => router.push({ pathname: '/partida/[id]/votar', params: { id } })}
            />
          )}
          {iVoted && <Sub>Seu voto foi enviado. Você pode mudar até o fim do prazo.</Sub>}
          {expired && <Button title="Encerrar votação" onPress={encerrar} loading={busy} />}
          {isStaff && !expired && (
            <Button
              title="Corrigir súmula"
              kind="secondary"
              onPress={() => router.push({ pathname: '/partida/[id]/sumula', params: { id } })}
            />
          )}
        </Card>
      )}

      {match.status === 'finalized' && (
        <Card>
          {/* V6.1: desde a V5 a súmula publicada finaliza sem a cédula antiga; a avaliação fica no painel acima. */}
          {!voting && <Sub>Resultado oficial. Contam gols, assistências e presença.</Sub>}
          {voting && voting.is_valid === false && (
            // Votação no formato antigo (antes da V5) encerrada sem votos suficientes. Não é regra das votações atuais.
            <Sub>Votação antiga sem votos suficientes: sem notas oficiais nem prêmios da votação nesta partida.</Sub>
          )}
          {awardNames('match_craque') !== '' && <Body>Craque da Partida: {awardNames('match_craque')}</Body>}
          {awardNames('bola_murcha') !== '' && <Body>Bola Murcha: {awardNames('bola_murcha')}</Body>}
          {voting?.is_valid && results.length === 0 && iAmVoter && !iVoted && (
            <Sub>Você não votou, então o resultado detalhado desta partida fica bloqueado para você.</Sub>
          )}
          {ranked.map((r) => (
            <Text key={r.membership_id} style={{ color: colors.ink }}>
              {/* Empate = mesma posição (1º, 1º, 3º), pelo valor oficial (RN-073). */}
              {posOf(r)}º {nameOf(r.membership_id)} —{' '}
              {fmtRating(Number(r.final_rating))}
            </Text>
          ))}
          {/* V5: sem nota fictícia; só a mensagem, nunca quantos votos o jogador recebeu. */}
          {ranked.length > 0 &&
            results
              .filter((r) => !r.has_valid_rating)
              .map((r) => (
                <Text key={r.membership_id} style={{ color: colors.muted }}>
                  {nameOf(r.membership_id)} — Avaliação insuficiente
                </Text>
              ))}
        </Card>
      )}

      {postGame && (
        <SharePanel label="Compartilhar meu pós-jogo" fileName="minuto91-pos-jogo" title="Meu pós-jogo">
          <PostGameArt data={postGame} />
        </SharePanel>
      )}
      {art && (
        <SharePanel label="Compartilhar resultado" fileName="minuto91-resultado" title="Resultado da partida">
          <ResultArt data={art} />
        </SharePanel>
      )}

      {selection && (
        <Card>
          <Body>Seleção da Rodada</Body>
          <View style={{ alignItems: 'center', gap: 10, marginTop: 4 }}>
            <SelectionField players={fieldPlayers} width={Math.min(320, screenW - 74)} />
            <TeamLegend teams={teamsLegend} />
          </View>
        </Card>
      )}
      {selection && isStaff && match.status === 'finalized' && (
        <Card>
          <TeamColorPicker matchId={match.id} teamA={match.team_a_name} teamB={match.team_b_name} onSaved={setTeamColors} />
        </Card>
      )}
      {selection && ranked.length > 0 && (
        <SharePanel label="Compartilhar Seleção da Rodada" fileName="minuto91-selecao" title="Seleção da Rodada">
          <SelectionArt peladaName={peladaName} crestPath={crestPath} date={date} matchLabel={scoreLine(match)} players={fieldPlayers} teams={teamsLegend} />
        </SharePanel>
      )}

      {lineup && lineup.players.length > 0 && (
        <>
          <Text style={{ fontSize: 13, fontWeight: '800', color: colors.deepBlue, letterSpacing: 0.5, marginTop: 10 }}>Escalação</Text>
          <Card>
            <LineupBoard teamA={lineup.team_a_name} teamB={lineup.team_b_name} players={lineup.players} formations={lineup.formations} score={match.status === 'finalized' ? finalScore : null} />
          </Card>
          <SharePanel label="Compartilhar escalação" fileName="minuto91-escalacao" title="Escalação da partida">
            <LineupArt peladaName={peladaName} crestPath={crestPath} subtitle={date} teamA={lineup.team_a_name} teamB={lineup.team_b_name} players={lineup.players} formations={lineup.formations} score={match.status === 'finalized' ? finalScore : null} />
          </SharePanel>
        </>
      )}

      {match.status === 'finalized' && isAdmin && <AnnulMatch matchId={id} onDone={load} />}

      {annulled && (
        <Card>
          <AnnulledBadge />
          <Sub>Esta partida foi anulada e não conta para resultados. Placar, gols, cartões, notas e prêmios dela ficam fora do ar.</Sub>
          <MatchStatusTimeline matchId={id} admin={isAdmin} refreshKey={statusKey} />
        </Card>
      )}
      {!annulled && match.status === 'finalized' && (
        <MatchStatusTimeline matchId={id} admin={isAdmin} refreshKey={statusKey} />
      )}
      {annulled && isAdmin && <RestoreMatch matchId={id} onDone={load} />}

      {(['A', 'B'] as Team[]).map((t) => (
        <View key={t} style={{ gap: 6 }}>
          <Text style={{ fontWeight: '800', color: colors.deepBlue, marginTop: 8 }}>
            {t === 'A' ? match.team_a_name : match.team_b_name}
          </Text>
          {players
            .filter((p) => p.team === t)
            .map((p) => (
              <Text key={p.key} style={{ color: colors.ink }}>
                {playerName(p)} · {positionLabel(p.position)}
                {annulled ? '' : p.goals ? ` · ${p.goals} gol${p.goals > 1 ? 's' : ''}` : ''}
                {!annulled && p.assists ? ` · ${p.assists} assist.` : ''}
                {!annulled && p.yellows ? ' · amarelo' : ''}
                {!annulled && p.secondYellow ? ' · expulso (2º amarelo)' : ''}
                {!annulled && p.reds ? ` · ${p.reds} vermelho` : ''}
              </Text>
            ))}
          {!annulled && extras.unattributed[t] > 0 && <Sub>Gols sem autor: {extras.unattributed[t]}</Sub>}
          {!annulled && extras.ownGoals[t] > 0 && <Sub>Gols contra a favor: {extras.ownGoals[t]}</Sub>}
        </View>
      ))}
      {me &&
        matchGuests.map((g) => (
          <ReportLink
            key={g.id}
            peladaId={match.pelada_id}
            targetType="guest"
            targetId={g.id}
            label={`Denunciar nome do convidado ${g.display_name}`}
          />
        ))}
      {open && iAmVoter && <Sub>Confira a súmula: se houver erro, avise o administrador antes de votar.</Sub>}
    </Screen>
  );
}
