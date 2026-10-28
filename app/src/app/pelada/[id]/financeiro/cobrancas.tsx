import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, View } from 'react-native';
import { Text } from '../../../../lib/text';

import { todayIn } from '../../../../lib/dates';
import { confirm } from '../../../../lib/dialog';
import { friendly } from '../../../../lib/errors';
import { Charge, DateField, Field, People, Person, PersonPicker, StatusBadge } from '../../../../lib/financeui';
import { fmtDate } from '../../../../lib/match';
import { CHARGE_KIND, centsToInput, fmtDay, formatBRL, methodLabel, METHODS, monthShift, newRequestId, parseBRL } from '../../../../lib/money';
import { Page, usePaged } from '../../../../lib/paging';
import { supabase } from '../../../../lib/supabase';
import { useSticky } from '../../../../lib/sticky';
import { colors } from '../../../../lib/theme';
import { Body, Button, Card, Chips, EmptyState, ErrorText, Input, ListScreen, LoadingBlock, Screen, Sub, Title } from '../../../../lib/ui';

const STATUS = [
  { value: 'open', label: 'Em aberto' },
  { value: 'overdue', label: 'Vencidas' },
  { value: 'partial', label: 'Parciais' },
  { value: 'paid', label: 'Pagas' },
  { value: 'cancelled', label: 'Canceladas' },
  { value: 'all', label: 'Todas' },
] as const;
const PERIOD = [
  { value: 'all', label: 'Todos os meses' },
  { value: 'this', label: 'Este mês' },
  { value: 'prev', label: 'Mês anterior' },
] as const;
const PAGE = 30;
type Panel = { charge: string; kind: 'pay' | 'edit' | 'cancel' | 'reverse'; payment?: string } | null;
type Cursor = { due_date: string; created_at: string; id: string };
type Summary = { count: number; outstanding_cents: number; partial_count: number };

