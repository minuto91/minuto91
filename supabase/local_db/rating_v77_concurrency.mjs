// V7.7: concorrência do motor num PostgreSQL REAL (embedded-postgres) com conexões simultâneas.
// Uso: cd supabase/local_db; node rating_v77_concurrency.mjs [iterações=5]
// Cenários por iteração (duas peladas, 8 jogadores cada, 6 partidas oficiais):
//  1. duas publicações de notas de partidas diferentes da MESMA pelada ao mesmo tempo;
//  2. defesas difíceis x disciplina pendente x resenha x publicação, na mesma pelada, ao mesmo tempo;
//  3. reprocessamento simultâneo de duas peladas diferentes (não podem se bloquear nem se misturar);
//  4. publicação dupla da mesma sessão (idempotente: sem histórico 'original' duplicado);
//  5. anulação x reprocessamento manual ao mesmo tempo.
// Depois de cada rajada: sem deadlock, sem erro inesperado, e o estado final é o mesmo de um reprocessamento serial
// (reprocessar de novo não muda nada: todos os jogadores pulados pela impressão digital da entrada).
import EmbeddedPostgres from 'embedded-postgres';
import { execFileSync } from 'node:child_process';
import { chownSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';

const root = join(import.meta.dirname, '..');
const ITER = Number(process.argv[2] ?? 5);
const SETUP = `
create schema vc;
grant usage on schema vc to authenticated;
create function vc.uid(n int) returns uuid language sql as $$ select ('97700000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid $$;
create function vc.as_user(n int) returns void language sql as $$ select set_config('request.jwt.claim.sub', vc.uid(n)::text, false) $$;
grant execute on all functions in schema vc to authenticated;
insert into auth.users(id,aud,role,email) select vc.uid(n),'authenticated','authenticated','vc'||n||'@example.invalid' from generate_series(1,16) n;
do $$ begin for i in 1..16 loop perform vc.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop; end $$;
create table vc.runs(id int, k int, pelada uuid, matches uuid[], sessions uuid[], mems uuid[], primary key(id,k));
-- Pelada com 8 jogadores (usuários base+1..base+8), 6 partidas oficiais com notas abertas; publica as 4 primeiras.
create function vc.setup(p_run int, p_k int) returns void language plpgsql as $$
declare v_p uuid; v_tok text; v_m uuid[]; v_parts jsonb; v_x uuid; v_ms uuid[] := '{}'; v_ss uuid[] := '{}'; v_s uuid; b int := p_k*8;
begin
 perform vc.as_user(b+1);
 v_p := public.create_pelada('Conc '||p_run||'-'||p_k,'GOL');
 v_tok := public.create_pelada_invite(v_p);
 for i in 2..8 loop perform vc.as_user(b+i); perform public.join_pelada(v_tok, case when i=5 then 'GOL' when i%2=0 then 'ATA' else 'ZAG' end); end loop;
 v_m := array(select id from public.pelada_memberships where pelada_id=v_p order by user_id);
 select jsonb_agg(jsonb_build_object('membership_id',v_m[i],'team',case when i<=4 then 'A' else 'B' end)) into v_parts from generate_series(1,8) i;
 perform vc.as_user(b+1);
 perform public.set_cards_tracking(v_p, true);
 for j in 1..6 loop
  perform vc.as_user(b+1);
  v_x := public.create_match(v_p, now() - make_interval(days => 10 - j));
  perform public.save_match_sheet(v_x, v_parts, jsonb_build_array(jsonb_build_object('membership_id',v_m[2],'type','goal','quantity',1+j%2),
   jsonb_build_object('membership_id',v_m[6],'type','goal','quantity',1+j%3), jsonb_build_object('membership_id',v_m[3],'type','yellow_card','quantity',1)) );
  perform public.publish_match(v_x);
  v_s := (public.open_rating_vote(v_x)->>'session_id')::uuid;
  for i in 1..8 loop
   perform vc.as_user(b+i);
   perform public.cast_rating_vote(v_s, v_m[case when i=8 then 1 else i+1 end], 7 + (i+j)%4);
   perform public.cast_rating_vote(v_s, v_m[case when i<=4 then i+4 else i-4 end], 6 + (i*j)%5);
   perform public.set_rating_vote_resenha(v_s, array(select v_m[t] from generate_series(1,8) t where t<>i and (t+j)%3<>0));
  end loop;
  v_ms := v_ms || v_x; v_ss := v_ss || v_s;
 end loop;
 update public.rating_vote_sessions set closes_at=clock_timestamp()-interval '1 second' where id = any(v_ss);
 perform vc.as_user(b+1);
 for j in 1..4 loop perform public.publish_rating_vote(v_ss[j]); end loop;
 insert into vc.runs values(p_run, p_k, v_p, v_ms, v_ss, v_m);
end $$;
`;

const dir = mkdtempSync(join(tmpdir(), 'm91-v77c-'));
// Como root, o embedded-postgres roda o initdb como o usuário postgres: a pasta precisa ser dele.
if (process.getuid?.() === 0) chownSync(dir, Number(execFileSync('id', ['-u', 'postgres'])), Number(execFileSync('id', ['-g', 'postgres'])));
const port = 57000 + Math.floor(Math.random() * 500);
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
console.log(`Postgres ${(await admin.query('show server_version')).rows[0].server_version}; motor ativo formula_version ${(await admin.query('select (private.rating_params_active()).formula_version fv')).rows[0].fv}`);

const conn = async (user) => {
  const c = new pg.Client(cfg);
  await c.connect();
  await c.query(`set role authenticated; select vc.as_user(${user})`);
  return c;
};
const call = (c, sql, args) => c.query(sql, args).then(() => 'ok', (e) => (e.code === '40P01' ? 'DEADLOCK' : e.message.split('\n')[0]));
let problems = 0;
const fail = (msg) => { problems++; console.log('  PROBLEMA:', msg); };
const snapshot = async (pelada) => (await admin.query(`select membership_id, def, sec, apr, res, dis, ovr, ovr_display, matches_played from public.player_ratings
  where pelada_id=$1 order by 1`, [pelada])).rows;
const serialCheck = async (run, what) => {
  const before = await snapshot(run.pelada);
  const hist = (await admin.query('select count(*)::int n from public.player_rating_history where pelada_id=$1', [run.pelada])).rows[0].n;
  await admin.query(`select private.recompute_cards((select season_id from public.matches where id=$1), null)`, [run.matches[0]]);
  const r = (await admin.query('select members, changed, skipped from private.rating_runs where pelada_id=$1 order by id desc limit 1', [run.pelada])).rows[0];
  // Força o recálculo completo (sem a impressão digital) e compara com o estado deixado pela rajada.
  await admin.query('update public.player_ratings set input_hash=null where pelada_id=$1', [run.pelada]);
  await admin.query(`select private.recompute_cards((select season_id from public.matches where id=$1), null)`, [run.matches[0]]);
  const after = await snapshot(run.pelada);
  const hist2 = (await admin.query('select count(*)::int n from public.player_rating_history where pelada_id=$1', [run.pelada])).rows[0].n;
  if (r.skipped !== r.members) fail(`${what}: estado deixado pela rajada diferente do serial (${r.changed} jogadores recalculados)`);
  if (JSON.stringify(before) !== JSON.stringify(after)) fail(`${what}: recálculo serial mudou o OVR`);
  if (hist !== hist2) fail(`${what}: recálculo serial gravou histórico novo`);
  const dup = (await admin.query(`select count(*)::int n from (select membership_id, match_id, event from public.player_rating_history
    where pelada_id=$1 and kind='original' and match_id is not null group by 1,2,3 having count(*)>1) t`, [run.pelada])).rows[0].n;
  if (dup) fail(`${what}: ${dup} históricos 'original' duplicados`);
};

for (let it = 1; it <= ITER; it++) {
  await admin.query('select vc.setup($1,0), vc.setup($1,1)', [it]);
  const [r0, r1] = (await admin.query('select * from vc.runs where id=$1 order by k', [it])).rows;
  const t0 = Date.now();
  // 1. Duas publicações de partidas diferentes da mesma pelada ao mesmo tempo (admin e um assistente).
  const s1 = await conn(1); const s2 = await conn(1);
  const a1 = await Promise.all([call(s1, 'select public.publish_rating_vote($1)', [r0.sessions[4]]), call(s2, 'select public.publish_rating_vote($1)', [r0.sessions[5]])]);
  if (a1.some((x) => x !== 'ok')) fail(`publicações simultâneas: ${a1}`);
  await serialCheck(r0, 'publicações simultâneas');
  // 2. Defesas difíceis x disciplina pendente x publicação repetida, mesma pelada.
  const gk = (await admin.query('select id from public.match_participants where match_id=$1 and membership_id=$2', [r0.matches[2], r0.mems[0]])).rows[0].id;
  const s3 = await conn(1);
  const a2 = await Promise.all([
    call(s1, 'select public.set_match_hard_saves($1,$2::jsonb)', [r0.matches[2], JSON.stringify([{ participant_id: gk, hard_saves: 3 + it }])]),
    call(s2, "select public.set_match_discipline_status($1,'pending')", [r0.matches[3]]),
    call(s3, 'select public.publish_rating_vote($1)', [r0.sessions[1]]),
  ]);
  if (a2.some((x) => x !== 'ok')) fail(`defesas x disciplina x publicação: ${a2}`);
  await serialCheck(r0, 'defesas x disciplina x publicação');
  // 3. Duas peladas ao mesmo tempo: nenhuma espera pela outra e os números não se misturam.
  const other = await snapshot(r1.pelada);
  const s4 = await conn(9); const s5 = await conn(9);
  const a3 = await Promise.all([call(s4, 'select public.publish_rating_vote($1)', [r1.sessions[4]]), call(s1, "select public.set_match_discipline_status($1,'confirmed')", [r0.matches[3]]), call(s5, 'select public.publish_rating_vote($1)', [r1.sessions[5]])]);
  if (a3.some((x) => x !== 'ok')) fail(`duas peladas: ${a3}`);
  if (JSON.stringify(other) === JSON.stringify(await snapshot(r1.pelada))) fail('pelada B não foi atualizada');
  await serialCheck(r0, 'pelada A após rajada com B');
  await serialCheck(r1, 'pelada B');
  // 4. Publicação dupla da mesma sessão.
  await admin.query("update public.rating_vote_sessions set status='awaiting_publication' where id=$1 and status<>'published'", [r1.sessions[3]]);
  const a4 = await Promise.all([call(s4, 'select public.publish_rating_vote($1)', [r1.sessions[3]]), call(s5, 'select public.publish_rating_vote($1)', [r1.sessions[3]])]);
  if (a4.some((x) => x !== 'ok')) fail(`publicação dupla: ${a4}`);
  await serialCheck(r1, 'publicação dupla');
  // 5. Anulação x reprocessamento manual (agendador/admin) ao mesmo tempo.
  const a5 = await Promise.all([
    call(s1, "select public.annul_match($1,'duplicate_match','teste de concorrência',true)", [r0.matches[1]]),
    admin.query('select private.after_rating_inputs_changed($1, null, $2)', [r0.pelada, 'recompute']).then(() => 'ok', (e) => (e.code === '40P01' ? 'DEADLOCK' : e.message)),
  ]);
  if (a5.some((x) => x !== 'ok')) fail(`anulação x reprocessamento: ${a5}`);
  await serialCheck(r0, 'anulação x reprocessamento');
  const played = (await admin.query('select max(matches_played)::int n from public.player_ratings where pelada_id=$1', [r0.pelada])).rows[0].n;
  if (played !== 5) fail(`anulação não refletida: ${played} partidas`);
  for (const c of [s1, s2, s3, s4, s5]) await c.end();
  console.log(`iteração ${it}: publicações simultâneas ${a1.join('/')}, defesas x disciplina x publicação ${a2.join('/')}, duas peladas ${a3.join('/')}, publicação dupla ${a4.join('/')}, anulação x reprocessamento ${a5.join('/')} (${Date.now() - t0} ms)`);
}
const runs = (await admin.query('select count(*)::int n, round(avg(extract(epoch from finished_at-started_at))*1000)::int ms, max(members)::int m from private.rating_runs')).rows[0];
console.log(`execuções do motor registradas: ${runs.n}, média ${runs.ms} ms, até ${runs.m} jogadores por pelada`);
await admin.end();
await server.stop();
rmSync(dir, { recursive: true, force: true });
console.log(problems ? `${problems} problema(s)` : `sem problemas em ${ITER} iterações`);
process.exit(problems ? 1 : 0);
