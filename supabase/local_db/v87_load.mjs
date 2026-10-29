// V8.7: carga da apuração dos prêmios de temporada (068) com 100 jogadores na pelada, 12 goleiros oficiais (3 se revezam no gol), 2 temporadas de
// 25 partidas (20 em campo por partida) e defesas difíceis registradas. Mede a publicação conjunta, o recálculo idempotente
// (ganho do gancho em correções), a leitura do admin, o Meus Prêmios e a Sala, e confere invariantes.
// Uso: cd supabase/local_db; node v87_load.mjs   (PLAYERS=100 MATCHES=25 por padrão)
// PGlite roda em WebAssembly num único processo: os tempos servem para achar gargalos, não como previsão do Supabase.
import { PGlite } from '@electric-sql/pglite';
import { btree_gist } from '@electric-sql/pglite/contrib/btree_gist';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const PLAYERS = Number(process.env.PLAYERS ?? 100);
const PER_SEASON = Number(process.env.MATCHES ?? 25);
const GKS = 12;
const root = join(import.meta.dirname, '..');
const db = await PGlite.create({ extensions: { pgcrypto, btree_gist } });
await db.exec(readFileSync(join(import.meta.dirname, 'shim.sql'), 'utf8'));
for (const f of readdirSync(join(root, 'migrations')).filter((f) => f.endsWith('.sql')).sort())
  await db.exec(readFileSync(join(root, 'migrations', f), 'utf8'));

