// V5: concorrência da votação v2 num PostgreSQL REAL (embedded-postgres) com conexões simultâneas.
// Uso: cd supabase/local_db; node rating_concurrency.mjs [iterações=10]
// Cenários: mesmo voto enviado duas vezes ao mesmo tempo; duas notas diferentes ao mesmo tempo; voto x prorrogação;
// voto disparado em cima do prazo; publicação dupla simultânea; reprocessamento do pós-partida.
import EmbeddedPostgres from 'embedded-postgres';
import { chownSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';
import { execFileSync } from 'node:child_process';

const root = join(import.meta.dirname, '..');
const ITER = Number(process.argv[2] ?? 10);
const SETUP = `
create schema rc;
grant usage on schema rc to authenticated;
create function rc.uid(n int) returns uuid language sql as $$ select ('95500000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid $$;
create function rc.as_user(n int) returns void language sql as $$ select set_config('request.jwt.claim.sub', rc.uid(n)::text, false) $$;
grant execute on all functions in schema rc to authenticated;
insert into auth.users(id,aud,role,email) select rc.uid(n),'authenticated','authenticated','rc'||n||'@example.invalid' from generate_series(1,8) n;
do $$ begin for i in 1..8 loop perform rc.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop; end $$;
create table rc.runs(id int primary key, pelada uuid, match uuid, session uuid, mems uuid[]);
create function rc.setup(p_run int) returns void language plpgsql as $$
declare v_p uuid; v_tok text; v_m uuid[]; v_parts jsonb; v_x uuid;
begin
 perform rc.as_user(1);
 v_p := public.create_pelada('Votos '||p_run,'MEI');
 v_tok := public.create_pelada_invite(v_p);
 for i in 2..8 loop perform rc.as_user(i); perform public.join_pelada(v_tok,'MEI'); end loop;
 v_m := array(select id from public.pelada_memberships where pelada_id=v_p order by user_id);
 select jsonb_agg(jsonb_build_object('membership_id',v_m[i],'team',case when i%2=1 then 'A' else 'B' end)) into v_parts from generate_series(1,8) i;
 perform rc.as_user(1);
 v_x := public.create_match(v_p, now());
 perform public.save_match_sheet(v_x, v_parts, '[]');
 perform public.publish_match(v_x);
 insert into rc.runs values(p_run, v_p, v_x, (public.open_rating_vote(v_x)->>'session_id')::uuid, v_m);
end $$;
`;

const dir = mkdtempSync(join(tmpdir(), 'm91-rv-'));
// Como root, o embedded-postgres roda o initdb como o usuário postgres: a pasta precisa ser dele.
if (process.getuid?.() === 0) {
  chownSync(dir, Number(execFileSync('id', ['-u', 'postgres'])), Number(execFileSync('id', ['-g', 'postgres'])));
}
const port = 56000 + Math.floor(Math.random() * 500);
const server = new EmbeddedPostgres({ databaseDir: dir, user: 'postgres', password: 'postgres', port, persistent: false, onLog: () => {} });
await server.initialise();
await server.start();
await server.createDatabase('m91');
const cfg = { host: 'localhost', port, user: 'postgres', password: 'postgres', database: 'm91' };
const admin = new pg.Client(cfg);
await admin.connect();
await admin.query(readFileSync(join(import.meta.dirname, 'shim.sql'), 'utf8'));
for (const f of readdirSync(join(root, 'migrations')).filter((f) => f.endsWith('.sql')).sort())
  await admin.query(readFileSync(join(root, 'migrations', f), 'utf8'));
await admin.query(SETUP);
console.log(`Postgres ${(await admin.query('show server_version')).rows[0].server_version}`);

const conn = async (user) => {
  const c = new pg.Client(cfg);
  await c.connect();
  await c.query(`set role authenticated; select rc.as_user(${user})`);
  return c;
};
const call = (c, sql, args) => c.query(sql, args).then(() => 'ok', (e) => (e.code === '40P01' ? 'DEADLOCK' : e.message.split('\n')[0]));
let problems = 0;
const fail = (msg) => { problems++; console.log('  PROBLEMA:', msg); };

for (let it = 1; it <= ITER; it++) {
  await admin.query('select rc.setup($1)', [it]);
  const run = (await admin.query('select * from rc.runs where id=$1', [it])).rows[0];
  const target = run.mems[3];
  // 1/2. Mesmo eleitor, duas conexões ao mesmo tempo.
  const [a, b] = [await conn(2), await conn(2)];
  const r1 = await Promise.all([call(a, 'select public.cast_rating_vote($1,$2,8)', [run.session, target]), call(b, 'select public.cast_rating_vote($1,$2,8)', [run.session, target])]);
  const r2 = await Promise.all([call(a, 'select public.cast_rating_vote($1,$2,6)', [run.session, target]), call(b, 'select public.cast_rating_vote($1,$2,9)', [run.session, target])]);
  const rows = (await admin.query('select rating from private.rating_votes where session_id=$1 and voter_membership_id=$2 and target_membership_id=$3', [run.session, run.mems[1], target])).rows;
  if (r1.some((x) => x !== 'ok') || r2.some((x) => x !== 'ok')) fail(`envio simultâneo: ${r1} / ${r2}`);
  if (rows.length !== 1 || ![6, 9].includes(Number(rows[0].rating))) fail(`voto duplicado ou perdido: ${JSON.stringify(rows)}`);
  // 3. Voto x prorrogação ao mesmo tempo.
  const staff = await conn(1);
  const r3 = await Promise.all([call(a, 'select public.cast_rating_vote($1,$2,7)', [run.session, run.mems[4]]), call(staff, 'select public.extend_rating_vote($1,30)', [run.session])]);
  if (r3.some((x) => x !== 'ok')) fail(`voto x prorrogação: ${r3}`);
  // 4. Voto em cima do prazo: o prazo vence durante a rajada; nenhum voto aceito pode ter sido gravado depois dele.
  await admin.query("update public.rating_vote_sessions set closes_at=clock_timestamp()+interval '150 milliseconds' where id=$1", [run.session]);
  const burst = [];
  for (let k = 0; k < 20; k++) {
    const voter = 3 + (k % 5);
    const c = await conn(voter);
    burst.push(call(c, "select public.cast_rating_vote($1,$2,5) , clock_timestamp() t", [run.session, run.mems[voter === 8 ? 0 : voter]]).finally(() => c.end()));
    await new Promise((r) => setTimeout(r, 15));
  }
  const rb = await Promise.all(burst);
  const late = (await admin.query('select count(*)::int n from private.rating_votes v join public.rating_vote_sessions s on s.id=v.session_id where s.id=$1 and v.updated_at > s.closes_at', [run.session])).rows[0].n;
  if (late) fail(`${late} voto(s) gravado(s) depois do prazo`);
  if (!rb.some((x) => x.includes('VOTING_CLOSED'))) console.log('  (aviso) a rajada terminou antes do prazo nesta iteração');
  // 5. Publicação dupla simultânea.
  await admin.query("update public.rating_vote_sessions set closes_at=clock_timestamp()-interval '1 second' where id=$1", [run.session]);
  const staff2 = await conn(1);
  const r5 = await Promise.all([call(staff, 'select public.publish_rating_vote($1)', [run.session]), call(staff2, 'select public.publish_rating_vote($1)', [run.session])]);
  if (r5.some((x) => x !== 'ok')) fail(`publicação dupla: ${r5}`);
  const res = (await admin.query('select count(*)::int n from private.rating_vote_results where session_id=$1', [run.session])).rows[0].n;
  const orig = (await admin.query("select count(*)::int n from public.player_rating_history h where h.match_id=$1 and h.event='votes_published' and h.kind='original' group by h.membership_id having count(*)>1", [run.match])).rows.length;
  if (res !== 8 || orig) fail(`resultados ${res}, históricos originais duplicados ${orig}`);
  // 6. Reprocessar o pós-partida não muda o OVR nem duplica histórico.
  const before = (await admin.query('select membership_id, ovr from public.player_ratings where pelada_id=$1 order by 1', [run.pelada])).rows;
  const hist = (await admin.query('select count(*)::int n from public.player_rating_history where pelada_id=$1', [run.pelada])).rows[0].n;
  await admin.query('select private.after_match_finalized($1)', [run.match]);
  await admin.query('select private.after_match_finalized($1)', [run.match]);
  const after = (await admin.query('select membership_id, ovr from public.player_ratings where pelada_id=$1 order by 1', [run.pelada])).rows;
  const hist2 = (await admin.query('select count(*)::int n from public.player_rating_history where pelada_id=$1', [run.pelada])).rows[0].n;
  if (JSON.stringify(before) !== JSON.stringify(after) || hist !== hist2) fail('reprocessamento mudou OVR ou duplicou histórico');
  for (const c of [a, b, staff, staff2]) await c.end();
  console.log(`iteração ${it}: envio duplo ${r1.join('/')}, notas simultâneas ${r2.join('/')}, voto x prorrogação ${r3.join('/')}, rajada no prazo ${rb.filter((x) => x === 'ok').length} aceitos / ${rb.filter((x) => x.includes('VOTING_CLOSED')).length} recusados, publicação dupla ${r5.join('/')}`);
}
await admin.end();
await server.stop();
try { rmSync(dir, { recursive: true, force: true }); } catch { /* Windows às vezes segura a pasta do Postgres por alguns segundos */ }
console.log(problems ? `${problems} problema(s)` : `sem problemas em ${ITER} iterações`);
process.exit(problems ? 1 : 0);
