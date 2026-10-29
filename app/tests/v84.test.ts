// V8.4 — Central do Jogador: personalização (E13), atenção (E07), indicadores (E05/E06), notificações (E14),
// navegação (E15) e carregamento (E16). Regras puras. Rodar: cd app; npm test
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  classifyError,
  createCache,
  createGate,
  initialBlock,
  reduceBlock,
  refreshOutcome,
  syncedLabel,
  type BlockState,
  type KV,
} from '../src/lib/loadstate.ts';
import { createNavLock, isSafePath, planPushOpen, validParam } from '../src/lib/navguard.ts';
import { groupNotifs, groupOf, markAllRead, markRead, mergePage, notifPath, notifText, type Notif } from '../src/lib/notifs.ts';
import {
  careerStats,
  DEFAULT_LAYOUT,
  lastGameStats,
  moveBlock,
  normalizeLayout,
  positionGroup,
  sameLayout,
  showMyPeladas,
  splitAttention,
  toggleHidden,
  visibleSportBlocks,
} from '../src/lib/v84logic.ts';

const U1 = '11111111-1111-4111-8111-111111111111';
const U2 = '22222222-2222-4222-8222-222222222222';

// ---------------------------------------------------------------- E13
test('E13: layout padrão tem E04, E05, E06 e nada oculto', () => {
  assert.deepEqual(visibleSportBlocks(DEFAULT_LAYOUT), ['next_round', 'last_game', 'career_summary']);
  assert.equal(DEFAULT_LAYOUT.version, 0);
});

test('E13: reordenar e ocultar só mexem em E04–E06; E08 só oculta', () => {
  const o = moveBlock(DEFAULT_LAYOUT.order, 'career_summary', -1);
  assert.deepEqual(o, ['next_round', 'career_summary', 'last_game']);
  assert.deepEqual(moveBlock(o, 'next_round', -1), o, 'primeiro não sobe');
  assert.deepEqual(moveBlock(o, 'last_game', 1), o, 'último não desce');
  assert.deepEqual(toggleHidden([], 'last_game'), ['last_game']);
  assert.deepEqual(toggleHidden(['last_game'], 'last_game'), []);
  const l = { version: 1, order: o, hidden: ['last_game' as const] };
  assert.deepEqual(visibleSportBlocks(l), ['next_round', 'career_summary']);
});

test('E13/E08: Minhas Peladas só com 2+ peladas e se não estiver oculto', () => {
  assert.equal(showMyPeladas(DEFAULT_LAYOUT, 0), false);
  assert.equal(showMyPeladas(DEFAULT_LAYOUT, 1), false);
  assert.equal(showMyPeladas(DEFAULT_LAYOUT, 2), true);
  assert.equal(showMyPeladas({ ...DEFAULT_LAYOUT, hidden: ['my_peladas'] }, 5), false);
});

test('E13: layout inválido do servidor cai no padrão (nunca some bloco obrigatório)', () => {
  assert.deepEqual(normalizeLayout(null), DEFAULT_LAYOUT);
  assert.deepEqual(normalizeLayout({ version: 1, order: ['next_round', 'last_game'], hidden: [] }), DEFAULT_LAYOUT);
  assert.deepEqual(normalizeLayout({ version: 1, order: ['next_round', 'last_game', 'career_summary'], hidden: ['header'] }), DEFAULT_LAYOUT);
  assert.deepEqual(normalizeLayout({ version: 1, order: ['next_round', 'last_game', 'career_summary'], hidden: ['my_peladas', 'my_peladas'] }), DEFAULT_LAYOUT);
  const ok = normalizeLayout({ version: 3, order: ['last_game', 'next_round', 'career_summary'], hidden: ['my_peladas'] });
  assert.equal(ok.version, 3);
  assert.deepEqual(ok.order, ['last_game', 'next_round', 'career_summary']);
  assert.equal(sameLayout(ok, DEFAULT_LAYOUT), false);
  assert.equal(sameLayout({ ...ok, version: 9 }, ok), true);
});

