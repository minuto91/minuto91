// V7.7: atributos mostrados na carta por versão da fórmula (lib/cardattrs.ts).
// Rodar: cd app; node --experimental-strip-types --test tests/
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { cardAttributes, cardOverall, isV2, isV3 } from '../src/lib/cardattrs.ts';

const base = { overall: 74.4, tier: 'prata' as const, matches_played: 6 };
const codes = (c: Parameters<typeof cardAttributes>[0]) => cardAttributes(c).map((a) => a.code).join(',');

test('carta V7.7 de jogador de linha: DEF, LET, APR, RES, DIS (sem REF)', () => {
  const c = { ...base, formula_version: 3, def: 71, sec_code: 'LET' as const, ovr_display: 74 };
  assert.equal(codes(c), 'DEF,LET,APR,RES,DIS');
  assert.ok(isV3(c) && isV2(c));
  assert.equal(cardOverall(c), 74);
  assert.deepEqual(cardAttributes(c).map((a) => a.key), ['def', 'sec', 'apr', 'res', 'dis']);
});

test('carta V7.7 de goleiro: REF no lugar de LET, nunca os dois', () => {
  const c = { ...base, formula_version: 3, def: 71, sec_code: 'REF' as const, ovr_display: 74 };
  assert.equal(codes(c), 'DEF,REF,APR,RES,DIS');
  assert.ok(!codes(c).includes('LET'));
});

test('V7.7 em avaliação (menos de 5 partidas): sem OVR', () => {
  assert.equal(cardOverall({ ...base, formula_version: 3, def: 70, sec_code: 'LET', ovr_display: null }), null);
});

test('cartas antigas continuam como eram (V5 e v1)', () => {
  assert.equal(codes({ ...base, formula_version: 2, atu: 70 }), 'ATU,EST,PEQ,RES,DIS');
  assert.equal(codes({ ...base, formula_version: 1 }), 'FIN,GAR,PRE,PEQ,RES');
  assert.equal(cardOverall({ ...base, formula_version: 1 }), 74);
  assert.equal(cardOverall({ ...base, formula_version: 2, atu: 70, ovr_display: 71 }), 71);
  // formula_version 3 sem os atributos novos (dado incompleto) não finge ser V7.7.
  assert.ok(!isV3({ ...base, formula_version: 3, def: null }));
});
