// Teste de carga no banco local (PGlite): pelada grande com várias temporadas, prêmios e fila de avisos.
// Mede as consultas que as telas da V4.1 usam. Uso: cd supabase/local_db; node load.mjs
// PGlite roda em WebAssembly num único processo: os tempos servem para comparar consultas e achar
// gargalos, não como previsão do Supabase (que costuma ser mais rápido).
import { PGlite } from '@electric-sql/pglite';
import { btree_gist } from '@electric-sql/pglite/contrib/btree_gist';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const PLAYERS = Number(process.env.PLAYERS ?? 60);
const PER_SEASON = Number(process.env.MATCHES ?? 25); // partidas por temporada (3 temporadas)
const PER_SIDE = 8;
const NOTIFS = Number(process.env.NOTIFS ?? 5000);

const root = join(import.meta.dirname, '..');
const db = await PGlite.create({ extensions: { pgcrypto, btree_gist } });
await db.exec(readFileSync(join(import.meta.dirname, 'shim.sql'), 'utf8'));
for (const f of readdirSync(join(root, 'migrations')).filter((f) => f.endsWith('.sql')).sort())
  await db.exec(readFileSync(join(root, 'migrations', f), 'utf8'));

const uid = (n) => `d0000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const time = async (label, sql, params = []) => {
  const t = performance.now();
  const r = await db.query(sql, params);
  const ms = performance.now() - t;
  console.log(`${label.padEnd(46)} ${ms.toFixed(0).padStart(6)} ms`);
  return r;
};

console.log(`Montando: ${PLAYERS} jogadores, 3 temporadas x ${PER_SEASON} partidas, ${PER_SIDE}x${PER_SIDE}, ${NOTIFS} avisos`);
let t0 = performance.now();
await db.exec(`
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select ('d0000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'00000000-0000-0000-0000-000000000000','authenticated',
 'authenticated','load'||n||'@example.invalid','',now(),now(),now() from generate_series(1,${PLAYERS}) n;
set role authenticated;
do $$ declare v_pid uuid; v_tok text; begin
 for i in 1..${PLAYERS} loop
  perform set_config('request.jwt.claim.sub', ('d0000000-0000-4000-8000-'||lpad(i::text,12,'0')), false);
  perform public.complete_onboarding('Jogador '||i, true, true);
 end loop;
 perform set_config('request.jwt.claim.sub', 'd0000000-0000-4000-8000-000000000001', false);
 v_pid := public.create_pelada('Pelada Grande','attacker');
 v_tok := public.create_pelada_invite(v_pid, 24, 1000);
 for i in 2..${PLAYERS} loop
  perform set_config('request.jwt.claim.sub', ('d0000000-0000-4000-8000-'||lpad(i::text,12,'0')), false);
  perform public.join_pelada(v_tok, (array['goalkeeper','defender','midfielder','attacker'])[1 + i % 4]);
 end loop;
end $$;
reset role;
update private.app_config set value='false'::jsonb where key='premium_beta_open';
`);
const pid = (await db.query(`select id from public.peladas where name='Pelada Grande'`)).rows[0].id;
console.log(`  jogadores e pelada: ${((performance.now() - t0) / 1000).toFixed(1)}s`);

// Partidas já finalizadas passando pela cadeia oficial (014 -> 015 -> 016 -> 018), como nos testes 023/027.
t0 = performance.now();
let k = 0;
for (const year of [2024, 2025, 2026]) {
  for (let i = 0; i < PER_SEASON; i++, k++) {
    const day = year === 2026 ? `now() - interval '${PER_SEASON - i + 1} days'` : `make_timestamptz(${year},${1 + (i % 11)},${1 + (i % 27)},20,0,0,'America/Sao_Paulo')`;
    await db.exec(`
do $$ declare v_id uuid; v_p uuid := '${pid}'; begin
 insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
 values(v_p, private.season_for_date(v_p, private.pelada_local_date(v_p, ${day})), ${day}, 'finalized', ${k % 4}, ${(k * 7) % 3}, now())
 returning id into v_id;
 insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,objective_rating,
  final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
 select v_p, v_id, m.id, 5, 6 + (s.r % 4), 5, 6 + (s.r % 4), true, (s.r + ${k}) % 3, (s.r + ${k} + 1) % 2, 0,
  case when ${k % 4} = ${(k * 7) % 3} then 'draw' when (s.r % 2 = 0) = (${k % 4} > ${(k * 7) % 3}) then 'win' else 'loss' end,
  m.preferred_position, 1
 from (select id, preferred_position, row_number() over (order by md5(id::text || '${k}')) r from public.pelada_memberships
  where pelada_id=v_p and status='active') m
 cross join lateral (select m.r::int r) s where m.r <= ${PER_SIDE * 2};
 insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count)
 select v_p, v_id, (select season_id from public.matches where id=v_id), membership_id, 'match_craque', 5
 from public.match_player_results where match_id=v_id order by final_rating desc, membership_id limit 1;
 perform private.after_match_finalized(v_id);
