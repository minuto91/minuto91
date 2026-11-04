import assert from 'node:assert/strict';
import { test } from 'node:test';

import { arrange, orderLine, type SelRow } from '../src/lib/selectionlayout.ts';

const r = (sector: SelRow['sector'], code: string | null, rank: number) => ({ sector, code, rank, id: `${code}${rank}` });

test('REV-118: ataque com PE à esquerda, CA/ATA no centro e PD à direita', () => {
  const line = orderLine('attacker', [r('attacker', 'PD', 1), r('attacker', 'PE', 2), r('attacker', 'CA', 3)]);
  assert.deepEqual(line.map((x) => x.code), ['PE', 'CA', 'PD']);
});

test('REV-118: ATA em qualquer lugar (não força posição); sem lados, mantém a ordem de nota', () => {
  const line = orderLine('attacker', [r('attacker', 'ATA', 1), r('attacker', 'ATA', 2)]);
  assert.deepEqual(line.map((x) => x.rank), [1, 2]);
});

test('REV-118: defesa LE, ZAG, ZAG, LD; meio com MEI nas pontas e VOL no centro', () => {
  const d = orderLine('defender', [r('defender', 'LD', 1), r('defender', 'ZAG', 2), r('defender', 'LE', 3), r('defender', 'ZAG', 4)]);
  assert.deepEqual(d.map((x) => x.code), ['LE', 'ZAG', 'ZAG', 'LD']);
  const m433 = orderLine('midfielder', [r('midfielder', 'MEI', 1), r('midfielder', 'VOL', 2), r('midfielder', 'MEI', 3)]);
  assert.deepEqual(m433.map((x) => x.code), ['MEI', 'VOL', 'MEI']);
  const m442 = orderLine('midfielder', [r('midfielder', 'VOL', 1), r('midfielder', 'VOL', 2), r('midfielder', 'MEI', 3), r('midfielder', 'MEI', 4)]);
  assert.deepEqual(m442.map((x) => x.code), ['MEI', 'VOL', 'VOL', 'MEI']);
});

test('REV-118: 11 vagas por formação; vaga sem jogador fica vazia', () => {
  const rows = [r('goalkeeper', 'GOL', 1), r('attacker', 'PE', 2), r('attacker', 'CA', 3)];
  const a433 = arrange(rows, '4-3-3');
  const a442 = arrange(rows, '4-4-2');
  assert.equal(a433.length, 11);
  assert.equal(a442.length, 11);
  assert.equal(a433.filter((x) => x.sector === 'attacker').length, 3);
  assert.equal(a442.filter((x) => x.sector === 'attacker').length, 2);
  assert.equal(a442.filter((x) => x.sector === 'midfielder').length, 4);
  assert.equal(a433.filter((x) => x.row).length, 3);
});