// ---------------------------------------------------------------- E07
test('E07: 1 principal + até 2 secundárias; o restante vai para a folha', () => {
  const items = [
    { k: 'foto', rank: 4 },
    { k: 'voto-b', rank: 1 },
    { k: 'convite', rank: 2 },
    { k: 'voto-a', rank: 1 },
    { k: 'posicao', rank: 3 },
  ];
  const s = splitAttention(items);
  assert.equal(s.total, 5);
  assert.equal(s.primary?.k, 'voto-b', 'empate mantém a ordem de chegada');
  assert.deepEqual(s.secondary.map((i) => i.k), ['voto-a', 'convite']);
  assert.deepEqual(s.rest.map((i) => i.k), ['posicao', 'foto']);
  assert.equal(splitAttention([]).primary, null, 'vazio: o bloco some');
});

// ---------------------------------------------------------------- E05 / E06
test('posições: siglas e setores antigos caem no mesmo grupo', () => {
  assert.equal(positionGroup('GOL'), 'gk');
  assert.equal(positionGroup('goalkeeper'), 'gk');
  assert.equal(positionGroup('LE'), 'def');
  assert.equal(positionGroup('defender'), 'def');
  assert.equal(positionGroup('VOL'), 'mid');
  assert.equal(positionGroup('PD'), 'att');
  assert.equal(positionGroup(null), null);
  assert.equal(positionGroup('XYZ'), null);
});

test('E05: até 2 estatísticas; zero real aparece, dado ausente não', () => {
  const base = { goals: 0, assists: 0, hard_saves: null, my_team: 'A' as const, team_a_score: 3, team_b_score: 1 };
  assert.deepEqual(lastGameStats('ATA', base), [
    { label: 'Gols', value: 0 },
    { label: 'Assist.', value: 0 },
  ]);
  assert.deepEqual(lastGameStats('MEI', { ...base, goals: 1, assists: 2 }), [
    { label: 'Assist.', value: 2 },
    { label: 'Gol', value: 1 },
  ]);
  // goleiro: gols sofridos pelo placar oficial; defesas difíceis só com registro confirmado
  assert.deepEqual(lastGameStats('GOL', base), [{ label: 'Gols sofridos', value: 1 }]);
  assert.deepEqual(lastGameStats('GOL', { ...base, my_team: 'B', hard_saves: 0 }), [
    { label: 'Gols sofridos', value: 3 },
    { label: 'Defesas difíceis', value: 0 },
  ]);
  for (const p of ['GOL', 'ZAG', 'MEI', 'CA', null]) assert.ok(lastGameStats(p, base).length <= 2);
});

test('E06: no máximo 4 indicadores e "Jogos" sempre primeiro', () => {
  const t = { matches_played: 12, wins: 7, draws: 2, losses: 3, goals: 5, assists: 4 };
  for (const p of ['GOL', 'ZAG', 'VOL', 'ATA', null]) {
    const c = careerStats(p, t);
    assert.ok(c.length <= 4, p ?? 'sem posição');
    assert.equal(c[0].label, 'Jogos');
    assert.equal(c[0].value, 12);
  }
  assert.deepEqual(careerStats('CA', t).map((c) => c.label), ['Jogos', 'Gols', 'Assist.', 'Vitórias']);
  assert.deepEqual(careerStats('GOL', t).map((c) => c.label), ['Jogos', 'Vitórias', 'Empates', 'Derrotas']);
  assert.equal(careerStats('ATA', { ...t, goals: 0 })[1].value, 0, 'gols zero é 0, não some');
});

// ---------------------------------------------------------------- E14
const N = (over: Partial<Notif>): Notif => ({
  id: U1,
  event_type: 'result_published',
  pelada_id: U2,
  pelada_name: 'Pelada A',
  created_at: '2026-10-28T15:00:00Z',
  read_at: null,
  payload: { match_id: U1 },
  ...over,
});

