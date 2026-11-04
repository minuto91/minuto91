import assert from 'node:assert/strict';
import { test } from 'node:test';

import { filledLost, goalProblems, goalsFromSheet, goalsToSheet, newGoal, resizeGoals, scoreOf, type GoalPlayer } from '../src/lib/goals.ts';

const P: GoalPlayer[] = [
  { key: 'a1', team: 'A', goals: 2, assists: 1 },
  { key: 'a2', team: 'A', goals: 1, assists: 1 },
  { key: 'b1', team: 'B', goals: 1, assists: 0 },
];
const teamOf = (k: string) => (k.startsWith('a') ? 'A' : k.startsWith('b') ? 'B' : undefined) as 'A' | 'B' | undefined;
const noExtras = { unattributed: { A: 0, B: 0 }, ownGoals: { A: 0, B: 0 } };

test('0x0 não gera registros; o placar é igual ao número de registros', () => {
  assert.deepEqual(scoreOf([]), { A: 0, B: 0 });
  const g = resizeGoals(resizeGoals([], 'A', 3), 'B', 2);
  assert.deepEqual(scoreOf(g), { A: 3, B: 2 });
});

test('aumentar acrescenta; diminuir tira os últimos e avisa se havia preenchidos', () => {
  let g = resizeGoals([], 'A', 2);
  g[0].author = 'a1';
  g[1].author = 'a2';
  assert.equal(filledLost(g, 'A', 1), 1);
  assert.equal(filledLost(g, 'A', 3), 0);
  g = resizeGoals(g, 'A', 1);
  assert.equal(g.length, 1);
  assert.equal(g[0].author, 'a1');
});

test('cada gol exige autor; gol contra exige o adversário; autor não assiste o próprio gol', () => {
  const g = [newGoal('A'), { ...newGoal('B'), own: true }, { ...newGoal('A'), author: 'a1', assist: 'a1' }];
  assert.equal(goalProblems(g).length, 3);
  assert.deepEqual(goalProblems([{ ...newGoal('A'), author: 'a1', assist: 'a2' }, { ...newGoal('B'), own: true, culprit: 'a2' }]), []);
});

test('ida e volta preserva gols e assistências por jogador, sem inventar nada', () => {
  const recs = goalsFromSheet(P, noExtras, [], teamOf);
  assert.deepEqual(scoreOf(recs), { A: 3, B: 1 });
  const s = goalsToSheet(recs);
  assert.deepEqual(s.goalsBy, { a1: 2, a2: 1, b1: 1 });
  assert.deepEqual(s.assistsBy, { a1: 1, a2: 1 });
  assert.equal(recs.filter((g) => g.assist && g.assist === g.author).length, 0);
});

test('gol contra conta para o time beneficiado e não gera gol nem assistência individual', () => {
  const players: GoalPlayer[] = [
    { key: 'a1', team: 'A', goals: 0, assists: 0 },
    { key: 'b1', team: 'B', goals: 0, assists: 0 },
  ];
  const recs = goalsFromSheet(players, noExtras, ['a1'], teamOf);
  assert.deepEqual(scoreOf(recs), { A: 0, B: 1 });
  const s = goalsToSheet(recs);
  assert.deepEqual(s.culprits, ['a1']);
  assert.deepEqual(s.goalsBy, {});
  assert.deepEqual(s.assistsBy, {});
});

test('gols sem autor vindos do banco aparecem como pendência', () => {
  const recs = goalsFromSheet([], { unattributed: { A: 1, B: 0 }, ownGoals: { A: 0, B: 0 } }, [], teamOf);
  assert.equal(goalProblems(recs).length, 1);
  assert.deepEqual(goalsToSheet(recs).unattributed, { A: 1, B: 0 });
});
