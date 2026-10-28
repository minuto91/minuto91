// V8.1 etapas 43-45: suspender, retomar, cancelar e reativar temporada (só admin, com motivo; migração 059).
// O estado e a linha do tempo vêm do servidor (get_season_lifecycle); nada é decidido aqui.
import { useCallback, useEffect, useState } from 'react';
import { View } from 'react-native';

import { confirm } from './dialog';
import { friendly } from './errors';
import { supabase } from './supabase';
import { Text } from './text';
import { colors, type } from './theme';
import { Button, ErrorText, Input, Sub } from './ui';

type Lifecycle = 'normal' | 'suspended' | 'cancelled';
type Ev = { kind: 'suspension' | 'resumption' | 'cancellation' | 'reactivation'; occurred_at: string; reason?: string };
type Info = { lifecycle: Lifecycle; days_since_last_match: number | null; events: Ev[] };

const EV_LABEL: Record<Ev['kind'], string> = {
  suspension: 'Suspensa',
  resumption: 'Retomada',
  cancellation: 'Cancelada',
  reactivation: 'Reativada',
};
const fmt = (iso: string) => new Date(iso).toLocaleDateString('pt-BR');

type Action = { rpc: string; title: string; label: string; kind?: 'danger' | 'secondary'; effect: string };
const ACTIONS: Record<Lifecycle, Action[]> = {
  normal: [
    { rpc: 'suspend_season', title: 'Suspender', label: 'Suspender', kind: 'secondary', effect: 'A temporada segue em disputa e não é encerrada nem premiada enquanto estiver suspensa.' },
    { rpc: 'cancel_season', title: 'Cancelar', label: 'Cancelar temporada', kind: 'danger', effect: 'Partidas, estatísticas e troféus válidos continuam. Nenhum título da temporada será concedido.' },
  ],
  suspended: [
    { rpc: 'resume_season', title: 'Retomar', label: 'Retomar', kind: 'secondary', effect: 'A temporada volta a seguir o calendário.' },
    { rpc: 'cancel_season', title: 'Cancelar', label: 'Cancelar temporada', kind: 'danger', effect: 'Partidas, estatísticas e troféus válidos continuam. Nenhum título da temporada será concedido.' },
  ],
  cancelled: [
    { rpc: 'reactivate_season', title: 'Reativar', label: 'Reativar (excepcional)', kind: 'secondary', effect: 'A mesma temporada volta, com suas partidas e estatísticas. Nada é concedido automaticamente.' },
  ],
};

export function SeasonLifecycle({ seasonId, isAdmin, onChanged }: { seasonId: string; isAdmin: boolean; onChanged?: () => void }) {
  const [info, setInfo] = useState<Info | null>(null);
  const [open, setOpen] = useState<Action | null>(null);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const load = useCallback(
    () =>
      supabase.rpc('get_season_lifecycle', { p_season: seasonId }).then(({ data, error }) => {
        if (error) return setMsg(friendly(error.message));
        setInfo(data as Info);
      }),
    [seasonId],
  );
  useEffect(() => {
    load();
  }, [load]);

  if (!info) return <ErrorText>{msg}</ErrorText>;

  function run(a: Action) {
    if (reason.trim().length < 3) return setMsg('Informe o motivo (3 a 300 caracteres).');
    confirm(`${a.title} temporada?`, a.effect, 'Confirmar', async () => {
      setBusy(true);
      setMsg(null);
      const { error } = await supabase.rpc(a.rpc, { p_season: seasonId, p_reason: reason.trim() });
      setBusy(false);
      if (error) return setMsg(friendly(error.message));
      setOpen(null);
      setReason('');
      await load();
      onChanged?.();
    });
  }

  const actions = ACTIONS[info.lifecycle];
  return (
    <View style={{ gap: 6 }}>
      {info.lifecycle !== 'normal' && (
        <Text style={[type.caption, { color: colors.deepBlue, fontWeight: '700' }]}>
          {info.lifecycle === 'suspended' ? 'Suspensa · segue em disputa' : 'Cancelada · histórico preservado'}
        </Text>
      )}
      {isAdmin && info.days_since_last_match != null && info.days_since_last_match > 0 && (
        <Sub>{`Última partida há ${info.days_since_last_match} dias. Só informação: a falta de jogos nunca encerra a temporada.`}</Sub>
      )}
      {info.events.map((e, i) => (
        <Sub key={i}>{`${EV_LABEL[e.kind]} em ${fmt(e.occurred_at)}${e.reason ? ` · ${e.reason}` : ''}`}</Sub>
      ))}
      {isAdmin && !open && (
        <View style={{ gap: 6 }}>
          {actions.map((a) => (
            <Button key={a.rpc} title={a.label} kind={a.kind ?? 'secondary'} onPress={() => { setOpen(a); setMsg(null); }} />
          ))}
        </View>
      )}
      {isAdmin && open && (
        <View style={{ gap: 6 }}>
          <Input placeholder="motivo (obrigatório)" value={reason} onChangeText={setReason} maxLength={300} autoCapitalize="sentences" />
          <Button title={open.label} kind={open.kind ?? 'secondary'} onPress={() => run(open)} loading={busy} />
          <Button title="Voltar" kind="ghost" onPress={() => { setOpen(null); setReason(''); setMsg(null); }} />
        </View>
      )}
      <ErrorText>{msg}</ErrorText>
    </View>
  );
}
