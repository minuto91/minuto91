import { useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, View } from 'react-native';
import { Text } from '../../../../lib/text';

import { todayIn } from '../../../../lib/dates';
import { friendly } from '../../../../lib/errors';
import { DateField, Field } from '../../../../lib/financeui';
import {
  centsToInput,
  EXPENSE_CATEGORIES,
  fmtDay,
  formatBRL,
  INCOME_CATEGORIES,
  methodLabel,
  METHODS,
  monthLabel,
  monthShift,
  newRequestId,
  parseBRL,
} from '../../../../lib/money';
import { Page, usePaged } from '../../../../lib/paging';
import { supabase } from '../../../../lib/supabase';
import { colors } from '../../../../lib/theme';
import { Button, Card, Chips, ErrorText, Input, ListScreen, Screen, Sub, Title } from '../../../../lib/ui';

type Movement = {
  source: 'payment' | 'entry';
  id: string;
  direction: 'income' | 'expense';
  category: string;
  description: string;
  amount_cents: number;
  date: string;
  created_at: string;
  method: string | null;
  status: 'settled' | 'pending' | 'cancelled' | 'reversed';
  version?: number;
  notes?: string | null;
  cancel_reason?: string | null;
  author: string | null;
};
type Cursor = { date: string; created_at: string; id: string };
type LedgerPage = { items: Movement[]; next: Cursor | null; total: { count: number; settled_income_cents: number; settled_expense_cents: number } | null };
const DIRECTIONS = [
  { value: 'all', label: 'Tudo' },
  { value: 'income', label: 'Receitas' },
  { value: 'expense', label: 'Despesas' },
] as const;
const PAGE = 40;
const monthEnd = (m: string) => {
  const next = monthShift(m, 1);
  const d = new Date(`${next}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
};

// Receitas e despesas (V4.3): o livro-caixa. Pagamentos de cobranças entram sozinhos como receita; aqui também se
// lançam contribuições, patrocínios e as despesas (campo, arbitragem, água...). Categorias livres. Despesa pendente
// não sai do saldo até ser paga. Cancelar nunca apaga: fica no histórico com o motivo.
// V4.4: páginas do servidor em lista virtualizada (nenhum mês fica cortado), totais do mês calculados no servidor e
// "Repetir" para despesas e receitas recorrentes (abre o formulário já preenchido, com a data de hoje).
export default function Lancamentos() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const today = todayIn();
  const [month, setMonth] = useState(monthShift(today, 0));
  const [direction, setDirection] = useState<string>('all');
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [form, setForm] = useState<{ edit: Movement | null; direction: 'income' | 'expense' } | null>(null);
  const [category, setCategory] = useState('');
  const [desc, setDesc] = useState('');
  const [amount, setAmount] = useState('');
  const [day, setDay] = useState(today);
  const [paid, setPaid] = useState<'settled' | 'pending'>('settled');
  const [method, setMethod] = useState<string>('pix');
  const [notes, setNotes] = useState('');
  const [reqId, setReqId] = useState(newRequestId());
  const [cancelling, setCancelling] = useState<string | null>(null);

  const fetchPage = useCallback(
    async (after: Cursor | null): Promise<Page<Movement, Cursor, LedgerPage['total']>> => {
      const { data, error } = await supabase.rpc('get_finance_ledger_page', {
        p_pelada: id,
        p_from: month,
        p_to: monthEnd(month),
        p_direction: direction === 'all' ? null : direction,
        p_category: null,
        p_after: after,
        p_limit: PAGE,
        p_with_total: after === null,
      });
      if (error) throw error;
      const p = data as LedgerPage;
      return { items: p.items, next: p.next, summary: p.total };
    },
    [id, month, direction],
  );
  const list = usePaged(fetchPage, (x) => x.id);

  function abrir(dir: 'income' | 'expense', edit: Movement | null, copy?: Movement) {
    const src = edit ?? copy ?? null;
    setForm({ edit, direction: dir });
    setCategory(src?.category ?? '');
    setDesc(src?.description ?? '');
    setAmount(src ? centsToInput(src.amount_cents) : '');
    setDay(edit?.date ?? today);
    setPaid(edit?.status === 'pending' ? 'pending' : 'settled');
    setMethod(src?.method ?? 'pix');
    setNotes(edit?.notes ?? '');
    setReqId(newRequestId());
    setMsg(null);
  }

  async function salvar() {
    if (!form) return;
    const cents = parseBRL(amount);
    if (!cents) return setMsg('Valor inválido. Use, por exemplo, 50 ou 50,00.');
    setBusy(true);
    const { error } = await supabase.rpc('save_finance_entry', {
      p_pelada: id,
      p_id: form.edit?.id ?? null,
      p_direction: form.direction,
      p_category: category.trim(),
      p_description: desc.trim(),
      p_amount_cents: cents,
      p_entry_date: day,
      p_status: paid,
      p_method: paid === 'settled' ? method : null,
      p_notes: notes.trim() || null,
      p_request_id: form.edit ? null : reqId,
      p_expected_version: form.edit?.version ?? null,
    });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    setForm(null);
    list.refresh();
  }

  async function cancelar(row: Movement) {
    setBusy(true);
    const { error } = await supabase.rpc('cancel_finance_entry', { p_id: row.id, p_reason: notes.trim() });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    setCancelling(null);
    list.refresh();
  }

  if (form) {
    const income = form.direction === 'income';
    const suggestions = income ? INCOME_CATEGORIES : EXPENSE_CATEGORIES;
    return (
      <Screen>
        <Title>{form.edit ? 'Alterar lançamento' : income ? 'Nova receita' : 'Nova despesa'}</Title>
        <Field label="Categoria (escolha ou escreva outra)">
          <Chips options={suggestions.map((c) => ({ value: c, label: c }))} value={suggestions.includes(category) ? category : null} onChange={setCategory} />
          <Input value={category} onChangeText={setCategory} placeholder="Categoria" maxLength={40} autoCapitalize="sentences" />
        </Field>
        <Field label="Descrição">
          <Input value={desc} onChangeText={setDesc} placeholder={income ? 'Ex.: patrocínio da padaria' : 'Ex.: campo de outubro'} maxLength={120} autoCapitalize="sentences" />
        </Field>
        <Field label="Valor (R$)">
          <Input value={amount} onChangeText={setAmount} placeholder="0,00" keyboardType="decimal-pad" />
        </Field>
        <Field label="Situação">
          <Chips
            options={[
              { value: 'settled', label: income ? 'Recebido' : 'Pago' },
              { value: 'pending', label: income ? 'A receber' : 'A pagar' },
            ]}
            value={paid}
            onChange={(v) => setPaid(v as 'settled' | 'pending')}
          />
        </Field>
        <DateField label={paid === 'settled' ? (income ? 'Data do recebimento' : 'Data do pagamento') : 'Data prevista'} value={day} onChange={setDay} today={today} />
        {paid === 'settled' && (
          <Field label="Forma (só informativa)">
            <Chips options={METHODS} value={method} onChange={(v) => setMethod(v)} />
          </Field>
        )}
        <Input value={notes} onChangeText={setNotes} placeholder="Observação (opcional)" maxLength={200} autoCapitalize="sentences" />
        <ErrorText>{msg}</ErrorText>
        <Button title="Salvar" onPress={salvar} loading={busy} disabled={!category.trim() || !desc.trim()} />
        <Button title="Voltar" kind="secondary" onPress={() => setForm(null)} />
      </Screen>
    );
  }

  const t = list.summary;
  const header = (
    <>
      <Title>Receitas e despesas</Title>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
        <Pressable accessibilityRole="button" accessibilityLabel="Mês anterior" onPress={() => setMonth(monthShift(month, -1))} style={{ minWidth: 44, minHeight: 44, justifyContent: 'center' }}>
          <Text style={{ color: colors.blue, fontSize: 22, fontWeight: '800' }}>‹</Text>
        </Pressable>
        <Text style={{ fontWeight: '800', color: colors.deepBlue, fontSize: 16 }}>{monthLabel(month)}</Text>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Próximo mês"
          onPress={() => setMonth(monthShift(month, 1))}
          disabled={month >= monthShift(today, 0)}
          style={{ minWidth: 44, minHeight: 44, justifyContent: 'center', alignItems: 'flex-end', opacity: month >= monthShift(today, 0) ? 0.3 : 1 }}>
          <Text style={{ color: colors.blue, fontSize: 22, fontWeight: '800' }}>›</Text>
        </Pressable>
      </View>
      <Chips options={DIRECTIONS} value={direction} onChange={(v) => setDirection(v)} />
      {t && (
        <Sub>
          No mês (efetivado): receitas {formatBRL(t.settled_income_cents)} · despesas {formatBRL(t.settled_expense_cents)} · resultado{' '}
          {formatBRL(t.settled_income_cents - t.settled_expense_cents)} · {t.count} {t.count === 1 ? 'movimentação' : 'movimentações'}
        </Sub>
      )}
      <View style={{ flexDirection: 'row', gap: 8 }}>
        <View style={{ flex: 1 }}>
          <Button title="+ Receita" onPress={() => abrir('income', null)} />
        </View>
        <View style={{ flex: 1 }}>
          <Button title="+ Despesa" kind="secondary" onPress={() => abrir('expense', null)} />
        </View>
      </View>
      <ErrorText>{msg ?? list.error}</ErrorText>
      {list.error && <Button title="Tentar de novo" kind="secondary" onPress={list.refresh} />}
      {!list.items && !list.error && <Sub>Carregando...</Sub>}
    </>
  );

  return (
    <ListScreen
      header={header}
      data={list.items}
      keyExtractor={(r) => `${r.source}-${r.id}`}
      empty={<Sub>Nenhum lançamento neste mês.</Sub>}
      loadingMore={list.loadingMore}
      onEndReached={list.loadMore}
      footer={list.hasMore && !list.loadingMore ? <Button title="Carregar mais" kind="secondary" onPress={list.loadMore} /> : null}
      renderItem={(r) => (
        <Card>
          <View style={{ flexDirection: 'row', gap: 8, alignItems: 'center' }}>
            <View style={{ flex: 1 }}>
              <Text style={{ color: colors.ink, fontWeight: '600' }}>{r.description}</Text>
              <Sub>
                {fmtDay(r.date)} · {r.category}
                {r.method ? ` · ${methodLabel(r.method)}` : ''}
                {r.author ? ` · por ${r.author}` : ''}
              </Sub>
            </View>
            <Text
              style={{
                fontWeight: '800',
                fontVariant: ['tabular-nums'],
                color: r.status !== 'settled' ? colors.muted : r.direction === 'income' ? colors.blue : colors.danger,
                textDecorationLine: r.status === 'cancelled' || r.status === 'reversed' ? 'line-through' : 'none',
              }}>
              {r.direction === 'income' ? '+' : '−'}
              {formatBRL(r.amount_cents)}
            </Text>
          </View>
          {r.status === 'pending' && <Text style={{ color: colors.darkGold, fontWeight: '600' }}>{r.direction === 'income' ? 'A receber' : 'A pagar'}</Text>}
          {r.status === 'cancelled' && <Sub>Cancelado{r.cancel_reason ? `: ${r.cancel_reason}` : ''}</Sub>}
          {r.status === 'reversed' && <Sub>Pagamento estornado{r.cancel_reason ? `: ${r.cancel_reason}` : ''} (veja em Cobranças).</Sub>}
          {r.source === 'payment' && r.status === 'settled' && <Sub>Pagamento de cobrança (altere ou estorne em Cobranças).</Sub>}
          {r.source === 'entry' && cancelling !== r.id && (
            <View style={{ flexDirection: 'row', gap: 16, flexWrap: 'wrap' }}>
              {(r.status === 'settled' || r.status === 'pending') && (
                <Pressable accessibilityRole="button" onPress={() => abrir(r.direction, r)} style={{ minHeight: 40, justifyContent: 'center' }}>
                  <Text style={{ color: colors.blue, fontWeight: '600' }}>{r.status === 'pending' ? 'Alterar / marcar como pago' : 'Alterar'}</Text>
                </Pressable>
              )}
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={`Repetir ${r.description} com a data de hoje`}
                onPress={() => abrir(r.direction, null, r)}
                style={{ minHeight: 40, justifyContent: 'center' }}>
                <Text style={{ color: colors.blue, fontWeight: '600' }}>Repetir</Text>
              </Pressable>
              {(r.status === 'settled' || r.status === 'pending') && (
                <Pressable
                  accessibilityRole="button"
                  onPress={() => {
                    setNotes('');
                    setCancelling(r.id);
                  }}
                  style={{ minHeight: 40, justifyContent: 'center' }}>
                  <Text style={{ color: colors.danger, fontWeight: '600' }}>Cancelar</Text>
                </Pressable>
              )}
            </View>
          )}
          {cancelling === r.id && (
            <View style={{ gap: 8 }}>
              <Input value={notes} onChangeText={setNotes} placeholder="Motivo (obrigatório)" maxLength={200} autoCapitalize="sentences" />
              <Button title="Cancelar lançamento" kind="danger" onPress={() => cancelar(r)} loading={busy} disabled={notes.trim().length < 3} />
              <Button title="Voltar" kind="secondary" onPress={() => setCancelling(null)} />
            </View>
          )}
        </Card>
      )}
    />
  );
}