test('E14: grupos Hoje / Ontem / Esta semana / Anteriores', () => {
  const now = new Date(2026, 9, 28, 12, 0, 0).getTime(); // 28/10/2026 12:00 local
  const at = (d: number, h = 9) => new Date(2026, 9, d, h, 0, 0).toISOString();
  assert.equal(groupOf(at(28, 1), now), 'today');
  assert.equal(groupOf(at(27, 23), now), 'yesterday');
  assert.equal(groupOf(at(24), now), 'week');
  assert.equal(groupOf(at(22), now), 'week');
  assert.equal(groupOf(at(21), now), 'older');
  const g = groupNotifs([N({ id: 'a', created_at: at(28) }), N({ id: 'b', created_at: at(10) }), N({ id: 'c', created_at: at(27) })], now);
  assert.deepEqual(g.map((x) => x.label), ['Hoje', 'Ontem', 'Anteriores']);
});

test('E14: texto sem autoria de voto nem valores; link só com IDs válidos', () => {
  const t = notifText({ event_type: 'voting_opened', pelada_name: 'Pelada A' });
  assert.match(t.body, /Pelada A/);
  assert.doesNotMatch(JSON.stringify(t), /R\$|votou em|autor/i);
  assert.equal(notifPath(N({})), `/partida/${U1}`);
  assert.equal(notifPath(N({ payload: { match_id: 'nao-e-uuid' } })), null, 'ID inválido: sem destino');
  assert.equal(notifPath(N({ event_type: 'admin_succession', payload: {} })), `/pelada/${U2}`);
  assert.equal(notifPath(N({ event_type: 'admin_succession', pelada_id: null, payload: {} })), null);
  assert.equal(notifPath(N({ event_type: 'season_review', payload: {} })), `/pelada/${U2}/retrospectiva`);
  assert.equal(notifPath(N({ event_type: 'evento_desconhecido' })), null);
  assert.equal(notifPath(N({ event_type: 'award_monthly_king', payload: {} })), `/pelada/${U2}`);
  assert.equal(notifPath(N({ event_type: 'account_transferred' })), '/conta');
  // todo caminho gerado é aceito pela lista de destinos seguros
  for (const type of ['voting_opened', 'result_published', 'admin_succession', 'sticker_unlocked', 'season_review', 'account_transferred']) {
    const p = notifPath(N({ event_type: type }));
    if (p) assert.ok(isSafePath(p), p);
  }
});

test('E14: ler marca só aquele aviso; marcar todas é idempotente; páginas não repetem', () => {
  const items = [N({ id: 'a' }), N({ id: 'b', read_at: '2026-10-27T00:00:00Z' }), N({ id: 'c' })];
  const r = markRead(items, 'a', '2026-10-28T20:00:00Z');
  assert.equal(r[0].read_at, '2026-10-28T20:00:00Z');
  assert.equal(r[2].read_at, null);
  assert.equal(markRead(r, 'b', 'x')[1].read_at, '2026-10-27T00:00:00Z', 'não sobrescreve leitura anterior');
  const all = markAllRead(r, '2026-10-28T21:00:00Z');
  assert.ok(all.every((n) => n.read_at));
  assert.deepEqual(markAllRead(all, 'outra'), all);
  assert.equal(mergePage(items, [N({ id: 'c' }), N({ id: 'd' })]).length, 4);
});

// ---------------------------------------------------------------- E15
test('E15: caminhos de aviso seguros; o resto cai na Central', () => {
  assert.ok(isSafePath(`/partida/${U1}`));
  assert.ok(isSafePath(`/pelada/${U1}/retrospectiva`));
  assert.ok(isSafePath('/conta'));
  assert.ok(!isSafePath('/partida/abc'));
  assert.ok(!isSafePath(`/partida/${U1}/../../x`));
  assert.ok(!isSafePath('https://evil.example/x'));
  assert.ok(!isSafePath('//evil.example'));
  assert.ok(!isSafePath(42));
  assert.ok(!isSafePath(`/pelada/${U1}/financeiro/cobrancas`), 'financeiro não abre por aviso');
});