// Cobranças e pendências (V4.3; V4.4: páginas de 30 vindas do servidor em lista virtualizada, total em aberto calculado
// no servidor para o filtro inteiro, filtro de parciais e "Recebi tudo hoje" em um toque). Pagamento integral ou parcial
// registrado à mão (o app não recebe dinheiro), estorno sem apagar, cancelamento só sem pagamentos. Cada envio leva uma
// chave única: tocar duas vezes registra uma vez só.
export default function Cobrancas() {
  const { id, status: initialStatus } = useLocalSearchParams<{ id: string; status?: string }>();
  const today = todayIn();
  const [status, setStatus] = useState<string>(STATUS.some((s) => s.value === initialStatus) ? String(initialStatus) : 'open');
  const [period, setPeriod] = useSticky<string>(`cobrancas:${id}:period`, 'all');
  const [person, setPerson] = useState<Person | null>(null);
  const [people, setPeople] = useState<People | null>(null);
  const [matches, setMatches] = useState<{ id: string; played_at: string; team_a_name: string; team_b_name: string }[]>([]);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
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
  const [peopleReload, setPeopleReload] = useState(0);

  const membershipFilter = person?.membership_id ?? null;
  const payerFilter = person?.payer_id ?? null;
  const fetchPage = useCallback(
    async (after: Cursor | null): Promise<Page<Charge, Cursor, Summary>> => {
      const month = period === 'this' ? monthShift(today, 0) : period === 'prev' ? monthShift(today, -1) : null;
      const { data, error } = await supabase.rpc('get_finance_charges_page', {
        p_pelada: id,
        p_month: month,
        p_status: status === 'all' ? null : status,
        p_membership: membershipFilter,
        p_payer: payerFilter,
        p_kind: null,
        p_after: after,
        p_limit: PAGE,
      });
      if (error) throw error;
      return data as Page<Charge, Cursor, Summary>;
    },
    [id, status, period, membershipFilter, payerFilter, today],
  );
  const list = usePaged(fetchPage, (x) => x.id);

  // Pessoas e partidas recentes (formulário de nova cobrança).
  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        void peopleReload;
        const [{ data: pp }, { data: ms }] = await Promise.all([
          supabase.rpc('get_finance_people', { p_pelada: id }),
          supabase.from('matches').select('id, played_at, team_a_name, team_b_name').eq('pelada_id', id).neq('status', 'draft').order('played_at', { ascending: false }).limit(5),
        ]);
        if (!alive) return;
        setPeople(pp as People);
        setMatches(ms ?? []);
      })();
      return () => {
        alive = false;
      };
    }, [id, peopleReload]),
  );

  function open(p: Panel, c?: Charge) {
    setPanel(p);
    setReqId(newRequestId());
    setNotes('');
    setMsg(null);
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
      return { ok: false as const, error: error.message };
    }
    return { ok: true as const, data };
  }

  // O servidor devolve a cobrança atualizada: troca só ela na lista e ajusta o total em aberto.
  function updated(before: Charge, after: Charge) {
    list.replace((x) => x.id === before.id, after);
    list.setSummary((s) => (s ? { ...s, outstanding_cents: s.outstanding_cents - before.outstanding_cents + after.outstanding_cents } : s));
  }

  async function pagar(c: Charge, cents: number, when: string, how: string, obs: string | null, key: string, confirmDuplicate = false) {
    const r = await call('register_payment', {
      p_charge: c.id,
      p_amount_cents: cents,
      p_received_on: when,
      p_method: how,
      p_notes: obs,
      p_request_id: key,
      p_confirm_duplicate: confirmDuplicate,
    });
    if (!r.ok && r.error.includes('FINANCE_POSSIBLE_DUPLICATE')) {
      return confirm(
        'Pagamento parecido acabou de ser registrado',
        `Já existe um pagamento de ${formatBRL(cents)} nesta cobrança, registrado agora há pouco. É outro pagamento?`,
        'Registrar outro',
        () => pagar(c, cents, when, how, obs, key, true),
      );
    }
    if (r.ok) {
      setPanel(null);
      updated(c, r.data as Charge);
    }
  }

  function pagarDoFormulario(c: Charge) {
    const cents = parseBRL(amount);
    if (!cents) return setMsg('Valor inválido. Use, por exemplo, 50 ou 50,00.');
    if (cents > c.outstanding_cents) return setMsg(`O valor passa do que falta (${formatBRL(c.outstanding_cents)}).`);
    pagar(c, cents, day, method, notes.trim() || null, reqId);
  }

  // Atalho: o valor que falta, recebido hoje, na última forma usada. Um toque + confirmação.
  function recebiTudo(c: Charge) {
    const key = newRequestId();
    confirm(
      'Registrar pagamento',
      `${c.person_name} pagou ${formatBRL(c.outstanding_cents)} hoje (${methodLabel(method)})?`,
      'Registrar',
      () => pagar(c, c.outstanding_cents, today, method, null, key),
    );
  }

  async function editar(c: Charge) {
    const cents = parseBRL(amount);
    if (!cents) return setMsg('Valor inválido. Use, por exemplo, 50 ou 50,00.');
    const r = await call('update_charge', { p_charge: c.id, p_amount_cents: cents, p_due_date: day, p_description: null, p_expected_version: c.version });
    if (r.ok) {
      setPanel(null);
      updated(c, r.data as Charge);
    }
  }

  async function cancelar(c: Charge) {
    const r = await call('cancel_charge', { p_charge: c.id, p_reason: notes.trim() });
    if (r.ok) {
      setPanel(null);
      updated(c, r.data as Charge);
    }
  }

  async function estornar(c: Charge, paymentId: string) {
    const r = await call('reverse_payment', { p_payment: paymentId, p_reason: notes.trim() });
    if (r.ok) {
      setPanel(null);
      updated(c, r.data as Charge);
    }
  }

  async function cadastrarPessoa() {
    const r = await call('save_finance_payer', { p_pelada: id, p_id: null, p_name: newPayer.trim(), p_notes: null });
    if (r.ok) {
      setWho({ payer_id: String(r.data), name: newPayer.trim() });
      setNewPayer('');
      setPeopleReload((n) => n + 1);
    }
  }

  async function criar() {
    const cents = parseBRL(amount);
    if (!cents) return setMsg('Valor inválido. Use, por exemplo, 50 ou 50,00.');
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
      list.refresh();
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

  const s = list.summary;
  const header = (
    <>
      <Title>Cobranças e pendências</Title>
      <Chips options={STATUS} value={status} onChange={(v) => setStatus(v)} />
      <Chips options={PERIOD} value={period} onChange={(v) => setPeriod(v)} />
      {person && (
        <Pressable accessibilityRole="button" onPress={() => setPerson(null)} style={{ minHeight: 40, justifyContent: 'center' }}>
          <Text style={{ color: colors.blue, fontWeight: '700' }}>Só {person.name} · mostrar todos ✕</Text>
        </Pressable>
      )}
      <ErrorText>{panel ? list.error : (msg ?? list.error)}</ErrorText>
      {list.error && <Button title="Tentar de novo" kind="secondary" onPress={list.refresh} />}
      <Button
        title="Nova cobrança (avulso ou contribuição)"
        kind="secondary"
        onPress={() => {
          open(null);
          setAmount('');
          setCreating(true);
        }}
      />
      {!list.items && !list.error && <LoadingBlock />}
      {s && s.count > 0 && (
        <Sub>
          {s.count} {s.count === 1 ? 'cobrança' : 'cobranças'} · em aberto {formatBRL(s.outstanding_cents)}
          {s.partial_count > 0 ? ` · ${s.partial_count} ${s.partial_count === 1 ? 'parcial' : 'parciais'}` : ''}
        </Sub>
      )}
    </>
  );

  return (
    <ListScreen
      header={header}
      data={list.items}
      keyExtractor={(c) => c.id}
      empty={<EmptyState title="Nenhuma cobrança" />}
      loadingMore={list.loadingMore}
      onEndReached={list.loadMore}
      footer={list.hasMore && !list.loadingMore ? <Button title="Carregar mais" kind="secondary" onPress={list.loadMore} /> : null}
      renderItem={(c) => {
        const here = panel?.charge === c.id ? panel : null;
        const openCharge = c.status === 'pending' || c.status === 'partial';
        return (
          <Card>
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
                  <Pressable
                    accessibilityRole="button"
                    accessibilityLabel={`Estornar pagamento de ${formatBRL(p.amount_cents)} de ${fmtDay(p.received_on)}`}
                    onPress={() => open({ charge: c.id, kind: 'reverse', payment: p.id }, c)}
                    style={{ minHeight: 44, minWidth: 44, justifyContent: 'center', alignItems: 'flex-end' }}>
                    <Text style={{ color: colors.danger, fontSize: 13, fontWeight: '600' }}>Estornar</Text>
                  </Pressable>
                )}
              </View>
            ))}

            {!here && openCharge && (
              <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                <View style={{ flex: 1, minWidth: 140 }}>
                  <Button title="Recebi tudo hoje" onPress={() => recebiTudo(c)} disabled={busy} />
                </View>
                <View style={{ flex: 1, minWidth: 140 }}>
                  <Button title="Outro valor ou data" kind="secondary" onPress={() => open({ charge: c.id, kind: 'pay' }, c)} />
                </View>
                <Pressable accessibilityRole="button" onPress={() => open({ charge: c.id, kind: 'edit' }, c)} style={{ minHeight: 44, justifyContent: 'center' }}>
                  <Text style={{ color: colors.blue, fontWeight: '600' }}>Alterar</Text>
                </Pressable>
                {c.amount_paid_cents === 0 && (
                  <Pressable accessibilityRole="button" onPress={() => open({ charge: c.id, kind: 'cancel' }, c)} style={{ minHeight: 44, justifyContent: 'center' }}>
                    <Text style={{ color: colors.danger, fontWeight: '600' }}>Cancelar cobrança</Text>
                  </Pressable>
                )}
              </View>
            )}

            {here && <ErrorText>{msg}</ErrorText>}
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
                <Button title="Confirmar pagamento" onPress={() => pagarDoFormulario(c)} loading={busy} />
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
                  onPress={() => (here.kind === 'cancel' ? cancelar(c) : estornar(c, here.payment!))}
                  loading={busy}
                  disabled={notes.trim().length < 3}
                />
                <Button title="Voltar" kind="secondary" onPress={() => setPanel(null)} />
              </View>
            )}
          </Card>
        );
      }}
    />
  );
}
