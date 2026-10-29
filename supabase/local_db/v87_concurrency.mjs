// V8.7: concorrência da apuração dos prêmios de temporada (068) com um PostgreSQL REAL (embedded-postgres) e conexões
// simultâneas. Nada aqui conecta ao Supabase. Uso: cd supabase/local_db; npm install; node v87_concurrency.mjs [rodadas]
// Disputas: (1) várias apurações ao mesmo tempo da mesma temporada; (2) correção (anulação + close_month) × apuração;
// (3) duas concessões simultâneas da exceção da Luva. Invariantes: nenhum deadlock/erro inesperado, uma versão corrente por
// categoria, nenhum prêmio ativo duplicado, avisos deduplicados e estado final igual ao de um recálculo limpo.
import EmbeddedPostgres from 'embedded-postgres';
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';

const root = join(import.meta.dirname, '..');
const migrations = readdirSync(join(root, 'migrations')).filter((f) => f.endsWith('.sql')).sort();
const ITER = Number(process.argv[2] ?? 10);

const SETUP = `
create schema cc;
create function cc.uid(n int) returns uuid language sql as $$ select ('98700000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid $$;
create function cc.as_user(n int) returns void language sql as $$ select set_config('request.jwt.claim.sub', cc.uid(n)::text, false) $$;
create table cc.runs(id int primary key, pelada uuid, season uuid, match1 uuid);
insert into auth.users(id,aud,role,email) select cc.uid(n),'authenticated','authenticated','cc87'||n||'@example.invalid' from generate_series(1,8) n;
do $$ begin for i in 1..8 loop perform cc.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop; end $$;
update private.v87_activation set min_season_end = '2020-01-01';
create function cc.setup(p_run int) returns void language plpgsql as $$
declare v_p uuid; v_tok text; v_s uuid; v_m uuid; v_x uuid; i int; v_part uuid; v_first uuid;
begin
 perform cc.as_user(1);
 v_p := public.create_pelada('Concorrência V87 '||p_run,'ATA');
 v_tok := public.create_pelada_invite(v_p);
 for i in 2..8 loop perform cc.as_user(i); perform public.join_pelada(v_tok, case when i in (2,3) then 'GOL' else 'MEI' end); end loop;
 for i in 1..6 loop
  insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
  values(v_p, private.season_for_date(v_p, (date '2025-03-01' + i*7)), (date '2025-03-01' + i*7)::timestamptz + interval '20 hours', 'finalized', 1, 0, now())
  returning id into v_m;
  if i = 1 then v_first := v_m; end if;
  -- goleiros 2 (A) e 3 (B); 4 e 5 fazem gols e assistências alternadas
  insert into public.match_participants(pelada_id,match_id,membership_id,team,primary_position)
  select v_p, v_m, id, case user_id when cc.uid(2) then 'A' when cc.uid(3) then 'B' when cc.uid(4) then 'A' else 'B' end,
   case when user_id in (cc.uid(2), cc.uid(3)) then 'goalkeeper' else 'midfielder' end
  from public.pelada_memberships where pelada_id=v_p and user_id in (cc.uid(2),cc.uid(3),cc.uid(4),cc.uid(5));
  insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
  select v_p, v_m, x.id, x.team, case when pm.user_id = cc.uid(4) then 'goal' else 'assist' end, 1
  from public.match_participants x join public.pelada_memberships pm on pm.id=x.membership_id
  where x.match_id=v_m and pm.user_id in (cc.uid(4), cc.uid(5)) and (i % 2 = 0 or pm.user_id = cc.uid(4));
  insert into public.match_keeper_saves(pelada_id,match_id,participant_id,hard_saves)
  select v_p, v_m, x.id, case when pm.user_id = cc.uid(2) then 4 else 3 end from public.match_participants x
  join public.pelada_memberships pm on pm.id=x.membership_id where x.match_id=v_m and x.primary_position='goalkeeper';
  perform private.compute_match_results(v_m, null);
 end loop;
 select id into v_s from public.seasons where pelada_id=v_p and starts_on <= date '2025-06-01' and ends_on >= date '2025-06-01';
 insert into cc.runs values(p_run, v_p, v_s, v_first);
end $$;
`;

