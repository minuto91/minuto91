// Peças reutilizadas pelas telas do Financeiro (V4.3).
import * as Clipboard from 'expo-clipboard';
import { File, Paths } from 'expo-file-system';
import * as Sharing from 'expo-sharing';
import { ReactNode, useState } from 'react';
import { Platform, Pressable, Share, Text, View } from 'react-native';

import { fmtDay, formatBRL, parseDay } from './money';
import { colors } from './theme';
import { Chips, Input } from './ui';

export type Person = { membership_id?: string | null; payer_id?: string | null; name: string };
export type Charge = {
  id: string;
  kind: 'monthly' | 'single' | 'extra';
  finance_member_id: string | null;
  membership_id: string | null;
  payer_id: string | null;
  person_name: string;
  match_id: string | null;
  reference_month: string | null;
  description: string;
  amount_due_cents: number;
  amount_paid_cents: number;
  outstanding_cents: number;
  due_date: string;
  status: 'pending' | 'partial' | 'paid' | 'cancelled';
  overdue: boolean;
  version: number;
  cancel_reason: string | null;
  payments: {
    id: string;
    amount_cents: number;
    received_on: string;
    method: string | null;
    notes: string | null;
    reversed_at: string | null;
    reverse_reason: string | null;
    created_by_name: string | null;
  }[];
};
export type People = {
  monthly: {
    id: string;
    membership_id: string | null;
    payer_id: string | null;
    person_name: string;
    person_active: boolean;
    amount_cents: number;
    due_day: number;
    starts_on: string;
    ends_on: string | null;
    status: 'active' | 'suspended' | 'ended';
    notes: string | null;
    version: number;
    overdue_cents: number;
    open_cents: number;
  }[];
  payers: { id: string; name: string; notes: string | null }[];
  members: { membership_id: string; name: string }[];
};

/** Valor grande com rótulo (painel). tone: verde não é identidade: positivo azul, negativo vermelho, alerta dourado. */
export function Stat({ label, cents, tone, hint }: { label: string; cents: number; tone?: 'blue' | 'danger' | 'gold' | 'ink'; hint?: string }) {
  const color = tone === 'danger' ? colors.danger : tone === 'gold' ? colors.darkGold : tone === 'ink' ? colors.ink : colors.deepBlue;
  return (
    <View style={{ flexBasis: '47%', flexGrow: 1, borderWidth: 1, borderColor: colors.line, borderRadius: 12, padding: 12, gap: 2 }}>
      <Text style={{ fontSize: 12, color: colors.muted, fontWeight: '600' }}>{label}</Text>
      <Text style={{ fontSize: 20, fontWeight: '800', color, fontVariant: ['tabular-nums'] }}>{formatBRL(cents)}</Text>
      {hint ? <Text style={{ fontSize: 11, color: colors.muted }}>{hint}</Text> : null}
    </View>
  );
}

export function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <View style={{ gap: 4 }}>
      <Text style={{ fontSize: 13, fontWeight: '700', color: colors.muted }}>{label}</Text>
      {children}
    </View>
  );
}

/** Data DD/MM/AAAA com atalho "Hoje". value/onChange em AAAA-MM-DD. */
export function DateField({ label, value, onChange, today }: { label: string; value: string; onChange: (iso: string) => void; today: string }) {
  const [text, setText] = useState(fmtDay(value));
  const [bad, setBad] = useState(false);
  return (
    <Field label={label}>
      <View style={{ flexDirection: 'row', gap: 8, alignItems: 'center' }}>
        <View style={{ flex: 1 }}>
          <Input
            value={text}
            onChangeText={(t) => {
              setText(t);
              const iso = parseDay(t);
              setBad(!iso);
              if (iso) onChange(iso);
            }}
            placeholder="DD/MM/AAAA"
            keyboardType="numbers-and-punctuation"
            accessibilityLabel={label}
          />
        </View>
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            setText(fmtDay(today));
            setBad(false);
            onChange(today);
          }}
          style={{ minHeight: 44, justifyContent: 'center', paddingHorizontal: 12 }}>
          <Text style={{ color: colors.blue, fontWeight: '700' }}>Hoje</Text>
        </Pressable>
      </View>
      {bad && <Text style={{ color: colors.danger, fontSize: 12 }}>Data inválida.</Text>}
    </Field>
  );
}

