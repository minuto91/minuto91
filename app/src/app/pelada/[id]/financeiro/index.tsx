import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, Switch, Text, View } from 'react-native';

import { friendly } from '../../../../lib/errors';
import { Stat } from '../../../../lib/financeui';
import { fmtDay, formatBRL, monthLabel } from '../../../../lib/money';
import { supabase } from '../../../../lib/supabase';
import { colors } from '../../../../lib/theme';
import { Body, Button, Card, ErrorText, Screen, Sub, Title } from '../../../../lib/ui';

type Access = {
  can_access: boolean;
  premium: boolean;
  is_admin: boolean;
  has_records: boolean | null;
  assistants: { membership_id: string; name: string; enabled: boolean }[] | null;
};
type Movement = {
  source: 'payment' | 'entry';
  id: string;
  direction: 'income' | 'expense';
  category: string;
  description: string;
  amount_cents: number;
  date: string;
  status: string;
  author: string | null;
};
type Overview = {
  today: string;
  month: string;
  balance_cents: number;
  month_income_cents: number;
  month_expense_cents: number;
  receivable_cents: number;
  overdue_cents: number;
  pending_expense_cents: number;
  projected_balance_cents: number;
  monthly_active: number;
  monthly_late: number;
  single_count_month: number;
  month_charges_missing: number;
  latest: Movement[];
};

