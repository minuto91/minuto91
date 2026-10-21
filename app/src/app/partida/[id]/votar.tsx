import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { notify } from '../../../lib/dialog';

import { friendly } from '../../../lib/errors';
import {
  fmtRating,
  fmtTime,
  loadGuests,
  loadMatch,
  loadMembers,
  loadSheet,
  Match,
  Member,
  newKey,
  SheetPlayer,
} from '../../../lib/match';
import { supabase } from '../../../lib/supabase';
import { colors, positionLabel } from '../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Screen, Stepper, Sub, Title } from '../../../lib/ui';

type VotingState = {
  session_id: string | null;
  closes_at: string | null;
  sheet_version: number;
  eligible: boolean;
  sheet_confirmed: boolean;
};
type SessionInfo = { bola_murcha_required: boolean; minimum_numeric_ratings: number | null; eligible_voter_count: number };
// Nota de 0 a 10, "não vi jogar" ou em branco (sem entrada).
type Score = number | 'not_seen';

export default function Votar() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [state, setState] = useState<VotingState | null>(null);
  const [info, setInfo] = useState<SessionInfo | null>(null);
  const [match, setMatch] = useState<Match | null>(null);
  const [colleagues, setColleagues] = useState<Member[]>([]);
  const [sheet, setSheet] = useState<{ players: SheetPlayer[]; names: Map<string, string> } | null>(null);
  const [scores, setScores] = useState<Record<string, Score>>({});
  const [craque, setCraque] = useState<string | null>(null);
  const [bola, setBola] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const [reload, setReload] = useState(0); // incrementar = buscar de novo

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const { data: st, error } = await supabase.rpc('get_my_voting_state', { p_match: id });
        if (error) throw error;
        if (!alive) return;
        const s = st as VotingState | null;
        if (!s?.session_id || !s.eligible) return setMsg('Você não vota nesta partida, ou a votação já acabou.');
        const m = await loadMatch(id);
        const [{ data: si }, { data: el }, members, guests, sh, { data: ballot, error: e2 }] = await Promise.all([
          supabase
            .from('voting_sessions')
            .select('bola_murcha_required, minimum_numeric_ratings, eligible_voter_count')
            .eq('id', s.session_id)
            .single(),
          supabase.from('voting_eligible_members').select('membership_id').eq('session_id', s.session_id),
          loadMembers(m!.pelada_id),
          loadGuests(m!.pelada_id),
          loadSheet(id),
          supabase.rpc('get_my_ballot', { p_session: s.session_id }),
        ]);
        if (e2) throw e2;
        const { data: auth } = await supabase.auth.getUser();
        if (!alive) return;
        const meId = members.find((x) => x.user_id === auth.user?.id)?.id;
        const eligibleIds = new Set((el ?? []).map((x) => x.membership_id));
        setState(s);
        setInfo(si as SessionInfo);
        setMatch(m);
        setColleagues(members.filter((x) => eligibleIds.has(x.id) && x.id !== meId));
        setSheet({
          players: sh.players,
          names: new Map([...members.map((x) => [x.id, x.player_name] as const), ...guests.map((g) => [g.id, g.display_name] as const)]),
        });
        const b = ballot as { status: string; scores: { membership_id: string; rating?: number; not_seen?: boolean }[]; craque?: string; bola_murcha?: string };
        setScores(Object.fromEntries(b.scores.map((x) => [x.membership_id, x.not_seen ? 'not_seen' : Number(x.rating)])));
        setCraque(b.craque ?? null);
        setBola(b.bola_murcha ?? null);
        setSubmitted(b.status === 'submitted');
        setMsg(null);
      } catch (e) {
        if (alive) setMsg(friendly((e as Error).message));
      }
    })();
    return () => {
      alive = false;
    };
  }, [id, reload]);

  const payload = () =>
    Object.entries(scores).map(([membership_id, v]) =>
      v === 'not_seen' ? { membership_id, not_seen: true } : { membership_id, rating: v },
    );

  async function run(fn: string, args: Record<string, unknown>) {
    setBusy(true);
    setMsg(null);
    const { data, error } = await supabase.rpc(fn, args);
    setBusy(false);
    if (error) setMsg(friendly(error.message));
    return { ok: !error, data };
  }

  async function conferir() {
    if ((await run('confirm_match_sheet', { p_match: id, p_sheet_version: state!.sheet_version })).ok) setReload((n) => n + 1);
  }

  async function salvarRascunho() {
    const r = await run('save_ballot_draft', {
      p_session: state!.session_id,
      p_scores: payload(),
      p_craque: craque,
      p_bola_murcha: bola,
    });
    if (r.ok) notify('Rascunho salvo', 'Você pode terminar até o fim do prazo.');
  }

  async function enviar() {
    const r = await run('submit_ballot', {
      p_session: state!.session_id,
      p_sheet_version: state!.sheet_version,
      p_scores: payload(),
      p_craque: craque,
      p_bola_murcha: bola,
      p_idempotency_key: newKey(),
    });
    if (!r.ok) return;
    const res = r.data as { all_voted: boolean };
    notify(
      'Voto enviado',
      res.all_voted ? 'Todo mundo votou: o resultado já saiu!' : 'Você pode mudar seu voto até o fim do prazo.',
    );
    router.back();
  }

  if (!state || !info || !match || !sheet) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }

  const notSeen = Object.values(scores).filter((v) => v === 'not_seen').length;
  const maxNotSeen = Math.floor(colleagues.length / 2);
  const options = colleagues.map((c) => ({ value: c.id, label: c.player_name }));

  // RN-020: primeiro conferir a versão atual da súmula.
  if (!state.sheet_confirmed) {
    return (
      <Screen>
        <Title>Confira a súmula</Title>
        <Sub>
          Versão {state.sheet_version}. {match.team_a_name} {match.team_a_score} x {match.team_b_score} {match.team_b_name}
        </Sub>
        {(['A', 'B'] as const).map((t) => (
          <Card key={t}>
            <Body>{t === 'A' ? match.team_a_name : match.team_b_name}</Body>
            {sheet.players
              .filter((p) => p.team === t)
              .map((p) => (
                <Text key={p.key} style={{ color: colors.ink }}>
                  {sheet.names.get(p.membership_id ?? p.guest_id!) ?? 'Jogador'}
                  {p.guest_id ? ' (convidado)' : ''}
                  {p.goals ? ` · ${p.goals} gol(s)` : ''}
                  {p.assists ? ` · ${p.assists} assist.` : ''}
                  {p.reds ? ` · ${p.reds} vermelho` : ''}
                </Text>
              ))}
          </Card>
        ))}
        <ErrorText>{msg}</ErrorText>
        <Button title="Conferi a súmula" onPress={conferir} loading={busy} />
        <Sub>Viu um erro? Avise o administrador antes de votar.</Sub>
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>Suas notas</Title>
      <Sub>
        Notas secretas, de 0 a 10. Prazo: {state.closes_at ? fmtTime(state.closes_at) : '-'}.
        {info.minimum_numeric_ratings !== null
          ? ` Avalie pelo menos ${info.minimum_numeric_ratings} colegas.`
          : ' Avalie todos os colegas que você viu jogar.'}
      </Sub>
      <Sub>
        “Não vi jogar”: {notSeen} de no máximo {maxNotSeen}.
      </Sub>
      {submitted && <Sub>Seu voto já foi enviado. Mudanças valem ao enviar de novo.</Sub>}

      {colleagues.map((c) => {
        const v = scores[c.id];
        const set = (next: Score | undefined) =>
          setScores((s) => {
            const copy = { ...s };
            if (next === undefined) delete copy[c.id];
            else copy[c.id] = next;
            return copy;
          });
        return (
          <Card key={c.id}>
            <Body>{c.player_name}</Body>
            <Sub>{positionLabel(c.preferred_position)}</Sub>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
              {v === 'not_seen' ? (
                <Text style={{ color: colors.muted, fontWeight: '700' }}>Não vi jogar</Text>
              ) : (
                <Stepper
                  value={v ?? null}
                  onChange={(n) => set(n)}
                  min={0}
                  max={10}
                  step={0.5}
                  start={6}
                  format={fmtRating}
                />
              )}
              <Pressable onPress={() => set(v === 'not_seen' ? undefined : 'not_seen')}>
                <Text style={{ color: colors.blue, fontWeight: '600' }}>{v === 'not_seen' ? 'Vi jogar' : 'Não vi jogar'}</Text>
              </Pressable>
              {typeof v === 'number' && (
                <Pressable onPress={() => set(undefined)}>
                  <Text style={{ color: colors.muted }}>Limpar</Text>
                </Pressable>
              )}
            </View>
          </Card>
        );
      })}

      <Text style={{ fontWeight: '800', color: colors.deepBlue, marginTop: 8 }}>Craque da Partida</Text>
      <Chips options={options} value={craque} onChange={setCraque} />
      {info.bola_murcha_required && (
        <>
          <Text style={{ fontWeight: '800', color: colors.deepBlue, marginTop: 8 }}>Bola Murcha</Text>
          <Chips options={options} value={bola} onChange={setBola} />
        </>
      )}

      <ErrorText>{msg}</ErrorText>
      {!submitted && <Button title="Salvar rascunho" kind="secondary" onPress={salvarRascunho} loading={busy} />}
      <Button title={submitted ? 'Enviar de novo' : 'Enviar voto'} onPress={enviar} loading={busy} />
    </Screen>
  );
}