async function startDb() {
  const dir = mkdtempSync(join(tmpdir(), 'm91-pg87-'));
  const port = 55900 + Math.floor(Math.random() * 400);
  const server = new EmbeddedPostgres({ databaseDir: dir, user: 'postgres', password: 'postgres', port, persistent: false, onLog: () => {} });
  await server.initialise();
  await server.start();
  await server.createDatabase('m91');
  const cfg = { host: 'localhost', port, user: 'postgres', password: 'postgres', database: 'm91' };
  const admin = new pg.Client(cfg);
  await admin.connect();
  await admin.query(readFileSync(join(import.meta.dirname, 'shim.sql'), 'utf8'));
  for (const f of migrations) await admin.query(readFileSync(join(root, 'migrations', f), 'utf8'));
  await admin.query(`update private.app_config set value='true'::jsonb where key='premium_beta_open'`);
  await admin.query(SETUP);
  console.log(`Postgres ${(await admin.query('show server_version')).rows[0].server_version}, ${migrations.length} migrações`);
  return { server, dir, cfg, admin };
}
const client = async (cfg) => {
  const c = new pg.Client(cfg);
  await c.connect();
  return c;
};
const outcome = (e) => (e ? (e.code === '40P01' ? 'DEADLOCK' : e.message.split('\n')[0]) : 'ok');

// Invariantes de uma temporada.
async function invariants(admin, run) {
  const q = async (sql) => (await admin.query(sql, [run.season])).rows[0];
  const cur = await q(`select count(*)::int n, count(distinct category)::int c from private.season_award_results where season_id=$1 and is_current`);
  const dup = await q(`select count(*)::int n from (select membership_id, award_type from public.awards where season_id=$1 and status='active' and award_type like 'season_%' group by 1,2 having count(*)>1) x`);
  const coll = await q(`select count(*)::int n, count(distinct user_id)::int u from public.notification_events where event_type in ('season_awards_published','season_awards_corrected') and dedupe_key like 'season_awards:'||$1||':%'`);
  const mism = await q(`select count(*)::int n from private.season_award_results r where r.season_id=$1 and r.is_current and r.status='published'
    and (select coalesce(array_agg(a.membership_id order by a.membership_id),'{}') from public.awards a where a.season_id=r.season_id and a.status='active'
         and a.award_type = private.v87_award_type(r.category)) is distinct from (select array_agg(w order by w) from unnest(r.winners) w)`);
  return { current: cur.n, categories: cur.c, duplicates: dup.n, collective: coll.n, collectiveUsers: coll.u, awardsMismatch: mism.n };
}

