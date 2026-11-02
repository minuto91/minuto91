import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { View } from 'react-native';
import { Text } from '../../../../lib/text';

import { todayIn } from '../../../../lib/dates';
import { confirm } from '../../../../lib/dialog';
import { friendly } from '../../../../lib/errors';
import { DateField, Field, People, Person, PersonPicker } from '../../../../lib/financeui';
import { centsToInput, fmtDay, formatBRL, monthShift, parseBRL } from '../../../../lib/money';
import { supabase } from '../../../../lib/supabase';
import { colors } from '../../../../lib/theme';
import { Body, Button, Card, Chips, EmptyState, ErrorText, Input, LoadingBlock, Screen, Stepper, Sub, Title } from '../../../../lib/ui';

type Monthly = People['monthly'][number];
const STATUS_LABEL = { active: 'Ativo', suspended: 'Suspenso', ended: 'Encerrado' } as const;
const FILTERS = [
  { value: 'all', label: 'Todos' },
  { value: 'late', label: 'Atrasados' },
  { value: 'ok', label: 'Em dia' },
  { value: 'suspended', label: 'Suspensos' },
  { value: 'ended', label: 'Encerrados' },
] as const;
type Filter = (typeof FILTERS)[number]['value'];
const matches = (m: Monthly, f: Filter) =>
  f === 'all' ||
  (f === 'late' && m.overdue_cents > 0) ||
  (f === 'ok' && m.status === 'active' && m.overdue_cents === 0) ||
  (f === 'suspended' && m.status === 'suspended') ||
  (f === 'ended' && m.status === 'ended');