// Financeiro da Pelada Premium (V4.3): livro-caixa digital para o administrador e os assistentes com permissão
// financeira. O Minuto 91 não cobra, não recebe e não movimenta dinheiro: tudo aqui é registro feito por eles.
// Saldo = o que foi recebido menos o que foi pago; pendências e projeção ficam separadas (calculadas no servidor).
export default function Financeiro() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [access, setAccess] = useState<Access | null>(null);
  const [ov, setOv] = useState<Overview | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        void reload;
        const { data: a, error } = await supabase.rpc('get_finance_access', { p_pelada: id });
        if (!alive) return;
        if (error) return setMsg(friendly(error.message));
        setAccess(a as Access);
        if (!(a as Access).can_access || !(a as Access).premium) return;
        const { data: o, error: e2 } = await supabase.rpc('get_finance_overview', { p_pelada: id });
        if (!alive) return;
        if (e2) return setMsg(friendly(e2.message));
        setMsg(null);
        setOv(o as Overview);
      })();
      return () => {
        alive = false;
      };
    }, [id, reload]),
  );

  const go = (path: 'cobrancas' | 'mensalistas' | 'lancamentos' | 'relatorio') =>
    router.push({ pathname: `/pelada/[id]/financeiro/${path}`, params: { id } });

  async function gerar() {
    setBusy('gerar');
    const { data, error } = await supabase.rpc('generate_monthly_charges', { p_pelada: id, p_month: ov?.month ?? null });
    setBusy(null);
    if (error) return setMsg(friendly(error.message));
    setMsg(null);
    setReload((n) => n + 1);
    if (!data) setMsg('Nenhuma mensalidade nova para gerar.');
  }

  async function permissao(membership: string, enabled: boolean) {
    setBusy(membership);
    const { error } = await supabase.rpc('set_finance_access', { p_pelada: id, p_membership: membership, p_enabled: enabled });
    setBusy(null);
    if (error) return setMsg(friendly(error.message));
    setReload((n) => n + 1);
  }

  if (!access) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }
  if (!access.can_access) {
    return (
      <Screen>
        <Title>Financeiro</Title>
        <Sub>O Financeiro é só do administrador e dos assistentes que ele autorizar.</Sub>
      </Screen>
    );
  }
  if (!access.premium) {
    return (
      <Screen>
        <Title>Financeiro</Title>
        <Card>
          <Body>Recurso da Pelada Premium</Body>
          <Sub>
            {access.has_records
              ? 'A Pelada Premium desta pelada não está ativa. Todos os registros financeiros continuam guardados e voltam a aparecer quando a assinatura for reativada. Nada foi apagado.'
              : 'Controle mensalistas, avulsos, receitas, despesas e o saldo do caixa da pelada. O app não faz cobranças nem pagamentos: é um livro-caixa.'}
          </Sub>
          <Button title="Conhecer a Pelada Premium" onPress={() => router.push({ pathname: '/pelada/[id]/premium', params: { id } })} />
        </Card>
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>Financeiro</Title>
      <Sub>{ov ? `Caixa da pelada · ${monthLabel(ov.month)}` : 'Caixa da pelada'}</Sub>
      <ErrorText>{msg}</ErrorText>
      {!ov && !msg && <Sub>Carregando...</Sub>}
      {ov && (
        <>
          <View style={{ borderRadius: 14, backgroundColor: colors.deepBlue, padding: 16, gap: 4 }}>
            <Text style={{ color: colors.white, opacity: 0.8, fontSize: 13, fontWeight: '600' }}>Saldo atual (recebido − pago)</Text>
            <Text style={{ color: colors.white, fontSize: 32, fontWeight: '900', fontVariant: ['tabular-nums'] }}>{formatBRL(ov.balance_cents)}</Text>
            <Text style={{ color: colors.gold, fontSize: 12, fontWeight: '700' }}>
              Projeção com pendências: {formatBRL(ov.projected_balance_cents)}
            </Text>
          </View>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
            <Stat label="Receitas do mês" cents={ov.month_income_cents} />
            <Stat label="Despesas do mês" cents={ov.month_expense_cents} tone="ink" />
            <Stat label="A receber" cents={ov.receivable_cents} tone="gold" hint={ov.overdue_cents > 0 ? `${formatBRL(ov.overdue_cents)} vencido` : 'nada vencido'} />
            <Stat label="Despesas pendentes" cents={ov.pending_expense_cents} tone={ov.pending_expense_cents > 0 ? 'danger' : 'ink'} />
          </View>
          <Card>
            <Body>Mensalistas</Body>
            <Sub>
              {ov.monthly_active} {ov.monthly_active === 1 ? 'ativo' : 'ativos'} · {ov.monthly_active - ov.monthly_late} em dia ·{' '}
              <Text style={{ color: ov.monthly_late ? colors.danger : colors.muted }}>
                {ov.monthly_late} {ov.monthly_late === 1 ? 'atrasado' : 'atrasados'}
              </Text>
            </Sub>
            <Sub>Avulsos neste mês: {ov.single_count_month}</Sub>
            {ov.month_charges_missing > 0 && (
              <Button
                title={`Gerar mensalidades de ${monthLabel(ov.month)} (${ov.month_charges_missing})`}
                onPress={gerar}
                loading={busy === 'gerar'}
              />
            )}
          </Card>

          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
            {(
              [
                ['cobrancas', 'Cobranças e pendências'],
                ['mensalistas', 'Mensalistas'],
                ['lancamentos', 'Receitas e despesas'],
                ['relatorio', 'Relatórios'],
              ] as const
            ).map(([p, t]) => (
              <Pressable
                key={p}
                accessibilityRole="button"
                onPress={() => go(p)}
                style={({ pressed }) => ({
                  flexBasis: '47%',
                  flexGrow: 1,
                  minHeight: 56,
                  justifyContent: 'center',
                  paddingHorizontal: 12,
                  borderRadius: 12,
                  borderWidth: 1,
                  borderColor: colors.line,
                  backgroundColor: pressed ? colors.bg : colors.white,
                })}>
                <Text style={{ color: colors.deepBlue, fontWeight: '700' }}>{t} ›</Text>
              </Pressable>
            ))}
          </View>

          <Text style={{ fontSize: 13, fontWeight: '800', color: colors.deepBlue, letterSpacing: 0.5, marginTop: 6 }}>Últimas movimentações</Text>
          {ov.latest.length === 0 && <Sub>Nada registrado ainda.</Sub>}
          {ov.latest.map((m) => (
            <View key={`${m.source}-${m.id}`} style={{ flexDirection: 'row', alignItems: 'center', gap: 8, paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: colors.line }}>
              <View style={{ flex: 1 }}>
                <Text style={{ color: colors.ink }} numberOfLines={1}>
                  {m.description}
                </Text>
                <Text style={{ color: colors.muted, fontSize: 12 }}>
                  {fmtDay(m.date)} · {m.category}
                  {m.status === 'pending' ? ' · pendente' : m.status === 'reversed' ? ' · estornado' : m.status === 'cancelled' ? ' · cancelado' : ''}
                </Text>
              </View>
              <Text
                style={{
                  fontWeight: '800',
                  fontVariant: ['tabular-nums'],
                  color: m.status !== 'settled' ? colors.muted : m.direction === 'income' ? colors.blue : colors.danger,
                  textDecorationLine: m.status === 'reversed' || m.status === 'cancelled' ? 'line-through' : 'none',
                }}>
                {m.direction === 'income' ? '+' : '−'}
                {formatBRL(m.amount_cents)}
              </Text>
            </View>
          ))}
        </>
      )}

      {access.is_admin && (
        <Card>
          <Body>Quem acessa o Financeiro</Body>
          <Sub>Você (administrador) sempre. Assistentes só com a sua autorização. Jogadores não veem valores da pelada.</Sub>
          {(access.assistants ?? []).length === 0 && <Sub>Nenhum assistente na pelada.</Sub>}
          {(access.assistants ?? []).map((a) => (
            <View key={a.membership_id} style={{ flexDirection: 'row', alignItems: 'center', minHeight: 44, gap: 8 }}>
              <Text style={{ flex: 1, color: colors.ink }}>{a.name}</Text>
              <Switch
                value={a.enabled}
                disabled={busy === a.membership_id}
                onValueChange={(v) => permissao(a.membership_id, v)}
                trackColor={{ true: colors.blue, false: colors.line }}
                accessibilityLabel={`Permissão financeira de ${a.name}`}
              />
            </View>
          ))}
        </Card>
      )}
      <Sub>O Minuto 91 não faz cobranças nem pagamentos. Os valores são registrados à mão por quem cuida do caixa.</Sub>
    </Screen>
  );
}
