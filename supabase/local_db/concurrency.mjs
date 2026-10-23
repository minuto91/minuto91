// Testes de concorrência com um PostgreSQL REAL (embedded-postgres, binário oficial do Postgres 17)
// e duas conexões simultâneas (V4.2, seção 8.1). Nada aqui conecta ao Supabase.
// Uso: cd supabase/local_db; npm install; node concurrency.mjs
// Roda duas vezes: com as migrações até a 035 (V4.1) e com todas, e compara.
// V4.3: também disputa o Financeiro (043) com admin e assistente ao mesmo tempo (invariantes contábeis).
// V4.5: exporta o mês enquanto outra conexão escreve (ONLY_EXPORT=1 node concurrency.mjs 30 roda só essa parte).
import EmbeddedPostgres from 'embedded-postgres';
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';

const root = join(import.meta.dirname, '..');
const migrations = readdirSync(join(root, 'migrations')).filter((f) => f.endsWith('.sql')).sort();
const ITER = Number(process.argv[2] ?? 30);

// Cenário: pelada com 7 eleitores, partida publicada, 6 já votaram (confirmados); o 7º está confirmado.
const SETUP = `
create schema cc;
create function cc.uid(n int) returns uuid language sql as $$ select ('94000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid $$;
create function cc.as_user(n int) returns void language sql as $$ select set_config('request.jwt.claim.sub', cc.uid(n)::text, false) $$;
create table cc.runs(id int primary key, pelada uuid, match uuid, session uuid, parts jsonb, mems uuid[]);
insert into auth.users(id,aud,role,email) select cc.uid(n),'authenticated','authenticated','cc'||n||'@example.invalid' from generate_series(1,7) n;
do $$ begin for i in 1..7 loop perform cc.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop; end $$;
create function cc.setup(p_run int) returns void language plpgsql as $$
declare v_p uuid; v_tok text; v_m uuid[]; v_parts jsonb; v_x uuid; v_s uuid; v_me uuid; v_scores jsonb;
begin
 perform cc.as_user(1);
 v_p := public.create_pelada('Concorrência '||p_run,'attacker');
 update public.pelada_settings set bola_murcha_enabled=false where pelada_id=v_p;
 v_tok := public.create_pelada_invite(v_p);
 for i in 2..7 loop perform cc.as_user(i); perform public.join_pelada(v_tok,'midfielder'); end loop;
 v_m := array(select id from public.pelada_memberships where pelada_id=v_p order by user_id);
 select jsonb_agg(jsonb_build_object('membership_id',v_m[i],'team',case when i%2=1 then 'A' else 'B' end)) into v_parts from generate_series(1,7) i;
 perform cc.as_user(1);
 v_x := public.create_match(v_p, now());
 perform public.save_match_sheet(v_x, v_parts, '[]');
 v_s := (public.publish_match(v_x, 240)->>'session_id')::uuid;
 for i in 1..7 loop
  perform cc.as_user(i); v_me := v_m[i];
  perform public.confirm_match_sheet(v_x, 1);
  if i < 7 then
   select jsonb_agg(jsonb_build_object('membership_id',x,'rating',7)) into v_scores from unnest(v_m) x where x<>v_me;
   perform public.submit_ballot(v_s, 1, v_scores, (select x from unnest(v_m) x where x<>v_me limit 1), null, 'chave-cc-'||p_run||'-'||i);
  end if;
 end loop;
 insert into cc.runs values(p_run, v_p, v_x, v_s, v_parts, v_m);
end $$;
`;

async function startDb(label, files) {
  const dir = mkdtempSync(join(tmpdir(), 'm91-pg-'));
  const port = 55400 + Math.floor(Math.random() * 500);
  const server = new EmbeddedPostgres({ databaseDir: dir, user: 'postgres', password: 'postgres', port, persistent: false, onLog: () => {} });
  await server.initialise();
  await server.start();
  await server.createDatabase('m91');
  const cfg = { host: 'localhost', port, user: 'postgres', password: 'postgres', database: 'm91' };
  const admin = new pg.Client(cfg);
  await admin.connect();
  await admin.query(readFileSync(join(import.meta.dirname, 'shim.sql'), 'utf8'));
  for (const f of files) await admin.query(readFileSync(join(root, 'migrations', f), 'utf8'));
  await admin.query(`update private.app_config set value='true'::jsonb where key='premium_beta_open'`);
  await admin.query(SETUP);
  console.log(`${label}: Postgres ${(await admin.query('show server_version')).rows[0].server_version}, ${files.length} migrações`);
  return { server, dir, cfg, admin };
}

