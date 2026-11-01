import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isDevRouteBlocked, isPathHidden, isRouteHidden, isTrophyHidden, OUT_OF_SCOPE_TROPHIES } from '../src/lib/scope.ts';
import { trophyTotal } from '../src/lib/trophycount.ts';

const seg = (p: string) => p.split('/').filter(Boolean);

test('BETA-02: sem o escopo core nada é escondido (app como antes)', () => {
  for (const p of ['pelada/[id]/financeiro/index', 'pelada/[id]/sorteio', 'personalizar-central', 'guia-cards', 'pelada/[id]/craque-temporada']) {
    assert.equal(isRouteHidden(seg(p), false), false, p);
  }
  assert.equal(isTrophyHidden('season_craque', false), false);
  assert.equal(isPathHidden('/pelada/abc/financeiro', false), false);
});

test('BETA-02: core esconde as rotas fora do PRD v2.5', () => {
  const hidden = [
    'pelada/[id]/financeiro/index', 'pelada/[id]/financeiro/cobrancas', 'pelada/[id]/financeiro/lote',
    'pelada/[id]/sorteio', 'pelada/[id]/escalacoes', 'pelada/[id]/composicao/[cid]',
    'pelada/[id]/craque-temporada', 'pelada/[id]/premios-temporada', 'personalizar-central', 'guia-cards',
  ];
  for (const p of hidden) assert.equal(isRouteHidden(seg(p), true), true, p);
});

test('BETA-02: core mantém as rotas do PRD (inclui Duelo, Carreira, Álbum, Retrospectiva e Premium)', () => {
  const visible = [
    '(tabs)/index', '(tabs)/carreira', '(tabs)/peladas', '(tabs)/perfil', 'album', 'historico', 'conta', 'notificacoes',
    'pelada/[id]/index', 'pelada/[id]/partidas', 'pelada/[id]/elenco', 'pelada/[id]/rankings', 'pelada/[id]/duelo',
    'pelada/[id]/retrospectiva', 'pelada/[id]/temporadas', 'pelada/[id]/premium', 'pelada/[id]/configuracoes',
    'partida/[id]/votar', 'partida/[id]/sumula', 'jogador/[id]/index', 'convite/[token]', 'termos', 'privacidade', 'login',
  ];
  for (const p of visible) assert.equal(isRouteHidden(seg(p), true), false, p);
});

test('BETA-02: caminhos de avisos e links para telas escondidas são reconhecidos', () => {
  const id = '8f14e45f-ceea-467f-a0e6-1c3cf5c9a1b2';
  assert.equal(isPathHidden(`/pelada/${id}/escalacoes`, true), true);
  assert.equal(isPathHidden(`/pelada/${id}/financeiro?x=1`, true), true);
  assert.equal(isPathHidden('/guia-cards', true), true);
  assert.equal(isPathHidden(`/pelada/${id}/retrospectiva`, true), false);
  assert.equal(isPathHidden(`/pelada/${id}`, true), false);
  assert.equal(isPathHidden('/', true), false);
});

test('BETA-02: rotas dev-* só existem em __DEV__', () => {
  for (const p of ['dev-cards', 'dev-central', 'dev-v42', 'dev-v77', 'dev-v87']) {
    assert.equal(isDevRouteBlocked(seg(p), false), true, p);
    assert.equal(isDevRouteBlocked(seg(p), true), false, p);
  }
  assert.equal(isDevRouteBlocked(seg('conta'), false), false);
  assert.equal(isDevRouteBlocked(seg('pelada/[id]/index'), false), false);
});

test('BETA-02: troféus fora do PRD somem da Sala e do total no escopo core', () => {
  for (const t of OUT_OF_SCOPE_TROPHIES) assert.equal(isTrophyHidden(t, true), true, t);
  for (const t of ['match_craque', 'monthly_king', 'bola_murcha', 'monthly_garcom', 'top_scorer']) assert.equal(isTrophyHidden(t, true), false, t);
  const counts = { match_craque: 2, monthly_king: 1, bola_murcha: 1, monthly_garcom: 3, top_scorer: 1, monthly_goalkeeper: 4, season_craque: 1, season_top_scorer: 2, season_maestro: 1, season_golden_glove: 1 };
  assert.equal(trophyTotal(counts), 16);
  assert.equal(trophyTotal(counts, OUT_OF_SCOPE_TROPHIES), 7); // 2 + 1 + 1 + 3 (top_scorer do mês não entra no total, como antes)
  assert.equal(trophyTotal(null, OUT_OF_SCOPE_TROPHIES), 0);
});
