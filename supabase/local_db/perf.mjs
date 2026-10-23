// V4.4: testes de carga e planos de execução com um PostgreSQL 17 REAL (embedded-postgres), nada no Supabase.
// Uso: cd supabase/local_db; node perf.mjs            (cenário completo; alguns minutos)
//      SMALL=1 node perf.mjs                           (rápido, para conferir o script)
// Sobe dois bancos com a MESMA massa de dados (gerada de forma determinística):
//   v43 = migrações até a 043 (V4.3)   v44 = todas (V4.4)
// e mede as mesmas chamadas nos dois. Os planos (EXPLAIN ANALYZE BUFFERS das consultas internas, via auto_explain)
// vão para ../../docs/evidencias_v44/explain_*.txt e o resumo para ../../docs/evidencias_v44/perf_resultados.json.
// Limites (documentados no relatório): um computador só, sem rede (o Supabase soma ~20-80 ms de rede por chamada),
// Postgres com configuração padrão, massa sintética.
import EmbeddedPostgres from 'embedded-postgres';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';

const SMALL = !!process.env.SMALL;
const root = join(import.meta.dirname, '..');
const out = join(root, '..', 'docs', 'evidencias_v44');
mkdirSync(out, { recursive: true });
const all = readdirSync(join(root, 'migrations')).filter((f) => f.endsWith('.sql')).sort();
const upTo43 = all.filter((f) => f < '044');

// Peladas: jogadores cadastrados x partidas históricas. O usuário 1 administra todas; o 2 joga em todas.
const PELADAS = SMALL
  ? [
      { key: 'P20', players: 20, matches: 50 },
      { key: 'P100', players: 100, matches: 200 },
    ]
  : [
      { key: 'P20', players: 20, matches: 100 },
      { key: 'P50', players: 50, matches: 300 },
      { key: 'P100', players: 100, matches: 1000 },
      { key: 'P200', players: 200, matches: 1000 },
      { key: 'P500', players: 500, matches: 5000 },
    ];
const USERS = Math.max(...PELADAS.map((p) => p.players));
const FIN = SMALL ? [1000, 2400] : [1000, 5000, 10000]; // movimentações financeiras (todas no mês atual: pior caso)
const PER_SIDE = 8;

const results = { generated_at: new Date().toISOString(), small: SMALL, postgres: null, setup: {}, measures: [] };
const log = (...a) => console.log(...a);

async function startServer() {
  const dir = mkdtempSync(join(tmpdir(), 'm91-perf-'));
  const port = 56000 + Math.floor(Math.random() * 500);
  const server = new EmbeddedPostgres({ databaseDir: dir, user: 'postgres', password: 'postgres', port, persistent: false, onLog: (m) => process.env.PGLOG && console.error('[pg]', String(m).trim()), onError: (m) => console.error('[pg-err]', String(m).trim()) });
  await server.initialise();
  await server.start();
  return { server, dir, port };
}

async function makeDb(srv, name, files) {
  await srv.server.createDatabase(name);
  const cfg = { host: 'localhost', port: srv.port, user: 'postgres', password: 'postgres', database: name };
  const c = new pg.Client(cfg);
  await c.connect();
  await c.query(readFileSync(join(import.meta.dirname, 'shim.sql'), 'utf8'));
  for (const f of files) await c.query(readFileSync(join(root, 'migrations', f), 'utf8'));
  await c.query(`update private.app_config set value='true'::jsonb where key='premium_beta_open'`);
  return { name, cfg, c };
}

const uid = (n) => `d4400000-0000-4000-8000-${String(n).padStart(12, '0')}`;