async function client(cfg) {
  const c = new pg.Client(cfg);
  await c.connect();
  return c;
}

const outcome = (e) => (e ? (e.code === '40P01' ? 'DEADLOCK' : e.message.split('\n')[0]) : 'ok');

// Correção (A) e último voto (B) ao mesmo tempo, cada um na sua conexão e transação.
// determinístico: B começa pela primeira trava da função de voto da versão (sessão na V4.1;
// pelada -> partida -> sessão na V4.2), A corrige enquanto isso, e B termina o voto.
async function race(db, run, deterministic, v42) {
  const { admin } = db;
  await admin.query('select cc.setup($1)', [run]);
  const r = (await admin.query('select * from cc.runs where id=$1', [run])).rows[0];
  const A = await client(db.cfg);
  const B = await client(db.cfg);
  const events = JSON.stringify([{ membership_id: r.mems[0], type: 'goal', quantity: 1 }]);
  let ea = null;
  let eb = null;
  try {
    await A.query(`select cc.as_user(1)`);
    await B.query(`select cc.as_user(7)`);
    await B.query('begin');
    await A.query('begin');
    const scores = JSON.stringify(r.mems.filter((m) => m !== r.mems[6]).map((m) => ({ membership_id: m, rating: 7 })));
    const vote = () =>
      B.query(`select public.submit_ballot($1,1,$2::jsonb,$3,null,$4)`, [r.session, scores, r.mems[0], `chave-cc-${run}-7`]);
    let pa;
    if (deterministic) {
      if (v42) await B.query('select private.lock_session_chain($1)', [r.session]);
      else await B.query('select 1 from public.voting_sessions where id=$1 for update', [r.session]);
      pa = A.query(`select public.correct_match_sheet($1,$2::jsonb,$3::jsonb,'gol esquecido')`, [r.match, JSON.stringify(r.parts), events])
        .then(() => A.query('commit'))
        .catch((e) => ((ea = e), A.query('rollback')));
      await new Promise((ok) => setTimeout(ok, 300)); // A já está esperando a trava de B
      await vote().then(() => B.query('commit')).catch((e) => ((eb = e), B.query('rollback')));
      await pa;
    } else {
      pa = A.query(`select public.correct_match_sheet($1,$2::jsonb,$3::jsonb,'gol esquecido')`, [r.match, JSON.stringify(r.parts), events])
        .then(() => A.query('commit'))
        .catch((e) => ((ea = e), A.query('rollback')));
      const pb = vote().then(() => B.query('commit')).catch((e) => ((eb = e), B.query('rollback')));
      await Promise.all([pa, pb]);
    }
  } finally {
    await A.end();
    await B.end();
  }
  // Invariante: se finalizou, nenhuma cédula de outra versão entrou e o placar é o da versão final.
  const inv = (
    await admin.query(
      `select s.status, m.sheet_version, m.team_a_score,
        (select count(*) from private.secret_ballots b where b.session_id=s.id and b.status='submitted' and b.sheet_version<>m.sheet_version) stale,
        (select coalesce(max(numeric_rating_count),0) from public.match_player_results where match_id=m.id) ratings
       from public.voting_sessions s join public.matches m on m.id=s.match_id where s.id=$1`,
      [r.session],
    )
  ).rows[0];
  return { a: outcome(ea), b: outcome(eb), ...inv };
}