end $$;`);
  }
  console.log(`  temporada ${year}: ${((performance.now() - t0) / 1000).toFixed(1)}s acumulados`);
}

const counts = (await db.query(`select (select count(*) from public.matches) partidas, (select count(*) from public.match_player_results) resultados,
 (select count(*) from public.card_snapshots) snapshots, (select count(*) from public.awards) premios, (select count(*) from public.seasons) temporadas`)).rows[0];
console.log('  volume:', counts);

// V4.2 (8.2): finalização incremental (038) x recálculo completo (014). Mesmo resultado, linha a linha.
const statsSnapshot = `select coalesce(jsonb_agg(to_jsonb(x) - 'id' - 'updated_at' order by x.membership_id, x.season_id), '[]') j from (
  select s.*, null::uuid c from public.player_season_stats s where s.pelada_id=$1) x`;
const careerSnapshot = `select coalesce(jsonb_agg(to_jsonb(x) - 'id' - 'updated_at' order by x.membership_id), '[]') j
  from public.player_career_stats x where x.pelada_id=$1`;
const cardsSnapshot = `select coalesce(jsonb_agg(to_jsonb(x) - 'id' - 'updated_at' order by x.membership_id, x.season_id), '[]') j
  from public.player_cards x where x.pelada_id=$1`;
const snap = async () => [statsSnapshot, careerSnapshot, cardsSnapshot].map(async (q) => (await db.query(q, [pid])).rows[0].j);
const before = await Promise.all(await snap());
await db.exec(`do $$ declare s uuid; begin
 for s in select id from public.seasons where pelada_id='${pid}' order by starts_on loop
  perform private.recompute_stats('${pid}', s); perform private.recompute_season_cards(s, null);
 end loop; end $$;`);
const after = await Promise.all(await snap());
const same = ['estatísticas da temporada', 'carreira', 'Cards'].map((n, i) => `${n}: ${JSON.stringify(before[i]) === JSON.stringify(after[i]) ? 'iguais' : 'DIFERENTES'}`);
console.log('  incremental x recálculo completo →', same.join(', '));
if (same.some((x) => x.includes('DIFERENTES'))) process.exitCode = 1;

// Tempo de uma finalização (cadeia oficial inteira), com e sem o recálculo completo das estatísticas.
const oneMore = (full) => `do $$ declare v_id uuid; v_p uuid := '${pid}'; begin
 insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
 values(v_p, private.season_for_date(v_p, private.pelada_today(v_p)), now(), 'finalized', 2, 1, now()) returning id into v_id;
 insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,objective_rating,
  final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
 select v_p, v_id, id, 5, 7, 5, 7, true, 1, 0, 0, case when r % 2 = 0 then 'win' else 'loss' end, preferred_position, 1
 from (select id, preferred_position, row_number() over (order by id) r from public.pelada_memberships where pelada_id=v_p and status='active') m
 where r <= ${PER_SIDE * 2};
 ${full ? `perform private.recompute_stats(v_p, (select season_id from public.matches where id=v_id));` : ''}
 perform private.after_match_finalized(v_id);
