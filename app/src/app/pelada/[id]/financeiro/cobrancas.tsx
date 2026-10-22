import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { todayIn } from '../../../../lib/dates';
import { confirm } from '../../../../lib/dialog';
import { friendly } from '../../../../lib/errors';
import { Charge, DateField, Field, People, Person, PersonPicker, StatusBadge } from '../../../../lib/financeui';
import { fmtDate } from '../../../../lib/match';
import { CHARGE_KIND, centsToInput, fmtDay, formatBRL, methodLabel, METHODS, monthShift, newRequestId, parseBRL } from '../../../../lib/money';
import { supabase } from '../../../../lib/supabase';
import { colors } from '../../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Input, Screen, Sub, Title } from '../../../../lib/ui';

const STATUS = [
  { value: 'open', label: 'Em aberto' },
  { value: 'overdue', label: 'Vencidas' },
  { value: 'paid', label: 'Pagas' },
  { value: 'cancelled', label: 'Canceladas' },
  { value: 'all', label: 'Todas' },
] as const;
const PERIOD = [
  { value: 'all', label: 'Todos os meses' },
  { value: 'this', label: 'Este mês' },
  { value: 'prev', label: 'Mês anterior' },
] as const;
type Panel = { charge: string; kind: 'pay' | 'edit' | 'cancel' | 'reverse'; payment?: string } | null;