// Massa esportiva: usuários, peladas, partidas finalizadas (súmula, resultados, eventos, Craque, Rei do Mês),
// estatísticas e Cards recalculados pelas funções oficiais. Tudo determinístico (mesma massa nos dois bancos).
async function seedSports(db) {
  const { c } = db;
  let t = performance.now();
  await c.query(`insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
   select ('d4400000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'perf'||n||'@example.invalid','',now(),now(),now() from generate_series(1,${USERS}) n`);
  await c.query(`set role authenticated`);
  await c.query(`do $$ begin for i in 1..${USERS} loop
    perform set_config('request.jwt.claim.sub', ('d4400000-0000-4000-8000-'||lpad(i::text,12,'0')), false);
    perform public.complete_onboarding('Jogador '||i, true, true); end loop; end $$`);
  const ids = {};
  for (const p of PELADAS) {
    await c.query(`select set_config('request.jwt.claim.sub', $1, false)`, [uid(1)]);
    const pid = (await c.query(`select public.create_pelada($1,'GOL') id`, [`Pelada ${p.key}`])).rows[0].id;
    const tok = (await c.query(`select public.create_pelada_invite($1, 24, 1000) t`, [pid])).rows[0].t;
    // até 100 entram pelo convite (regra atual do servidor: no máximo 100 ativos); acima disso, direto no banco (só para medir)
    const viaInvite = Math.min(p.players, 100);
    await c.query(`do $$ declare codes text[] := array['GOL','ZAG','LD','LE','VOL','MEI','CA','PD','PE','ATA']; begin
      for i in 2..${viaInvite} loop
       perform set_config('request.jwt.claim.sub', ('d4400000-0000-4000-8000-'||lpad(i::text,12,'0')), false);
       perform public.join_pelada('${tok}', codes[1 + i % 10]); end loop; end $$`);
    ids[p.key] = pid;
  }
  await c.query(`reset role`);
  for (const p of PELADAS.filter((x) => x.players > 100)) {
    await c.query(`insert into public.pelada_memberships(pelada_id,user_id,player_name,preferred_position,position_code)
      select $1, ('d4400000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid, 'Jogador '||i,
       (array['goalkeeper','defender','defender','defender','midfielder','midfielder','attacker','attacker','attacker','attacker'])[1 + i % 10],
       (array['GOL','ZAG','LD','LE','VOL','MEI','CA','PD','PE','ATA'])[1 + i % 10]
      from generate_series(101, ${p.players}) i`, [ids[p.key]]);
  }
  results.setup.users_and_peladas_s = +((performance.now() - t) / 1000).toFixed(1);

  t = performance.now();
  for (const p of PELADAS) {
    const pid = ids[p.key];
    // partidas espalhadas por ~4 anos (várias temporadas)
    await c.query(`insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
      select $1, private.season_for_date($1, private.pelada_local_date($1, ts)), ts, 'finalized', g % 5, (g * 7) % 4, ts
      from (select g, now() - make_interval(hours => ((${p.matches} - g) * (24 * 4 * 365 / ${p.matches}))::int + 1) ts
            from generate_series(1, ${p.matches}) g) x`, [pid]);
    // 16 jogadores por partida (8 x 8), escolhidos de forma determinística
    await c.query(`with mt as (select id, row_number() over (order by played_at, id) k from public.matches where pelada_id=$1),
      mem as (select id, preferred_position, row_number() over (order by id) r, count(*) over () n from public.pelada_memberships where pelada_id=$1 and status='active'),
      pick as (select mt.id match_id, mt.k, mem.id membership_id, mem.preferred_position, s.slot
               from mt cross join generate_series(0, ${PER_SIDE * 2 - 1}) s(slot)
               join mem on mem.r = 1 + ((mt.k * 7 + s.slot * 13) % mem.n))
      insert into public.match_participants(pelada_id,match_id,membership_id,team,primary_position)
      select distinct on (match_id, membership_id) $1, match_id, membership_id, case when slot % 2 = 0 then 'A' else 'B' end, preferred_position
      from pick order by match_id, membership_id, slot`, [pid]);
    await c.query(`insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
      select $1, mp.match_id, mp.id, mp.team, 'goal', 1 from public.match_participants mp
      where mp.pelada_id=$1 and abs(hashtext(mp.id::text)) % 4 = 0`, [pid]);
    await c.query(`insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
      select $1, mp.match_id, mp.id, mp.team, 'assist', 1 from public.match_participants mp
      where mp.pelada_id=$1 and abs(hashtext(mp.id::text)) % 4 = 1`, [pid]);
    await c.query(`insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,objective_rating,
       final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
      select $1, mp.match_id, mp.membership_id, 6, r, 5, r, true,
       (select count(*) from public.match_events e where e.participant_id=mp.id and e.event_type='goal'),
       (select count(*) from public.match_events e where e.participant_id=mp.id and e.event_type='assist'), 0,
       case when m.team_a_score = m.team_b_score then 'draw' when (m.team_a_score > m.team_b_score) = (mp.team='A') then 'win' else 'loss' end,
       mp.primary_position, 1
      from public.match_participants mp join public.matches m on m.id=mp.match_id
      cross join lateral (select 5 + (abs(hashtext(mp.id::text)) % 50) / 10.0 r) rr
      where mp.pelada_id=$1`, [pid]);
    await c.query(`insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count)
      select distinct on (r.match_id) $1, r.match_id, m.season_id, r.membership_id, 'match_craque', 3
      from public.match_player_results r join public.matches m on m.id=r.match_id where r.pelada_id=$1
      order by r.match_id, r.final_rating desc, r.membership_id`, [pid]);
    await c.query(`insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count)
      select distinct on (r.match_id) $1, r.match_id, m.season_id, r.membership_id, 'bola_murcha', 2
      from public.match_player_results r join public.matches m on m.id=r.match_id where r.pelada_id=$1
      order by r.match_id, r.final_rating, r.membership_id`, [pid]);
    await c.query(`insert into public.awards(pelada_id,season_id,membership_id,award_type,period_month)
      select distinct on (date_trunc('month', m.played_at)) $1, m.season_id, r.membership_id, 'monthly_king', date_trunc('month', m.played_at)::date
      from public.match_player_results r join public.matches m on m.id=r.match_id where r.pelada_id=$1
      order by date_trunc('month', m.played_at), r.final_rating desc, r.membership_id`, [pid]);
    await c.query(`do $$ declare s uuid; begin for s in select id from public.seasons where pelada_id='${pid}' order by starts_on loop
      perform private.recompute_stats('${pid}', s); perform private.recompute_season_cards(s, null); end loop; end $$`);
  }
  await c.query(`analyze`);
  results.setup.sports_s = +((performance.now() - t) / 1000).toFixed(1);
  return ids;
}

