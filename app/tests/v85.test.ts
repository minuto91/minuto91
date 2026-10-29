import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  autoPositions,
  checkPages,
  type CompMember,
  countLabel,
  createGate,
  displayNames,
  groupKey,
  idempotent,
  isOutside,
  nameHints,
  overlaps,
  paginateField,
  paginateList,
  type SharePayload,
  summaryText,
} from '../src/lib/v85.ts';

const mk = (n: number, team: 'A' | 'B', extra: Partial<CompMember> = {}): CompMember => ({
  pid: `p${String(n).padStart(3, '0')}`,
  membership_id: `m${n}`,
  guest: false,
  name: `Jogador ${n}`,
  position: 'MEI',
  group: 'MEI',
  team,
  captain: false,
  eligible: true,
  ...extra,
});

test('grupos: CA/PD/PE/ATA juntos; legado sem inventar', () => {
  assert.equal(groupKey('PD'), 'ATA');
  assert.equal(groupKey('attacker'), 'ATA');
  assert.equal(groupKey('defender'), 'DEF');
  assert.equal(groupKey(null), 'none');
});

test('resumo: inevitável explicado, sem OVR', () => {
  const s = summaryText({ cost: 1, size_a: 4, size_b: 3, by_group: [{ group: 'ZAG', a: 2, b: 1 }, { group: 'GOL', a: 1, b: 1 }] }, 1);
  assert.ok(s.unavoidable);
  assert.equal(s.lines[0], 'Goleiros: 1 x 1');
  assert.ok(!JSON.stringify(s).toLowerCase().includes('overall'));
  assert.equal(countLabel('1'), 'só existe 1 divisão ideal');
  assert.match(countLabel('37923487539242125335330816'), /milhões/);
});

test('homônimos: diferenciação discreta e estável', () => {
  const h = nameHints([
    { pid: 'b', name: 'João', position: 'ZAG' },
    { pid: 'a', name: 'joão ', position: 'ATA', guest: true },
    { pid: 'c', name: 'Pedro', position: 'MEI' },
  ]);
  assert.equal(h.a, 'ATA · convidado');
  assert.equal(h.b, 'ZAG');
  assert.equal(h.c, undefined);
  const same = nameHints([
    { pid: 'x', name: 'Ana', position: 'MEI' },
    { pid: 'y', name: 'Ana', position: 'MEI' },
  ]);
  assert.notEqual(same.x, same.y);
});

test('nomes longos: abrevia só sem ambiguidade', () => {
  const d = displayNames([
    { pid: '1', name: 'Carlos Eduardo Albuquerque Souza' },
    { pid: '2', name: 'Carlos Henrique Monteiro Silva' },
    { pid: '3', name: 'Rodrigo Albuquerque Nascimento' },
  ]);
  // os dois virariam "Carlos S.": ambíguo, então os dois ficam com o nome inteiro
  assert.equal(d['1'], 'Carlos Eduardo Albuquerque Souza');
  assert.equal(d['2'], 'Carlos Henrique Monteiro Silva');
  assert.equal(d['3'], 'Rodrigo N.');
  assert.equal(displayNames([{ pid: '9', name: 'Carlos Eduardo Albuquerque Souza 1' }])['9'], 'Carlos Eduardo Albuquerque Souza 1');
});

test('paginação: 100 participantes, todos uma única vez, capitão primeiro', () => {
  const ms = Array.from({ length: 100 }, (_, i) => mk(i, i % 2 ? 'B' : 'A', { captain: i === 7 || i === 8 }));
  const pages = paginateList(ms, 14);
  assert.equal(pages.length, 4);
  const all = pages.flatMap((p) => [...p.A, ...p.B]);
  assert.equal(all.length, 100);
  assert.equal(new Set(all.map((m) => m.pid)).size, 100);
  assert.ok(pages[0].B[0].captain);
  const fields = paginateField(ms);
  assert.equal(fields.flat().length, 100);
  assert.equal(fields.length, 5);
});

