import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { notifPath, notifText } from '../src/lib/notifs.ts';
import {
  categoryStatusText, CATEGORY_TYPE, exceptionParamsError, gloveRequirement, scopedTitles, seasonTag, SEASON_AWARD_LABEL,
  sharedLabel, showMyAwards, showOrigin, sortTitles, statText, titleLabel,
} from '../src/lib/v87logic.ts';
import { trophyTotal } from '../src/lib/trophycount.ts';
import { COUNTER_ONLY, myAwardTitles } from '../src/lib/v87logic.ts';
import type { SeasonAwardsData, SeasonTitle } from '../src/lib/v87logic.ts';

// trophies.tsx importa react-native e não roda no node:test: a lista da Sala é conferida no texto do arquivo.
const trophiesSrc = readFileSync(new URL('../src/lib/trophies.tsx', import.meta.url), 'utf8');
const TROPHY_TYPES = [...trophiesSrc.slice(trophiesSrc.indexOf('export const TROPHIES'), trophiesSrc.indexOf('];', trophiesSrc.indexOf('export const TROPHIES'))).matchAll(/type: '([a-z_]+)', label: '([^']+)'/g)].map((m) => ({ type: m[1], label: m[2] }));

const t = (o: Partial<SeasonTitle>): SeasonTitle => ({
  id: 'a', award_type: 'season_top_scorer', season_id: 's', season_name: 'Temporada 2026', year: 2026, starts_on: '2026-01-01', is_shared: false, pelada_id: 'p1', pelada_name: 'Pelada A', ...o,
});

test('A01: nome oficial; "Chuteira de Ouro" nunca é nome de prêmio', () => {
  assert.equal(SEASON_AWARD_LABEL.season_top_scorer, 'Artilheiro da Temporada');
  assert.equal(SEASON_AWARD_LABEL.season_maestro, 'Maestro da Temporada');
  assert.equal(SEASON_AWARD_LABEL.season_golden_glove, 'Luva de Ouro');
  for (const l of Object.values(SEASON_AWARD_LABEL)) assert.doesNotMatch(l, /chuteira/i);
  assert.ok(TROPHY_TYPES.length >= 10);
  assert.ok(!TROPHY_TYPES.some((x) => /chuteira/i.test(x.label)));
  assert.equal(TROPHY_TYPES.filter((x) => x.type === 'season_top_scorer').length, 1, 'um único Artilheiro da Temporada, sem duplicar');
  assert.equal(TROPHY_TYPES.filter((x) => /artilheiro/i.test(x.label)).length, 2, 'só Artilheiro do Mês e Artilheiro da Temporada');
  assert.deepEqual(CATEGORY_TYPE, { top_scorer: 'season_top_scorer', maestro: 'season_maestro', golden_glove: 'season_golden_glove' });
});

test('AD01: rótulo = nome oficial + ano/temporada', () => {
  assert.equal(titleLabel(t({})), 'Artilheiro da Temporada 2026');
  assert.equal(titleLabel(t({ award_type: 'season_craque', season_name: 'Temporada 2027' })), 'Craque da Temporada 2027');
  assert.equal(titleLabel(t({ award_type: 'season_golden_glove', season_name: 'Temporada 2027/1' })), 'Luva de Ouro 2027/1');
  assert.equal(titleLabel(t({ award_type: 'season_maestro', season_name: 'Copa de Verão' })), 'Maestro da Temporada Copa de Verão');
  assert.equal(seasonTag('  temporada 2030 '), '2030');
});

test('AD01: bloco só com título; mais recente primeiro; origem só com várias peladas', () => {
  assert.equal(showMyAwards([]), false);
  assert.equal(showMyAwards(null), false);
  assert.equal(showMyAwards(undefined), false);
  assert.equal(showMyAwards([t({})]), true);
  const items = [
    t({ id: '1', starts_on: '2025-01-01', season_name: 'Temporada 2025' }),
    t({ id: '2', starts_on: '2026-01-01', award_type: 'season_golden_glove' }),
    t({ id: '3', starts_on: '2026-01-01', award_type: 'season_craque' }),
  ];
  assert.deepEqual(sortTitles(items).map((i) => i.id), ['3', '2', '1']);
  assert.equal(showOrigin(items), false);
  assert.equal(showOrigin([...items, t({ id: '4', pelada_id: 'p2' })]), true);
  // seletor de pelada na carreira: filtra; filtro sem títulos = bloco escondido (nunca vazio)
  assert.equal(scopedTitles([...items, t({ id: '4', pelada_id: 'p2' })], 'p2').length, 1);
  assert.equal(showMyAwards(scopedTitles(items, 'p9')), false);
  // títulos de anos diferentes continuam linhas separadas (sem contador)
  assert.equal(scopedTitles(items, null).length, 3);
});

