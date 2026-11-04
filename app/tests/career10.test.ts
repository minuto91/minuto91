import assert from 'node:assert/strict';
import { test } from 'node:test';

import { avgLabel, orderPeladas, recentTrophies, visiblePosition, yearOptions } from '../src/lib/careerlogic.ts';
import type { SeasonTitle } from '../src/lib/v87logic.ts';

const title = (id: string, starts_on: string, award_type: SeasonTitle['award_type'] = 'season_craque'): SeasonTitle => ({
  id,
  award_type,
  season_id: id,
  season_name: `Temporada ${starts_on.slice(0, 4)}`,
  year: Number(starts_on.slice(0, 4)),
  starts_on,
  is_shared: false,
  pelada_id: 'p',
  pelada_name: 'P',
});
const ORDER = [
  { type: 'match_craque', label: 'Craque da Partida' },
  { type: 'monthly_king', label: 'Rei do Mês' },
  { type: 'bola_murcha', label: 'Bola Murcha' },
];

test('REV-131: filtro de temporada mostra só o ano; desempata pelo nome quando repete', () => {
  assert.deepEqual(yearOptions([{ season_id: 'a', name: 'Temporada 2026', starts_on: '2026-01-01' }]), [{ value: 'a', label: '2026' }]);
  const dup = yearOptions([
    { season_id: 'a', name: 'Temporada 2026/1', starts_on: '2026-01-01' },
    { season_id: 'b', name: 'Temporada 2026/2', starts_on: '2026-07-01' },
  ]);
  assert.equal(dup[0].label, '2026 · Temporada 2026/1');
});

test('REV-125: Meio-campista vira Meio-campo só no texto visível', () => {
  assert.equal(visiblePosition('Meio-campista'), 'Meio-campo');
  assert.equal(visiblePosition('Meio-campo'), 'Meio-campo');
});

test('REV-131: média de notas sem nota válida mostra traço, nunca zero', () => {
  assert.equal(avgLabel(null), '–');
  assert.equal(avgLabel(7.66), '7,7');
});

test('REV-126: zero troféus = lista vazia; no máximo três; títulos de temporada mais recentes primeiro', () => {
  assert.deepEqual(recentTrophies([], {}, ORDER), []);
  assert.equal(recentTrophies([title('1', '2024-01-01'), title('2', '2026-01-01'), title('3', '2025-01-01'), title('4', '2023-01-01')], {}, ORDER).map((t) => t.key).join(), '2,3,1');
  // dois títulos + um contador completam as três vagas; um contador só preenche o que falta
  const mix = recentTrophies([title('1', '2026-01-01')], { match_craque: 4, monthly_king: 1 }, ORDER);
  assert.equal(mix.length, 3);
  assert.equal(recentTrophies(null, { monthly_king: 2 }, ORDER).length, 1);
});

test('REV-095/124: pelada de origem vem primeiro; encerradas por último', () => {
  const l = [
    { pelada_id: 'b', name: 'B', status: 'left' },
    { pelada_id: 'c', name: 'C', status: 'active' },
    { pelada_id: 'a', name: 'A', status: 'active' },
  ];
  assert.deepEqual(orderPeladas(l, 'c').map((p) => p.pelada_id), ['c', 'a', 'b']);
  assert.deepEqual(orderPeladas(l, null).map((p) => p.pelada_id), ['a', 'c', 'b']);
});