const db = await startDb();
let bad = 0;
const fail = (m) => {
  bad++;
  console.log(`  FALHA: ${m}`);
};
try {
  // (1) várias apurações simultâneas da mesma temporada
  console.log(`(1) ${ITER} rodadas de 4 apurações simultâneas`);
  for (let r = 1; r <= ITER; r++) {
    await db.admin.query('select cc.setup($1)', [r]);
    const run = (await db.admin.query('select * from cc.runs where id=$1', [r])).rows[0];
    const cs = await Promise.all([1, 2, 3, 4].map(() => client(db.cfg)));
    const res = await Promise.all(cs.map((c) => c.query('select private.season_awards_sync($1)', [run.season]).then(() => null, (e) => e)));
    await Promise.all(cs.map((c) => c.end()));
    const errs = res.map(outcome).filter((x) => x !== 'ok');
    if (errs.length) fail(`rodada ${r}: ${errs.join(' | ')}`);
    const inv = await invariants(db.admin, run);
    if (inv.current !== 3 || inv.categories !== 3 || inv.duplicates || inv.awardsMismatch) fail(`rodada ${r}: ${JSON.stringify(inv)}`);
    if (inv.collective !== 8 || inv.collectiveUsers !== 8) fail(`rodada ${r}: aviso coletivo duplicado ou ausente ${JSON.stringify(inv)}`);
    const ver = (await db.admin.query(`select max(version)::int v from private.season_award_results where season_id=$1`, [run.season])).rows[0].v;
    if (ver !== 1) fail(`rodada ${r}: versão ${ver} (esperado 1)`);
  }
  // (2) correção (anulação + close_month) × apuração
  console.log(`(2) ${ITER} rodadas de correção × apuração`);
  for (let r = 1; r <= ITER; r++) {
    const id = 1000 + r;
    await db.admin.query('select cc.setup($1)', [id]);
    const run = (await db.admin.query('select * from cc.runs where id=$1', [id])).rows[0];
    await db.admin.query('select private.season_awards_sync($1)', [run.season]);
    const A = await client(db.cfg);
    const B = await client(db.cfg);
    let ea = null;
    let eb = null;
    try {
      await A.query('begin');
      await A.query(`update public.matches set status='annulled' where id=$1`, [run.match1]);
      const pa = A.query(`select private.close_month($1, date '2025-03-01')`, [run.pelada]).then(() => A.query('commit')).catch((e) => ((ea = e), A.query('rollback')));
      const pb = B.query('select private.season_awards_sync($1)', [run.season]).catch((e) => (eb = e));
      await Promise.all([pa, pb]);
    } finally {
      await A.end();
      await B.end();
    }
    if (ea || eb) fail(`rodada ${r}: A=${outcome(ea)} B=${outcome(eb)}`);
    // O estado final tem de ser o de um recálculo limpo: uma nova apuração não muda nada.
    const before = JSON.stringify((await db.admin.query(`select category, version, status, winners from private.season_award_results where season_id=$1 and is_current order by category`, [run.season])).rows);
    const again = (await db.admin.query('select private.season_awards_sync($1) r', [run.season])).rows[0].r;
    const after = JSON.stringify((await db.admin.query(`select category, version, status, winners from private.season_award_results where season_id=$1 and is_current order by category`, [run.season])).rows);
    if (before !== after || ['top_scorer', 'maestro', 'golden_glove'].some((c) => again[c] !== 'unchanged')) fail(`rodada ${r}: estado final diferente de um recálculo limpo ${JSON.stringify(again)}`);
    const inv = await invariants(db.admin, run);
    if (inv.current !== 3 || inv.duplicates || inv.awardsMismatch) fail(`rodada ${r}: ${JSON.stringify(inv)}`);
  }
  // (3) duas concessões simultâneas da exceção (temporada sem elegível normal: exigir 6 atuações no gol)
  console.log(`(3) ${ITER} rodadas de concessão simultânea da exceção`);
  for (let r = 1; r <= ITER; r++) {
    const id = 2000 + r;
    await db.admin.query('select cc.setup($1)', [id]);
    const run = (await db.admin.query('select * from cc.runs where id=$1', [id])).rows[0];
    // 6 partidas, GOL 2 e 3 com 6 atuações cada: normal elegível. Para forçar "aguardando", anula 2 partidas (T=4, GOL com 4 < 5).
    await db.admin.query(`update public.matches set status='annulled' where id in (select id from public.matches where season_id=$1 order by played_at limit 2)`, [run.season]);
    await db.admin.query(`select private.close_month($1, date '2025-03-01'), private.close_month($1, date '2025-04-01')`, [run.pelada]);
    await db.admin.query('select private.season_awards_sync($1)', [run.season]);
    const st = (await db.admin.query(`select status from private.season_award_results where season_id=$1 and category='golden_glove' and is_current`, [run.season])).rows[0]?.status;
    if (st !== 'awaiting_exception') {
      fail(`rodada ${r}: Luva em "${st}" (esperado awaiting_exception)`);
      continue;
    }
    const cs = await Promise.all([1, 2].map(() => client(db.cfg)));
    for (const c of cs) await c.query('select cc.as_user(1)');
    const res = await Promise.all(
      cs.map((c, i) => c.query(`select public.grant_golden_glove_exception($1, 50, 3, $2)`, [run.season, `Concessão simultânea número ${i} da exceção`]).then(() => null, (e) => e)),
    );
    await Promise.all(cs.map((c) => c.end()));
    const errs = res.map(outcome).filter((x) => x !== 'ok');
    if (errs.length) fail(`rodada ${r}: ${errs.join(' | ')}`);
    const act = (await db.admin.query(`select count(*)::int n from private.golden_glove_exceptions where season_id=$1 and status='active'`, [run.season])).rows[0].n;
    if (act !== 1) fail(`rodada ${r}: ${act} exceções ativas (esperado 1)`);
    const inv = await invariants(db.admin, run);
    if (inv.current !== 3 || inv.duplicates || inv.awardsMismatch) fail(`rodada ${r}: ${JSON.stringify(inv)}`);
  }
} finally {
  await db.admin.end();
  await db.server.stop();
  rmSync(db.dir, { recursive: true, force: true });
}
console.log(bad ? `${bad} falha(s)` : 'concorrência V8.7 ok: sem deadlock, sem duplicidade, estado final consistente');
process.exit(bad ? 1 : 0);