// A01 em sequência: 6 votaram, correção sem mudar eleitores, o 7º confere a versão nova e vota.
async function staleSequential(db, run) {
  const { admin } = db;
  await admin.query('select cc.setup($1)', [run]);
  const r = (await admin.query('select * from cc.runs where id=$1', [run])).rows[0];
  const events = JSON.stringify([{ membership_id: r.mems[0], type: 'goal', quantity: 1 }]);
  await admin.query('select cc.as_user(1)');
  await admin.query(`select public.correct_match_sheet($1,$2::jsonb,$3::jsonb,'gol esquecido')`, [r.match, JSON.stringify(r.parts), events]);
  await admin.query('select cc.as_user(7)');
  await admin.query('select public.confirm_match_sheet($1,2)', [r.match]);
  const scores = JSON.stringify(r.mems.filter((m) => m !== r.mems[6]).map((m) => ({ membership_id: m, rating: 7 })));
  const res = (await admin.query('select public.submit_ballot($1,2,$2::jsonb,$3,null,$4) r', [r.session, scores, r.mems[0], `chave-seq-${run}`])).rows[0].r;
  const st = (
    await admin.query(
      `select s.status, (select count(*) from private.secret_ballots b where b.session_id=s.id and b.status='submitted' and b.sheet_version<>2) stale,
        (select coalesce(max(numeric_rating_count),0) from public.match_player_results where match_id=s.match_id) ratings
       from public.voting_sessions s where s.id=$1`,
      [r.session],
    )
  ).rows[0];
  return { allVoted: res.all_voted, ...st };
}

async function suite(label, files, v42) {
  const db = await startDb(label, files);
  const tally = new Map();
  let deadlocks = 0;
  let broken = 0;
  try {
    const seq = await staleSequential(db, 1000);
    console.log(
      `  A01 em sequência (6 votos da versão 1, correção, 7º vota a versão 2): encerrou=${seq.allVoted} | sessão=${seq.status} | cédulas da versão antiga aceitas=${seq.stale} | notas por jogador=${seq.ratings}`,
    );
    if (seq.status === 'finalized' && Number(seq.stale) > 0) broken++;
    const det = await race(db, 0, true, v42);
    console.log(`  determinístico (B segura a 1ª trava do voto, A corrige, B termina): A=${det.a} | B=${det.b} | sessão=${det.status}`);
    if (det.a === 'DEADLOCK' || det.b === 'DEADLOCK') deadlocks++;
    const t0 = Date.now();
    for (let i = 1; i <= ITER; i++) {
      const x = await race(db, i, false, v42);
      const key = `A=${x.a} | B=${x.b} | sessão=${x.status}`;
      tally.set(key, (tally.get(key) ?? 0) + 1);
      if (x.a === 'DEADLOCK' || x.b === 'DEADLOCK') deadlocks++;
      // Finalizada com cédula de versão antiga = voto inválido na apuração.
      if (x.status === 'finalized' && Number(x.stale) > 0) broken++;
    }
    console.log(`  ${ITER} disputas reais simultâneas (${((Date.now() - t0) / 1000).toFixed(1)}s):`);
    for (const [k, n] of tally) console.log(`    ${n}× ${k}`);
    console.log(`  deadlocks: ${deadlocks}; apurações com voto de versão antiga: ${broken}`);
  } finally {
    await db.admin.end();
    await db.server.stop();
    rmSync(db.dir, { recursive: true, force: true });
  }
  return { deadlocks, broken };
}

// ===== V4.3: Financeiro (043) com duas pessoas autorizadas (admin e assistente) ao mesmo tempo =====
const FIN_SETUP = `
create function cc.fin_setup(p_run int) returns jsonb language plpgsql as $$
declare v_p uuid; v_tok text; v_m uuid; v_a uuid; v_c jsonb; v_today date;
begin
 perform cc.as_user(1);
 v_p := public.create_pelada('Caixa '||p_run,'GOL');
 v_tok := public.create_pelada_invite(v_p);
 for i in 2..4 loop perform cc.as_user(i); perform public.join_pelada(v_tok,'MEI'); end loop;
 perform cc.as_user(1);
 v_a := (select id from public.pelada_memberships where pelada_id=v_p and user_id=cc.uid(2));
 perform public.set_assistant(v_p, v_a, true);
 perform public.set_finance_access(v_p, v_a, true);
 v_m := (select id from public.pelada_memberships where pelada_id=v_p and user_id=cc.uid(3));
 v_today := private.pelada_today(v_p);
 perform public.save_monthly_member(v_p, null, v_m, null, 10000, 28, date_trunc('month', v_today)::date);
 v_c := public.create_charge(v_p, 'extra', v_m, null, null, 'Rateio', 10000, v_today, gen_random_uuid());
 return jsonb_build_object('pelada', v_p, 'charge', v_c->>'id', 'today', v_today);
end $$;
`;

