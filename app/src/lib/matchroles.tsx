// REV-010 goleiro temporário, REV-013 defesas difíceis informadas (V10.0, REV-147: sem posição secundária).
// Nada aqui muda a posição oficial, a carta ou o OVR: o servidor guarda tudo vinculado à partida.
import { useEffect, useState } from 'react';
import { View } from 'react-native';

import { friendly } from './errors';
import { supabase } from './supabase';
import { Text } from './text';
import { colors, type } from './theme';
import { Button, Card, ErrorText, Stepper, Sub } from './ui';

export type RolePlayer = { participant_id: string; membership_id: string | null; team: 'A' | 'B'; position: string; name: string };
type Part = { id: string; temp_goalkeeper: boolean; primary_position: string };
type Claim = { id: string; participant_id: string; membership_id: string; claimed_saves: number; status: string; official_saves: number | null };

const isGk = (p: string) => p === 'GOL' || p === 'goalkeeper';

export function MatchRoles({
  matchId, players, staff, myMembershipId, teamNames, mode = 'details',
}: {
  /** REV-146: o goleiro temporário só é indicado no fluxo da súmula ('sheet'); os detalhes da partida não o mostram. */
  mode?: 'details' | 'sheet';
  matchId: string;
  players: RolePlayer[];
  staff: boolean;
  myMembershipId: string | null;
  teamNames: { A: string; B: string };
}) {
  const [parts, setParts] = useState<Record<string, Part>>({});
  const [claims, setClaims] = useState<Claim[]>([]);
  const [saves, setSaves] = useState(0);
  const [review, setReview] = useState<Record<string, number>>({});
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    let alive = true;
    (async () => {
      void reload;
      const [{ data: ps }, { data: cs }] = await Promise.all([
        supabase.from('match_participants').select('id, temp_goalkeeper, primary_position').eq('match_id', matchId),
        supabase.from('match_keeper_save_claims').select('id, participant_id, membership_id, claimed_saves, status, official_saves').eq('match_id', matchId),
      ]);
      if (!alive) return;
      setParts(Object.fromEntries(((ps ?? []) as Part[]).map((p) => [p.id, p])));
      setClaims((cs ?? []) as Claim[]);
    })();
    return () => {
      alive = false;
    };
  }, [matchId, players, reload]);

  async function run(fn: string, args: Record<string, unknown>) {
    if (busy) return;
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc(fn, args);
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    setReload((n) => n + 1); // sucesso só depois do servidor
  }

  const me = players.find((p) => p.membership_id && p.membership_id === myMembershipId);
  const iAmKeeper = !!me && (isGk(me.position) || !!parts[me.participant_id]?.temp_goalkeeper);
  const myClaim = me ? claims.find((c) => c.participant_id === me.participant_id) : undefined;
  const teamsWithoutGk = (['A', 'B'] as const).filter((t) => !players.some((p) => p.team === t && isGk(p.position)));
  const pendingClaims = claims.filter((c) => c.status === 'pending');
  const nameOf = (pid: string) => players.find((p) => p.participant_id === pid)?.name ?? 'Goleiro';

  const sheet = mode === 'sheet';
  const showStaff = staff && (sheet ? teamsWithoutGk.length > 0 : pendingClaims.length > 0);
  if (!showStaff && (sheet || !iAmKeeper)) return null;

  return (
    <Card>
      {!sheet && iAmKeeper && (
        <View style={{ gap: 8 }}>
          <Text style={type.cardTitle}>Defesas difíceis</Text>
          {myClaim && myClaim.status !== 'pending' ? (
            <Sub>{`Oficial: ${myClaim.official_saves ?? '—'}${myClaim.status === 'corrected' ? ' (corrigido pela administração)' : ''}`}</Sub>
          ) : (
            <>
              {myClaim && <Sub>{`Informado: ${myClaim.claimed_saves} · aguardando revisão`}</Sub>}
              <Stepper label="Defesas" value={saves} onChange={setSaves} min={0} max={99} />
              <Button title={myClaim ? 'Atualizar' : 'Informar'} kind="secondary" loading={busy} onPress={() => run('submit_keeper_saves_claim', { p_match: matchId, p_saves: saves })} />
            </>
          )}
        </View>
      )}

      {!sheet && staff && pendingClaims.length > 0 && (
        <View style={{ gap: 8, marginTop: iAmKeeper ? 12 : 0 }}>
          <Text style={type.cardTitle}>Defesas para revisar</Text>
          {pendingClaims.map((c) => (
            <View key={c.id} style={{ gap: 6 }}>
              <Text style={type.body}>{`${nameOf(c.participant_id)} informou ${c.claimed_saves}`}</Text>
              <Stepper label="Oficial" value={review[c.id] ?? c.claimed_saves} onChange={(n) => setReview({ ...review, [c.id]: n })} min={0} max={99} />
              <View style={{ flexDirection: 'row', gap: 8 }}>
                <View style={{ flex: 1 }}>
                  <Button title="Confirmar" loading={busy} onPress={() => run('review_keeper_saves_claim', { p_claim: c.id, p_saves: review[c.id] ?? c.claimed_saves })} />
                </View>
                <View style={{ flex: 1 }}>
                  <Button title="Recusar" kind="ghost" disabled={busy} onPress={() => run('review_keeper_saves_claim', { p_claim: c.id, p_saves: null })} />
                </View>
              </View>
            </View>
          ))}
        </View>
      )}

      {sheet && staff &&
        teamsWithoutGk.map((t) => {
          const current = players.find((p) => p.team === t && parts[p.participant_id]?.temp_goalkeeper);
          return (
            <View key={t} style={{ gap: 6, marginTop: 12 }}>
              <Text style={type.cardTitle}>{`Goleiro temporário · ${teamNames[t]}`}</Text>
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
                {players
                  .filter((p) => p.team === t)
                  .map((p) => {
                    const on = current?.participant_id === p.participant_id;
                    return (
                      <Button
                        key={p.participant_id}
                        title={p.name}
                        kind={on ? 'primary' : 'secondary'}
                        disabled={busy}
                        onPress={() => run('set_match_temp_goalkeeper', { p_match: matchId, p_participant: p.participant_id, p_on: !on })}
                      />
                    );
                  })}
              </View>
            </View>
          );
        })}

      <ErrorText>{msg}</ErrorText>
      {msg === null && busy ? <Text style={{ color: colors.muted }}>Salvando...</Text> : null}
    </Card>
  );
}