test('integridade: falta, duplicidade, versão e capitão detectados', () => {
  const ms = [mk(1, 'A', { captain: true }), mk(2, 'B', { captain: true }), mk(3, 'A')];
  const payload = { composition_version: 3, stamp: 's', members: ms } as unknown as SharePayload;
  const page = (m: CompMember[], v = 3, s = 's') => ({ members: m, version: v, stamp: s });
  assert.deepEqual(checkPages(payload, [page(ms)]), []);
  assert.ok(checkPages(payload, [page(ms.slice(0, 2))]).includes('MISSING'));
  assert.ok(checkPages(payload, [page(ms), page([ms[0]])]).includes('DUPLICATE'));
  assert.ok(checkPages(payload, [page(ms, 2)]).includes('VERSION'));
  assert.ok(checkPages(payload, [page([ms[0], { ...ms[1], captain: false }, ms[2]])]).includes('CAPTAINS'));
  assert.ok(checkPages(payload, [page([ms[0], ms[1], { ...ms[2], team: 'B' }])]).includes('TEAM_MISMATCH'));
});

test('campo: posição automática por equipe, mantém as editadas, fora = neutro, sobreposição', () => {
  const ms = [mk(1, 'A', { group: 'GOL', position: 'GOL' }), mk(2, 'B', { group: 'GOL', position: 'GOL' }), mk(3, 'A'), mk(4, 'A')];
  const p = autoPositions(ms, { p004: { x: 110, y: 50 } });
  assert.ok(p.p001.y > 50 && p.p002.y < 50, 'A embaixo, B em cima');
  assert.deepEqual(p.p004, { x: 110, y: 50 });
  assert.ok(isOutside(p.p004));
  assert.equal(Object.keys(p).length, 4);
  assert.deepEqual(overlaps({ a: { x: 10, y: 10 }, b: { x: 12, y: 11 }, c: { x: 60, y: 60 } }), [['a', 'b']]);
});

test('rede: resposta perdida é recuperada pelo resultado gravado, sem repetir', async () => {
  let calls = 0;
  const r = await idempotent(
    async () => {
      calls++;
      return { data: null, error: { message: 'Network request failed' } };
    },
    async () => ({ data: { found: true, result: { ok: 1 } }, error: null }),
  );
  assert.deepEqual(r.data, { ok: 1 });
  assert.equal(calls, 1);
  const e = await idempotent(
    async () => ({ data: null, error: { message: 'VERSION_CONFLICT' } }),
    async () => ({ data: { found: false }, error: null }),
  );
  assert.equal(e.error?.message, 'VERSION_CONFLICT');
});

test('gate: resposta obsoleta não se aplica', () => {
  const g = createGate();
  const first = g.next('prep');
  const second = g.next('prep');
  assert.equal(first(), false);
  assert.equal(second(), true);
});

test('avisos V8.5: texto e destino seguros', async () => {
  const { notifText, notifPath } = await import('../src/lib/notifs.ts');
  const pid = '11111111-1111-4111-8111-111111111111';
  assert.equal(notifText({ event_type: 'round_rescheduled', pelada_name: 'X' }).title, 'Rodada remarcada');
  assert.equal(notifPath({ event_type: 'lineup_changed', pelada_id: pid, payload: {} }), `/pelada/${pid}/escalacoes`);
  assert.equal(notifPath({ event_type: 'round_cancelled', pelada_id: 'x', payload: {} }), null);
});

test('campo: posicionamento automático sem sobreposição (12 e 30 jogadores)', () => {
  const POS = ['GOL', 'ZAG', 'ZAG', 'LD', 'LE', 'VOL', 'MEI', 'MEI', 'ATA', 'ATA', 'ATA', null];
  for (const n of [12, 22, 30]) {
    const ms = Array.from({ length: n }, (_, i) => mk(i, i % 2 ? 'B' : 'A', { position: POS[i % 12], group: groupKey(POS[i % 12]) }));
    const p = autoPositions(ms);
    assert.equal(overlaps(p).length, 0, `n=${n}`);
    assert.ok(Object.values(p).every((q) => !isOutside(q)), 'automático sempre dentro do campo');
  }
});