async function finSuite(files) {
  const db = await startDb('V4.3 Financeiro (todas)', files);
  let deadlocks = 0;
  const tally = new Map();
  const note = (k) => tally.set(k, (tally.get(k) ?? 0) + 1);
  const run = (c, sql, args) => c.query(sql, args).then(() => 'ok', (e) => outcome(e).replace(/^.*?(FINANCE_[A-Z_]+).*$/, '$1'));
  try {
    await db.admin.query(FIN_SETUP);
    const t0 = Date.now();
    for (let i = 1; i <= ITER; i++) {
      const r = (await db.admin.query('select cc.fin_setup($1) r', [i])).rows[0].r;
      const A = await client(db.cfg);
      const B = await client(db.cfg);
      try {
        await A.query('select cc.as_user(1)');
        await B.query('select cc.as_user(2)');
        // 1) o mesmo pagamento enviado pelos dois (mesmo request_id): um só registro
        const rid = crypto.randomUUID();
        const pay = 'select public.register_payment($1,3000,$2,null,null,$3)';
        const s1 = await Promise.all([run(A, pay, [r.charge, r.today, rid]), run(B, pay, [r.charge, r.today, rid])]);
        note(`mesmo request_id: ${s1.sort().join(' / ')}`);
        // 2) os dois registram 6.000 ao mesmo tempo onde faltam 7.000: só um entra
        const pay2 = 'select public.register_payment($1,6000,$2,null,null,$3,true)';
        const s2 = await Promise.all([run(A, pay2, [r.charge, r.today, crypto.randomUUID()]), run(B, pay2, [r.charge, r.today, crypto.randomUUID()])]);
        note(`dois pagamentos que estouram a dívida: ${s2.sort().join(' / ')}`);
        // 3) os dois geram as mensalidades do mês ao mesmo tempo
        const gen = 'select public.generate_monthly_charges($1)';
        const s3 = await Promise.all([run(A, gen, [r.pelada]), run(B, gen, [r.pelada])]);
        // 4) estorno e novo pagamento ao mesmo tempo
        const p1 = (await db.admin.query('select id from public.finance_payments where charge_id=$1 and reversed_at is null order by created_at limit 1', [r.charge])).rows[0].id;
        const s4 = await Promise.all([
          run(A, 'select public.reverse_payment($1,$2)', [p1, 'estorno concorrente']),
          run(B, 'select public.register_payment($1,1000,$2,null,null,$3,true)', [r.charge, r.today, crypto.randomUUID()]),
        ]);
        note(`estorno x pagamento: ${s4.sort().join(' / ')}`);
        for (const x of [...s1, ...s2, ...s3, ...s4]) if (x === 'DEADLOCK') deadlocks++;
      } finally {
        await A.end();
        await B.end();
      }
    }
    // Invariantes contábeis em todas as cobranças.
    const inv = (
      await db.admin.query(`select
        count(*) filter (where c.amount_paid_cents <> coalesce((select sum(p.amount_cents) from public.finance_payments p
          where p.charge_id=c.id and p.reversed_at is null),0)) mismatch,
        count(*) filter (where c.amount_paid_cents > c.amount_due_cents) over_paid,
        (select count(*) from (select finance_member_id, reference_month from public.finance_charges where kind='monthly' group by 1,2 having count(*)>1) d) dup_monthly,
        (select count(*) from (select pelada_id, request_id from public.finance_payments group by 1,2 having count(*)>1) d) dup_request,
        (select count(*) from public.finance_charges where kind='monthly') monthly
        from public.finance_charges c`)
    ).rows[0];
    console.log(`  ${ITER} rodadas com duas conexões (${((Date.now() - t0) / 1000).toFixed(1)}s):`);
    for (const [k, n] of tally) console.log(`    ${n}× ${k}`);
    console.log(
      `  deadlocks: ${deadlocks}; pago ≠ soma dos pagamentos: ${inv.mismatch}; pago acima do devido: ${inv.over_paid}; ` +
        `mensalidade duplicada: ${inv.dup_monthly} (${inv.monthly} geradas); request_id duplicado: ${inv.dup_request}`,
    );
    return deadlocks === 0 && [inv.mismatch, inv.over_paid, inv.dup_monthly, inv.dup_request].every((x) => Number(x) === 0) && Number(inv.monthly) === ITER;
  } finally {
    await db.admin.end();
    await db.server.stop();
    rmSync(db.dir, { recursive: true, force: true });
  }
}


