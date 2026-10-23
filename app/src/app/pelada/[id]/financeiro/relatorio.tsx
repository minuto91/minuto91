import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { todayIn } from '../../../../lib/dates';
import { friendly } from '../../../../lib/errors';
import { exportCsvFile, Stat } from '../../../../lib/financeui';
import { csvRow, fmtDay, formatBRL, methodLabel, monthLabel, monthShift } from '../../../../lib/money';
import { readAllPages } from '../../../../lib/paging';
import { supabase } from '../../../../lib/supabase';
import { colors } from '../../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Screen, Sub, Title } from '../../../../lib/ui';

type Report = {
  month: string;
  income_cents: number;
  expense_cents: number;
  result_cents: number;
  open_cents: number;
  pending_income_cents?: number;
  pending_expense_cents?: number;
  reversed_cents?: number;
  movements_count?: number;
  by_category: { direction: 'income' | 'expense'; category: string; amount_cents: number }[];
  by_person: { name: string; due_cents: number | null; paid_cents: number; open_total_cents: number | null }[];
};
type Cursor = { date: string; created_at: string; id: string };
type Event = { id: number; event_type: string; entity: string; before: Record<string, unknown> | null; after: Record<string, unknown> | null; created_at: string; author: string | null };
type Movement = { id: string; created_at: string; date: string; direction: string; category: string; description: string; amount_cents: number; method: string | null; status: string; author: string | null };

const EVENT_LABEL: Record<string, string> = {
  access_granted: 'Permissão financeira dada',
  access_revoked: 'Permissão financeira retirada',
  payer_created: 'Pessoa de fora cadastrada',
  payer_updated: 'Pessoa de fora alterada',
  monthly_created: 'Mensalista cadastrado',
  monthly_updated: 'Mensalista alterado',
  monthly_status: 'Situação do mensalista',
  charge_created: 'Cobrança criada',
  charge_updated: 'Cobrança alterada',
  charge_due_date_changed: 'Vencimento alterado',
  charge_cancelled: 'Cobrança cancelada',
  payment_registered: 'Pagamento registrado',
  payment_reversed: 'Pagamento estornado',
  entry_created: 'Lançamento criado',
  entry_updated: 'Lançamento alterado',
  entry_cancelled: 'Lançamento cancelado',
};
const STATUS_CSV: Record<string, string> = { settled: 'Efetivado', pending: 'Pendente', cancelled: 'Cancelado', reversed: 'Estornado' };
const TABS = [
  { value: 'mes', label: 'Resumo do mês' },
  { value: 'historico', label: 'Auditoria' },
] as const;
const money = (v: unknown) => (typeof v === 'number' ? formatBRL(v) : null);