const uid = (n) => `d8700000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const time = async (label, sql, params = []) => {
  const t = performance.now();
  const r = await db.query(sql, params);
  const ms = performance.now() - t;
  console.log(`${label.padEnd(58)} ${ms.toFixed(0).padStart(7)} ms`);
  return { r, ms };
};
let fail = 0;
const check = (ok, msg) => {
  console.log(`${ok ? 'ok  ' : 'FALHA'} ${msg}`);
  if (!ok) fail++;
};

console.log(`Montando: ${PLAYERS} jogadores (${GKS} goleiros oficiais), 2 temporadas x ${PER_SEASON} partidas`);
await db.exec(`
update private.app_config set value='true'::jsonb where key='premium_beta_open';
update private.v87_activation set min_season_end = '2099-01-01';
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select ('d8700000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'00000000-0000-0000-0000-000000000000','authenticated',
 'authenticated','v87load'||n||'@example.invalid','',now(),now(),now() from generate_series(1,${PLAYERS}) n;
set role authenticated;
do $$ declare v_pid uuid; v_tok text; begin
 for i in 1..${PLAYERS} loop
  perform set_config('request.jwt.claim.sub', ('d8700000-0000-4000-8000-'||lpad(i::text,12,'0')), false);
  perform public.complete_onboarding('Jogador '||i, true, true);
 end loop;
 perform set_config('request.jwt.claim.sub', 'd8700000-0000-4000-8000-000000000001', false);
 v_pid := public.create_pelada('Pelada V87','ATA');
 v_tok := public.create_pelada_invite(v_pid, 24, 1000);
 for i in 2..${PLAYERS} loop
  perform set_config('request.jwt.claim.sub', ('d8700000-0000-4000-8000-'||lpad(i::text,12,'0')), false);
  perform public.join_pelada(v_tok, case when i between 2 and ${GKS + 1} then 'GOL' else 'MEI' end);
 end loop;
end $$;
reset role;`);
const pid = (await db.query(`select id from public.peladas where name='Pelada V87'`)).rows[0].id;
const gk = (await db.query(`select id from public.pelada_memberships where pelada_id=$1 and position_code='GOL' order by id`, [pid])).rows.map((x) => x.id);
const field = (await db.query(`select id from public.pelada_memberships where pelada_id=$1 and (position_code is distinct from 'GOL') order by id`, [pid])).rows.map((x) => x.id);

const arr = (xs) => `array[${xs.map((x) => `'${x}'`).join(',')}]::uuid[]`;
let k = 0;
for (const year of [2024, 2025]) {
  for (let i = 0; i < PER_SEASON; i++, k++) {
    await db.exec(
      `do $$ declare v_id uuid; v_p uuid := '${pid}'; gk uuid[] := ${arr(gk)}; fd uuid[] := ${arr(field)}; r int := ${k}; a uuid; b uuid; x uuid; t text; n int; begin
        insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
        values(v_p, private.season_for_date(v_p, make_date(${year}, 1 + r % 11, 1 + r % 27)),
         make_timestamptz(${year}, 1 + r % 11, 1 + r % 27, 20, 0, 0, 'America/Sao_Paulo'), 'finalized', r % 4, (r * 7) % 3, now())
        returning id into v_id;
        a := gk[1 + r % 3]; b := gk[1 + (r + 1) % 3]; -- 3 dos ${GKS} goleiros oficiais se revezam (cada um em ~2/3 das partidas)
        insert into public.match_participants(pelada_id,match_id,membership_id,team,primary_position)
        values(v_p, v_id, a, 'A', 'goalkeeper'), (v_p, v_id, b, 'B', 'goalkeeper');
        for n in 1..${PLAYERS < 20 ? PLAYERS : 18} loop
         x := fd[1 + (r * 13 + n) % array_length(fd,1)];
         if not exists(select 1 from public.match_participants where match_id=v_id and membership_id=x) then
          insert into public.match_participants(pelada_id,match_id,membership_id,team,primary_position)
          values(v_p, v_id, x, case when n % 2 = 0 then 'A' else 'B' end, 'midfielder');
         end if;
        end loop;
        insert into public.match_keeper_saves(pelada_id,match_id,participant_id,hard_saves)
        select v_p, v_id, id, (r + ascii(substr(membership_id::text, 1, 1)) + ascii(substr(membership_id::text, 2, 1))) % 9 from public.match_participants where match_id=v_id and primary_position='goalkeeper';
        insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
        select v_p, v_id, q.id, q.team, 'goal', 1 + (r % 2) from (select id, team, row_number() over (order by id) rn from public.match_participants where match_id=v_id and primary_position='midfielder') q where (r + q.rn) % 7 = 0;
        insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
        select v_p, v_id, q.id, q.team, 'assist', 1 from (select id, team, row_number() over (order by id) rn from public.match_participants where match_id=v_id and primary_position='midfielder') q where (r + q.rn) % 5 = 1;
        perform private.compute_match_results(v_id, null);
       end $$;`,
    );
  }
  console.log(`  temporada ${year} montada`);
}
await db.exec(`update public.seasons set ends_on = least(ends_on, make_date(extract(year from starts_on)::int, 12, 31)) where pelada_id='${pid}';
 select private.sync_season_status('${pid}');`);
const counts = (await db.query(`select (select count(*) from public.matches where pelada_id=$1) partidas, (select count(*) from public.match_participants where pelada_id=$1) participacoes,
 (select count(*) from public.match_keeper_saves where pelada_id=$1) defesas`, [pid])).rows[0];
console.log('  volume:', counts);

await db.exec(`update private.v87_activation set min_season_end = '2020-01-01'`);
const seasons = (await db.query(`select id, name from public.seasons where pelada_id=$1 and ends_on < current_date order by starts_on`, [pid])).rows;
check(seasons.length === 2, `2 temporadas encerradas (${seasons.map((s) => s.name).join(', ')})`);

const pub = await time('publicação conjunta (2 temporadas, 12 goleiros)', `select private.season_awards_after_change($1, null)`, [pid]);
const res = (await db.query(`select s.name, r.category, r.status, cardinality(r.winners) n, r.version from private.season_award_results r join public.seasons s on s.id=r.season_id where r.pelada_id=$1 and r.is_current order by s.starts_on, r.category`, [pid])).rows;
console.table(res);
check(res.length === 6, 'três categorias por temporada');
check(res.every((x) => x.version === 1), 'versão 1 em todas');
await time('recálculo sem mudança (idempotente)', `select private.season_awards_after_change($1, null)`, [pid]);
check((await db.query(`select count(*) c from private.season_award_results where pelada_id=$1`, [pid])).rows[0].c === 6, 'sem versões novas no recálculo');
check(Number((await db.query(`select count(*) c from (select season_id, award_type, membership_id from public.awards where pelada_id=$1 and status='active' and award_type like 'season_%' group by 1,2,3 having count(*)>1) x`, [pid])).rows[0].c) === 0, 'nenhum prêmio ativo duplicado');
await time('cálculo de uma Luva (REF dos 12 goleiros)', `select private.v87_glove_result($1)`, [seasons[1].id]);
await time('cálculo do Artilheiro (100 jogadores)', `select private.v87_stat_result($1,'goals')`, [seasons[1].id]);

await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${uid(1)}', false);`);
await time('get_season_awards (admin)', `select public.get_season_awards($1)`, [seasons[1].id]);
await time('get_player_season_titles', `select public.get_player_season_titles($1)`, [uid(2)]);
await time('get_player_career_summary (com contadores V8.7)', `select public.get_player_career_summary($1)`, [uid(2)]);
await db.exec(`reset role`);

// Plano de execução das consultas internas: nada de varredura da tabela inteira de partidas por jogador.
const plan = (await db.query(`explain (analyze, buffers off, timing off) select * from private.glove_candidates($1, 50, 5)`, [seasons[1].id])).rows.map((r) => r['QUERY PLAN']).join('\n');
console.log(plan.split('\n').slice(0, 6).join('\n') + '\n  …');
check(pub.ms < 60000, `publicação conjunta abaixo de 60 s no PGlite (${(pub.ms / 1000).toFixed(1)} s)`);
console.log(fail ? `${fail} falha(s)` : 'carga V8.7 ok');
process.exit(fail ? 1 : 0);