// Financeiro: N movimentações (metade pagamentos de cobranças, metade lançamentos), todas no mês atual (pior caso
// para o limite de 1.000 da V4.3). Invariantes do 043 mantidos (pago = soma dos pagamentos não estornados).
async function seedFinance(db, pid, n) {
  const { c } = db;
  const charges = Math.floor(n / 2);
  await c.query(`do $$ declare v_p uuid := '${pid}'; v_today date := private.pelada_today(v_p); v_m0 date := date_trunc('month', v_today)::date;
    v_days int := v_today - date_trunc('month', v_today)::date + 1; v_mem uuid[]; begin
    v_mem := array(select id from public.pelada_memberships where pelada_id=v_p and status='active' order by id limit 30);
    insert into public.finance_charges(id,pelada_id,kind,membership_id,description,amount_due_cents,amount_paid_cents,due_date,status,request_id,created_at)
    select ('f'||lpad(to_hex(g),7,'0')||'-0000-4000-8000-'||lpad(to_hex(${n}),12,'0'))::uuid, v_p, 'single', v_mem[1 + g % cardinality(v_mem)],
     'Avulso '||g, 1000 + (g*37) % 9000,
     case when g % 12 = 0 or g % 10 = 0 then 0 when g % 10 = 1 then (1000 + (g*37) % 9000) / 2 else 1000 + (g*37) % 9000 end,
     v_m0 + (g % 3) * 10,
     case when g % 12 = 0 or g % 10 = 0 then 'pending' when g % 10 = 1 then 'partial' else 'paid' end,
     gen_random_uuid(), now() - make_interval(secs => ${charges} - g)
    from generate_series(1, ${charges}) g;
    insert into public.finance_payments(pelada_id,charge_id,amount_cents,received_on,method,request_id,created_at,reversed_at,reverse_reason)
    select v_p, c.id, case when g % 10 = 1 then c.amount_due_cents / 2 else c.amount_due_cents end, v_m0 + (g % v_days), 'pix', gen_random_uuid(),
     now() - make_interval(secs => ${charges} - g), case when g % 12 = 0 then now() end, case when g % 12 = 0 then 'carga' end
    from generate_series(1, ${charges}) g
    join public.finance_charges c on c.id = ('f'||lpad(to_hex(g),7,'0')||'-0000-4000-8000-'||lpad(to_hex(${n}),12,'0'))::uuid
    where g % 10 <> 0;
    insert into public.finance_entries(pelada_id,direction,category,description,amount_cents,entry_date,status,request_id,created_at)
    select v_p, case when g % 2 = 0 then 'income' else 'expense' end,
     (array['Aluguel do campo','Arbitragem','Água','Patrocínio','Venda de uniformes','Outras receitas'])[1 + g % 6],
     'Lançamento '||g, 300 + g % 5000, v_m0 + (g % v_days), case when g % 15 = 0 then 'pending' when g % 31 = 0 then 'cancelled' else 'settled' end,
     gen_random_uuid(), now() - make_interval(secs => ${n} - g)
    from generate_series(1, ${n - charges}) g;
    insert into public.finance_events(pelada_id,event_type,entity,created_at) select v_p,'payment_registered','payment',now() from generate_series(1, ${charges});
  end $$`);
  await c.query(`analyze public.finance_charges, public.finance_payments, public.finance_entries, public.finance_events`);
}

