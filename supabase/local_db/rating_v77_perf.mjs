// V7.7: custo do reprocessamento completo de uma pelada num PostgreSQL REAL (embedded-postgres).
// Uso: PLAYERS=40 MATCHES=200 node rating_v77_perf.mjs
// Monta a pelada direto no banco (súmula, resultados, defesas, cartões e resenha), em duas temporadas, e mede
// private.recompute_pelada_ratings com e sem a impressão digital da entrada (cache).
import EmbeddedPostgres from 'embedded-postgres';
import { execFileSync } from 'node:child_process';
import { chownSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';

const root = join(import.meta.dirname, '..');
const PLAYERS = Number(process.env.PLAYERS ?? 40);
const MATCHES = Number(process.env.MATCHES ?? 200);
const dir = mkdtempSync(join(tmpdir(), 'm91-v77p-'));
if (process.getuid?.() === 0) chownSync(dir, Number(execFileSync('id', ['-u', 'postgres'])), Number(execFileSync('id', ['-g', 'postgres'])));
const port = 57600 + Math.floor(Math.random() * 300);
const server = new EmbeddedPostgres({ databaseDir: dir, user: 'postgres', password: 'postgres', port, persistent: false, onLog: () => {} });
await server.initialise();
await server.start();
await server.createDatabase('m91');
const c = new pg.Client({ host: 'localhost', port, user: 'postgres', password: 'postgres', database: 'm91' });
await c.connect();
await c.query(readFileSync(join(import.meta.dirname, 'shim.sql'), 'utf8'));
for (const f of readdirSync(join(root, 'migrations')).filter((f) => f.endsWith('.sql')).sort()) await c.query(readFileSync(join(root, 'migrations', f), 'utf8'));
await c.query(`
insert into auth.users(id,aud,role,email) select ('98800000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'authenticated','authenticated','p'||n||'@example.invalid' from generate_series(1,${PLAYERS}) n;
do $$ declare v_p uuid; v_tok text; begin
 for i in 1..${PLAYERS} loop perform set_config('request.jwt.claim.sub','98800000-0000-4000-8000-'||lpad(i::text,12,'0'),true); perform public.complete_onboarding('J'||i,true,true); end loop;
 perform set_config('request.jwt.claim.sub','98800000-0000-4000-8000-000000000001',true);
 v_p := public.create_pelada('Perf','GOL'); v_tok := public.create_pelada_invite(v_p);
 for i in 2..${PLAYERS} loop perform set_config('request.jwt.claim.sub','98800000-0000-4000-8000-'||lpad(i::text,12,'0'),true);
  perform public.join_pelada(v_tok, (array['GOL','ZAG','LD','VOL','MEI','CA','PE'])[1 + i%7]); end loop;
 update public.pelada_settings set cards_tracking=true where pelada_id=v_p;
end $$;`);
const pelada = (await c.query(`select id from public.peladas where name='Perf'`)).rows[0].id;
const t0 = Date.now();
await c.query(`
do $$ declare v_p uuid := '${pelada}'; v_m uuid; mems uuid[]; picked uuid[]; i int; ga int; gb int; v_at timestamptz; begin
 mems := array(select id from public.pelada_memberships where pelada_id=v_p order by id);
 for j in 1..${MATCHES} loop
  v_at := now() - make_interval(days => ${MATCHES} - j + 1) - interval '2 hours';
  ga := (j*7)%5; gb := (j*3)%4;
  insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at,discipline_status)
  values(v_p,private.season_for_date(v_p,private.pelada_local_date(v_p,v_at)),v_at,'finalized',ga,gb,now(),'confirmed') returning id into v_m;
  picked := array(select x from unnest(mems) with ordinality u(x,o) where (o*31 + j*17) % 10 < 7 order by o limit 22);
  insert into public.match_participants(pelada_id,match_id,membership_id,team,primary_position)
  select v_p, v_m, x, case when o%2=0 then 'A' else 'B' end, (select preferred_position from public.pelada_memberships where id=x)
  from unnest(picked) with ordinality u(x,o);
  insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,objective_rating,final_rating,
   has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version,resenha)
  select v_p, v_m, p.membership_id, 0, case when (o+j)%5<>0 then 6 + ((o*j)%9)/2.0 end, 5, case when (o+j)%5<>0 then 6 + ((o*j)%9)/2.0 end, (o+j)%5<>0, (o+j)%4/3, (o*j)%3/2, 0,
   case when ga=gb then 'draw' when (p.team='A') = (ga>gb) then 'win' else 'loss' end, p.primary_position, 2,
   case (o+j)%3 when 0 then null when 1 then true else false end
  from public.match_participants p join lateral (select o from unnest(picked) with ordinality u(x,o) where x=p.membership_id) z on true
  where p.match_id=v_m;
  insert into public.match_keeper_saves(pelada_id,match_id,participant_id,hard_saves)
  select v_p, v_m, p.id, j%6 from public.match_participants p where p.match_id=v_m and p.primary_position='goalkeeper' and j%4<>0;
  insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
  select v_p, v_m, p.id, p.team, 'yellow_card', 1 from public.match_participants p where p.match_id=v_m and (hashtext(p.id::text) % 9) = 0;
 end loop;
end $$;`);
console.log(`Postgres ${(await c.query('show server_version')).rows[0].server_version}: ${PLAYERS} jogadores, ${MATCHES} partidas montadas em ${Date.now() - t0} ms`);
const time = async (label, sql) => {
  const ts = [];
  for (let k = 0; k < 3; k++) { const t = Date.now(); await c.query(sql); ts.push(Date.now() - t); }
  console.log(`${label}: ${ts.join(' / ')} ms`);
  return ts;
};
await time('reprocessamento completo (sem cache)', `update public.player_ratings set input_hash=null where pelada_id='${pelada}'; select private.recompute_pelada_ratings('${pelada}', null)`);
await time('reprocessamento com entrada idêntica (cache)', `select private.recompute_pelada_ratings('${pelada}', null)`);
await time('só montar as entradas', `select count(private.v77_member_input(id)) from public.pelada_memberships where pelada_id='${pelada}'`);
await time('cadeia completa pós-partida (notas + cartas)', `update public.player_ratings set input_hash=null where pelada_id='${pelada}'; select private.after_match_finalized((select id from public.matches where pelada_id='${pelada}' order by played_at desc limit 1))`);
const r = (await c.query(`select count(*)::int n, count(*) filter (where eligible)::int e, round(min(ovr),2) mn, round(max(ovr),2) mx from public.player_ratings where pelada_id='${pelada}'`)).rows[0];
console.log(`jogadores com nota: ${r.n} (${r.e} com OVR publicado), OVR de ${r.mn} a ${r.mx}`);
await c.end();
await server.stop();
rmSync(dir, { recursive: true, force: true });
