// Testes de concorrência com um PostgreSQL REAL (embedded-postgres, binário oficial do Postgres 17)
// e duas conexões simultâneas (V4.2, seção 8.1). Nada aqui conecta ao Supabase.
// Uso: cd supabase/local_db; npm install; node concurrency.mjs
// Roda duas vezes: com as migrações até a 035 (V4.1) e com todas (V4.2), e compara.
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

const old = await suite('V4.1 (até 035)', migrations.filter((f) => f < '036'), false);
const cur = await suite('V4.2 (todas)', migrations, true);
const ok = cur.deadlocks === 0 && cur.broken === 0;
console.log(ok ? 'PASS: V4.2 sem deadlock e sem voto de versão antiga' : 'FAIL: V4.2 ainda tem deadlock ou voto antigo');
console.log(`(V4.1 no mesmo roteiro: ${old.deadlocks} deadlock(s), ${old.broken} apuração(ões) com voto de versão antiga)`);
process.exit(ok ? 0 : 1);