async function asUser(c, n) {
  await c.query(`select set_config('request.jwt.claim.sub', $1, false)`, [uid(n)]);
  await c.query(`set role authenticated`);
}

async function timeIt(c, sql, params, reps = 5) {
  const times = [];
  let row;
  for (let i = 0; i < reps; i++) {
    const t = performance.now();
    const r = await c.query(sql, params);
    times.push(performance.now() - t);
    row = r.rows[0];
  }
  times.sort((a, b) => a - b);
  const bytes = row ? Buffer.byteLength(JSON.stringify(row)) : 0;
  return { median_ms: +times[Math.floor(times.length / 2)].toFixed(1), max_ms: +times[times.length - 1].toFixed(1), bytes, row };
}

async function measure(db, label, area, sql, params, extra = {}) {
  const r = await timeIt(db.c, sql, params);
  const m = { db: db.name, area, label, median_ms: r.median_ms, max_ms: r.max_ms, response_kb: +(r.bytes / 1024).toFixed(1), ...extra };
  results.measures.push(m);
  log(`  [${db.name}] ${label.padEnd(64)} ${String(r.median_ms).padStart(8)} ms  ${String(m.response_kb).padStart(8)} KB`);
  return r.row;
}

// Planos das consultas internas (auto_explain com ANALYZE e BUFFERS, devolvidos como NOTICE ao cliente).
async function explain(db, file, sql, params) {
  const notes = [];
  const h = (n) => notes.push(n.message);
  db.c.on('notice', h);
  await db.c.query(`reset role`);
  await db.c.query(`load 'auto_explain'`);
  await db.c.query(`set auto_explain.log_min_duration = 0; set auto_explain.log_analyze = on; set auto_explain.log_buffers = on;
    set auto_explain.log_nested_statements = on; set auto_explain.log_level = notice; set client_min_messages = notice`);
  await asUser(db.c, 1);
  await db.c.query(sql, params);
  await db.c.query(`reset role`);
  await db.c.query(`set auto_explain.log_min_duration = -1`);
  db.c.removeListener('notice', h);
  // Cada comando interno executado vira um plano. Guardamos quantos foram (N+1 aparece aqui) e os 25 mais lentos.
  const parsed = notes
    .map((n) => ({ ms: Number(/duration: ([\d.]+) ms/.exec(n)?.[1] ?? 0), n }))
    .filter((x) => !x.n.includes("set_config('request.jwt"));
  const total = parsed.reduce((t, x) => t + x.ms, 0);
  const top = [...parsed].sort((x, y) => y.ms - x.ms).slice(0, 25);
  writeFileSync(
    join(out, file),
    `-- ${db.name}: ${sql}\n-- comandos internos executados: ${parsed.length}; soma das durações: ${total.toFixed(1)} ms\n` +
      `-- abaixo, os ${top.length} mais lentos (EXPLAIN ANALYZE, BUFFERS via auto_explain)\n\n${top.map((x) => x.n).join('\n\n-----\n\n')}\n`,
  );
  results.measures.push({ db: db.name, area: 'explain', label: file, internal_statements: parsed.length, internal_ms: +total.toFixed(1) });
  await asUser(db.c, 1);
}