// ===== V4.5: exportação do Financeiro enquanto outra pessoa registra, estorna, edita e cancela =====
// Leitor (assistente) exporta o mês; escritor (admin) escreve sem parar na mesma pelada, em outra conexão.
//  - V4.4 (páginas de 500 em requisições separadas, conferência só pela quantidade): conta quantas exportações a
//    conferência aceitou com conteúdo inconsistente (linha repetida ou somas diferentes do total da 1ª página) e quantas
//    foram recusadas pela quantidade.
//  - V4.5 (get_finance_export, uma chamada STABLE): toda exportação tem de ser íntegra (sem repetição, ordem estável,
//    linhas = total, somas das linhas = totais do mesmo instantâneo).
//  - Controle negativo: a MESMA função recriada como VOLATILE (cada comando com o seu instantâneo) mostra que o teste
//    percebe quando linhas e totais não vêm do mesmo instantâneo.
const EXP_SETUP = `
create function cc.exp_setup() returns jsonb language plpgsql as $$
declare v_p uuid; v_tok text; v_a uuid; v_m uuid[]; v_today date; v_m0 date; v_days int; v_c jsonb; i int;
begin
 perform cc.as_user(1);
 v_p := public.create_pelada('Exportação concorrente','GOL');
 v_tok := public.create_pelada_invite(v_p);
 for i in 2..4 loop perform cc.as_user(i); perform public.join_pelada(v_tok,'MEI'); end loop;
 perform cc.as_user(1);
 v_a := (select id from public.pelada_memberships where pelada_id=v_p and user_id=cc.uid(2));
 perform public.set_assistant(v_p, v_a, true);
 perform public.set_finance_access(v_p, v_a, true);
 v_m := array(select id from public.pelada_memberships where pelada_id=v_p and role='player');
 v_today := private.pelada_today(v_p); v_m0 := date_trunc('month', v_today)::date; v_days := v_today - v_m0 + 1;
 for i in 1..3000 loop
  v_c := public.create_charge(v_p, 'single', v_m[1 + i % array_length(v_m,1)], null, null, 'Avulso '||i, 1000 + i % 500, v_m0, gen_random_uuid());
  if i <= 2000 then perform public.register_payment((v_c->>'id')::uuid, 1000 + i % 500, v_m0 + (i % v_days), 'pix', null, gen_random_uuid(), true); end if;
 end loop;
 for i in 1..2000 loop
  perform public.save_finance_entry(v_p, null, case when i % 2 = 0 then 'income' else 'expense' end, 'Categoria '||(i % 4),
   'Lançamento '||i, 300 + i % 700, v_m0 + (i % v_days), case when i % 10 = 0 then 'pending' else 'settled' end, null, null, gen_random_uuid());
 end loop;
 return jsonb_build_object('pelada', v_p, 'from', v_m0, 'to', (v_m0 + interval '1 month - 1 day')::date, 'days', v_days);
end $$;
`;

function exportProblems(items, total) {
  const ids = new Set();
  let dups = 0;
  let order = 0;
  const sum = { inc: 0, exp: 0, rev: 0 };
  const key = (r) => [r.date, new Date(r.created_at).getTime() * 1000 + Number(String(r.created_at).match(/\.(\d+)/)?.[1]?.padEnd(6, '0').slice(3) ?? 0), r.id];
  for (let i = 0; i < items.length; i++) {
    const x = items[i];
    if (ids.has(x.id)) dups++;
    ids.add(x.id);
    if (i > 0) {
      const [a, b] = [key(items[i - 1]), key(x)];
      const gt = a[0] > b[0] || (a[0] === b[0] && (a[1] > b[1] || (a[1] === b[1] && a[2] > b[2])));
      if (!gt) order++;
    }
    if (x.status === 'settled' && x.direction === 'income') sum.inc += x.amount_cents;
    if (x.status === 'settled' && x.direction === 'expense') sum.exp += x.amount_cents;
    if (x.status === 'reversed') sum.rev += x.amount_cents;
  }
  const out = [];
  if (dups) out.push('repetida');
  if (order) out.push('ordem');
  if (items.length !== Number(total.count)) out.push('quantidade');
  if (sum.inc !== Number(total.settled_income_cents) || sum.exp !== Number(total.settled_expense_cents)) out.push('somas');
  if (total.reversed_cents !== undefined && sum.rev !== Number(total.reversed_cents)) out.push('estornos');
  return out;
}