test('E15-17/20: push a frio entra pela Central; com app aberto empilha; inseguro nunca abre destino', () => {
  assert.deepEqual(planPushOpen(`/partida/${U1}`, true), ['/', `/partida/${U1}`]);
  assert.deepEqual(planPushOpen(`/partida/${U1}`, false), [`/partida/${U1}`]);
  assert.deepEqual(planPushOpen('/qualquer/coisa', true), ['/']);
  assert.deepEqual(planPushOpen('/qualquer/coisa', false), []);
  assert.deepEqual(planPushOpen(undefined, true), ['/']);
});

test('E15-32: parâmetro de rota inválido não abre conteúdo', () => {
  assert.equal(validParam(U1), U1);
  assert.equal(validParam([U1, U2]), U1);
  assert.equal(validParam('undefined'), null);
  assert.equal(validParam(undefined), null);
  assert.equal(validParam("1' or '1'='1"), null);
});

test('E15-26/E12: toque repetido no mesmo destino é ignorado; outro destino passa', () => {
  let t = 1000;
  const go = createNavLock(700, () => t);
  assert.equal(go('/a'), true);
  t += 200;
  assert.equal(go('/a'), false);
  assert.equal(go('/b'), true);
  t += 800;
  assert.equal(go('/b'), true, 'passada a janela, vale de novo');
});

// ---------------------------------------------------------------- E16
const ok = <T>(data: T, now = 1000): Parameters<typeof reduceBlock<T>>[1] => ({ type: 'success', data, now });

test('E16: classificação de falhas', () => {
  assert.equal(classifyError({ message: 'Network request failed' }), 'offline');
  assert.equal(classifyError(new TypeError('Failed to fetch')), 'offline');
  assert.equal(classifyError({ message: 'JWT expired' }), 'session');
  assert.equal(classifyError({ code: '42501', message: 'AUTH_REQUIRED' }), 'session');
  assert.equal(classifyError({ message: 'PELADA_NOT_FOUND' }), 'denied');
  assert.equal(classifyError({ status: 403, message: 'x' }), 'denied');
  assert.equal(classifyError({ message: 'algo inesperado' }), 'other');
});

test('E16: vazio confirmado ≠ erro ≠ offline ≠ acesso negado', () => {
  let s: BlockState<number> = initialBlock();
  assert.equal(s.status, 'loading');
  s = reduceBlock(s, { type: 'start' });
  assert.equal(s.status, 'loading');
  assert.equal(reduceBlock(s, { type: 'success', data: null, empty: true, now: 5 }).status, 'empty_confirmed');
  assert.equal(reduceBlock(s, { type: 'failure', kind: 'other', message: 'm' }).status, 'error');
  assert.equal(reduceBlock(s, { type: 'failure', kind: 'offline', message: 'm' }).status, 'offline_uncached');
  assert.equal(reduceBlock(s, { type: 'failure', kind: 'denied', message: 'm' }).status, 'access_denied');
  assert.equal(reduceBlock(s, { type: 'failure', kind: 'session', message: 'm' }).status, 'session_expired');
});

test('E16-33 (C): falha informativa mantém o dado anterior sinalizado; refresh não troca por skeleton', () => {
  let s: BlockState<number> = reduceBlock(initialBlock<number>(), ok(10, 1000));
  assert.equal(s.syncedAt, 1000);
  s = reduceBlock(s, { type: 'start' });
  assert.equal(s.status, 'loaded');
  assert.equal(s.data, 10, 'conteúdo válido preservado durante a atualização');
  assert.equal(s.refreshing, true);
  const failed = reduceBlock(s, { type: 'failure', kind: 'other', message: 'falhou' });
  assert.equal(failed.data, 10);
  assert.equal(failed.stale, true);
  assert.equal(failed.error, 'falhou');
  assert.equal(failed.syncedAt, 1000, 'a última sincronização continua sendo a real');
  const off = reduceBlock(s, { type: 'failure', kind: 'offline', message: '' });
  assert.equal(off.status, 'offline_cached');
  assert.equal(off.data, 10);
  // acesso negado nunca mantém conteúdo
  const denied = reduceBlock(s, { type: 'failure', kind: 'denied', message: '' });
  assert.equal(denied.data, null);
});

