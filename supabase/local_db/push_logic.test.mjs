// Regras do remetente de push (supabase/functions/push-sender/logic.ts), sem rede.
// Uso: cd supabase/local_db; node --test
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { buildMessages, chunk, outcomeFor, pathFor, receiptFor, texts } from '../functions/push-sender/logic.ts';

const P = '11111111-1111-4111-8111-111111111111';
const M = '22222222-2222-4222-8222-222222222222';
const n = (event_type, payload = {}, tokens = ['t1', 't2']) => ({ id: 'n1', user_id: 'u', pelada_id: P, event_type, payload, tokens, attempt: 1 });

test('todos os tipos produzidos pelo banco têm texto, menos Bola Murcha', () => {
  for (const t of ['voting_opened', 'voting_closing_soon', 'sheet_corrected', 'voting_restarted', 'result_published', 'match_annulled',
    'admin_succession', 'subscription_changed', 'account_transferred', 'role_changed', 'successor_designated', 'sticker_unlocked',
    'season_review', 'award_match_craque', 'award_monthly_king', 'award_top_scorer', 'award_top_assist', 'award_most_improved',
    'award_match_garcom', 'award_monthly_garcom'])
    assert.ok(texts(t, {}, 'Pelada X'), t);
  assert.equal(texts('award_bola_murcha', {}, 'Pelada X'), null);
  assert.equal(texts('tipo_desconhecido', {}, 'Pelada X'), null);
});

test('texto sem dados sensíveis: só o nome da pelada', () => {
  const t = texts('result_published', { match_id: M, rating: 9.5 }, 'Resenha FC');
  assert.match(t.body, /Resenha FC/);
  assert.doesNotMatch(t.body, /9[.,]5/);
});

test('caminho do toque', () => {
  assert.equal(pathFor('voting_opened', { match_id: M }, P), `/partida/${M}`);
  assert.equal(pathFor('season_review', {}, P), `/pelada/${P}/retrospectiva`);
  assert.equal(pathFor('award_monthly_king', { match_id: null }, P), `/pelada/${P}/rankings`);
  assert.equal(pathFor('role_changed', {}, P), `/pelada/${P}`);
  assert.equal(pathFor('account_transferred', {}, null), '/conta');
  assert.equal(pathFor('voting_opened', { match_id: '../../x' }, null), '/', 'id inválido não vira caminho');
});

test('uma mensagem por aparelho, com o id da notificação', () => {
  const ms = buildMessages(n('voting_opened', { match_id: M }), 'X');
  assert.equal(ms.length, 2);
  assert.deepEqual(ms.map((m) => m.to), ['t1', 't2']);
  assert.equal(ms[0].data.notification_id, 'n1');
  assert.equal(ms[0].priority, 'high');
  assert.equal(buildMessages(n('award_match_craque', { match_id: M }), 'X')[0].priority, 'default');
  assert.equal(buildMessages(n('award_bola_murcha'), 'X').length, 0);
});

test('aceite: basta um aparelho; token morto é apagado', () => {
  const ms = buildMessages(n('voting_opened', { match_id: M }), 'X');
  const o = outcomeFor('n1', ms, [{ status: 'ok', id: 'tk1' }, { status: 'error', details: { error: 'DeviceNotRegistered' } }]);
  assert.equal(o.outcome, 'accepted');
  assert.deepEqual(o.tickets, [{ token: 't1', ticket_id: 'tk1' }]);
  assert.deepEqual(o.invalid_tokens, ['t2']);
});

test('todos os aparelhos mortos = falha; limite de envio = tentar de novo', () => {
  const ms = buildMessages(n('voting_opened', { match_id: M }), 'X');
  const dead = { status: 'error', details: { error: 'DeviceNotRegistered' } };
  assert.equal(outcomeFor('n1', ms, [dead, dead]).outcome, 'failed');
  assert.equal(outcomeFor('n1', ms, [dead, { status: 'error', details: { error: 'MessageRateExceeded' } }]).outcome, 'retry');
  assert.equal(outcomeFor('n1', ms, []).outcome, 'retry', 'sem ticket (resposta incompleta) = tentar de novo');
});

test('recibos: espera até 24h; depois marca indisponível', () => {
  const tickets = [{ token: 't1', ticket_id: 'a' }, { token: 't2', ticket_id: 'b' }];
  const now = Date.parse('2026-10-22T12:00:00Z');
  assert.equal(receiptFor('n1', tickets, { a: { status: 'ok', id: 'a' } }, '2026-10-22T11:00:00Z', now), undefined);
  assert.deepEqual(receiptFor('n1', tickets, { a: { status: 'ok', id: 'a' }, b: { status: 'ok', id: 'b' } }, '2026-10-22T11:00:00Z', now),
    { id: 'n1', error: null, invalid_tokens: undefined });
  const r = receiptFor('n1', tickets, { a: { status: 'error', details: { error: 'DeviceNotRegistered' } } }, '2026-10-21T10:00:00Z', now);
  assert.equal(r.error, 'DeviceNotRegistered, RECEIPT_UNAVAILABLE');
  assert.deepEqual(r.invalid_tokens, ['t1']);
});

test('lotes de 100', () => {
  assert.deepEqual(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);
});
