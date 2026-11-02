// V7.7 (056): posição secundária. O jogador indica um setor diferente do principal; vale só depois que a
// administração confirma. Confirmada, conta igual à principal na Seleção da Rodada (escolha global no servidor).
// Não muda o cálculo do Card, que segue só a posição principal.
import { useEffect, useState } from 'react';
import { View } from 'react-native';

import { friendly } from './errors';
import { supabase } from './supabase';
import { Text } from './text';
import { colors, SECTORS } from './theme';
import { Body, Button, Card, Chips, ErrorText, Sub } from './ui';

type Sector = (typeof SECTORS)[number]['value'];
const sectorName = (v: string | null) => SECTORS.find((s) => s.value === v)?.label ?? '—';

export function MySecondaryPosition({ peladaId, membershipId, primary }: { peladaId: string; membershipId: string; primary: string }) {
  const [cur, setCur] = useState<{ secondary_position: Sector | null; secondary_status: 'pending' | 'confirmed' | null } | null>(null);
  const [pick, setPick] = useState<Sector | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [reload, setReload] = useState(0);
  useEffect(() => {
    let alive = true;
    (async () => {
      void reload;
      const { data } = await supabase.from('pelada_memberships').select('secondary_position, secondary_status').eq('id', membershipId).maybeSingle();
      if (alive) setCur((data as typeof cur) ?? { secondary_position: null, secondary_status: null });
    })();
    return () => {
      alive = false;
    };
  }, [membershipId, reload]);

  async function save(p: Sector | null) {
    if (busy) return;
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc('request_secondary_position', { p_pelada: peladaId, p_position: p });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    setPick(null);
    setReload((n) => n + 1);
  }
  if (!cur) return null;
  const options = SECTORS.filter((s) => s.value !== primary).map((s) => ({ value: s.value as Sector, label: s.label }));
  return (
    <Card>
      <Body>Posição secundária</Body>
      <Sub>
        {cur.secondary_position
          ? `${sectorName(cur.secondary_position)} · ${cur.secondary_status === 'confirmed' ? 'confirmada pela administração' : 'aguardando confirmação'}`
          : 'Nenhuma. Se você também joga em outro setor, indique aqui.'}
      </Sub>
      <Sub>Vale na Seleção da Rodada quando a administração confirma que você jogou nela. O Card segue a principal.</Sub>
      <Chips options={options} value={pick ?? cur.secondary_position} onChange={(v) => setPick(v)} />
      {pick && pick !== cur.secondary_position && <Button title={`Pedir ${sectorName(pick)}`} onPress={() => save(pick)} loading={busy} />}
      {cur.secondary_position && <Button title="Remover secundária" kind="ghost" onPress={() => save(null)} disabled={busy} />}
      <ErrorText>{msg}</ErrorText>
    </Card>
  );
}

export function SecondaryRequests({ peladaId, isAdmin }: { peladaId: string; isAdmin: boolean }) {
  const [rows, setRows] = useState<{ id: string; player_name: string; secondary_position: Sector }[]>([]);
  const [err, setErr] = useState<string | null>(null);
  const [reload, setReload] = useState(0);
  useEffect(() => {
    let alive = true;
    (async () => {
      void reload;
      const { data } = await supabase
        .from('pelada_memberships')
        .select('id, player_name, secondary_position')
        .eq('pelada_id', peladaId)
        .eq('status', 'active')
        .eq('secondary_status', 'pending');
      if (alive) setRows((data ?? []) as typeof rows);
    })();
    return () => {
      alive = false;
    };
  }, [peladaId, reload]);
  if (!isAdmin || rows.length === 0) return null;
  async function decide(id: string, pos: Sector, ok: boolean) {
    setErr(null);
    const { error } = await supabase.rpc('decide_secondary_position', { p_membership: id, p_position: pos, p_confirm: ok });
    if (error) return setErr(friendly(error.message));
    setReload((n) => n + 1);
  }
  return (
    <Card>
      <Text style={{ fontWeight: '800', color: colors.ink }}>Posições secundárias para confirmar</Text>
      <Sub>Confirmada, a secundária conta como a principal na Seleção da Rodada.</Sub>
      {rows.map((r) => (
        <View key={r.id} style={{ gap: 6, marginTop: 6 }}>
          <Body>
            {r.player_name} → {sectorName(r.secondary_position)}
          </Body>
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Button title="Confirmar" onPress={() => decide(r.id, r.secondary_position, true)} />
            </View>
            <View style={{ flex: 1 }}>
              <Button title="Recusar" kind="secondary" onPress={() => decide(r.id, r.secondary_position, false)} />
            </View>
          </View>
        </View>
      ))}
      <ErrorText>{err}</ErrorText>
    </Card>
  );
}
