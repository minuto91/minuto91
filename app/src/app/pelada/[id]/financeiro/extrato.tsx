import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { View } from 'react-native';

import { Skeleton } from '../../../../lib/central';
import { friendly } from '../../../../lib/errors';
import { CHARGE_STATUS, fmtDay, formatBRL, monthLabel } from '../../../../lib/money';
import { supabase } from '../../../../lib/supabase';
import { Text } from '../../../../lib/text';
import { colors, type } from '../../../../lib/theme';
import { Button, EmptyState, ErrorText, Screen, Section, Sub, Title } from '../../../../lib/ui';

// REV-049: extrato do jogador. Cada cobrança pela competência original; pendências de antes da saída separadas das
// mensalidades novas depois do retorno. Nada é quitado ou renegociado sozinho; pagar usa o fluxo normal ou o lote.
type Row = {
  id: string;
  kind: string;
  reference_month: string | null;
  description: string;
  amount_due_cents: number;
  amount_paid_cents: number;
  due_date: string;
  status: string;
  segment: 'before_leave' | 'current';
};
type Statement = { periods: { started_at: string; ended_at: string | null }[]; charges: Row[]; open_cents: number };

export default function Extrato() {
  const { id, membership, name } = useLocalSearchParams<{ id: string; membership: string; name?: string }>();
  const router = useRouter();
  const [st, setSt] = useState<Statement | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  const [retry, setRetry] = useState(0);
  const load = () => setRetry((n) => n + 1);

  useEffect(() => {
    let alive = true;
    supabase.rpc('get_member_finance_statement', { p_membership: membership }).then(({ data, error }) => {
      if (!alive) return;
      if (error) return setMsg(friendly(error.message));
      setMsg(null);
      setSt(data as Statement);
    });
    return () => {
      alive = false;
    };
  }, [membership, retry]);

  if (msg && !st)
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        <Button title="Tentar de novo" kind="secondary" onPress={load} />
      </Screen>
    );
  if (!st)
    return (
      <Screen>
        <Skeleton height={32} />
        <Skeleton height={64} />
        <Skeleton height={64} />
      </Screen>
    );

  const before = st.charges.filter((c) => c.segment === 'before_leave');
  const current = st.charges.filter((c) => c.segment === 'current');
  const fmtTs = (s: string) => new Date(s).toLocaleDateString('pt-BR');

  return (
    <Screen>
      <Title>{name ?? 'Extrato'}</Title>
      <Text style={[type.number, { color: st.open_cents > 0 ? colors.danger : colors.deepBlue }]}>{formatBRL(st.open_cents)}</Text>
      <Sub>Em aberto no total</Sub>
      {st.periods.length > 1 && (
        <Sub>{st.periods.map((p) => `${fmtTs(p.started_at)} – ${p.ended_at ? fmtTs(p.ended_at) : 'hoje'}`).join(' · ')}</Sub>
      )}
      {st.charges.length === 0 && <EmptyState title="Sem cobranças" />}
      {before.length > 0 && (
        <>
          <Section>Antes da saída</Section>
          {before.map((c) => (
            <ChargeRow key={c.id} c={c} />
          ))}
        </>
      )}
      {current.length > 0 && (
        <>
          <Section>{before.length > 0 ? 'Depois do retorno' : 'Cobranças'}</Section>
          {current.map((c) => (
            <ChargeRow key={c.id} c={c} />
          ))}
        </>
      )}
      {st.open_cents > 0 && (
        <Button title="Registrar pagamentos" onPress={() => router.push({ pathname: '/pelada/[id]/financeiro/lote', params: { id } })} />
      )}
    </Screen>
  );
}

function ChargeRow({ c }: { c: Row }) {
  const open = c.amount_due_cents - c.amount_paid_cents;
  return (
    <View style={{ minHeight: 52, flexDirection: 'row', alignItems: 'center', gap: 12, borderBottomWidth: 1, borderBottomColor: colors.line, paddingVertical: 8 }}>
      <View style={{ flex: 1 }}>
        <Text style={type.body}>{c.reference_month ? monthLabel(c.reference_month) : c.description}</Text>
        <Sub>{`${CHARGE_STATUS[c.status] ?? c.status} · vence ${fmtDay(c.due_date)}`}</Sub>
      </View>
      <View style={{ alignItems: 'flex-end' }}>
        <Text style={{ fontWeight: '700', color: open > 0 ? colors.danger : colors.deepBlue }}>{formatBRL(open > 0 ? open : c.amount_due_cents)}</Text>
        {c.amount_paid_cents > 0 && open > 0 && <Sub>{`pago ${formatBRL(c.amount_paid_cents)}`}</Sub>}
      </View>
    </View>
  );
}
