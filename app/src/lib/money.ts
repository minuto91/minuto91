// Financeiro da Pelada Premium (V4.3, migração 043): utilitários do app. Valores sempre em centavos inteiros
// (nunca float); os números oficiais (saldo, pendências, relatórios) vêm calculados do servidor. O Minuto 91 não
// movimenta dinheiro: a forma de pagamento é só informativa. Funções puras (testadas em supabase/local_db/money_logic.test.mjs).
/** 12345 -> "R$ 123,45" (negativo: "-R$ 57,00"). */
export function formatBRL(cents: number | string | null | undefined): string {
  const v = Number(cents ?? 0);
  const abs = Math.abs(Math.trunc(v));
  const reais = Math.floor(abs / 100)
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, '.');
  const cts = String(abs % 100).padStart(2, '0');
  return `${v < 0 ? '-' : ''}R$ ${reais},${cts}`;
}

/** "50" / "50,5" / "1.234,56" / "R$ 12,30" -> centavos inteiros; null se inválido ou <= 0. */
export function parseBRL(text: string): number | null {
  const t = text.replace(/R\$|\s/g, '');
  if (!/^\d{1,3}(\.\d{3})*(,\d{1,2})?$|^\d+(,\d{1,2})?$|^\d+(\.\d{1,2})?$/.test(t)) return null;
  // Vírgula é o separador decimal; ponto só é decimal quando não houver vírgula e tiver 1-2 casas no fim.
  let reais: string;
  let cts = '0';
  if (t.includes(',')) {
    [reais, cts] = t.split(',');
    reais = reais.replace(/\./g, '');
  } else if (/\.\d{1,2}$/.test(t) && !/^\d{1,3}(\.\d{3})+$/.test(t)) {
    [reais, cts] = t.split('.');
  } else reais = t.replace(/\./g, '');
  const v = Number(reais) * 100 + Number(cts.padEnd(2, '0'));
  return Number.isSafeInteger(v) && v > 0 && v <= 100000000 ? v : null;
}

/** Centavos -> texto editável ("50,00"). */
export const centsToInput = (cents: number) => formatBRL(cents).replace('R$ ', '').replace('-', '');

/** Chave de idempotência de um envio (mesmo toque duplo = um registro só no servidor). */
export function newRequestId(): string {
  const c = (globalThis as { crypto?: { randomUUID?: () => string } }).crypto;
  if (c?.randomUUID) return c.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (ch) => {
    const r = (Math.random() * 16) | 0;
    return (ch === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

/** "2026-10-22" -> "22/10/2026". */
export const fmtDay = (iso: string | null | undefined) => (iso ? `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}` : '');

/** "22/10/2026" (ou "22/10/26") -> "2026-10-22"; null se a data não existe. */
export function parseDay(text: string): string | null {
  const m = text.trim().match(/^(\d{1,2})\/(\d{1,2})\/(\d{2}|\d{4})$/);
  if (!m) return null;
  const y = m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3]);
  const mo = Number(m[2]);
  const d = Number(m[1]);
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) return null;
  return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

const MONTHS = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
/** "2026-10-01" -> "outubro de 2026". */
export const monthLabel = (iso: string) => `${MONTHS[Number(iso.slice(5, 7)) - 1]} de ${iso.slice(0, 4)}`;
/** Primeiro dia do mês, deslocado em n meses ("2026-10-22", -1 -> "2026-09-01"). */
export function monthShift(iso: string, n: number): string {
  const y = Number(iso.slice(0, 4));
  const m = Number(iso.slice(5, 7)) - 1 + n;
  const yy = y + Math.floor(m / 12);
  const mm = ((m % 12) + 12) % 12;
  return `${yy}-${String(mm + 1).padStart(2, '0')}-01`;
}

export const METHODS = [
  { value: 'pix', label: 'Pix' },
  { value: 'dinheiro', label: 'Dinheiro' },
  { value: 'cartao', label: 'Cartão' },
  { value: 'transferencia', label: 'Transferência' },
  { value: 'outro', label: 'Outro' },
] as const;
export const methodLabel = (v: string | null | undefined) => METHODS.find((m) => m.value === v)?.label ?? '';

/** Sugestões (as categorias são livres). */
export const INCOME_CATEGORIES = ['Contribuição extraordinária', 'Patrocínio', 'Venda de uniformes', 'Outras receitas'];
export const EXPENSE_CATEGORIES = ['Aluguel do campo', 'Arbitragem', 'Material esportivo', 'Água', 'Uniformes', 'Outras despesas'];

export const CHARGE_STATUS: Record<string, string> = { pending: 'Pendente', partial: 'Parcialmente pago', paid: 'Pago', cancelled: 'Cancelado' };
export const CHARGE_KIND: Record<string, string> = { monthly: 'Mensalidade', single: 'Avulso', extra: 'Contribuição extraordinária' };

/**
 * Uma linha de CSV (separador ;, como o Excel em português abre). V4.4: texto livre que começa com = + - @ (ou tab/enter)
 * ganha um apóstrofo na frente, para a planilha não executar como fórmula (nomes e descrições são digitados à mão).
 * Números (valores) não passam por isso.
 */
export const csvRow = (cols: (string | number | null | undefined)[]) =>
  cols
    .map((c) => {
      const s = String(c ?? '');
      const safe = typeof c === 'string' && /^[=+\-@\t\r]/.test(s) ? `'${s}` : s;
      return `"${safe.replace(/"/g, '""')}"`;
    })
    .join(';');
