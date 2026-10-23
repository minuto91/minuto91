// V4.5: listas paginadas do app (app/src/lib/pager.ts, usado por usePaged) sob pedidos simultâneos e respostas fora
// de ordem. Servidor falso com cursor e respostas que só chegam quando o teste manda (controle total da ordem).
// Uso: cd supabase/local_db; node --test
import assert from 'node:assert/strict';
import { test } from 'node:test';

const { Pager, readAllPages } = await import('../../app/src/lib/pager.ts');
const exp = await import('../../app/src/lib/exportCheck.ts');

// Servidor falso: itens 1..total, páginas de `size` em ordem; cada chamada fica pendente até resolve(i)/reject(i).
function fakeServer(total = 10, size = 3, prefix = '') {
  const calls = [];
  const fetchPage = (after) =>
    new Promise((resolve, reject) => {
      const start = after ?? 0;
      const items = [];
      for (let i = start + 1; i <= Math.min(total, start + size); i++) items.push({ id: `${prefix}${i}` });
      const next = start + size < total ? start + size : null;
      calls.push({ after, resolve: () => resolve({ items, next, summary: { total } }), reject: (e) => reject(e ?? new Error('REDE')) });
    });
  return { fetchPage, calls };
}
const tick = () => new Promise((r) => setTimeout(r, 0));
const ids = (p) => (p.snapshot.items ?? []).map((x) => x.id);
const make = (keyed = true) => new Pager(() => {}, keyed ? (x) => x.id : undefined);

