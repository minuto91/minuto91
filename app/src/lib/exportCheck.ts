// Conferência da exportação do Financeiro (V4.5), antes de gerar o arquivo. O servidor devolve as linhas e os totais
// do mesmo instantâneo (get_finance_export); se algo não bater (linha repetida, quantidade ou somas), nada é gerado.
// Sem dependências: testado no Node (supabase/local_db/money_logic.test.mjs).

export type ExportRow = { id: string; direction: string; status: string; amount_cents: number };
export type ExportTotal = { count: number; settled_income_cents: number; settled_expense_cents: number; reversed_cents: number };

/** Lista do que não bate (vazia = exportação íntegra). */
export function exportProblems(items: readonly ExportRow[], total: ExportTotal | null | undefined): string[] {
  if (!total) return ['sem total'];
  const ids = new Set<string>();
  let dups = 0;
  let income = 0;
  let expense = 0;
  let reversed = 0;
  for (const x of items) {
    if (ids.has(x.id)) dups++;
    ids.add(x.id);
    if (x.status === 'settled' && x.direction === 'income') income += x.amount_cents;
    else if (x.status === 'settled' && x.direction === 'expense') expense += x.amount_cents;
    else if (x.status === 'reversed') reversed += x.amount_cents;
  }
  const out: string[] = [];
  if (dups) out.push('linha repetida');
  if (items.length !== Number(total.count)) out.push('quantidade');
  if (income !== Number(total.settled_income_cents)) out.push('receitas');
  if (expense !== Number(total.settled_expense_cents)) out.push('despesas');
  if (reversed !== Number(total.reversed_cents)) out.push('estornos');
  return out;
}
