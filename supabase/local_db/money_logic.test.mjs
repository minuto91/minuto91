// V4.3: lógica de valores do Financeiro no app (app/src/lib/money.ts): centavos inteiros, formato R$, leitura do
// que a pessoa digita, datas DD/MM/AAAA e meses (funções puras).
// Uso: cd supabase/local_db; node --test
import assert from 'node:assert/strict';
import { test } from 'node:test';

const m = await import('../../app/src/lib/money.ts');

test('formatBRL: centavos inteiros em reais', () => {
  assert.equal(m.formatBRL(0), 'R$ 0,00');
  assert.equal(m.formatBRL(5), 'R$ 0,05');
  assert.equal(m.formatBRL(123456), 'R$ 1.234,56');
  assert.equal(m.formatBRL(-5700), '-R$ 57,00');
  assert.equal(m.formatBRL(100000000), 'R$ 1.000.000,00');
});

test('parseBRL: o que a pessoa digita vira centavos exatos (sem float)', () => {
  const ok = { '50': 5000, '50,5': 5050, '50,05': 5005, '1.234,56': 123456, 'R$ 12,30': 1230, '0,10': 10, '33,34': 3334, '12.5': 1250, '1.000': 100000 };
  for (const [t, v] of Object.entries(ok)) assert.equal(m.parseBRL(t), v, t);
  for (const t of ['', '0', '0,00', '-10', 'abc', '1,234', '10,999', '1.000.000,01']) assert.equal(m.parseBRL(t), null, t);
  // 0,1 + 0,2 em centavos é exato
  assert.equal(m.parseBRL('0,1') + m.parseBRL('0,2'), m.parseBRL('0,3'));
});

test('datas: DD/MM/AAAA <-> AAAA-MM-DD, sem datas impossíveis', () => {
  assert.equal(m.parseDay('22/10/2026'), '2026-10-22');
  assert.equal(m.parseDay('1/2/26'), '2026-02-01');
  assert.equal(m.parseDay('29/02/2027'), null);
  assert.equal(m.parseDay('31/04/2026'), null);
  assert.equal(m.fmtDay('2026-10-22'), '22/10/2026');
});

test('meses: deslocamento e nome', () => {
  assert.equal(m.monthShift('2026-01-15', -1), '2025-12-01');
  assert.equal(m.monthShift('2026-12-03', 1), '2027-01-01');
  assert.equal(m.monthLabel('2026-10-01'), 'outubro de 2026');
});

test('CSV e chave de idempotência', () => {
  assert.equal(m.csvRow(['a', 'b "c"', null, 3]), '"a";"b ""c""";"";"3"');
  // V4.4: fórmula digitada num nome/descrição não roda na planilha
  assert.equal(m.csvRow(['=HYPERLINK("x")', '+1', '-2', '@SUM(A1)', 'ok']), `"'=HYPERLINK(""x"")";"'+1";"'-2";"'@SUM(A1)";"ok"`);
  assert.equal(m.csvRow([-5]), '"-5"');
  const a = m.newRequestId();
  assert.match(a, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.notEqual(a, m.newRequestId());
});