end $$;`;
for (const [label, full] of [['finalizar 1 partida (V4.2, incremental)', false], ['finalizar 1 partida (+ recálculo completo, como V4.1)', true]]) {
  const t = performance.now();
  await db.exec(oneMore(full));
  console.log(`  ${label.padEnd(52)} ${(performance.now() - t).toFixed(0).padStart(6)} ms`);
}

// Fila de avisos: NOTIFS pendentes para os jogadores, 2 aparelhos por jogador.
await db.exec(`
insert into public.push_devices(user_id, expo_push_token, platform)
select u.id, 'ExponentPushToken[load-'||u.n||'-'||d||']', 'ios'
from (select ('d0000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid id, n from generate_series(1,${PLAYERS}) n) u, generate_series(1,2) d;
insert into public.notification_events(user_id,pelada_id,event_type,category,dedupe_key,payload)
select ('d0000000-0000-4000-8000-'||lpad((1 + g % ${PLAYERS})::text,12,'0'))::uuid, '${pid}', 'result_published', 'essential',
 'load:'||g, jsonb_build_object('pelada_id','${pid}') from generate_series(1,${NOTIFS}) g;`);

const seasons = (await db.query(`select id, name from public.seasons where pelada_id=$1 order by starts_on desc`, [pid])).rows;
const cur = seasons[0].id;
const me = (await db.query(`select id from public.pelada_memberships where pelada_id=$1 and user_id=$2`, [pid, uid(2)])).rows[0].id;

console.log('\nConsultas (usuário comum, temporada atual):');
await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid(2)}', false);`);
for (const m of ['goals', 'assists', 'overall', 'avg_rating', 'matches', 'wins'])
  await time(`get_season_ranking ${m}`, `select count(*) from public.get_season_ranking($1, $2)`, [cur, m]);
await time('get_season_records', `select public.get_season_records($1)`, [cur]);
const evo = await time('get_player_evolution', `select public.get_player_evolution($1, $2) e`, [me, cur]);
console.log(`  (pontos na evolução: ${evo.rows[0].e.points.length})`);
await time('get_player_career', `select public.get_player_career($1)`, [uid(2)]);
await time('Central: partidas (20 últimas, RLS)', `select count(*) from (select id from public.matches where pelada_id=$1 order by played_at desc limit 20) x`, [pid]);
await time('Elenco: cards da temporada (RLS)', `select count(*) from public.player_cards where season_id=$1`, [cur]);
await time('Retrospectiva: stats da temporada (RLS)', `select count(*) from public.player_season_stats where season_id=$1`, [cur]);
await time('Prêmios da pelada (RLS)', `select count(*) from public.awards where pelada_id=$1 and status='active'`, [pid]);
await db.exec(`reset role;`);

console.log('\nFila de avisos (remetente, service_role):');
await db.exec(`set role service_role;`);
let claimed = 0;
const t1 = performance.now();
for (;;) {
  const r = await db.query(`select id from public.claim_notifications(100)`);
  if (!r.rows.length) break;
  claimed += r.rows.length;
  await db.query(`select public.complete_notifications($1::jsonb)`, [JSON.stringify(r.rows.map((x) => ({ id: x.id, outcome: 'accepted', tickets: [] })))]);
}
console.log(`  ${claimed} avisos reservados e confirmados em lotes de 100: ${((performance.now() - t1) / 1000).toFixed(1)}s`);
await db.exec(`reset role;`);
const st = (await db.query(`select status, count(*)::int n from public.notification_events group by 1 order by 1`)).rows;
console.log('  estados finais:', Object.fromEntries(st.map((r) => [r.status, r.n])));
await db.close();