async function exportSuite(files) {
  const db = await startDb('V4.5 Exportação (todas)', files);
  try {
    await db.admin.query(EXP_SETUP);
    const t0 = Date.now();
    const r = (await db.admin.query('select cc.exp_setup() r')).rows[0].r;
    // controle negativo: a mesma função, VOLATILE
    const def = (await db.admin.query("select pg_get_functiondef('public.get_finance_export(uuid,date,date,text,text)'::regprocedure) d")).rows[0].d;
    await db.admin.query(def.replace('public.get_finance_export', 'cc.export_volatile').replace(/\bSTABLE\b/, 'VOLATILE'));
    await db.admin.query('select cc.as_user(1)');
    const base = (await db.admin.query("select (public.get_finance_export($1,$2,$3)->'total'->>'count')::int n", [r.pelada, r.from, r.to])).rows[0].n;
    console.log(`  massa: ${base} movimentações no mês (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
    const W = await client(db.cfg);
    const R = await client(db.cfg);
    await W.query('select cc.as_user(1)');
    await R.query('select cc.as_user(2)');
    async function phase(label, ops) {
    let writing = true;
    const writes = { pagamento: 0, estorno: 0, edicao: 0, novo: 0, cancelamento: 0, erro: 0 };
    const someDay = "($2::date + (random()*($3-1))::int)";
    const writer = (async () => {
      let i = 0;
      while (writing) {
        i++;
        try {
          switch (ops[i % ops.length]) {
            case 0: {
              const c = (await W.query("select id, amount_due_cents - amount_paid_cents o from public.finance_charges where pelada_id=$1 and status='pending' order by random() limit 1", [r.pelada])).rows[0];
              if (c) await W.query(`select public.register_payment($1,$4,${someDay},'pix',null,gen_random_uuid(),true)`, [c.id, r.from, r.days, c.o]);
              writes.pagamento++;
              break;
            }
            case 1: {
              const p = (await W.query('select id from public.finance_payments where pelada_id=$1 and reversed_at is null order by random() limit 1', [r.pelada])).rows[0];
              if (p) await W.query("select public.reverse_payment($1,'estorno durante a exportação')", [p.id]);
              writes.estorno++;
              break;
            }
            case 2: {
              const e = (await W.query("select * from public.finance_entries where pelada_id=$1 and status<>'cancelled' order by random() limit 1", [r.pelada])).rows[0];
              if (e)
                await W.query(`select public.save_finance_entry($1,$4,$5,$6,$7,$8,${someDay},$9,null,null,null,$10)`, [
                  r.pelada, r.from, r.days, e.id, e.direction, e.category, e.description, e.amount_cents + 1, e.status, e.version,
                ]);
              writes.edicao++;
              break;
            }
            case 3:
              await W.query(`select public.save_finance_entry($1,null,'expense','Atrasado','Lançado depois',777,${someDay},'settled',null,null,gen_random_uuid())`, [r.pelada, r.from, r.days]);
              writes.novo++;
              break;
            default: {
              const e = (await W.query("select id from public.finance_entries where pelada_id=$1 and status<>'cancelled' order by random() limit 1", [r.pelada])).rows[0];
              if (e) await W.query("select public.cancel_finance_entry($1,'cancelado durante a exportação')", [e.id]);
              writes.cancelamento++;
            }
          }
        } catch {
          writes.erro++;
        }
      }
    })();
    const res = { v44: { aceitas_inconsistentes: 0, recusadas: 0, integras: 0, tipos: {} }, v45: { problemas: 0, integras: 0, ms: [] }, vol: { problemas: 0, integras: 0 } };
    for (let k = 0; k < ITER; k++) {
      // V4.4: páginas de 500 em requisições separadas (o que o app V4.4 fazia)
      let after = null;
      let first = null;
      const rows = [];
      for (;;) {
        const p = (await R.query('select public.get_finance_ledger_page($1,$2,$3,null,null,$4,500,$5) p', [r.pelada, r.from, r.to, after, after === null])).rows[0].p;
        if (!first) first = p.total;
        rows.push(...p.items);
        if (!p.next) break;
        after = p.next;
      }
      if (rows.length !== Number(first.count)) res.v44.recusadas++;
      else {
        const pr = exportProblems(rows, first);
        if (pr.length) {
          res.v44.aceitas_inconsistentes++;
          for (const t of pr) res.v44.tipos[t] = (res.v44.tipos[t] ?? 0) + 1;
        } else res.v44.integras++;
      }
      // V4.5: uma chamada
      const t = Date.now();
      const x = (await R.query('select public.get_finance_export($1,$2,$3) x', [r.pelada, r.from, r.to])).rows[0].x;
      res.v45.ms.push(Date.now() - t);
      if (exportProblems(x.items, x.total).length) res.v45.problemas++;
      else res.v45.integras++;
      // controle negativo
      const v = (await R.query('select cc.export_volatile($1,$2,$3) x', [r.pelada, r.from, r.to])).rows[0].x;
      if (exportProblems(v.items, v.total).length) res.vol.problemas++;
      else res.vol.integras++;
    }
    writing = false;
    await writer;
    const ms = res.v45.ms.sort((a, b) => a - b);
    const q = (f) => ms[Math.min(ms.length - 1, Math.floor(f * ms.length))];
    console.log(`  [${label}]`);
    console.log(`  escritas concorrentes: ${JSON.stringify(writes)}`);
    console.log(`  V4.4 (páginas): ${ITER} exportações -> ${res.v44.integras} íntegras, ${res.v44.aceitas_inconsistentes} ACEITAS com conteúdo inconsistente ${JSON.stringify(res.v44.tipos)}, ${res.v44.recusadas} recusadas pela quantidade`);
    console.log(`  V4.5 (um instantâneo): ${ITER} exportações -> ${res.v45.integras} íntegras, ${res.v45.problemas} com problema; p50 ${q(0.5)} ms, p95 ${q(0.95)} ms`);
    console.log(`  controle (mesma função VOLATILE): ${res.vol.integras} íntegras, ${res.vol.problemas} com linhas e totais de instantes diferentes`);
    return { ok: res.v45.problemas === 0 && res.v45.integras === ITER, res, writes };
    }
    // 1) todas as escritas (pagamento, estorno, edição, lançamento novo com data passada, cancelamento)
    const all = await phase('todas as escritas', [0, 1, 2, 3, 4]);
    // 2) só escritas que não mudam a quantidade (estorno e edição de data/valor): a conferência da V4.4 não percebe
    const neutral = await phase('só estornos e edições (a quantidade não muda)', [1, 2]);
    await W.end();
    await R.end();
    return { ok: all.ok && neutral.ok, all, neutral };
  } finally {
    await db.admin.end();
    await db.server.stop();
    rmSync(db.dir, { recursive: true, force: true });
  }
}

const ONLY_EXPORT = process.env.ONLY_EXPORT === '1';
const old = ONLY_EXPORT ? null : await suite('V4.1 (até 035)', migrations.filter((f) => f < '036'), false);
// V5: a 052 desliga a cédula antiga para partidas novas; a disputa correção x último voto roda até a 051.
const cur = ONLY_EXPORT ? { deadlocks: 0, broken: 0 } : await suite('V4.6 (até 051)', migrations.filter((f) => f < '052'), true);
const finOk = ONLY_EXPORT ? true : await finSuite(migrations);
const exp = await exportSuite(migrations);
const ok = cur.deadlocks === 0 && cur.broken === 0 && finOk && exp.ok;
console.log(ok ? 'PASS: sem deadlock, sem voto de versão antiga, Financeiro íntegro e exportação íntegra sob concorrência' : 'FAIL: deadlock, voto antigo, Financeiro ou exportação inconsistente');
if (old) console.log(`(V4.1 no mesmo roteiro: ${old.deadlocks} deadlock(s), ${old.broken} apuração(ões) com voto de versão antiga)`);
process.exit(ok ? 0 : 1);