test('B06/A04: requisito = max(5, teto de 50%) — 19/20/21 partidas', () => {
  assert.equal(gloveRequirement(19), 10);
  assert.equal(gloveRequirement(20), 10);
  assert.equal(gloveRequirement(21), 11);
  assert.equal(gloveRequirement(8), 5);
  assert.equal(gloveRequirement(10), 5);
  assert.equal(gloveRequirement(0), 5);
  // exceção: piso absoluto de 3
  assert.equal(gloveRequirement(8, 40, 3), 4);
  assert.equal(gloveRequirement(4, 0, 3), 3);
});

test('F01: parâmetros da exceção só reduzem, com piso de 3 atuações', () => {
  assert.equal(exceptionParamsError(40, 3), null);
  assert.equal(exceptionParamsError(50, 4), null);
  assert.equal(exceptionParamsError(0, 5), null);
  assert.match(exceptionParamsError(50, 2) ?? '', /3/);
  assert.match(exceptionParamsError(50, 5) ?? '', /reduzir/);
  assert.match(exceptionParamsError(60, 3) ?? '', /0 a 50/);
  assert.match(exceptionParamsError(40, 6) ?? '', /reduzir/);
  assert.match(exceptionParamsError(1.5, 3) ?? '', /inteiros/);
});

test('textos de estado e estatística principal', () => {
  assert.match(categoryStatusText('golden_glove', 'awaiting_exception', true), /exceção/);
  assert.match(categoryStatusText('golden_glove', 'awaiting_exception', false), /Aguardando/);
  assert.match(categoryStatusText('golden_glove', 'pending', false), /Aguardando/);
  assert.match(categoryStatusText('golden_glove', 'no_winner', true), /Sem goleiro elegível/);
  assert.match(categoryStatusText('top_scorer', 'no_winner', true), /mínimo de 1/);
  assert.equal(statText('top_scorer', 1), '1 gol');
  assert.equal(statText('top_scorer', 6), '6 gols');
  assert.equal(statText('maestro', 1), '1 assistência');
  assert.equal(statText('maestro', 4), '4 assistências');
  assert.equal(statText('golden_glove', '76.0585'), 'REF 76,1');
  assert.equal(statText('top_scorer', null), '');
  assert.equal(sharedLabel(true), 'Título compartilhado');
  assert.equal(sharedLabel(false), '');
});

test('C02/F02: Sala só com contadores para os três tipos; total soma os novos', () => {
  assert.deepEqual([...COUNTER_ONLY].sort(), ['season_golden_glove', 'season_maestro', 'season_top_scorer']);
  for (const type of COUNTER_ONLY) assert.ok(TROPHY_TYPES.some((x) => x.type === type), type);
  // tipos anteriores continuam na Sala, na mesma ordem relativa
  assert.deepEqual(TROPHY_TYPES.slice(0, 7).map((x) => x.type), ['match_craque', 'monthly_king', 'top_scorer', 'bola_murcha', 'monthly_garcom', 'monthly_goalkeeper', 'season_craque']);
  assert.equal(trophyTotal({ match_craque: 1, monthly_king: 1, bola_murcha: 1, season_top_scorer: 2, season_maestro: 1, season_golden_glove: 1 }), 7);
  assert.equal(trophyTotal(null), 0);
});

test('C07: avisos de prêmio de temporada não trazem vencedores e abrem a retrospectiva', () => {
  const P = '11111111-1111-4111-8111-111111111111';
  for (const e of ['season_awards_published', 'season_awards_corrected', 'season_award_revoked', 'award_season_top_scorer', 'award_season_maestro', 'award_season_golden_glove']) {
    const x = notifText({ event_type: e, pelada_name: 'Pelada X' });
    assert.ok(x.title && x.body, e);
    assert.match(x.body, /Pelada X/);
    assert.equal(notifPath({ event_type: e, pelada_id: P, payload: {} }), `/pelada/${P}/retrospectiva`, e);
    assert.equal(notifPath({ event_type: e, pelada_id: null, payload: {} }), null, `${e}: sem id válido não há destino`);
  }
  assert.match(notifText({ event_type: 'award_season_golden_glove', pelada_name: null }).body, /Luva de Ouro/);
});

test('C04/C05: arte individual só para quem ganhou título na temporada', () => {
  const retro = {
    season_awards: {
      top_scorer: { version: 1, basis: 'normal', winners: [{ membership_id: 'm1', name: 'Ana', avatar_path: null, value: 6, is_shared: true }, { membership_id: 'm2', name: 'Bia', avatar_path: null, value: 6, is_shared: true }] },
      golden_glove: { version: 2, basis: 'exception', winners: [{ membership_id: 'm1', name: 'Ana', avatar_path: null, value: '76.05', is_shared: false }] },
    },
  } as { season_awards: SeasonAwardsData };
  assert.deepEqual(myAwardTitles(retro, 'm1'), ['top_scorer', 'golden_glove']);
  assert.deepEqual(myAwardTitles(retro, 'm2'), ['top_scorer']);
  assert.deepEqual(myAwardTitles(retro, 'm3'), []);
  assert.deepEqual(myAwardTitles(retro, null), []);
  assert.deepEqual(myAwardTitles({}, 'm1'), []);
});
