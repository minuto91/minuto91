// REV-010 goleiro temporário, REV-011 posição secundária confirmada NA partida, REV-013 defesas difíceis informadas.
// Nada aqui muda a posição oficial, a carta ou o OVR: o servidor guarda tudo vinculado à partida.
import { useEffect, useState } from 'react';
import { View } from 'react-native';

import { friendly } from './errors';
import { supabase } from './supabase';
import { Text } from './text';
import { colors, positionLabel, type } from './theme';
import { Toggle } from './toggle';
import { Button, Card, ErrorText, Stepper, Sub } from './ui';

export type RolePlayer = { participant_id: string; membership_id: string | null; team: 'A' | 'B'; position: string; name: string };
type Part = { id: string; temp_goalkeeper: boolean; secondary_position: string | null; primary_position: string };
type Mem = { id: string; secondary_position: string | null; secondary_status: string | null };
type Claim = { id: string; participant_id: string; membership_id: string; claimed_saves: number; status: string; official_saves: number | null };

const isGk = (p: string) => p === 'GOL' || p === 'goalkeeper';

export function MatchRoles({
  matchId, players, staff, myMembershipId, teamNames,
}: {
  matchId: string;
  players: RolePlayer[];
  staff: boolean;
  myMembershipId: string | null;
  teamNames: { A: string; B: string };
}) {
  const [parts, setParts] = useState<Record<string, Part>>({});
  const [mems, setMems] = useState<Record<string, Mem>>({});
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
      const ids = players.map((p) => p.membership_id).filter((x): x is string => !!x);
      const [{ data: ps }, { data: ms }, { data: cs }] = await Promise.all([
        supabase.from('match_participants').select('id, temp_goalkeeper, secondary_position, primary_position').eq('match_id', matchId),
        ids.length ? supabase.from('pelada_memberships').select('id, secondary_position, secondary_status').in('id', ids) : Promise.resolve({ data: [] }),
        supabase.from('match_keeper_save_claims').select('id, participant_id, membership_id, claimed_saves, status, official_saves').eq('match_id', matchId),
      ]);
      if (!alive) return;
      setParts(Object.fromEntries(((ps ?? []) as Part[]).map((p) => [p.id, p])));
      setMems(Object.fromEntries(((ms ?? []) as Mem[]).map((m) => [m.id, m])));
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
  const secondaryCandidates = players.filter((p) => p.membership_id && mems[p.membership_id]?.secondary_status === 'confirmed');
  const pendingClaims = claims.filter((c) => c.status === 'pending');
  const nameOf = (pid: string) => players.find((p) => p.participant_id === pid)?.name ?? 'Goleiro';

  const showStaff = staff && (teamsWithoutGk.length > 0 || secondaryCandidates.length > 0 || pendingClaims.length > 0);
  if (!showStaff && !iAmKeeper) return null;

  return (
    <Card>
      {iAmKeeper && (
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

      {staff && pendingClaims.length > 0 && (
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

      {staff &&
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

      {staff && secondaryCandidates.length > 0 && (
        <View style={{ gap: 2, marginTop: 12 }}>
          <Text style={type.cardTitle}>Atuou na posição secundária?</Text>
          {secondaryCandidates.map((p) => {
            const m = mems[p.membership_id!];
            const on = !!parts[p.participant_id]?.secondary_position;
            return (
              <Toggle
                key={p.participant_id}
                label={`${p.name} · ${positionLabel(m.secondary_position)}`}
                value={on}
                disabled={busy}
                onChange={(v) => run('set_match_secondary_played', { p_match: matchId, p_membership: p.membership_id, p_played: v })}
              />
            );
          })}
        </View>
      )}
      <ErrorText>{msg}</ErrorText>
      {msg === null && busy ? <Text style={{ color: colors.muted }}>Salvando...</Text> : null}
    </Card>
  );
}
