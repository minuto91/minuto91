import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Text, View } from 'react-native';

import { ANNUL_REASONS, AnnulMatch } from '../../../lib/annul';
import { friendly } from '../../../lib/errors';
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
  STATUS_LABEL,
  Team,
  TeamExtras,
} from '../../../lib/match';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, positionLabel } from '../../../lib/theme';
import { Body, Button, Card, ErrorText, Screen, Sub, Title } from '../../../lib/ui';

type Session = {
  id: string;
  status: string;
  closes_at: string;
  eligible_voter_count: number;
  is_valid: boolean | null;
};
type Result = { membership_id: string; final_rating: number | null; has_valid_rating: boolean; numeric_rating_count: number };
type Award = { membership_id: string; award_type: string; is_shared: boolean };
type Annulment = { reason_category: string; description: string; created_at: string };

export default function Partida() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session: auth } = useAuth();
  const router = useRouter();
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
  const [annulment, setAnnulment] = useState<Annulment | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const m = await loadMatch(id);
      if (!m) return setMsg('Partida não encontrada.');
      const [ms, gs, sheet, { data: ss }] = await Promise.all([
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
      ]);
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
      if (m.status === 'finalized') {
        const [{ data: rs }, { data: aw }] = await Promise.all([
          supabase
            .from('match_player_results')
            .select('membership_id, final_rating, has_valid_rating, numeric_rating_count')
            .eq('match_id', id),
          supabase.from('awards').select('membership_id, award_type, is_shared').eq('match_id', id).eq('status', 'active'),
        ]);
        setResults((rs ?? []) as Result[]);
        setAwards((aw ?? []) as Award[]);
      }
      if (m.status === 'annulled') {
        const { data: an } = await supabase
          .from('match_annulments')
          .select('reason_category, description, created_at')
          .eq('match_id', id)
          .maybeSingle();
        setAnnulment(an as Annulment | null);
      }
      setMsg(null);
    } catch (e) {
      setMsg(friendly((e as Error).message));
    }
  }, [id]);

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

  return (
    <Screen>
      <Title>
        {match.team_a_name} {match.team_a_score} x {match.team_b_score} {match.team_b_name}
      </Title>
      <Sub>
        {fmtDate(match.played_at)} · {STATUS_LABEL[match.status] ?? match.status}
        {match.sheet_version > 1 ? ` · súmula versão ${match.sheet_version}` : ''}
      </Sub>
      <ErrorText>{msg}</ErrorText>

      {match.status === 'draft' && isStaff && (
        <Button title="Editar súmula" onPress={() => router.push({ pathname: '/partida/[id]/sumula', params: { id } })} />
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
          {!voting && <Sub>Finalizada sem votação (menos de 6 jogadores com conta). Contam gols, assistências e presença.</Sub>}
          {voting && voting.is_valid === false && (
            <Sub>Votação inválida: menos da metade votou. Sem notas oficiais nem prêmios nesta partida.</Sub>
          )}
          {awardNames('match_craque') !== '' && <Body>Craque da Partida: {awardNames('match_craque')}</Body>}
          {awardNames('bola_murcha') !== '' && <Body>Bola Murcha: {awardNames('bola_murcha')}</Body>}
          {voting?.is_valid && results.length === 0 && iAmVoter && !iVoted && (
            <Sub>Você não votou, então o resultado detalhado desta partida fica bloqueado para você.</Sub>
          )}
          {ranked.map((r) => (
            <Text key={r.membership_id} style={{ color: colors.ink }}>
              {/* Empate = mesma posição (1º, 1º, 3º), pelo valor oficial (RN-073). */}
              {1 + ranked.filter((x) => Number(x.final_rating) > Number(r.final_rating)).length}º {nameOf(r.membership_id)} —{' '}
              {fmtRating(Number(r.final_rating))}
            </Text>
          ))}
        </Card>
      )}

      {match.status === 'finalized' && isAdmin && <AnnulMatch matchId={id} nameOf={nameOf} onDone={load} />}

      {match.status === 'annulled' && (
        <Card>
          <Sub>Esta partida foi anulada e não conta para resultados.</Sub>
          {annulment && (
            <Sub>
              Motivo: {ANNUL_REASONS.find((r) => r.value === annulment.reason_category)?.label ?? 'Outro'} —{' '}
              {annulment.description} ({fmtDate(annulment.created_at)})
            </Sub>
          )}
        </Card>
      )}

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
                {p.goals ? ` · ${p.goals} gol${p.goals > 1 ? 's' : ''}` : ''}
                {p.assists ? ` · ${p.assists} assist.` : ''}
                {p.reds ? ` · ${p.reds} vermelho` : ''}
              </Text>
            ))}
          {extras.unattributed[t] > 0 && <Sub>Gols sem autor: {extras.unattributed[t]}</Sub>}
          {extras.ownGoals[t] > 0 && <Sub>Gols contra a favor: {extras.ownGoals[t]}</Sub>}
        </View>
      ))}
      {open && iAmVoter && <Sub>Confira a súmula: se houver erro, avise o administrador antes de votar.</Sub>}
    </Screen>
  );
}