// Relatórios do Financeiro (V4.3): resumo mensal, por categoria e por jogador, e o histórico de auditoria (quem fez o
// quê, quando, com valores antes e depois). Exportação simples em CSV pelo compartilhamento do celular.
export default function Relatorio() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const today = todayIn();
  const [tab, setTab] = useState<'mes' | 'historico'>('mes');
  const [month, setMonth] = useState(monthShift(today, 0));
  const [report, setReport] = useState<Report | null>(null);
  const [events, setEvents] = useState<Event[] | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState<string | null>(null);
  const [moreEvents, setMoreEvents] = useState<number | null>(null);

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        const [{ data: r, error }, { data: ev, error: e2 }] = await Promise.all([
          supabase.rpc('get_finance_report', { p_pelada: id, p_month: month }),
          supabase.rpc('get_finance_history_page', { p_pelada: id, p_before: null, p_limit: 50 }),
        ]);
        if (!alive) return;
        if (error || e2) return setMsg(friendly((error ?? e2)!.message));
        setMsg(null);
        setReport(r as Report);
        const h = ev as { items: Event[]; next: number | null };
        setEvents(h.items);
        setMoreEvents(h.next);
      })();
      return () => {
        alive = false;
      };
    }, [id, month]),
  );

  // V4.4: lê TODAS as movimentações do mês em páginas de 500 e só gera o arquivo se o que leu bate com o total do
  // servidor. Se a internet cair no meio, nada é entregue pela metade.
  async function exportar() {
    setBusy(true);
    setMsg(null);
    setProgress('Preparando...');
    const last = new Date(`${monthShift(month, 1)}T12:00:00Z`);
    last.setUTCDate(last.getUTCDate() - 1);
    let expected: number | null = null;
    try {
      const rows = await readAllPages<Movement, Cursor>(
        async (after) => {
          const { data, error } = await supabase.rpc('get_finance_ledger_page', {
            p_pelada: id,
            p_from: month,
            p_to: last.toISOString().slice(0, 10),
            p_direction: null,
            p_category: null,
            p_after: after,
            p_limit: 500,
            p_with_total: after === null,
          });
          if (error) throw error;
          const p = data as { items: Movement[]; next: Cursor | null; total: { count: number } | null };
          if (p.total) expected = p.total.count;
          return p;
        },
        (n) => setProgress(`Lendo movimentações: ${n}${expected !== null ? ` de ${expected}` : ''}`),
      );
      if (expected !== null && rows.length !== expected) throw new Error('EXPORT_INCOMPLETE');
      const lines = rows.map((m) =>
        csvRow([fmtDay(m.date), m.direction === 'income' ? 'Receita' : 'Despesa', m.category, m.description, (m.amount_cents / 100).toFixed(2).replace('.', ','), methodLabel(m.method), STATUS_CSV[m.status] ?? m.status, m.author]),
      );
      const csv = [csvRow(['Data', 'Tipo', 'Categoria', 'Descrição', 'Valor (R$)', 'Forma', 'Situação', 'Responsável']), ...lines].join('\n');
      setProgress(`${rows.length} ${rows.length === 1 ? 'movimentação' : 'movimentações'} na planilha.`);
      await exportCsvFile(`financeiro-${month.slice(0, 7)}`, `Financeiro ${monthLabel(month)}`, csv);
    } catch (e) {
      setProgress(null);
      const m = (e as Error).message;
      setMsg(m === 'EXPORT_INCOMPLETE' ? 'A exportação não leu todas as movimentações. Nada foi gerado: tente de novo.' : `Não foi possível exportar: ${friendly(m)}`);
    }
    setBusy(false);
  }

  async function maisEventos() {
    if (moreEvents === null) return;
    const { data, error } = await supabase.rpc('get_finance_history_page', { p_pelada: id, p_before: moreEvents, p_limit: 50 });
    if (error) return setMsg(friendly(error.message));
    const h = data as { items: Event[]; next: number | null };
    setEvents((xs) => [...(xs ?? []), ...h.items]);
    setMoreEvents(h.next);
  }

  const incomeCats = report?.by_category.filter((c) => c.direction === 'income') ?? [];
  const expenseCats = report?.by_category.filter((c) => c.direction === 'expense') ?? [];

  return (
    <Screen>
      <Title>Relatórios</Title>
      <Chips options={TABS} value={tab} onChange={(v) => setTab(v as 'mes' | 'historico')} />
      <ErrorText>{msg}</ErrorText>
      {tab === 'mes' && (
        <>
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
          {!report && !msg && <Sub>Carregando...</Sub>}
          {report && (
            <>
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                <Stat label="Receitas" cents={report.income_cents} />
                <Stat label="Despesas" cents={report.expense_cents} tone="ink" />
                <Stat label="Resultado do mês" cents={report.result_cents} tone={report.result_cents < 0 ? 'danger' : 'blue'} />
                <Stat label="Em aberto (vencem no mês)" cents={report.open_cents} tone="gold" />
              </View>
              <Card>
                <Body>Origem das receitas</Body>
                {incomeCats.length === 0 && <Sub>Nenhuma receita no mês.</Sub>}
                {incomeCats.map((c) => (
                  <Bar key={c.category} label={c.category} cents={c.amount_cents} total={report.income_cents} color={colors.blue} />
                ))}
              </Card>
              <Card>
                <Body>Distribuição das despesas</Body>
                {expenseCats.length === 0 && <Sub>Nenhuma despesa no mês.</Sub>}
                {expenseCats.map((c) => (
                  <Bar key={c.category} label={c.category} cents={c.amount_cents} total={report.expense_cents} color={colors.gold} />
                ))}
              </Card>
              <Card>
                <Body>Por jogador</Body>
                <Sub>Devido e pago no mês; em aberto no total.</Sub>
                {report.by_person.length === 0 && <Sub>Nada no mês.</Sub>}
                {report.by_person.map((p, i) => (
                  <View key={`${p.name}-${i}`} style={{ paddingVertical: 6, borderBottomWidth: 1, borderBottomColor: colors.line }}>
                    <Text style={{ color: colors.ink, fontWeight: '600' }}>{p.name}</Text>
                    <Text style={{ color: colors.muted, fontSize: 13, fontVariant: ['tabular-nums'] }}>
                      Devido {formatBRL(p.due_cents ?? 0)} · pago {formatBRL(p.paid_cents)}
                      {p.open_total_cents ? ` · em aberto ${formatBRL(p.open_total_cents)}` : ''}
                    </Text>
                  </View>
                ))}
              </Card>
              {(report.pending_income_cents || report.pending_expense_cents || report.reversed_cents) ? (
                <Card>
                  <Body>Fora do resultado</Body>
                  <Sub>Pendências e estornos não entram nas receitas, nas despesas nem no saldo.</Sub>
                  {!!report.pending_income_cents && <Sub>Receitas a receber no mês: {formatBRL(report.pending_income_cents)}</Sub>}
                  {!!report.pending_expense_cents && <Sub>Despesas a pagar no mês: {formatBRL(report.pending_expense_cents)}</Sub>}
                  {!!report.reversed_cents && <Sub>Pagamentos estornados: {formatBRL(report.reversed_cents)}</Sub>}
                </Card>
              ) : null}
              <Button
                title={report.movements_count !== undefined ? `Exportar as ${report.movements_count} movimentações do mês (CSV)` : 'Exportar movimentações do mês (CSV)'}
                kind="secondary"
                onPress={exportar}
                loading={busy}
              />
              {progress && <Sub>{progress}</Sub>}
            </>
          )}
        </>
      )}
      {tab === 'historico' && (
        <>
          <Sub>Tudo o que muda no Financeiro fica registrado: quem, quando e os valores antes e depois. Nada é apagado.</Sub>
          {!events && !msg && <Sub>Carregando...</Sub>}
          {events?.length === 0 && <Sub>Nada registrado ainda.</Sub>}
          {events?.map((e) => {
            const before = e.before ?? {};
            const after = e.after ?? {};
            const detail = [
              money(after.amount_cents) && `valor ${money(before.amount_cents) ? `${money(before.amount_cents)} → ` : ''}${money(after.amount_cents)}`,
              money(after.amount_due_cents) && `devido ${money(before.amount_due_cents) ? `${money(before.amount_due_cents)} → ` : ''}${money(after.amount_due_cents)}`,
              typeof after.due_date === 'string' && `vencimento ${typeof before.due_date === 'string' ? `${fmtDay(before.due_date)} → ` : ''}${fmtDay(after.due_date)}`,
              typeof after.status === 'string' && typeof before.status === 'string' && `situação ${before.status} → ${after.status}`,
              typeof after.reason === 'string' && `motivo: ${after.reason}`,
            ].filter(Boolean);
            return (
              <View key={e.id} style={{ paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: colors.line, gap: 2 }}>
                <Text style={{ color: colors.ink, fontWeight: '600' }}>{EVENT_LABEL[e.event_type] ?? e.event_type}</Text>
                <Text style={{ color: colors.muted, fontSize: 12 }}>
                  {new Date(e.created_at).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })} · {e.author ?? 'conta excluída'}
                </Text>
                {detail.length > 0 && <Text style={{ color: colors.muted, fontSize: 12 }}>{detail.join(' · ')}</Text>}
              </View>
            );
          })}
          {moreEvents !== null && <Button title="Carregar mais" kind="secondary" onPress={maisEventos} />}
        </>
      )}
    </Screen>
  );
}

function Bar({ label, cents, total, color }: { label: string; cents: number; total: number; color: string }) {
  const pct = total > 0 ? Math.max(2, Math.round((cents / total) * 100)) : 0;
  return (
    <View style={{ gap: 2, paddingVertical: 4 }}>
      <View style={{ flexDirection: 'row' }}>
        <Text style={{ flex: 1, color: colors.ink }}>{label}</Text>
        <Text style={{ color: colors.ink, fontWeight: '700', fontVariant: ['tabular-nums'] }}>{formatBRL(cents)}</Text>
      </View>
      <View style={{ height: 6, borderRadius: 3, backgroundColor: colors.bg }}>
        <View style={{ width: `${pct}%`, height: 6, borderRadius: 3, backgroundColor: color }} />
      </View>
    </View>
  );
}
