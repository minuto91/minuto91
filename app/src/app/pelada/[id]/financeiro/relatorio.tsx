import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { todayIn } from '../../../../lib/dates';
import { notify } from '../../../../lib/dialog';
import { friendly } from '../../../../lib/errors';
import { exportText, Stat } from '../../../../lib/financeui';
import { csvRow, fmtDay, formatBRL, monthLabel, monthShift } from '../../../../lib/money';
import { supabase } from '../../../../lib/supabase';
import { colors } from '../../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Screen, Sub, Title } from '../../../../lib/ui';

type Report = {
  month: string;
  income_cents: number;
  expense_cents: number;
  result_cents: number;
  open_cents: number;
  by_category: { direction: 'income' | 'expense'; category: string; amount_cents: number }[];
  by_person: { name: string; due_cents: number | null; paid_cents: number; open_total_cents: number | null }[];
};
type Event = { id: number; event_type: string; entity: string; before: Record<string, unknown> | null; after: Record<string, unknown> | null; created_at: string; author: string | null };
type Movement = { date: string; direction: string; category: string; description: string; amount_cents: number; method: string | null; status: string; author: string | null };

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

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        const [{ data: r, error }, { data: ev, error: e2 }] = await Promise.all([
          supabase.rpc('get_finance_report', { p_pelada: id, p_month: month }),
          supabase.rpc('get_finance_history', { p_pelada: id, p_limit: 200 }),
        ]);
        if (!alive) return;
        if (error || e2) return setMsg(friendly((error ?? e2)!.message));
        setMsg(null);
        setReport(r as Report);
        setEvents(ev as Event[]);
      })();
      return () => {
        alive = false;
      };
    }, [id, month]),
  );

  async function exportar() {
    setBusy(true);
    const { data, error } = await supabase.rpc('get_finance_ledger', { p_pelada: id, p_month: month, p_direction: null, p_category: null, p_limit: 1000 });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    const rows = (data as Movement[]).map((m) =>
      csvRow([fmtDay(m.date), m.direction === 'income' ? 'Receita' : 'Despesa', m.category, m.description, (m.amount_cents / 100).toFixed(2).replace('.', ','), m.method, m.status, m.author]),
    );
    const csv = [csvRow(['Data', 'Tipo', 'Categoria', 'Descrição', 'Valor (R$)', 'Forma', 'Situação', 'Responsável']), ...rows].join('\n');
    const how = await exportText(`Financeiro ${monthLabel(month)}`, csv);
    if (how === 'copied') notify('Copiado', 'A planilha (CSV) foi copiada. Cole numa planilha ou mensagem.');
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
              <Button title="Exportar movimentações do mês (CSV)" kind="secondary" onPress={exportar} loading={busy} />
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