/** Escolha de quem paga: jogador da pelada ou pessoa de fora (sem conta). */
export function PersonPicker({
  people,
  value,
  onChange,
}: {
  people: People;
  value: Person | null;
  onChange: (p: Person) => void;
}) {
  const [kind, setKind] = useState<'member' | 'payer'>(value?.payer_id ? 'payer' : 'member');
  const [q, setQ] = useState('');
  const list =
    kind === 'member'
      ? people.members.map((m) => ({ key: m.membership_id, name: m.name, p: { membership_id: m.membership_id, name: m.name } }))
      : people.payers.map((x) => ({ key: x.id, name: x.name, p: { payer_id: x.id, name: x.name } }));
  const shown = list.filter((x) => !q.trim() || x.name.toLocaleLowerCase('pt-BR').includes(q.trim().toLocaleLowerCase('pt-BR'))).slice(0, 30);
  return (
    <View style={{ gap: 6 }}>
      <Chips
        options={[
          { value: 'member', label: 'Jogador da pelada' },
          { value: 'payer', label: 'Pessoa de fora' },
        ]}
        value={kind}
        onChange={(v) => setKind(v as 'member' | 'payer')}
      />
      {list.length > 8 && <Input value={q} onChangeText={setQ} placeholder="Buscar pelo nome" autoCapitalize="words" />}
      {shown.length === 0 && (
        <Text style={{ color: colors.muted }}>{kind === 'payer' ? 'Nenhuma pessoa de fora cadastrada.' : 'Nenhum jogador encontrado.'}</Text>
      )}
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
        {shown.map((x) => {
          const on = (value?.membership_id ?? value?.payer_id) === x.key;
          return (
            <Pressable
              key={x.key}
              accessibilityRole="button"
              accessibilityState={{ selected: on }}
              onPress={() => onChange(x.p)}
              style={{
                minHeight: 40,
                justifyContent: 'center',
                paddingHorizontal: 12,
                borderRadius: 20,
                borderWidth: 1,
                borderColor: on ? colors.blue : colors.line,
                backgroundColor: on ? colors.blue : colors.white,
              }}>
              <Text style={{ color: on ? colors.white : colors.ink, fontWeight: '600' }}>{x.name}</Text>
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}

/** Selo da situação da cobrança. */
export function StatusBadge({ status, overdue }: { status: Charge['status']; overdue?: boolean }) {
  const map = {
    pending: { t: overdue ? 'Vencido' : 'Pendente', c: overdue ? colors.danger : colors.darkGold },
    partial: { t: overdue ? 'Parcial · vencido' : 'Parcial', c: overdue ? colors.danger : colors.darkGold },
    paid: { t: 'Pago', c: colors.blue },
    cancelled: { t: 'Cancelado', c: colors.muted },
  }[status];
  return (
    <Text style={{ fontSize: 11, fontWeight: '800', color: map.c, borderWidth: 1, borderColor: map.c, borderRadius: 10, paddingHorizontal: 8, paddingVertical: 2, alignSelf: 'flex-start' }}>
      {map.t.toUpperCase()}
    </Text>
  );
}

/** Exporta texto (CSV) pelo compartilhamento do sistema; na web, copia para a área de transferência. */
export async function exportText(title: string, text: string): Promise<'shared' | 'copied'> {
  if (Platform.OS !== 'web') {
    await Share.share({ title, message: text });
    return 'shared';
  }
  await Clipboard.setStringAsync(text);
  return 'copied';
}

/**
 * V4.4: exporta o CSV como ARQUIVO (planilhas grandes não cabem no texto do compartilhamento do Android).
 * Celular: grava no cache do app e abre o compartilhamento do arquivo. Web: baixa o arquivo.
 * O BOM no início faz o Excel abrir os acentos corretamente.
 */
export async function exportCsvFile(fileName: string, title: string, csv: string): Promise<void> {
  const content = `﻿${csv}`;
  const name = `${fileName.replace(/[^\w.-]+/g, '_')}.csv`;
  if (Platform.OS === 'web') {
    const url = URL.createObjectURL(new Blob([content], { type: 'text/csv;charset=utf-8' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = name;
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
    return;
  }
  const file = new File(Paths.cache, name);
  file.create({ overwrite: true });
  file.write(content);
  if (!(await Sharing.isAvailableAsync())) throw new Error('Compartilhamento indisponível neste aparelho.');
  await Sharing.shareAsync(file.uri, { mimeType: 'text/csv', UTI: 'public.comma-separated-values-text', dialogTitle: title });
}