test('carrega a primeira página e as seguintes, sem repetir nem pular', async () => {
  const s = fakeServer(10, 3);
  const p = make();
  const first = p.load(s.fetchPage);
  s.calls[0].resolve();
  await first;
  assert.deepEqual(ids(p), ['1', '2', '3']);
  assert.equal(p.snapshot.hasMore, true);
  for (let k = 1; k <= 3; k++) {
    const m = p.loadMore();
    s.calls[k].resolve();
    await m;
  }
  assert.deepEqual(ids(p), ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10']);
  assert.equal(p.snapshot.hasMore, false);
  await p.loadMore(); // fim: não pede mais nada
  assert.equal(s.calls.length, 4);
});

test('dois loadMore seguidos (rolagem + botão) buscam a próxima página uma vez só', async () => {
  const s = fakeServer(10, 3);
  const p = make(false); // sem chave: só a trava evita a duplicata
  const f = p.load(s.fetchPage);
  s.calls[0].resolve();
  await f;
  const a = p.loadMore();
  const b = p.loadMore();
  const c = p.loadMore();
  assert.equal(s.calls.length, 2, 'uma requisição para a página 2');
  s.calls[1].resolve();
  await Promise.all([a, b, c]);
  assert.deepEqual(ids(p), ['1', '2', '3', '4', '5', '6']);
  assert.equal(p.snapshot.loadingMore, false);
});

test('recarregar durante um loadMore: a página atrasada da lista antiga é descartada', async () => {
  const s = fakeServer(10, 3);
  const p = make(false);
  const f = p.load(s.fetchPage);
  s.calls[0].resolve();
  await f;
  const more = p.loadMore(); // calls[1] (página 2 da lista antiga)
  const again = p.reload(); // calls[2] (primeira página de novo)
  s.calls[2].resolve();
  await again;
  s.calls[1].resolve(); // chega depois, fora de ordem
  await more;
  assert.deepEqual(ids(p), ['1', '2', '3'], 'só a primeira página nova');
  assert.equal(p.snapshot.loadingMore, false);
  // e a próxima página volta a funcionar com o cursor da lista nova
  const m2 = p.loadMore();
  assert.equal(s.calls.length, 4);
  assert.equal(s.calls[3].after, 3);
  s.calls[3].resolve();
  await m2;
  assert.deepEqual(ids(p), ['1', '2', '3', '4', '5', '6']);
});

test('loadMore enquanto a primeira página recarrega não usa o cursor antigo', async () => {
  const s = fakeServer(10, 3);
  const p = make(false);
  const f = p.load(s.fetchPage);
  s.calls[0].resolve();
  await f;
  const again = p.reload(); // calls[1]
  await p.loadMore(); // ignorado: recarregando
  assert.equal(s.calls.length, 2);
  s.calls[1].resolve();
  await again;
  assert.deepEqual(ids(p), ['1', '2', '3']);
});

test('troca de filtro: lista limpa na hora e resposta do filtro anterior nunca entra', async () => {
  const a = fakeServer(10, 3, 'a');
  const b = fakeServer(10, 3, 'b');
  const p = make();
  const fa = p.load(a.fetchPage);
  a.calls[0].resolve();
  await fa;
  const moreA = p.loadMore(); // página 2 do filtro A, ainda a caminho
  const fb = p.load(b.fetchPage);
  assert.equal(p.snapshot.items, null, 'não mostra itens do filtro anterior');
  b.calls[0].resolve();
  await fb;
  a.calls[1].resolve();
  await moreA;
  assert.deepEqual(ids(p), ['b1', 'b2', 'b3']);
});

test('duas trocas de filtro rápidas: vale a última, mesmo que a primeira responda depois', async () => {
  const a = fakeServer(5, 5, 'a');
  const b = fakeServer(5, 5, 'b');
  const p = make();
  const fa = p.load(a.fetchPage);
  const fb = p.load(b.fetchPage);
  b.calls[0].resolve();
  await fb;
  a.calls[0].resolve();
  await fa;
  assert.deepEqual(ids(p), ['b1', 'b2', 'b3', 'b4', 'b5']);
});

test('recarregar com o mesmo filtro mantém a lista na tela até chegar a resposta', async () => {
  const s = fakeServer(10, 3);
  const p = make();
  const f = p.load(s.fetchPage);
  s.calls[0].resolve();
  await f;
  const again = p.load(s.fetchPage); // voltou o foco, mesmo filtro
  assert.deepEqual(ids(p), ['1', '2', '3']);
  assert.equal(p.snapshot.loading, true);
  s.calls[1].resolve();
  await again;
  assert.equal(p.snapshot.loading, false);
});

test('tela sem foco (cancel) ou desmontada (dispose): nada atrasado entra nem avisa', async () => {
  const s = fakeServer(10, 3);
  let changes = 0;
  const p = new Pager(() => changes++, (x) => x.id);
  const f = p.load(s.fetchPage);
  s.calls[0].resolve();
  await f;
  const more = p.loadMore();
  p.cancel();
  s.calls[1].resolve();
  await more;
  assert.deepEqual(ids(p), ['1', '2', '3']);
  assert.equal(p.snapshot.loadingMore, false);
  const again = p.reload();
  p.dispose();
  const before = changes;
  s.calls[2].resolve();
  await again;
  await p.loadMore();
  assert.equal(changes, before, 'nenhum aviso depois de desmontar');
});

test('item repetido entre páginas (mudou de posição no servidor) entra uma vez só', async () => {
  const pages = [
    { items: [{ id: 'x' }, { id: 'y' }], next: 2 },
    { items: [{ id: 'y' }, { id: 'z' }], next: null },
  ];
  const p = make();
  await p.load(async (after) => pages[after ? 1 : 0]);
  await p.loadMore();
  assert.deepEqual(ids(p), ['x', 'y', 'z']);
});

test('erro na próxima página: mantém o que já carregou e permite tentar de novo', async () => {
  const s = fakeServer(10, 3);
  const p = make();
  const f = p.load(s.fetchPage);
  s.calls[0].resolve();
  await f;
  const m = p.loadMore();
  s.calls[1].reject();
  await m;
  assert.equal(p.snapshot.error, 'REDE');
  assert.deepEqual(ids(p), ['1', '2', '3']);
  assert.equal(p.snapshot.hasMore, true);
  const m2 = p.loadMore();
  s.calls[2].resolve();
  await m2;
  assert.deepEqual(ids(p), ['1', '2', '3', '4', '5', '6']);
  assert.equal(p.snapshot.error, null);
});

test('replace e resumo: troca só o item e mantém o resumo coerente', async () => {
  const s = fakeServer(4, 4);
  const p = make();
  const f = p.load(s.fetchPage);
  s.calls[0].resolve();
  await f;
  p.replace((x) => x.id === '2', { id: '2', pago: true });
  assert.deepEqual(p.snapshot.items[1], { id: '2', pago: true });
  p.setSummary((x) => ({ ...x, total: x.total - 1 }));
  assert.equal(p.snapshot.summary.total, 3);
});

test('readAllPages: lê tudo e nunca entra em laço se o servidor repetir o cursor', async () => {
  const s = fakeServer(7, 3);
  const all = readAllPages(s.fetchPage);
  for (let k = 0; k < 3; k++) {
    await tick();
    s.calls[k].resolve();
  }
  assert.deepEqual((await all).map((x) => x.id), ['1', '2', '3', '4', '5', '6', '7']);
  await assert.rejects(readAllPages(async () => ({ items: [{ id: 'a' }], next: { c: 1 } })), /PAGING_STUCK/);
});

test('conferência da exportação: íntegra, linha repetida, quantidade e somas', () => {
  const rows = [
    { id: 'a', direction: 'income', status: 'settled', amount_cents: 1000 },
    { id: 'b', direction: 'expense', status: 'settled', amount_cents: 300 },
    { id: 'c', direction: 'income', status: 'reversed', amount_cents: 500 },
    { id: 'd', direction: 'expense', status: 'pending', amount_cents: 70 },
  ];
  const total = { count: 4, settled_income_cents: 1000, settled_expense_cents: 300, reversed_cents: 500 };
  assert.deepEqual(exp.exportProblems(rows, total), []);
  assert.ok(exp.exportProblems([...rows.slice(0, 3), rows[0]], total).includes('linha repetida'));
  assert.ok(exp.exportProblems(rows.slice(0, 3), total).includes('quantidade'));
  // estorno lido como efetivado (o defeito da V4.4): receitas e estornos não batem
  const stale = rows.map((x) => (x.id === 'c' ? { ...x, status: 'settled' } : x));
  assert.deepEqual(exp.exportProblems(stale, total), ['receitas', 'estornos']);
  assert.deepEqual(exp.exportProblems(rows, null), ['sem total']);
});
