// V7.7 ponta a ponta no banco (PGlite, todas as migrações): o fluxo real do app (súmula, publicação, votação com
// notas e resenha, defesas difíceis, cartões, correção durante a votação, anulação, troca de posição, duas
// temporadas) e o OVR gravado pelo servidor comparado com o motor JS calculado SÓ a partir do roteiro do teste
// (sem ler a entrada que o servidor montou). Também: idempotência, isolamento entre peladas, cartas, ranking,
// histórico e permissões. node --test rating_v77_integration.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as E from './rating/v77.mjs';
import { migratedDb } from './rating/testdb.mjs';

const TOL = 1e-6; // os valores gravados são numeric(9,6)
let seed = 2026;
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const int = (a, b) => a + Math.floor(rnd() * (b - a + 1));
const uid = (n) => `77000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const CODE = { 1: 'GOL', 2: 'ZAG', 3: 'MEI', 4: 'CA', 5: 'GOL', 6: 'LD', 7: 'VOL', 8: 'PE', 9: 'ATA', 10: 'LE', 11: 'MEI' };
const ENGINE = { GOL: 'GOL', ZAG: 'ZAG', LD: 'LAT', LE: 'LAT', VOL: 'VOL', MEI: 'MEI', CA: 'ATA', ATA: 'ATA', PD: 'PON', PE: 'PON' };

test('V7.7 ponta a ponta: servidor = motor JS a partir do roteiro', { timeout: 1800000 }, async () => {
  const d = await migratedDb();
  const q = async (sql, args) => (await d.query(sql, args)).rows;
  const one = async (sql, args) => Object.values((await d.query(sql, args)).rows[0] ?? {})[0];
  const su = async () => d.exec('reset role');
  const as = async (n) => { await d.exec('reset role'); await d.query(`select set_config('request.jwt.claim.sub', $1, false)`, [uid(n)]); await d.exec('set role authenticated'); };
  const expectError = async (fn, msg) => { try { await fn(); } catch (e) { assert.ok(e.message.includes(msg), `esperado ${msg}, veio ${e.message}`); return; } assert.fail(`deveria falhar com ${msg}`); };

  // ---------------------------------------------------------------- usuários e peladas
  await su();
  await d.query(`insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
    select ('77000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','v77-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,20) n`);
  for (let i = 1; i <= 20; i++) { await as(i); await d.query(`select public.complete_onboarding($1,true,true)`, [`Jogador ${i}`]); }
  await as(1);
  const A = await one(`select public.create_pelada('V77 A','GOL')`);
  const tok = await one(`select public.create_pelada_invite($1)`, [A]);
  for (let i = 2; i <= 11; i++) { await as(i); await d.query(`select public.join_pelada($1,$2)`, [tok, CODE[i]]); }
  // Pelada B (isolamento): jogador 2 também está nela.
  await as(15); const B = await one(`select public.create_pelada('V77 B','MEI')`);
  const tokB = await one(`select public.create_pelada_invite($1)`, [B]);
  for (const i of [2, 16, 17, 18]) { await as(i); await d.query(`select public.join_pelada($1,'ATA')`, [tokB]); }
  await su();
  const memRows = await q(`select user_id, id from public.pelada_memberships where pelada_id=$1`, [A]);
  const MEM = Object.fromEntries(memRows.map((r) => [Number(r.user_id.slice(-12)), r.id]));
  const USER = Object.fromEntries(Object.entries(MEM).map(([u, m]) => [m, Number(u)]));
  await as(1); await d.query(`select public.set_cards_tracking($1,true)`, [A]);

  // ---------------------------------------------------------------- roteiro
  const script = []; // {id, at, annulled, parts:{user:{team, goals, assists, yellow, secondYellow, red, saves}}, votes, resenha}
  const now = new Date();
  const year = now.getUTCFullYear();
  // 6 partidas no ano passado (temporada anterior) + 16 neste ano, a mais recente ontem.
  const dates = [
    ...Array.from({ length: 6 }, (_, i) => new Date(Date.UTC(year - 1, 5, 1 + i * 7, 22))),
    ...Array.from({ length: 16 }, (_, i) => new Date(Date.UTC(year, 0, 10 + i * 15, 22))),
  ].sort((a, b) => a - b);

  async function playMatch(at, { correct = false } = {}) {
    // Goleiros 1 e 5 sempre; demais faltam com 20%; 11 só entra a partir da 8ª partida (ausências antes não contam).
    const users = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].filter((u) => u === 1 || u === 5 || (u === 11 ? script.length >= 8 && rnd() < 0.7 : rnd() < 0.8));
    const teamA = users.filter((u, i) => (u === 1 ? true : u === 5 ? false : i % 2 === 0));
    const teamB = users.filter((u) => !teamA.includes(u));
    const parts = {};
    for (const u of users) parts[u] = { team: teamA.includes(u) ? 'A' : 'B', goals: 0, assists: 0, yellow: 0, secondYellow: 0, red: 0, saves: null };
    const events = [];
    for (const team of [teamA, teamB]) {
      const field = team.filter((u) => u !== 1 && u !== 5);
      let goals = 0;
      for (const u of field) { const g = rnd() < 0.3 ? int(1, 2) : 0; if (g) { parts[u].goals = g; goals += g; events.push({ membership_id: MEM[u], type: 'goal', quantity: g }); } }
      let assists = Math.min(goals, int(0, 2));
      for (const u of field) { if (!assists) break; if (rnd() < 0.5) { parts[u].assists = 1; assists--; events.push({ membership_id: MEM[u], type: 'assist', quantity: 1 }); } }
      for (const u of field) {
        const r = rnd();
        if (r < 0.08) { parts[u].yellow = 1; events.push({ membership_id: MEM[u], type: 'yellow_card', quantity: 1 }); }
        else if (r < 0.1) { parts[u].secondYellow = 1; events.push({ membership_id: MEM[u], type: 'second_yellow', quantity: 1 }); }
        else if (r < 0.11) { parts[u].red = 1; parts[u].yellow = 1; events.push({ membership_id: MEM[u], type: 'red_card', quantity: 1 }, { membership_id: MEM[u], type: 'yellow_card', quantity: 1 }); }
      }
    }
    const sheet = users.map((u) => ({ membership_id: MEM[u], team: parts[u].team }));
    await as(1);
    const id = await one(`select public.create_match($1,$2)`, [A, at.toISOString()]);
    await d.query(`select public.save_match_sheet($1,$2::jsonb,$3::jsonb)`, [id, JSON.stringify(sheet), JSON.stringify(events)]);
    await d.query(`select public.publish_match($1)`, [id]);
    // Defesas difíceis: às vezes sem registro (null), às vezes zero.
    await su();
    const pids = Object.fromEntries((await q(`select membership_id, id from public.match_participants where match_id=$1`, [id])).map((r) => [USER[r.membership_id], r.id]));
    const saves = [];
    for (const k of [1, 5]) { const s = rnd() < 0.2 ? null : int(0, 7); parts[k].saves = s; if (s !== null) saves.push({ participant_id: pids[k], hard_saves: s }); }
    await as(1);
    if (saves.length) await d.query(`select public.set_match_hard_saves($1,$2::jsonb)`, [id, JSON.stringify(saves)]);
    const session = (await one(`select public.open_rating_vote($1)`, [id])).session_id;
    // Notas: para cada alvo, às vezes um companheiro e um adversário (nota válida), às vezes só um grupo (insuficiente).
    const votes = {};
    for (const t of users) {
      const mates = users.filter((u) => u !== t && parts[u].team === parts[t].team);
      const opps = users.filter((u) => parts[u].team !== parts[t].team);
      const mode = rnd();
      const tv = mode < 0.85 && mates.length ? { voter: mates[int(0, mates.length - 1)], r: int(8, 20) / 2 } : null;
      const ov = mode < 0.75 || mode >= 0.85 ? { voter: opps[int(0, opps.length - 1)], r: int(8, 20) / 2 } : null;
      for (const v of [tv, ov].filter(Boolean)) { await as(v.voter); await d.query(`select public.cast_rating_vote($1,$2,$3)`, [session, MEM[t], v.r]); }
      votes[t] = tv && ov ? 0.5 * tv.r + 0.5 * ov.r : null;
    }
    // Resenha: cada participante responde com 70% de chance; marca cada outro com 60%.
    const answers = {};
    for (const v of users) {
      if (rnd() >= 0.7) continue;
      answers[v] = users.filter((u) => u !== v && rnd() < 0.6);
      await as(v);
      await d.query(`select public.set_rating_vote_resenha($1,$2::uuid[])`, [session, answers[v].map((u) => MEM[u])]);
    }
    const m = { id, at, session, parts, votes, answers, annulled: false };
    if (correct) {
      // Correção da súmula durante a votação: tira o gol do primeiro artilheiro (assistências do time ajustadas).
      const scorer = users.find((u) => parts[u].goals > 0);
      if (scorer) {
        parts[scorer].goals -= 1;
        const fixed = events.map((e) => ({ ...e })).filter((e) => !(e.membership_id === MEM[scorer] && e.type === 'goal' && (e.quantity -= 1) === 0));
        const team = users.filter((u) => parts[u].team === parts[scorer].team);
        const tg = team.reduce((s, u) => s + parts[u].goals, 0);
        let ta = team.reduce((s, u) => s + parts[u].assists, 0);
        const out = fixed.filter((e) => { if (e.type === 'assist' && ta > tg && team.some((u) => MEM[u] === e.membership_id)) { parts[USER[e.membership_id]].assists = 0; ta--; return false; } return true; });
        await as(1);
        await d.query(`select public.correct_match_sheet($1,$2::jsonb,$3::jsonb,'gol anulado pelo vídeo')`, [id, JSON.stringify(sheet), JSON.stringify(out)]);
        m.corrected = scorer;
      }
    }
    await su();
    await d.query(`update public.rating_vote_sessions set closes_at=clock_timestamp()-interval '1 second' where id=$1`, [session]);
    await as(1);
    await d.query(`select public.publish_rating_vote($1)`, [session]);
    script.push(m);
    return m;
  }

  // Resenha esperada (regra aprovada), a partir das respostas do roteiro.
  const resenhaOf = (m, t) => {
    const voters = Object.keys(m.answers).map(Number).filter((v) => v !== t);
    return E.resenhaOutcome(voters.filter((v) => m.answers[v].includes(t)).length, voters.length);
  };
  const seasonOf = (at) => (at.getUTCFullYear() < year ? 'prev' : 'cur');
  // Entrada esperada de um jogador, montada só a partir do roteiro.
  function expectedInput(u, position, previousPosition = null, changedAt = null) {
    const live = script.filter((m) => !m.annulled).sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : 1));
    const first = live.find((m) => m.parts[u]);
    if (!first) return { position, seasons: [] };
    const seasons = [];
    for (const m of live.filter((x) => x.at >= first.at)) {
      const s = seasonOf(m.at);
      if (!seasons.length || seasons[seasons.length - 1].seasonId !== s) seasons.push({ seasonId: s, events: [] });
      const p = m.parts[u];
      if (!p) { seasons[seasons.length - 1].events.push({ played: false }); continue; }
      const opp = Object.values(m.parts).filter((x) => x.team !== p.team).reduce((acc, x) => acc + x.goals, 0);
      const own = Object.values(m.parts).filter((x) => x.team === p.team).reduce((acc, x) => acc + x.goals, 0);
      const c = E.normalizeCards({ yellowCard: p.yellow, secondYellow: p.secondYellow, redCard: p.red });
      seasons[seasons.length - 1].events.push({
        played: true, q: m.votes[u], goals: p.goals, assists: p.assists, conceded: opp, saves: E.secCode(position) === 'REF' ? p.saves : p.saves,
        result: own > opp ? 1 : own === opp ? 1 / 3 : 0, yellow: c.yellow, red: c.red, cardsKnown: true, resenha: resenhaOf(m, u),
      });
    }
    let transitionK = null;
    if (previousPosition) transitionK = live.filter((m) => m.parts[u] && m.at > changedAt).length;
    return { position, previousPosition, transitionK, seasons };
  }
  async function compareAll(label, overrides = {}) {
    await su();
    const rows = await q(`select r.*, m.user_id from public.player_ratings r join public.pelada_memberships m on m.id=r.membership_id where r.pelada_id=$1`, [A]);
    let n = 0;
    for (const r of rows) {
      const u = Number(r.user_id.slice(-12));
      const pos = overrides[u]?.position ?? ENGINE[CODE[u]];
      const js = E.computeCareer(expectedInput(u, pos, overrides[u]?.previousPosition, overrides[u]?.changedAt));
      assert.equal(r.formula_version, 3, `${label} fv`);
      assert.equal(r.position, pos);
      assert.equal(r.sec_code, E.secCode(pos));
      const cur = js.current ?? { DEF: 70, SEC: 70, APR: 70, RES: 70, DIS: 70, ovr: 70, eligible: false, ovrDisplay: null };
      for (const [col, key] of [['def', 'DEF'], ['sec', 'SEC'], ['apr', 'APR'], ['res', 'RES'], ['dis', 'DIS'], ['ovr', 'ovr']])
        assert.ok(Math.abs(Number(r[col]) - cur[key]) <= TOL, `${label}: jogador ${u} ${key} servidor ${r[col]} x JS ${cur[key]}`);
      assert.equal(r.eligible, cur.eligible, `${label}: jogador ${u} elegível`);
      assert.equal(r.ovr_display, cur.ovrDisplay, `${label}: jogador ${u} OVR exibido`);
      assert.equal(r.matches_played, js.matchesPlayed, `${label}: jogador ${u} partidas`);
      assert.equal(r.atu, null); assert.equal(r.est, null); assert.equal(r.peq, null);
      n++;
    }
    return n;
  }

  // Temporada anterior + atual
  for (let i = 0; i < dates.length; i++) await playMatch(dates[i], { correct: i === 9 });
  assert.equal(await compareAll('após 22 partidas'), 11);
  const corrected = script[9];
  assert.ok(corrected.corrected, 'houve correção durante a votação');

  // ---------------------------------------------------------------- resenha gravada = regra
  await su();
  for (const m of script.slice(-4)) {
    const rows = await q(`select membership_id, resenha from public.match_player_results where match_id=$1`, [m.id]);
    for (const r of rows) assert.equal(r.resenha, resenhaOf(m, USER[r.membership_id]), 'resenha apurada');
  }

  // ---------------------------------------------------------------- votação de resenha: regras de servidor
  const extra = await (async () => { await as(1); const id = await one(`select public.create_match($1,$2)`, [A, new Date(now.getTime() - 3600000).toISOString()]); return id; })();
  await d.query(`select public.save_match_sheet($1,$2::jsonb,'[]')`, [extra, JSON.stringify([1, 2, 3, 5, 6, 7].map((u, i) => ({ membership_id: MEM[u], team: i < 3 ? 'A' : 'B' })))]);
  await d.query(`select public.publish_match($1)`, [extra]);
  const s2 = (await one(`select public.open_rating_vote($1)`, [extra])).session_id;
  await as(2);
  await expectError(() => d.query(`select public.set_rating_vote_resenha($1,$2::uuid[])`, [s2, [MEM[2]]]), 'SELF_VOTE_NOT_ALLOWED');
  await expectError(() => d.query(`select public.set_rating_vote_resenha($1,$2::uuid[])`, [s2, [MEM[9]]]), 'TARGET_NOT_ELIGIBLE');
  let st = await one(`select public.set_rating_vote_resenha($1,$2::uuid[])`, [s2, [MEM[3], MEM[3], MEM[5]]]);
  assert.deepEqual([...st.my_resenha].sort(), [MEM[3], MEM[5]].sort(), 'seleção múltipla sem duplicar');
  st = await one(`select public.set_rating_vote_resenha($1,null)`, [s2]);
  assert.equal(st.my_resenha, null, 'apagar resposta volta a "não respondeu"');
  await as(9);
  await expectError(() => d.query(`select public.set_rating_vote_resenha($1,$2::uuid[])`, [s2, [MEM[3]]]), 'NOT_ELIGIBLE_VOTER');
  await as(2); await d.query(`select public.set_rating_vote_resenha($1,$2::uuid[])`, [s2, [MEM[3]]]);
  await as(1); await d.query(`select public.set_rating_vote_resenha($1,$2::uuid[])`, [s2, []]);
  assert.equal(Number((await one(`select public.get_rating_vote($1)`, [extra])).resenha_answers), 2, 'gestão vê só quantos responderam');
  await as(3); assert.equal((await one(`select public.get_rating_vote($1)`, [extra])).resenha_answers, null, 'jogador não vê contagem');
  await expectError(() => d.query(`select count(*) from private.rating_vote_resenha`), 'permission denied');
  await su(); await d.query(`update public.rating_vote_sessions set closes_at=clock_timestamp()-interval '1 second' where id=$1`, [s2]);
  await as(3); await expectError(() => d.query(`select public.set_rating_vote_resenha($1,$2::uuid[])`, [s2, [MEM[2]]]), 'VOTING_CLOSED');
  await as(1); await d.query(`select public.publish_rating_vote($1)`, [s2]);
  await su();
  const r3 = await q(`select resenha_yes, resenha_voters, resenha from private.rating_vote_results where session_id=$1 and membership_id=$2`, [s2, MEM[3]]);
  assert.deepEqual(r3[0], { resenha_yes: 1, resenha_voters: 2, resenha: false }, 'dois eleitores, um sim => não');
  const r2 = await q(`select resenha_voters, resenha from private.rating_vote_results where session_id=$1 and membership_id=$2`, [s2, MEM[2]]);
  assert.deepEqual(r2[0], { resenha_voters: 1, resenha: null }, 'um eleitor válido (sem o próprio) => indeterminado');
  script.push({ id: extra, at: new Date(now.getTime() - 3600000), parts: Object.fromEntries([1, 2, 3, 5, 6, 7].map((u, i) => [u, { team: i < 3 ? 'A' : 'B', goals: 0, assists: 0, yellow: 0, secondYellow: 0, red: 0, saves: null }])), votes: {}, answers: { 2: [3], 1: [] }, annulled: false });
  assert.equal(await compareAll('após partida de regras da resenha'), 11);

  // ---------------------------------------------------------------- idempotência / duplicidade
  await su();
  const hist0 = Number(await one(`select count(*) from public.player_rating_history where pelada_id=$1`, [A]));
  await d.query(`select private.recompute_cards((select season_id from public.matches where id=$1), null)`, [extra]);
  await d.query(`select private.recompute_cards((select season_id from public.matches where id=$1), null)`, [extra]);
  assert.equal(Number(await one(`select count(*) from public.player_rating_history where pelada_id=$1`, [A])), hist0, 'reprocessar não duplica histórico');
  const run = (await q(`select members, changed, skipped from private.rating_runs where pelada_id=$1 order by id desc limit 1`, [A]))[0];
  assert.equal(run.skipped, run.members, 'entrada idêntica: todos pulados');
  await as(1); await d.query(`select public.publish_rating_vote($1)`, [s2]); // publicação repetida é idempotente
  await su(); assert.equal(Number(await one(`select count(*) from public.player_rating_history where pelada_id=$1`, [A])), hist0);

  // ---------------------------------------------------------------- anulação retroativa (partida da temporada atual)
  const victim = script[12];
  await as(1);
  await d.query(`select public.annul_match($1,'sheet_error','súmula duplicada no teste',true,public.preview_match_annulment($1)->>'preview_token',gen_random_uuid())`, [victim.id]);
  victim.annulled = true;
  assert.equal(await compareAll('após anulação'), 11);
  await su();
  assert.ok(Number(await one(`select count(*) from public.player_rating_history where pelada_id=$1 and kind='recalculated'`, [A])) > 0, 'correção fica no histórico como recalculada');

  // ---------------------------------------------------------------- troca de posição: transição de 5 partidas
  await as(1);
  await d.query(`select public.set_member_position($1,'ATA')`, [MEM[2]]);
  await su();
  const changedAt = new Date((await one(`select changed_at from public.position_changes where membership_id=$1 order by changed_at desc limit 1`, [MEM[2]])));
  const ov = { 2: { position: 'ATA', previousPosition: 'ZAG', changedAt } };
  CODE[2] = 'ATA';
  assert.equal(await compareAll('troca de posição (k=0)', ov), 11);
  assert.equal(Number(await one(`select transition_k from public.player_ratings where membership_id=$1`, [MEM[2]])), 0);
  // Goleiro vira jogador de linha: REF -> LET na carta.
  await as(1); await d.query(`select public.set_member_position($1,'MEI')`, [MEM[5]]);
  await su();
  ov[5] = { position: 'MEI', previousPosition: 'GOL', changedAt: new Date(await one(`select changed_at from public.position_changes where membership_id=$1 order by changed_at desc limit 1`, [MEM[5]])) };
  CODE[5] = 'MEI';
  assert.equal(await compareAll('goleiro para meia', ov), 11);
  assert.equal(await one(`select sec_code from public.player_ratings where membership_id=$1`, [MEM[5]]), 'LET');

  // ---------------------------------------------------------------- cartas, ranking, temporadas
  await su();
  const curSeason = await one(`select season_id from public.matches where id=$1`, [extra]);
  const prevSeason = await one(`select season_id from public.matches where id=$1`, [script[0].id]);
  assert.notEqual(curSeason, prevSeason);
  const cards = await q(`select c.*, r.def rdef, r.sec rsec, r.apr rapr, r.ovr_display rdisp, r.eligible rel, r.ovr rovr from public.player_cards c
    join public.player_season_ratings r on r.season_id=c.season_id and r.membership_id=c.membership_id where c.season_id=$1`, [curSeason]);
  assert.ok(cards.length >= 10);
  for (const c of cards) {
    assert.equal(c.formula_version, 3); assert.equal(c.atu, null);
    assert.equal(Number(c.def), Number(c.rdef)); assert.equal(Number(c.sec), Number(c.rsec)); assert.equal(Number(c.apr), Number(c.rapr));
    assert.equal(c.ovr_display, c.rdisp); assert.equal(c.is_provisional, !c.rel);
    assert.ok(['LET', 'REF'].includes(c.sec_code));
  }
  // 073 (decisão de 01/11/2026): corte desde o início. A temporada anterior, já encerrada, também é V7.7.
  const prevCards = await q(`select formula_version, atu, def from public.player_cards where season_id=$1`, [prevSeason]);
  assert.ok(prevCards.length > 0 && prevCards.every((c) => c.formula_version === 3 && c.atu === null && c.def !== null),
    'temporada encerrada também recalculada pela V7.7 (073)');
  // ... mas o estado V7.7 da temporada anterior existe (herança) com a evidência usada.
  const prevState = await q(`select membership_id, evidence, matches_played from public.player_season_ratings where season_id=$1`, [prevSeason]);
  assert.ok(prevState.length >= 8 && prevState.every((x) => x.evidence.SEC <= x.matches_played));
  await as(3);
  const ranking = await q(`select * from public.get_season_ranking($1,'overall')`, [curSeason]);
  const eligibleCards = cards.filter((c) => c.rel);
  assert.equal(ranking.length, eligibleCards.length, 'ranking só com OVR publicado (5+ partidas)');
  for (const r of ranking) assert.equal(Number(r.metric_value), cards.find((c) => c.membership_id === r.membership_id).rdisp);
  const sorted = [...ranking].map((r) => Number(r.metric_value));
  assert.deepEqual(sorted, [...sorted].sort((a, b) => b - a));
  const pr = await one(`select public.get_player_rating($1)`, [MEM[4]]);
  assert.equal(pr.formula_version, 3); assert.equal(pr.sec_code, 'LET'); assert.ok(pr.def !== null && pr.apr !== null && pr.atu === null);
  const gk = await one(`select public.get_player_rating($1)`, [MEM[1]]);
  assert.equal(gk.sec_code, 'REF');
  assert.ok(gk.history.every((h) => h.formula_version === 3));
  const evo = await one(`select public.get_player_evolution($1,$2)`, [MEM[4], curSeason]);
  assert.equal(evo.current.formula_version, 3);
  assert.ok(evo.current.def !== null && evo.current.sec_code === 'LET');
  assert.ok(evo.points.some((p) => p.def !== null && p.sec_code === 'LET'), 'pontos da evolução com DEF/LET');
  await as(4);
  const career = await one(`select public.get_player_career_summary($1)`, [uid(4)]);
  assert.ok(JSON.stringify(career).includes('"sec_code": "LET"') || JSON.stringify(career).includes('"sec_code":"LET"'), 'Minha Carreira leva LET');

  // ---------------------------------------------------------------- permissões e isolamento
  await as(3);
  await expectError(() => d.query(`select ovr from public.player_season_ratings limit 1`), 'permission denied');
  assert.ok((await q(`select def from public.player_season_ratings where pelada_id=$1`, [A])).length > 0);
  await as(16);
  assert.equal((await q(`select id from public.player_season_ratings where pelada_id=$1`, [A])).length, 0, 'membro de outra pelada não lê');
  await expectError(() => d.query(`select public.get_player_rating($1)`, [MEM[3]]), 'NOT_FOUND');
  await su();
  const bRating = (await q(`select * from public.player_ratings where pelada_id=$1 and membership_id=(select id from public.pelada_memberships where pelada_id=$1 and user_id=$2)`, [B, uid(2)]))[0];
  assert.ok(!bRating || bRating.matches_played === 0, 'jogador 2 na pelada B sem nada da pelada A');
  await expectError(async () => { await as(3); await d.query(`select count(*) from private.rating_runs`); }, 'permission denied');

  // ---------------------------------------------------------------- rollback para a V5 e volta
  await su();
  await d.query(`update private.rating_params set active=false where version=2`);
  await d.query(`select private.recompute_cards($1, null)`, [curSeason]);
  assert.equal(Number(await one(`select count(*) from public.player_ratings where pelada_id=$1 and formula_version=2 and atu is not null`, [A])), 11, 'rollback: V5 de volta');
  assert.ok(Number(await one(`select count(*) from public.player_rating_history where pelada_id=$1 and formula_version=3`, [A])) > 0, 'histórico V7.7 preservado');
  await d.query(`update private.rating_params set active=true where version=2`);
  await d.query(`select private.recompute_cards($1, null)`, [curSeason]);
  assert.equal(await compareAll('de volta à V7.7', ov), 11);
  await d.close();
});