// Mensalistas (V4.3): valor, dia de vencimento (1 a 28), início e situação. Mudar o valor vale só para as
// mensalidades geradas depois (as cobranças antigas não mudam). Suspender pausa novas cobranças; encerrar é final.
export default function Mensalistas() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const today = todayIn();
  const [people, setPeople] = useState<People | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reload, setReload] = useState(0);
  const [form, setForm] = useState<{ edit: Monthly | null } | null>(null);
  const [who, setWho] = useState<Person | null>(null);
  const [amount, setAmount] = useState('');
  const [dueDay, setDueDay] = useState(10);
  const [start, setStart] = useState(monthShift(today, 0));
  const [notes, setNotes] = useState('');
  const [filter, setFilter] = useState<Filter>('all');

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        void reload;
        const { data, error } = await supabase.rpc('get_finance_people', { p_pelada: id });
        if (!alive) return;
        if (error) return setMsg(friendly(error.message));
        setMsg(null);
        setPeople(data as People);
      })();
      return () => {
        alive = false;
      };
    }, [id, reload]),
  );

  function abrir(edit: Monthly | null) {
    setForm({ edit });
    setWho(edit ? { membership_id: edit.membership_id, payer_id: edit.payer_id, name: edit.person_name } : null);
    setAmount(edit ? centsToInput(edit.amount_cents) : '');
    setDueDay(edit?.due_day ?? 10);
    setStart(edit?.starts_on ?? monthShift(today, 0));
    setNotes(edit?.notes ?? '');
    setMsg(null);
  }

  async function salvar() {
    const cents = parseBRL(amount);
    if (!cents) return setMsg('Valor inválido.');
    if (!who) return setMsg('Escolha o mensalista.');
    setBusy(true);
    const { error } = await supabase.rpc('save_monthly_member', {
      p_pelada: id,
      p_id: form?.edit?.id ?? null,
      p_membership: who.membership_id ?? null,
      p_payer: who.payer_id ?? null,
      p_amount_cents: cents,
      p_due_day: dueDay,
      p_starts_on: start,
      p_notes: notes.trim() || null,
      p_expected_version: form?.edit?.version ?? null,
    });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    setForm(null);
    setReload((n) => n + 1);
  }

  async function situacao(m: Monthly, status: 'active' | 'suspended' | 'ended') {
    const go = async () => {
      setBusy(true);
      const { error } = await supabase.rpc('set_monthly_member_status', { p_id: m.id, p_status: status, p_reason: null });
      setBusy(false);
      if (error) return setMsg(friendly(error.message));
      setReload((n) => n + 1);
    };
    if (status === 'ended')
      confirm('Encerrar mensalista?', `${m.person_name} não recebe novas mensalidades. As pendências antigas continuam devidas e o histórico fica guardado.`, 'Encerrar', go);
    else go();
  }

  if (form && people) {
    return (
      <Screen>
        <Title>{form.edit ? 'Alterar mensalista' : 'Novo mensalista'}</Title>
        {form.edit ? (
          <Body>{form.edit.person_name}</Body>
        ) : (
          <Field label="Quem">
            <PersonPicker people={people} value={who} onChange={setWho} />
          </Field>
        )}
        <Field label="Mensalidade (R$)">
          <Input value={amount} onChangeText={setAmount} placeholder="0,00" keyboardType="decimal-pad" />
        </Field>
        {form.edit && <Sub>O novo valor vale para as próximas mensalidades geradas. As já geradas não mudam.</Sub>}
        <Field label="Dia de vencimento">
          <Stepper value={dueDay} onChange={setDueDay} min={1} max={28} a11yName="Dia de vencimento" />
        </Field>
        <DateField label="Início" value={start} onChange={setStart} today={today} />
        <Input value={notes} onChangeText={setNotes} placeholder="Observação (opcional)" maxLength={200} autoCapitalize="sentences" />
        <ErrorText>{msg}</ErrorText>
        <Button title="Salvar" onPress={salvar} loading={busy} />
        <Button title="Voltar" kind="secondary" onPress={() => setForm(null)} />
      </Screen>
    );
  }

  const all = people?.monthly ?? [];
  const list = all.filter((m) => matches(m, filter));
  return (
    <Screen>
      <Title>Mensalistas</Title>
      <ErrorText>{msg}</ErrorText>
      <Button title="Novo mensalista" onPress={() => abrir(null)} />
      {all.length > 0 && (
        <Chips
          options={FILTERS.map((f) => ({ value: f.value, label: `${f.label} (${all.filter((m) => matches(m, f.value)).length})` }))}
          value={filter}
          onChange={(v) => setFilter(v as Filter)}
        />
      )}
      {!people && !msg && <LoadingBlock />}
      {people && all.length === 0 && <EmptyState title="Nenhum mensalista" />}
      {all.length > 0 && list.length === 0 && <EmptyState title="Ninguém com esse filtro" />}
      {list.map((m) => (
        <Card key={m.id}>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Body>{m.person_name}</Body>
              <Sub>
                {formatBRL(m.amount_cents)} · vence dia {m.due_day} · desde {fmtDay(m.starts_on)}
              </Sub>
            </View>
            <Text style={{ fontSize: 12, fontWeight: '800', color: m.status === 'active' ? colors.blue : colors.muted }}>
              {STATUS_LABEL[m.status].toUpperCase()}
            </Text>
          </View>
          {m.overdue_cents > 0 ? (
            <Text style={{ color: colors.danger, fontWeight: '600' }}>Atrasado: {formatBRL(m.overdue_cents)}</Text>
          ) : m.status === 'active' ? (
            <Text style={{ color: colors.ink, fontWeight: '600' }}>Em dia{m.open_cents > 0 ? ` · ${formatBRL(m.open_cents)} a vencer` : ''}</Text>
          ) : null}
          {!m.person_active && <Sub>Fora da pelada: sem novas mensalidades.</Sub>}
          {m.notes && <Sub>{m.notes}</Sub>}
          {m.membership_id && (
            <Button
              title="Extrato"
              kind="ghost"
              onPress={() =>
                router.push({ pathname: '/pelada/[id]/financeiro/extrato', params: { id, membership: m.membership_id!, name: m.person_name } })
              }
            />
          )}
          {m.status !== 'ended' && (
            <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
              <View style={{ flex: 1, minWidth: 120 }}>
                <Button title="Alterar" kind="secondary" onPress={() => abrir(m)} />
              </View>
              <View style={{ flex: 1, minWidth: 120 }}>
                <Button
                  title={m.status === 'active' ? 'Suspender' : 'Reativar'}
                  kind="secondary"
                  onPress={() => situacao(m, m.status === 'active' ? 'suspended' : 'active')}
                  disabled={busy}
                />
              </View>
              <View style={{ flex: 1, minWidth: 120 }}>
                <Button title="Encerrar" kind="danger" onPress={() => situacao(m, 'ended')} disabled={busy} />
              </View>
            </View>
          )}
        </Card>
      ))}
    </Screen>
  );
}
