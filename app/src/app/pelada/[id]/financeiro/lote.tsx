import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Pressable, View } from 'react-native';

import { confirm } from '../../../../lib/dialog';
import { friendly } from '../../../../lib/errors';
import { Charge } from '../../../../lib/financeui';
import { centsToInput, fmtDay, formatBRL, METHODS, newRequestId, parseBRL } from '../../../../lib/money';
import { matchesName, showSearch } from '../../../../lib/search';
import { supabase } from '../../../../lib/supabase';
import { Text } from '../../../../lib/text';
import { colors, radius, type } from '../../../../lib/theme';
import { Button, Chips, EmptyState, ErrorText, Input, Loading, Screen, Sub, Title } from '../../../../lib/ui';

// REV-007 / REV-049: pagamentos em lote. Cada cobrança vira um lançamento próprio (com a competência original);
// o valor vem preenchido com o saldo e pode ser editado (parcial). O lote é atômico e idempotente no servidor.
type Group = { key: string; name: string; charges: Charge[] };

export default function Lote() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [charges, setCharges] = useState<Charge[] | null>(null);
  const [q, setQ] = useState('');
  const [picked, setPicked] = useState<Record<string, string>>({}); // charge_id -> valor digitado
  const [method, setMethod] = useState<string>('pix');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const reqId = useRef(newRequestId()); // mesmo id até dar certo: duplo toque e retry não duplicam

  useEffect(() => {
    supabase.rpc('get_finance_charges', { p_pelada: id, p_status: 'open' }).then(({ data, error }) => {
      if (error) return setMsg(friendly(error.message));
      setCharges(((data ?? []) as Charge[]).filter((c) => c.status === 'pending' || c.status === 'partial'));
    });
  }, [id]);

  const groups = useMemo(() => {
    const m = new Map<string, Group>();
    for (const c of charges ?? []) {
      const key = c.membership_id ?? c.payer_id ?? c.id;
      if (!m.has(key)) m.set(key, { key, name: c.person_name, charges: [] });
      m.get(key)!.charges.push(c);
    }
    return [...m.values()].sort((a, b) => a.name.localeCompare(b.name, 'pt-BR'));
  }, [charges]);

  const visible = groups.filter((g) => matchesName(g.name, q));
  const items = Object.entries(picked).map(([charge_id, v]) => ({ charge_id, amount_cents: parseBRL(v) ?? 0 }));
  const total = items.reduce((s, i) => s + i.amount_cents, 0);
  const invalid = items.some((i) => {
    const c = charges?.find((x) => x.id === i.charge_id);
    return !c || i.amount_cents < 1 || i.amount_cents > c.outstanding_cents;
  });

  function toggleGroup(g: Group) {
    const all = g.charges.every((c) => picked[c.id] !== undefined);
    const next = { ...picked };
    for (const c of g.charges) {
      if (all) delete next[c.id];
      else next[c.id] = centsToInput(c.outstanding_cents);
    }
    setPicked(next);
  }

  async function enviar() {
    setBusy(true);
    setMsg(null);
    const today = new Date();
    const day = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
    const { error } = await supabase.rpc('register_payments_batch', {
      p_pelada: id, p_items: items, p_received_on: day, p_method: method, p_request_id: reqId.current,
    });
    setBusy(false);
    if (error) return setMsg(friendly(error.message)); // seleção e valores ficam como estavam
    reqId.current = newRequestId();
    router.back();
  }

  if (!charges) return <Screen>{msg ? <ErrorText>{msg}</ErrorText> : <Loading />}</Screen>;

  return (
    <Screen>
      <Title>Pagamentos em lote</Title>
      {groups.length === 0 && <EmptyState title="Nenhuma cobrança em aberto" />}
      {showSearch(groups.length) && <Input placeholder="Buscar jogador" value={q} onChangeText={setQ} />}
      {visible.map((g) => {
        const on = g.charges.some((c) => picked[c.id] !== undefined);
        return (
          <View key={g.key} style={{ borderWidth: 1, borderColor: on ? colors.blue : colors.line, borderRadius: radius.card }}>
            <Pressable
              onPress={() => toggleGroup(g)}
              accessibilityRole="checkbox"
              accessibilityState={{ checked: on }}
              style={{ minHeight: 48, padding: 12, flexDirection: 'row', alignItems: 'center', gap: 10 }}>
              <View style={{ width: 22, height: 22, borderRadius: 6, borderWidth: 2, borderColor: colors.blue, backgroundColor: on ? colors.blue : colors.white }} />
              <Text style={[type.body, { flex: 1, fontWeight: '600' }]} numberOfLines={1}>{g.name}</Text>
              <Text style={type.caption}>{formatBRL(g.charges.reduce((s, c) => s + c.outstanding_cents, 0))}</Text>
            </Pressable>
            {on &&
              g.charges.map((c) => (
                <View key={c.id} style={{ flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 12, paddingBottom: 10 }}>
                  <View style={{ flex: 1 }}>
                    <Text style={type.bodySm}>{c.description}</Text>
                    <Sub>{`Vence ${fmtDay(c.due_date)} · falta ${formatBRL(c.outstanding_cents)}`}</Sub>
                  </View>
                  <View style={{ width: 110 }}>
                    <Input
                      keyboardType="decimal-pad"
                      value={picked[c.id] ?? ''}
                      onChangeText={(v) => setPicked({ ...picked, [c.id]: v })}
                      accessibilityLabel={`Valor de ${c.description}`}
                    />
                  </View>
                </View>
              ))}
          </View>
        );
      })}
      {items.length > 0 && (
        <>
          <Chips options={METHODS} value={method} onChange={setMethod} />
          <ErrorText>{msg ?? (invalid ? 'Confira os valores: entre R$ 0,01 e o saldo de cada cobrança.' : null)}</ErrorText>
          <Button
            title={`Registrar ${items.length} ${items.length === 1 ? 'pagamento' : 'pagamentos'} · ${formatBRL(total)}`}
            loading={busy}
            disabled={invalid}
            onPress={() =>
              confirm('Registrar pagamentos?', `${items.length} lançamentos, total ${formatBRL(total)}. Cada um pode ser estornado depois.`, 'Registrar', enviar)
            }
          />
        </>
      )}
    </Screen>
  );
}