const srv = await startServer();
try {
  const dbs = [];
  for (const [name, files] of [['v43', upTo43], ['v44', all]]) {
    const t = performance.now();
    const db = await makeDb(srv, name, files);
    log(`${name}: ${files.length} migrações (${((performance.now() - t) / 1000).toFixed(1)}s)`);
    const s0 = performance.now();
    db.ids = await seedSports(db);
    log(`  massa esportiva: ${((performance.now() - s0) / 1000).toFixed(1)}s`, results.setup);
    dbs.push(db);
  }
  results.postgres = (await dbs[0].c.query('show server_version')).rows[0].server_version;
  const vol = (await dbs[1].c.query(`select (select count(*) from public.matches) partidas, (select count(*) from public.match_player_results) resultados,
    (select count(*) from public.awards) premios, (select count(*) from public.pelada_memberships) membros, (select count(*) from public.seasons) temporadas`)).rows[0];
  results.setup.volume = vol;
  log('volume:', vol);

  // ---------- Financeiro ----------
  log('\nFinanceiro (admin, Pelada Premium; todas as movimentações no mês atual):');
  for (const n of FIN) {
    const pidKey = 'P20';
    for (const db of dbs) {
      await db.c.query('reset role');
      // uma pelada nova por cenário, com o admin 1
      await asUser(db.c, 1);
      const pid = (await db.c.query(`select public.create_pelada($1,'GOL') id`, [`Caixa ${n}`])).rows[0].id;
      const tok = (await db.c.query(`select public.create_pelada_invite($1, 24, 1000) t`, [pid])).rows[0].t;
      await db.c.query(`do $$ begin for i in 2..31 loop perform set_config('request.jwt.claim.sub', ('d4400000-0000-4000-8000-'||lpad(i::text,12,'0')), false);
        perform public.join_pelada('${tok}', 'MEI'); end loop; end $$`);
      await db.c.query('reset role');
      await seedFinance(db, pid, n);
      db.fin = db.fin ?? {};
      db.fin[n] = pid;
      void pidKey;
    }
    for (const db of dbs) {
      const pid = db.fin[n];
      await asUser(db.c, 1);
      const month = (await db.c.query(`select date_trunc('month', now())::date m`)).rows[0].m;
      const tag = { movements: n };
      const rep = await measure(db, `relatório do mês (${n} mov.)`, 'financeiro', `select public.get_finance_report($1, $2) r`, [pid, month], tag);
      const cats = rep.r.by_category.filter((x) => x.direction === 'income').reduce((s, x) => s + Number(x.amount_cents), 0);
      const ok = cats === Number(rep.r.income_cents);
      results.measures.push({ db: db.name, area: 'financeiro', label: `categorias = total de receitas (${n} mov.)`, correct: ok, categories_income: cats, income: Number(rep.r.income_cents), ...tag });
      log(`  [${db.name}] categorias de receita ${cats} x total ${rep.r.income_cents} → ${ok ? 'IGUAIS' : 'DIFERENTES (perda de registros)'}`);
      await measure(db, `painel (${n} mov.)`, 'financeiro', `select public.get_finance_overview($1) r`, [pid], tag);
      await measure(db, `cobranças: lista inteira da V4.3 (${n / 2})`, 'financeiro', `select public.get_finance_charges($1) r`, [pid], tag);
      await measure(db, `pessoas e mensalistas (${n} mov.)`, 'financeiro', `select public.get_finance_people($1) r`, [pid], tag);
      if (db.name === 'v44') {
        await measure(db, `cobranças: 1ª página de 30 + resumo (${n / 2})`, 'financeiro', `select public.get_finance_charges_page($1,null,null,null,null,null,null,30) r`, [pid], tag);
        await measure(db, `cobranças: em aberto, 1ª página`, 'financeiro', `select public.get_finance_charges_page($1,null,'open',null,null,null,null,30) r`, [pid], tag);
        await measure(db, `livro-caixa: 1ª página de 40 + total`, 'financeiro', `select public.get_finance_ledger_page($1,$2,null,null,null,null,40,true) r`, [pid, month], tag);
        // exportação completa: todas as páginas de 500
        const t = performance.now();
        let after = null;
        let count = 0;
        let total = null;
        let pages = 0;
        for (;;) {
          const r = (await db.c.query(`select public.get_finance_ledger_page($1,$2,null,null,null,$3,500,$4) r`, [pid, month, after, after === null])).rows[0].r;
          if (r.total) total = Number(r.total.count);
          count += r.items.length;
          pages++;
          if (!r.next) break;
          after = r.next;
        }
        const ms = performance.now() - t;
        results.measures.push({ db: db.name, area: 'financeiro', label: `exportação completa (${n} mov.)`, total_ms: +ms.toFixed(0), pages, rows: count, expected: total, complete: count === total, ...tag });
        log(`  [${db.name}] exportação completa: ${count}/${total} linhas em ${pages} páginas, ${ms.toFixed(0)} ms → ${count === total ? 'COMPLETA' : 'INCOMPLETA'}`);
      } else {
        const r = await measure(db, `exportação V4.3 (ledger 1000)`, 'financeiro', `select jsonb_array_length(public.get_finance_ledger($1,$2,null,null,1000)) n`, [pid, month], tag);
        // verdade: quantas movimentações existem no mês (10% das cobranças ficaram sem pagamento)
        await db.c.query('reset role');
        const truth = Number((await db.c.query(`select (select count(*) from public.finance_payments where pelada_id=$1 and received_on >= $2)
          + (select count(*) from public.finance_entries where pelada_id=$1 and entry_date >= $2) n`, [pid, month])).rows[0].n);
        await asUser(db.c, 1);
        results.measures.push({ db: db.name, area: 'financeiro', label: `exportação V4.3 (${n} mov.)`, rows: r.n, expected: truth, complete: r.n === truth, ...tag });
        log(`  [${db.name}] exportação V4.3: ${r.n} de ${truth} linhas → ${r.n === truth ? 'COMPLETA' : 'INCOMPLETA'}`);
      }
      await db.c.query('reset role');
    }
  }
  // Planos (10.000 ou o maior cenário)
  const big = FIN[FIN.length - 1];
  for (const db of dbs) {
    const pid = db.fin[big];
    await asUser(db.c, 1);
    const month = (await db.c.query(`select date_trunc('month', now())::date m`)).rows[0].m;
    await explain(db, `explain_${db.name}_relatorio_${big}.txt`, `select public.get_finance_report($1, $2)`, [pid, month]);
    await explain(db, `explain_${db.name}_painel_${big}.txt`, `select public.get_finance_overview($1)`, [pid]);
    if (db.name === 'v44') {
      await explain(db, `explain_v44_cobrancas_pagina_${big}.txt`, `select public.get_finance_charges_page($1,null,'open',null,null,null,null,30)`, [pid]);
      await explain(db, `explain_v44_livro_caixa_pagina_${big}.txt`, `select public.get_finance_ledger_page($1,$2,null,null,null,null,500,true)`, [pid, month]);
    }
    await db.c.query('reset role');
  }

  // ---------- Central do Jogador, carreira e telas da pelada ----------
  const v44 = dbs[1];
  log('\nCentral do Jogador e Minha Carreira (usuário 2: joga em todas as peladas):');
  await asUser(v44.c, 2);
  await measure(v44, 'Central do Jogador (get_player_central)', 'central', `select public.get_player_central() r`, []);
  await measure(v44, 'Resumo da carreira (get_player_career_summary)', 'central', `select public.get_player_career_summary($1) r`, [uid(2)]);
  await measure(v44, 'Troféus: Craque, 1ª página de 20', 'carreira', `select public.get_trophy_history($1,'match_craque',null,20) r`, [uid(2)]);
  const h1 = await measure(v44, 'Histórico de partidas: 1ª página de 20', 'carreira', `select public.get_my_match_history(null,null,20) r`, []);
  let after = h1.r.next;
  for (let i = 0; i < 20 && after; i++) after = (await v44.c.query(`select public.get_my_match_history(null,$1,20) r`, [after])).rows[0].r.next;
  if (after) await measure(v44, 'Histórico de partidas: página 22 (antiga)', 'carreira', `select public.get_my_match_history(null,$1,20) r`, [after]);
  await measure(v44, 'Carreira V4.3 (get_player_career, com conquistas)', 'carreira', `select public.get_player_career($1) r`, [uid(2)]);
  await measure(v44, 'Início V4.3 (get_my_home)', 'central', `select public.get_my_home() r`, []);
  await explain(v44, 'explain_v44_central.txt', `select public.get_player_central()`, []);
  await v44.c.query('reset role');

  log('\nTelas da pelada por tamanho (usuário 2, RLS):');
  for (const p of PELADAS) {
    const pid = v44.ids[p.key];
    await asUser(v44.c, 2);
    const season = (await v44.c.query(`select id from public.seasons where pelada_id=$1 order by starts_on desc limit 1`, [pid])).rows[0].id;
    const tag = { pelada: p.key, players: p.players, matches: p.matches };
    await measure(v44, `${p.key}: Elenco (cards + membros)`, 'pelada', `select (select count(*) from public.player_cards where season_id=$1) + (select count(*) from public.pelada_memberships where pelada_id=$2 and status='active') n`, [season, pid], tag);
    await measure(v44, `${p.key}: partidas (página de 30)`, 'pelada', `select count(*) n from (select id from public.matches where pelada_id=$1 order by played_at desc limit 31) x`, [pid], tag);
    await measure(v44, `${p.key}: ranking de gols da temporada`, 'pelada', `select count(*) n from public.get_season_ranking($1,'goals')`, [season], tag);
    await measure(v44, `${p.key}: ranking de overall da temporada`, 'pelada', `select count(*) n from public.get_season_ranking($1,'overall')`, [season], tag);
    await measure(v44, `${p.key}: recordes da temporada`, 'pelada', `select public.get_season_records($1) r`, [season], tag);
    await v44.c.query('reset role');
  }

  log('\nSorteio no servidor (admin, Pelada Premium):');
  await asUser(v44.c, 1);
  await v44.c.query(`set statement_timeout = '180s'`);
  const bigKey = PELADAS[PELADAS.length - 1].key;
  for (const n of SMALL ? [20, 50] : [20, 50, 100]) {
    const ids = (await v44.c.query(`select array_agg(id) a from (select id from public.pelada_memberships where pelada_id=$1 and status='active' order by id limit $2) x`, [v44.ids[bigKey], n])).rows[0].a;
    try {
      const r = await timeIt(v44.c, `select public.create_team_draw($1, $2::uuid[], 'single', 1) r`, [v44.ids[bigKey], ids], 3);
      results.measures.push({ db: 'v44', area: 'sorteio', label: `sorteio único, ${n} jogadores`, median_ms: r.median_ms, max_ms: r.max_ms, players: n });
      log(`  sorteio único, ${n} jogadores: ${r.median_ms} ms`);
    } catch (e) {
      results.measures.push({ db: 'v44', area: 'sorteio', label: `sorteio único, ${n} jogadores`, error: e.message, players: n });
      log(`  sorteio único, ${n} jogadores: ERRO ${e.message}`);
    }
  }
  await v44.c.query(`reset statement_timeout; reset role`);

  // ---------- Concorrência: vários usuários de várias peladas ao mesmo tempo ----------
  log('\nConcorrência (leituras simultâneas, conexões separadas):');
  for (const conns of SMALL ? [10] : [10, 30]) {
    const clients = await Promise.all(Array.from({ length: conns }, async (_, i) => {
      const cl = new pg.Client(v44.cfg);
      await cl.connect();
      await asUser(cl, 2 + i);
      return cl;
    }));
    // 1ª chamada de cada conexão (compila as funções PL/pgSQL na sessão): medida à parte
    const cold = [];
    await Promise.all(clients.map(async (cl, i) => {
      const s = performance.now();
      await cl.query(`select public.get_player_central()`);
      await cl.query(`select public.get_player_career_summary($1)`, [uid(2 + i)]);
      cold.push(performance.now() - s);
    }));
    cold.sort((a, b) => a - b);
    const lat = [];
    const t = performance.now();
    await Promise.all(clients.map(async (cl, i) => {
      for (let k = 0; k < 10; k++) {
        const s = performance.now();
        await cl.query(`select public.get_player_central()`);
        await cl.query(`select public.get_player_career_summary($1)`, [uid(2 + i)]);
        lat.push(performance.now() - s);
      }
    }));
    const wall = performance.now() - t;
    lat.sort((a, b) => a - b);
    const p = (q) => +lat[Math.min(lat.length - 1, Math.floor(q * lat.length))].toFixed(1);
    results.measures.push({ db: 'v44', area: 'concorrencia', label: `${conns} usuários x 10 aberturas da Central`, connections: conns, requests: lat.length, p50_ms: p(0.5), p95_ms: p(0.95), max_ms: p(1), wall_ms: +wall.toFixed(0),
      cold_first_call_median_ms: +cold[Math.floor(cold.length / 2)].toFixed(1), cold_first_call_max_ms: +cold[cold.length - 1].toFixed(1) });
    log(`  ${conns} conexões: ${lat.length} aberturas da Central, p50 ${p(0.5)} ms, p95 ${p(0.95)} ms, total ${wall.toFixed(0)} ms; 1ª chamada de cada conexão (fria): mediana ${cold[Math.floor(cold.length / 2)].toFixed(0)} ms`);
    await Promise.all(clients.map((cl) => cl.end()));
  }

  for (const db of dbs) results.measures.forEach((m) => delete m.row);
  writeFileSync(join(out, SMALL ? 'perf_resultados_small.json' : 'perf_resultados.json'), JSON.stringify(results, null, 1));
  log(`\nResultados em docs/evidencias_v44/${SMALL ? 'perf_resultados_small.json' : 'perf_resultados.json'}`);
  for (const db of dbs) await db.c.end();
} finally {
  await srv.server.stop();
  try {
    rmSync(srv.dir, { recursive: true, force: true });
  } catch {
    // Windows às vezes segura a pasta por alguns segundos; é temporária
  }
}