// Cobranças e pendências (V4.3): mensalidades, avulsos e contribuições. Pagamento integral ou parcial registrado à mão
// (o app não recebe dinheiro), estorno sem apagar, cancelamento só sem pagamentos. Cada envio leva uma chave única:
// tocar duas vezes registra uma vez só.
export default function Cobrancas() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const today = todayIn();
  const [status, setStatus] = useState<string>('open');
  const [period, setPeriod] = useState<string>('all');
  const [person, setPerson] = useState<Person | null>(null);
  const [charges, setCharges] = useState<Charge[] | null>(null);
  const [people, setPeople] = useState<People | null>(null);
  const [matches, setMatches] = useState<{ id: string; played_at: string; team_a_name: string; team_b_name: string }[]>([]);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reload, setReload] = useState(0);
  const [panel, setPanel] = useState<Panel>(null);
  // Formulários
  const [amount, setAmount] = useState('');
  const [day, setDay] = useState(today);
  const [method, setMethod] = useState<string>('pix');
  const [notes, setNotes] = useState('');
  const [reqId, setReqId] = useState(newRequestId());
  const [creating, setCreating] = useState(false);
  const [kind, setKind] = useState<'single' | 'extra'>('single');
  const [who, setWho] = useState<Person | null>(null);
  const [desc, setDesc] = useState('');
  const [match, setMatch] = useState<string | null>(null);
  const [newPayer, setNewPayer] = useState('');

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        void reload;
        const month = period === 'this' ? monthShift(today, 0) : period === 'prev' ? monthShift(today, -1) : null;
        const [{ data: cs, error }, { data: pp }, { data: ms }] = await Promise.all([
          supabase.rpc('get_finance_charges', {
            p_pelada: id,
            p_month: month,
            p_status: status === 'all' ? null : status,
            p_membership: person?.membership_id ?? null,
            p_payer: person?.payer_id ?? null,
          }),
          supabase.rpc('get_finance_people', { p_pelada: id }),
          supabase.from('matches').select('id, played_at, team_a_name, team_b_name').eq('pelada_id', id).neq('status', 'draft').order('played_at', { ascending: false }).limit(5),
        ]);
        if (!alive) return;
        if (error) return setMsg(friendly(error.message));
        setMsg(null);
        setCharges(cs as Charge[]);
        setPeople(pp as People);
        setMatches(ms ?? []);
      })();
      return () => {
        alive = false;
      };
    }, [id, status, period, person, reload, today]),
  );

  function open(p: Panel, c?: Charge) {
    setPanel(p);
    setReqId(newRequestId());
    setNotes('');
    setDay(p?.kind === 'edit' && c ? c.due_date : today);
    setAmount(c ? centsToInput(p?.kind === 'edit' ? c.amount_due_cents : c.outstanding_cents) : '');
  }

  async function call(fn: string, args: Record<string, unknown>) {
    setBusy(true);
    setMsg(null);
    const { data, error } = await supabase.rpc(fn, args);
    setBusy(false);
    if (error) {
      setMsg(friendly(error.message));
      return { ok: false, error: error.message };
    }
    return { ok: true, data };
  }

  async function pagar(c: Charge, confirmDuplicate = false) {
    const cents = parseBRL(amount);
    if (!cents) return setMsg('Valor inválido.');
    const r = await call('register_payment', {
      p_charge: c.id,
      p_amount_cents: cents,
      p_received_on: day,
      p_method: method,
      p_notes: notes.trim() || null,
      p_request_id: reqId,
      p_confirm_duplicate: confirmDuplicate,
    });
    if (!r.ok && r.error?.includes('FINANCE_POSSIBLE_DUPLICATE')) {
      return confirm(
        'Pagamento parecido acabou de ser registrado',
        `Já existe um pagamento de ${formatBRL(cents)} nesta cobrança, registrado agora há pouco. É outro pagamento?`,
        'Registrar outro',
        () => pagar(c, true),
      );
    }
    if (r.ok) {
      setPanel(null);
      setReload((n) => n + 1);
    }
  }

  async function editar(c: Charge) {
    const cents = parseBRL(amount);
    if (!cents) return setMsg('Valor inválido.');
    const r = await call('update_charge', { p_charge: c.id, p_amount_cents: cents, p_due_date: day, p_description: null, p_expected_version: c.version });
    if (r.ok) {
      setPanel(null);
      setReload((n) => n + 1);
    }
  }

  async function cancelar(c: Charge) {
    const r = await call('cancel_charge', { p_charge: c.id, p_reason: notes.trim() });
    if (r.ok) {
      setPanel(null);
      setReload((n) => n + 1);
    }
  }

  async function estornar(paymentId: string) {
    const r = await call('reverse_payment', { p_payment: paymentId, p_reason: notes.trim() });
    if (r.ok) {
      setPanel(null);
      setReload((n) => n + 1);
    }
  }

  async function cadastrarPessoa() {
    const r = await call('save_finance_payer', { p_pelada: id, p_id: null, p_name: newPayer.trim(), p_notes: null });
    if (r.ok) {
      setWho({ payer_id: String(r.data), name: newPayer.trim() });
      setNewPayer('');
      setReload((n) => n + 1);
    }
  }

  async function criar() {
    const cents = parseBRL(amount);
    if (!cents) return setMsg('Valor inválido.');
    if (!who) return setMsg('Escolha quem deve pagar.');
    const r = await call('create_charge', {
      p_pelada: id,
      p_kind: kind,
      p_membership: who.membership_id ?? null,
      p_payer: who.payer_id ?? null,
      p_match: kind === 'single' ? match : null,
      p_description: desc.trim() || null,
      p_amount_cents: cents,
      p_due_date: day,
      p_request_id: reqId,
    });
    if (r.ok) {
      setCreating(false);
      setWho(null);
      setDesc('');
      setMatch(null);
      setReload((n) => n + 1);
    }
  }

  if (creating && people) {
    return (
      <Screen>
        <Title>Nova cobrança</Title>
        <Chips
          options={[
            { value: 'single', label: 'Avulso' },
            { value: 'extra', label: 'Contribuição extraordinária' },
          ]}
          value={kind}
          onChange={(v) => setKind(v as 'single' | 'extra')}
        />
        <Field label="Quem paga">
          <PersonPicker people={people} value={who} onChange={setWho} />
        </Field>
        <Field label="Cadastrar pessoa de fora (sem conta no app)">
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Input value={newPayer} onChangeText={setNewPayer} placeholder="Nome" autoCapitalize="words" maxLength={60} />
            </View>
            <Button title="Adicionar" kind="secondary" onPress={cadastrarPessoa} disabled={newPayer.trim().length < 2} />
          </View>
          <Sub>Só o nome (e uma observação, se quiser). Nenhum outro dado pessoal.</Sub>
        </Field>
        {kind === 'single' && matches.length > 0 && (
          <Field label="Partida (opcional)">
            <Chips
              options={[{ value: '', label: 'Nenhuma' }, ...matches.map((m) => ({ value: m.id, label: `${fmtDate(m.played_at)} · ${m.team_a_name} x ${m.team_b_name}` }))]}
              value={match ?? ''}
              onChange={(v) => setMatch(v || null)}
            />
          </Field>
        )}
        <Field label="Descrição ou referência">
          <Input value={desc} onChangeText={setDesc} placeholder={kind === 'single' ? 'Avulso' : 'Ex.: rateio do churrasco'} maxLength={120} autoCapitalize="sentences" />
        </Field>
        <Field label="Valor (R$)">
          <Input value={amount} onChangeText={setAmount} placeholder="0,00" keyboardType="decimal-pad" />
        </Field>
        <DateField label="Vencimento" value={day} onChange={setDay} today={today} />
        <ErrorText>{msg}</ErrorText>
        <Button title="Criar cobrança" onPress={criar} loading={busy} />
        <Button title="Voltar" kind="secondary" onPress={() => setCreating(false)} />
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>Cobranças e pendências</Title>
      <Chips options={STATUS} value={status} onChange={(v) => setStatus(v)} />
      <Chips options={PERIOD} value={period} onChange={(v) => setPeriod(v)} />
      {person && (
        <Pressable accessibilityRole="button" onPress={() => setPerson(null)} style={{ minHeight: 40, justifyContent: 'center' }}>
          <Text style={{ color: colors.blue, fontWeight: '700' }}>Só {person.name} · mostrar todos ✕</Text>
        </Pressable>
      )}
      <ErrorText>{msg}</ErrorText>
      <Button
        title="Nova cobrança (avulso ou contribuição)"
        kind="secondary"
        onPress={() => {
          open(null);
          setAmount('');
          setCreating(true);
        }}
      />
      {!charges && !msg && <Sub>Carregando...</Sub>}
      {charges?.length === 0 && <Sub>Nenhuma cobrança com esses filtros.</Sub>}
      {charges && charges.length > 0 && (
        <Sub>
          {charges.length} {charges.length === 1 ? 'cobrança' : 'cobranças'} · em aberto {formatBRL(charges.reduce((s, c) => s + c.outstanding_cents, 0))}
        </Sub>
      )}
      {charges?.map((c) => {
        const here = panel?.charge === c.id ? panel : null;
        const openCharge = c.status === 'pending' || c.status === 'partial';
        return (
          <Card key={c.id}>
            <View style={{ flexDirection: 'row', gap: 8, alignItems: 'flex-start' }}>
              <View style={{ flex: 1, gap: 2 }}>
                <Pressable
                  accessibilityRole="button"
                  accessibilityLabel={`Filtrar por ${c.person_name}`}
                  onPress={() => setPerson({ membership_id: c.membership_id, payer_id: c.payer_id, name: c.person_name })}>
                  <Body>{c.person_name}</Body>
                </Pressable>
                <Sub>
                  {CHARGE_KIND[c.kind]} · {c.description} · vence {fmtDay(c.due_date)}
                </Sub>
              </View>
              <StatusBadge status={c.status} overdue={c.overdue} />
            </View>
            <Text style={{ color: colors.ink, fontVariant: ['tabular-nums'] }}>
              Devido {formatBRL(c.amount_due_cents)} · pago {formatBRL(c.amount_paid_cents)}
              {openCharge ? ` · falta ${formatBRL(c.outstanding_cents)}` : ''}
            </Text>
            {c.cancel_reason && <Sub>Cancelada: {c.cancel_reason}</Sub>}
            {c.payments.map((p) => (
              <View key={p.id} style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                <Text style={{ flex: 1, fontSize: 13, color: p.reversed_at ? colors.muted : colors.ink, textDecorationLine: p.reversed_at ? 'line-through' : 'none' }}>
                  {fmtDay(p.received_on)} · {formatBRL(p.amount_cents)}
                  {p.method ? ` · ${methodLabel(p.method)}` : ''}
                  {p.created_by_name ? ` · por ${p.created_by_name}` : ''}
                </Text>
                {p.reversed_at ? (
                  <Text style={{ fontSize: 12, color: colors.muted }}>estornado</Text>
                ) : (
                  <Pressable accessibilityRole="button" onPress={() => open({ charge: c.id, kind: 'reverse', payment: p.id }, c)} style={{ minHeight: 36, justifyContent: 'center' }}>
                    <Text style={{ color: colors.danger, fontSize: 13, fontWeight: '600' }}>Estornar</Text>
                  </Pressable>
                )}
              </View>
            ))}

            {!here && openCharge && (
              <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                <View style={{ flex: 1, minWidth: 140 }}>
                  <Button title="Registrar pagamento" onPress={() => open({ charge: c.id, kind: 'pay' }, c)} />
                </View>
                <View style={{ flex: 1, minWidth: 140 }}>
                  <Button title="Alterar" kind="secondary" onPress={() => open({ charge: c.id, kind: 'edit' }, c)} />
                </View>
                {c.amount_paid_cents === 0 && (
                  <Pressable accessibilityRole="button" onPress={() => open({ charge: c.id, kind: 'cancel' }, c)} style={{ minHeight: 44, justifyContent: 'center' }}>
                    <Text style={{ color: colors.danger, fontWeight: '600' }}>Cancelar cobrança</Text>
                  </Pressable>
                )}
              </View>
            )}

            {here?.kind === 'pay' && (
              <View style={{ gap: 8 }}>
                <Field label="Valor recebido (R$)">
                  <Input value={amount} onChangeText={setAmount} keyboardType="decimal-pad" />
                </Field>
                <Sub>Para pagamento parcial, digite só o que foi pago. O restante continua pendente.</Sub>
                <DateField label="Data do recebimento" value={day} onChange={setDay} today={today} />
                <Field label="Forma (só informativa)">
                  <Chips options={METHODS} value={method} onChange={(v) => setMethod(v)} />
                </Field>
                <Input value={notes} onChangeText={setNotes} placeholder="Observação (opcional)" maxLength={200} autoCapitalize="sentences" />
                <Button title="Confirmar pagamento" onPress={() => pagar(c)} loading={busy} />
                <Button title="Voltar" kind="secondary" onPress={() => setPanel(null)} />
              </View>
            )}
            {here?.kind === 'edit' && (
              <View style={{ gap: 8 }}>
                <Field label="Valor devido (R$)">
                  <Input value={amount} onChangeText={setAmount} keyboardType="decimal-pad" />
                </Field>
                <DateField label="Vencimento" value={day} onChange={setDay} today={today} />
                <Button title="Salvar alteração" onPress={() => editar(c)} loading={busy} />
                <Button title="Voltar" kind="secondary" onPress={() => setPanel(null)} />
              </View>
            )}
            {(here?.kind === 'cancel' || here?.kind === 'reverse') && (
              <View style={{ gap: 8 }}>
                <Input value={notes} onChangeText={setNotes} placeholder="Motivo (obrigatório)" maxLength={200} autoCapitalize="sentences" />
                <Sub>Nada é apagado: o registro fica no histórico com o motivo, quem fez e quando.</Sub>
                <Button
                  title={here.kind === 'cancel' ? 'Cancelar cobrança' : 'Estornar pagamento'}
                  kind="danger"
                  onPress={() => (here.kind === 'cancel' ? cancelar(c) : estornar(here.payment!))}
                  loading={busy}
                  disabled={notes.trim().length < 3}
                />
                <Button title="Voltar" kind="secondary" onPress={() => setPanel(null)} />
              </View>
            )}
          </Card>
        );
      })}
    </Screen>
  );
}
