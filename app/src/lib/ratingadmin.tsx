// V5: pequenas ferramentas da gestão que alimentam o OVR (migração 050). Tudo é validado no servidor.
// - PositionRequests: pedidos de troca de posição (só o admin aprova).
// - CardsTracking: a pelada registra cartões? Desligado = Disciplina 70 para todos.
// - HardSaves: defesas difíceis dos goleiros de uma partida oficial ("sem registro" nunca vira zero).
import { useEffect, useState } from 'react';
import { View } from 'react-native';

import { friendly } from './errors';
import { supabase } from './supabase';
import { Text } from './text';
import { colors, positionLabel } from './theme';
import { Body, Button, Card, ErrorText, Stepper, Sub } from './ui';

type Request = { id: string; membership_id: string; requested_position: string };

export function PositionRequests({ peladaId, isAdmin }: { peladaId: string; isAdmin: boolean }) {
  const [rows, setRows] = useState<(Request & { name: string })[]>([]);
  const [err, setErr] = useState<string | null>(null);
  const [reload, setReload] = useState(0);
  useEffect(() => {
    let alive = true;
    (async () => {
      void reload;
      const { data } = await supabase
        .from('position_change_requests')
        .select('id, membership_id, requested_position')
        .eq('pelada_id', peladaId)
        .eq('status', 'pending');
      const reqs = (data ?? []) as Request[];
      const { data: ms } = reqs.length
        ? await supabase.from('pelada_memberships').select('id, player_name').in('id', reqs.map((r) => r.membership_id))
        : { data: [] as { id: string; player_name: string }[] };
      if (alive) setRows(reqs.map((r) => ({ ...r, name: ms?.find((m) => m.id === r.membership_id)?.player_name ?? 'Jogador' })));
    })();
    return () => {
      alive = false;
    };
  }, [peladaId, reload]);
  if (!isAdmin || rows.length === 0) return null;
  async function decide(id: string, approve: boolean) {
    setErr(null);
    const { error } = await supabase.rpc('decide_position_change', { p_request: id, p_approve: approve });
    if (error) return setErr(friendly(error.message));
    setReload((n) => n + 1);
  }
  return (
    <Card>
      <Text style={{ fontWeight: '800', color: colors.ink }}>Pedidos de troca de posição</Text>
      <Sub>A nova posição muda o cálculo das Estatísticas aos poucos, ao longo de 5 partidas.</Sub>
      {rows.map((r) => (
        <View key={r.id} style={{ gap: 6, marginTop: 6 }}>
          <Body>
            {r.name} → {positionLabel(r.requested_position)}
          </Body>
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Button title="Aprovar" onPress={() => decide(r.id, true)} />
            </View>
            <View style={{ flex: 1 }}>
              <Button title="Recusar" kind="secondary" onPress={() => decide(r.id, false)} />
            </View>
          </View>
        </View>
      ))}
      <ErrorText>{err}</ErrorText>
    </Card>
  );
}

export function CardsTracking({ peladaId, isAdmin }: { peladaId: string; isAdmin: boolean }) {
  const [on, setOn] = useState<boolean | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    supabase
      .from('pelada_settings')
      .select('cards_tracking')
      .eq('pelada_id', peladaId)
      .maybeSingle()
      .then(({ data }) => alive && setOn(Boolean(data?.cards_tracking)));
    return () => {
      alive = false;
    };
  }, [peladaId]);
  if (on === null) return null;
  return (
    <Card>
      <Text style={{ fontWeight: '800', color: colors.ink }}>Registro de cartões</Text>
      <Sub>
        {on
          ? 'Ligado: a súmula publicada conta para a Disciplina.'
          : 'Desligado: Disciplina 70 para todos.'}
      </Sub>
      {isAdmin && (
        <Button
          title={on ? 'Desligar registro de cartões' : 'Ligar registro de cartões'}
          kind="secondary"
          onPress={async () => {
            setErr(null);
            const { error } = await supabase.rpc('set_cards_tracking', { p_pelada: peladaId, p_enabled: !on });
            if (error) return setErr(friendly(error.message));
            setOn(!on);
          }}
        />
      )}
      <ErrorText>{err}</ErrorText>
    </Card>
  );
}

type Keeper = { participant_id: string; name: string; saves: number | null };

export function HardSaves({ matchId, keepers }: { matchId: string; keepers: { participant_id: string; name: string }[] }) {
  const [rows, setRows] = useState<Keeper[]>([]);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const ids = keepers.map((k) => k.participant_id).join(',');
  useEffect(() => {
    let alive = true;
    (async () => {
      const list = ids ? ids.split(',') : [];
      const { data } = list.length
        ? await supabase.from('match_keeper_saves').select('participant_id, hard_saves').eq('match_id', matchId)
        : { data: [] as { participant_id: string; hard_saves: number }[] };
      if (alive)
        setRows(keepers.map((k) => ({ ...k, saves: data?.find((d) => d.participant_id === k.participant_id)?.hard_saves ?? null })));
    })();
    return () => {
      alive = false;
    };
    // keepers vem da súmula já carregada; ids resume a lista.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [matchId, ids]);
  if (!rows.length) return null;
  return (
    <Card>
      <Text style={{ fontWeight: '800', color: colors.ink }}>Defesas difíceis</Text>
      <Sub>Confirme quantas defesas difíceis cada goleiro fez. Sem registro não conta como zero.</Sub>
      {rows.map((k, i) => (
        <View key={k.participant_id} style={{ gap: 4 }}>
          <Stepper
            label={k.name}
            value={k.saves}
            start={0}
            onChange={(n) => setRows(rows.map((r, j) => (j === i ? { ...r, saves: n } : r)))}
          />
          {k.saves !== null && (
            <Button title="Sem registro" kind="ghost" onPress={() => setRows(rows.map((r, j) => (j === i ? { ...r, saves: null } : r)))} />
          )}
        </View>
      ))}
      <Button
        title="Salvar defesas"
        loading={busy}
        disabled={busy}
        onPress={async () => {
          setBusy(true);
          setMsg(null);
          const { error } = await supabase.rpc('set_match_hard_saves', {
            p_match: matchId,
            p_saves: rows.map((r) => ({ participant_id: r.participant_id, hard_saves: r.saves })),
          });
          setBusy(false);
          setMsg(error ? friendly(error.message) : 'Defesas salvas.');
        }}
      />
      <Sub>{msg}</Sub>
    </Card>
  );
}
