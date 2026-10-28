// REV-050: cancelar (só rascunho; resultado publicado segue a anulação) e remarcar a mesma partida.
import { useEffect, useRef, useState } from 'react';
import { View } from 'react-native';

import { confirm } from './dialog';
import { friendly } from './errors';
import { supabase } from './supabase';
import { Text } from './text';
import { colors, radius, type } from './theme';
import { Button, ErrorText, Input } from './ui';

type Ev = { kind: 'cancelled' | 'rescheduled'; from_at: string; to_at: string | null; reason: string | null; actor_name: string | null; created_at: string };

const fmt = (iso: string) =>
  new Date(iso).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });

export function CancelledInfo({ matchId }: { matchId: string }) {
  const [evs, setEvs] = useState<Ev[] | null>(null);
  useEffect(() => {
    supabase.rpc('get_match_schedule_history', { p_match: matchId }).then(({ data }) => setEvs((data ?? []) as Ev[]));
  }, [matchId]);
  const last = evs?.filter((e) => e.kind === 'cancelled').at(-1);
  if (!last) return null;
  return (
    <View style={{ borderWidth: 1, borderColor: colors.line, borderRadius: radius.card, padding: 14, gap: 4 }}>
      <Text style={type.cardTitle}>Cancelada</Text>
      <Text style={type.caption}>{`Data prevista: ${fmt(last.from_at)}`}</Text>
      {last.reason ? <Text style={type.caption}>{`Motivo: ${last.reason}`}</Text> : null}
      <Text style={type.caption}>{`Por ${last.actor_name ?? 'administração'} em ${fmt(last.created_at)}`}</Text>
    </View>
  );
}

export function ScheduleActions({ matchId, status, onDone }: { matchId: string; status: string; onDone: () => void }) {
  const [mode, setMode] = useState<'idle' | 'cancel' | 'reschedule'>('idle');
  const [reason, setReason] = useState('');
  const [when, setWhen] = useState(''); // AAAA-MM-DD HH:MM
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const sending = useRef(false);

  async function run(fn: string, args: Record<string, unknown>) {
    if (sending.current) return;
    sending.current = true;
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc(fn, args);
    sending.current = false;
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    setMode('idle');
    onDone();
  }

  const parsed = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$/.exec(when.trim());
  const at = parsed ? new Date(+parsed[1], +parsed[2] - 1, +parsed[3], +parsed[4], +parsed[5]) : null;

  if (mode === 'cancel')
    return (
      <View style={{ gap: 8 }}>
        <Input autoCapitalize="sentences" placeholder="Motivo (opcional)" value={reason} onChangeText={setReason} maxLength={200} />
        <ErrorText>{msg}</ErrorText>
        <Button
          title="Cancelar partida"
          kind="danger"
          loading={busy}
          onPress={() =>
            confirm('Cancelar partida?', 'Ela fica no histórico como Cancelada e não conta em nada. Dá para remarcar depois.', 'Cancelar partida', () =>
              run('cancel_match', { p_match: matchId, p_reason: reason.trim() || null }),
            )
          }
        />
        <Button title="Voltar" kind="ghost" onPress={() => setMode('idle')} />
      </View>
    );
  if (mode === 'reschedule')
    return (
      <View style={{ gap: 8 }}>
        <Input placeholder="2026-11-05 20:00" value={when} onChangeText={setWhen} keyboardType="numbers-and-punctuation" maxLength={16} />
        <ErrorText>{msg ?? (when && !at ? 'Use o formato 2026-11-05 20:00.' : null)}</ErrorText>
        <Button title="Remarcar" loading={busy} disabled={!at} onPress={() => run('reschedule_match', { p_match: matchId, p_played_at: at!.toISOString() })} />
        <Button title="Voltar" kind="ghost" onPress={() => setMode('idle')} />
      </View>
    );
  return (
    <View style={{ flexDirection: 'row', gap: 8 }}>
      <View style={{ flex: 1 }}>
        <Button title="Remarcar" kind="secondary" onPress={() => setMode('reschedule')} />
      </View>
      {status === 'draft' && (
        <View style={{ flex: 1 }}>
          <Button title="Cancelar" kind="ghost" onPress={() => setMode('cancel')} />
        </View>
      )}
    </View>
  );
}