test('E16: cache só preenche enquanto nada melhor chegou e vem marcado como não confirmado', () => {
  const seeded = reduceBlock(initialBlock<number>(), { type: 'seed', data: 7, syncedAt: 500 });
  assert.equal(seeded.data, 7);
  assert.equal(seeded.stale, true);
  assert.equal(seeded.syncedAt, 500);
  const fresh = reduceBlock(seeded, ok(9, 2000));
  assert.equal(fresh.stale, false);
  assert.equal(fresh.data, 9);
  // cache que chega depois da resposta do servidor é ignorado
  assert.equal(reduceBlock(fresh, { type: 'seed', data: 1, syncedAt: 1 }).data, 9);
});

test('E16-25/41: resposta antiga não sobrescreve a nova; logout invalida tudo', () => {
  const gate = createGate();
  const a = gate.take('u1:peladaA:rating');
  const b = gate.take('u1:peladaA:rating');
  assert.equal(gate.isCurrent(a), false, 'pedido antigo do mesmo escopo');
  assert.equal(gate.isCurrent(b), true);
  const other = gate.take('u1:peladaB:rating');
  assert.equal(gate.isCurrent(b), true, 'escopos independentes');
  assert.equal(gate.isCurrent(other), true);
  gate.reset();
  assert.equal(gate.isCurrent(b), false, 'logout/troca de conta');
  assert.equal(gate.isCurrent(other), false);
  assert.equal(gate.isCurrent(gate.take('u2:peladaA:rating')), true);
});

test('E16-44: só mostra "atualizado" com sincronização real', () => {
  assert.equal(syncedLabel(null, 1_000_000), null);
  assert.equal(syncedLabel(1_000_000, 1_000_000 + 5 * 60_000), 'Atualizado há 5 min');
  assert.equal(syncedLabel(0, 3 * 3_600_000), 'Atualizado há 3 h');
});

test('E16-18/39: atualização parcial não é sucesso total', () => {
  assert.equal(refreshOutcome(['ok', 'ok']), 'complete');
  assert.equal(refreshOutcome(['ok', 'fail']), 'partial');
  assert.equal(refreshOutcome(['fail', 'fail']), 'failed');
});

function memoryKV(): KV & { dump(): string[] } {
  const m = new Map<string, string>();
  return {
    getItem: async (k) => m.get(k) ?? null,
    setItem: async (k, v) => void m.set(k, v),
    removeItem: async (k) => void m.delete(k),
    getAllKeys: async () => [...m.keys()],
    dump: () => [...m.keys()],
  };
}

test('E16-26/27: cache segregado por usuário e apagado no logout', async () => {
  const kv = memoryKV();
  await kv.setItem('outra_chave_do_app', 'x');
  const cache = createCache(kv);
  await cache.set(U1, 'central', { a: 1 }, 100);
  await cache.set(U2, 'central', { a: 2 }, 200);
  assert.deepEqual((await cache.get<{ a: number }>(U1, 'central'))?.data, { a: 1 });
  assert.deepEqual((await cache.get<{ a: number }>(U2, 'central'))?.data, { a: 2 });
  assert.equal(await cache.get('', 'central'), null, 'sem usuário não lê');
  await kv.setItem('m91:central:v1:' + U1 + ':quebrado', '{não é json');
  assert.equal(await cache.get(U1, 'quebrado'), null, 'cache corrompido vira "sem cache"');
  await cache.clearAll();
  assert.equal(await cache.get(U1, 'central'), null);
  assert.equal(await cache.get(U2, 'central'), null);
  assert.deepEqual(kv.dump(), ['outra_chave_do_app'], 'só apaga o que é da Central');
});
