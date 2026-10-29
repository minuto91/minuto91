-- V4.2 (migração 039): sorteio de times equilibrado por posição, escalações e Duelo de Jogadores.
-- Inclui o teste de propriedade (1.500 combinações aleatórias de posições e quantidades).
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 032_draws_duel_lineups".
-- V4.3 (040/041): o app não escolhe mais a semente; os sorteios com semente fixa deste teste usam a função interna
-- private.create_team_draw_core (só o dono do banco executa). Goleiros viram GOL (041).
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('96000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
create function pg_temp.as_user(n int) returns void language plpgsql as
 $$ begin perform set_config('request.jwt.claim.sub', pg_temp.uid(n)::text, true); end $$;
create function pg_temp.expect_error(p_sql text, p_msg text) returns void language plpgsql as
 $$ begin
  begin execute p_sql; exception when others then
   if sqlerrm like '%'||p_msg||'%' then return; end if;
   raise exception 'erro inesperado "%" (esperado "%") em: %', sqlerrm, p_msg, p_sql;
  end;
  raise exception 'deveria falhar com "%": %', p_msg, p_sql;
 end $$;
create function pg_temp.assert(p_ok boolean, p_msg text) returns void language plpgsql as
 $$ begin if not coalesce(p_ok,false) then raise exception 'FALHOU: %', p_msg; end if; end $$;
-- Sorteio com semente fixa (reprodução/auditoria): só pelo dono do banco, como o mesmo usuário (auth.uid()).
create function pg_temp.draw(p uuid, s uuid[], m text, r int, seed text) returns jsonb language plpgsql as
 $$ declare v jsonb; begin
  reset role; v := private.create_team_draw_core(p, s, m, r, seed);
  perform set_config('role','authenticated',true); return v; end $$;
create function pg_temp.mem(p_pelada uuid, n int) returns uuid language sql as
 $$ select id from public.pelada_memberships where pelada_id=p_pelada and user_id=pg_temp.uid(n) $$;
-- Contagem (A, B) de uma posição numa rodada do sorteio.
create function pg_temp.cnt(p_draw jsonb, p_round int, p_pos text) returns int[] language sql as
 $$ select array[coalesce((x->>'a')::int,0), coalesce((x->>'b')::int,0)]
    from jsonb_array_elements(p_draw->'rounds'->(p_round-1)->'by_position') x where x->>'position'=p_pos
    union all select array[0,0] limit 1 $$;
create function pg_temp.sizes(p_draw jsonb, p_round int) returns int[] language sql as
 $$ select array[jsonb_array_length(p_draw->'rounds'->(p_round-1)->'team_a'), jsonb_array_length(p_draw->'rounds'->(p_round-1)->'team_b')] $$;
-- Todas as regras obrigatórias numa rodada: por posição <= 1, total <= 1, cada jogador uma vez.
create function pg_temp.valid(p_draw jsonb, p_round int, p_members uuid[]) returns boolean language sql as
 $$ select not exists(select 1 from jsonb_array_elements(p_draw->'rounds'->(p_round-1)->'by_position') x
          where abs((x->>'a')::int - (x->>'b')::int) > 1)
     and abs((pg_temp.sizes(p_draw,p_round))[1] - (pg_temp.sizes(p_draw,p_round))[2]) <= 1
     and (select array_agg(m order by m) from (
           select (x->>'membership_id')::uuid m from jsonb_array_elements(p_draw->'rounds'->(p_round-1)->'team_a') x
           union all select (x->>'membership_id')::uuid from jsonb_array_elements(p_draw->'rounds'->(p_round-1)->'team_b') x) y)
         = (select array_agg(m order by m) from unnest(p_members) m) $$;
create function pg_temp.members(p_pelada uuid, p_pos text[]) returns uuid[] language sql as
 $$ select array_agg(id order by id) from public.pelada_memberships where pelada_id=p_pelada and status='active'
     and preferred_position = any(p_pos) $$;

-- V8.5 (062): public.create_team_draw recusa novos sorteios por OVR (DRAW_ALGORITHM_SUPERSEDED). Os testes do
-- sorteio histórico (algorithm_version 2) passam a chamar o núcleo antigo como dono do banco, só para manter
-- a regressão do histórico (leitura, confirmação, escalações).
create function pg_temp.legacy(p uuid, s uuid[], m text, r int) returns jsonb language plpgsql as
 $$ declare v jsonb; begin
  reset role; v := private.create_team_draw_core(p, s, m, r, null);
  perform set_config('role','authenticated',true); return v; end $$;
do $test$
declare
 v_p uuid; v_tok text; v_d jsonb; v_d2 jsonb; v_all uuid[]; v_sel uuid[]; v_gk uuid[]; v_l jsonb; v_x uuid; v_n int;
 v_pos text[]; v_ov numeric[]; v_t text[]; v_trial int; v_fail int := 0; v_gk2 int := 0; v_sz int; v_s uuid; v_r jsonb;
 v_same int := 0; v_diffs numeric; v_rand numeric;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-dr'||n||'@example.invalid','',now(),now(),now() from generate_series(1,30) n;
perform set_config('role','authenticated',true);
for i in 1..30 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||lpad(i::text,2,'0'),true,true); end loop;

-- Pelada com 4 goleiros (1..4), 6 zagueiros (5..10), 6 meias (11..16), 4 atacantes (17..20), 21..23 meias.
perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada Sorteio','goalkeeper');
v_tok := public.create_pelada_invite(v_p);
for i in 2..23 loop
 perform pg_temp.as_user(i);
 perform public.join_pelada(v_tok, case when i<=4 then 'goalkeeper' when i<=10 then 'defender' when i<=16 then 'midfielder'
  when i<=20 then 'attacker' else 'midfielder' end);
end loop;
perform pg_temp.as_user(2); perform public.join_pelada(v_tok,'goalkeeper'); -- já é membro: nada muda
perform pg_temp.as_user(1);
perform public.set_assistant(v_p, pg_temp.mem(v_p,5), true);
v_gk := array[pg_temp.mem(v_p,1),pg_temp.mem(v_p,2),pg_temp.mem(v_p,3),pg_temp.mem(v_p,4)];

-- 1) Dois goleiros e 14 de linha (16): 8x8, um goleiro em cada time.
v_sel := v_gk[1:2] || (select array_agg(pg_temp.mem(v_p,i)) from generate_series(5,18) i);
v_d := pg_temp.draw(v_p, v_sel, 'single', 4, 'semente-1');
perform pg_temp.assert(pg_temp.valid(v_d,1,v_sel),'16 jogadores: regras obrigatórias');
perform pg_temp.assert(pg_temp.cnt(v_d,1,'GOL')=array[1,1],'dois goleiros separados');
perform pg_temp.assert(pg_temp.sizes(v_d,1)=array[8,8],'8 x 8');
perform pg_temp.assert(v_d->>'status'='draft' and (v_d->>'rounds_total')::int=4 and jsonb_array_length(v_d->'rounds')=1,
 'sorteio único: uma divisão para 4 rodadas');
-- 9) total ímpar e 6) posições ímpares: 15 jogadores -> 8x7.
v_sel := v_gk[1:2] || (select array_agg(pg_temp.mem(v_p,i)) from generate_series(5,17) i);
v_d := pg_temp.draw(v_p, v_sel, 'single', 1, 'semente-2');
perform pg_temp.assert(pg_temp.valid(v_d,1,v_sel) and (select array_agg(x order by x) from unnest(pg_temp.sizes(v_d,1)) x)=array[7,8],'15 -> 8 x 7');
-- 2) um goleiro: 1x0 com aviso.
v_sel := v_gk[1:1] || (select array_agg(pg_temp.mem(v_p,i)) from generate_series(5,12) i);
v_d := pg_temp.draw(v_p, v_sel, 'single', 1, 'semente-3');
perform pg_temp.assert(pg_temp.valid(v_d,1,v_sel) and (v_d->'warnings') ? 'ONE_GOALKEEPER','um goleiro: aviso explícito');
perform pg_temp.assert((select sum(x) from unnest(pg_temp.cnt(v_d,1,'GOL')) x)=1,'nenhum goleiro inventado');
-- 3) três goleiros: 2x1 com aviso.
v_sel := v_gk[1:3] || (select array_agg(pg_temp.mem(v_p,i)) from generate_series(5,13) i);
v_d := pg_temp.draw(v_p, v_sel, 'single', 1, 'semente-4');
perform pg_temp.assert(pg_temp.valid(v_d,1,v_sel) and (v_d->'warnings') ? 'ODD_GOALKEEPERS'
 and (select array_agg(x order by x) from unnest(pg_temp.cnt(v_d,1,'GOL')) x)=array[1,2],'três goleiros: 2 x 1');
-- 4) quatro goleiros: 2x2. 5) posições pares.
v_sel := v_gk || (select array_agg(pg_temp.mem(v_p,i)) from generate_series(5,16) i);
v_d := pg_temp.draw(v_p, v_sel, 'single', 1, 'semente-5');
perform pg_temp.assert(pg_temp.cnt(v_d,1,'GOL')=array[2,2] and pg_temp.cnt(v_d,1,'defender')=array[3,3]
 and pg_temp.cnt(v_d,1,'midfielder')=array[3,3],'quatro goleiros 2 x 2 e pares divididos ao meio');
-- 10) total par.
perform pg_temp.assert(pg_temp.sizes(v_d,1)=array[8,8],'total par: 8 x 8');

-- 8) sem overall definitivo: todos provisórios (base oficial 50), com aviso.
perform pg_temp.assert((v_d->'warnings') ? 'PROVISIONAL_OVERALL','overall provisório sinalizado');
perform pg_temp.assert((select bool_and((x->>'overall')::numeric=50) from jsonb_array_elements(v_d->'rounds'->0->'team_a') x),
 'sem Card: base oficial 50 (nada inventado)');

-- 11) sorteios repetidos: mesma semente = mesmo resultado; sementes diferentes variam.
v_d := pg_temp.draw(v_p, v_sel, 'single', 1, 'semente-repetida');
v_d2 := pg_temp.draw(v_p, v_sel, 'single', 1, 'semente-repetida');
perform pg_temp.assert(v_d->'rounds' = v_d2->'rounds','reproduzível pela semente');
execute 'reset role';
perform pg_temp.assert((select count(*) from public.team_draws where pelada_id=v_p and status='draft')=1,
 'um rascunho por pelada (sem duplicados)');
perform set_config('role','authenticated',true);
for i in 1..8 loop
 v_d2 := pg_temp.draw(v_p, v_sel, 'single', 1, 'variando-'||i);
 if v_d2->'rounds'->0->'team_a' = v_d->'rounds'->0->'team_a' then v_same := v_same + 1; end if;
end loop;
perform pg_temp.assert(v_same < 8,'aleatoriedade entre soluções válidas');

-- 21) overall: com notas diferentes, a otimização reduz a diferença sem quebrar posições.
execute 'reset role';
select id into v_s from public.seasons where pelada_id=v_p order by starts_on desc limit 1;
insert into public.player_cards(pelada_id,season_id,membership_id,position,finishing,assisting,attendance,winning,peer_rating,overall,tier,is_provisional,matches_played,formula_version)
select v_p, v_s, m.id, m.preferred_position, 50,50,50,50,50, 40 + (row_number() over (order by m.id))*2.5, 'prata', false, 6, 1
from public.pelada_memberships m where m.pelada_id=v_p and m.status='active';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_d := pg_temp.draw(v_p, v_sel, 'single', 1, 'semente-overall');
perform pg_temp.assert(pg_temp.valid(v_d,1,v_sel),'otimização respeita as regras');
perform pg_temp.assert(abs((v_d->'rounds'->0->>'overall_a')::numeric - (v_d->'rounds'->0->>'overall_b')::numeric) <= 5,
 'diferença de overall pequena: '||(v_d->'rounds'->0->>'overall_a')||' x '||(v_d->'rounds'->0->>'overall_b'));
-- Comparação: média de 30 divisões aleatórias válidas (sem otimização) é bem pior.
execute 'reset role';
select array_agg(m.preferred_position order by m.id), array_agg(c.overall order by m.id) into v_pos, v_ov
from public.pelada_memberships m join public.player_cards c on c.membership_id=m.id and c.season_id=v_s where m.id = any(v_sel);
select avg(abs(sa-sb)) into v_rand from (
 select sum(v_ov[i]) filter (where t[i]='A') sa, sum(v_ov[i]) filter (where t[i]='B') sb
 from (select g, private.draw_split(v_pos, v_ov, 'aleatorio-'||g, 1) t from generate_series(1,30) g) x, generate_subscripts(v_pos,1) i
 group by g) y;
perform pg_temp.assert(abs((v_d->'rounds'->0->>'overall_a')::numeric - (v_d->'rounds'->0->>'overall_b')::numeric) <= v_rand,
 'otimizado não é pior que uma divisão qualquer');
perform set_config('role','authenticated',true);

-- 12) sorteios independentes: 4 rodadas, cada uma válida, distribuições não todas iguais.
perform pg_temp.as_user(1);
v_d := pg_temp.draw(v_p, v_sel, 'independent', 4, 'semente-indep');
perform pg_temp.assert(jsonb_array_length(v_d->'rounds')=4,'4 rodadas independentes');
for r in 1..4 loop perform pg_temp.assert(pg_temp.valid(v_d,r,v_sel),'rodada '||r||' válida'); end loop;
perform pg_temp.assert((select count(distinct x->'team_a') from jsonb_array_elements(v_d->'rounds') x) > 1,'divisões independentes');
-- 22) persistência e recuperação; confirmação cria 4 escalações.
v_d2 := public.confirm_team_draw((v_d->>'id')::uuid, 'Azul', 'Dourado');
perform pg_temp.assert(v_d2->>'status'='confirmed' and v_d2->'rounds'=v_d->'rounds','confirmado sem recalcular');
perform pg_temp.expect_error(format('select public.confirm_team_draw(%L)',v_d->>'id'),'DRAW_ALREADY_CONFIRMED');
v_l := public.get_lineups(v_p);
perform pg_temp.assert(jsonb_array_length(v_l)=4 and (select bool_and(x->>'source'='draw' and x->>'team_a_name'='Azul') from jsonb_array_elements(v_l) x),
 '4 escalações, uma por rodada');
execute 'reset role';
perform pg_temp.assert((select count(*) from public.team_draw_players where draw_id=(v_d->>'id')::uuid)=4*cardinality(v_sel),
 'resultado persistido por rodada');
perform set_config('role','authenticated',true);
-- 13) sorteio reutilizável: confirmação gera uma escalação válida por 3 rodadas.
v_d := pg_temp.draw(v_p, v_sel, 'single', 3, 'semente-unico');
perform public.confirm_team_draw((v_d->>'id')::uuid);
v_l := (select x from jsonb_array_elements(public.get_lineups(v_p)) x where x->>'draw_id'=v_d->>'id');
perform pg_temp.assert((v_l->>'rounds_total')::int=3 and v_l->>'label' like 'Sorteio único%','mesma composição por 3 rodadas');
-- Usar na súmula: rascunho com os times (não finaliza nada).
v_x := public.use_lineup_in_match((v_l->>'id')::uuid, now());
execute 'reset role';
perform pg_temp.assert((select status='draft' from public.matches where id=v_x),'escalação vira só rascunho de súmula');
perform pg_temp.assert((select count(*) from public.match_participants where match_id=v_x)=cardinality(v_sel),'jogadores na súmula');
perform pg_temp.assert((select rounds_used=1 and status='active' from public.planned_lineups where id=(v_l->>'id')::uuid),
 'conta a rodada usada e segue ativa');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);

-- 14) jogador removido depois do sorteio: escalação marcada para revisão, nunca mudada em silêncio.
perform pg_temp.as_user(12); perform public.leave_pelada(v_p);
perform pg_temp.as_user(1);
v_l := (select x from jsonb_array_elements(public.get_lineups(v_p)) x where x->>'draw_id'=v_d->>'id');
perform pg_temp.assert((v_l->>'needs_review')::boolean,'escalação precisa de revisão');
perform pg_temp.assert(jsonb_array_length(v_l->'players')=cardinality(v_sel),'composição não mudou sozinha');
perform pg_temp.expect_error(format('select public.use_lineup_in_match(%L)',v_l->>'id'),'DRAW_STALE');
-- Rascunho com quem saiu não pode ser confirmado.
v_d := pg_temp.draw(v_p, v_gk || (select array_agg(pg_temp.mem(v_p,i)) from generate_series(5,11) i), 'single', 1, 'x');
perform pg_temp.as_user(7); perform public.leave_pelada(v_p);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.confirm_team_draw(%L)',v_d->>'id'),'DRAW_STALE');
-- 15) novo jogador cadastrado depois: fica fora do sorteio confirmado (nada muda).
perform pg_temp.as_user(24); perform public.complete_onboarding('Novato',true,true); perform public.join_pelada(v_tok,'attacker');
perform pg_temp.as_user(1);
execute 'reset role';
perform pg_temp.assert(not exists(select 1 from public.planned_lineup_players where membership_id=pg_temp.mem(v_p,24)),
 'novato não entra em sorteio já confirmado');
perform set_config('role','authenticated',true);
-- 16) alteração de posição depois do sorteio: sinalizada.
v_sel := v_gk[1:2] || (select array_agg(pg_temp.mem(v_p,i)) from generate_series(13,20) i);
v_d := pg_temp.draw(v_p, v_sel, 'single', 1, 'pos');
perform public.confirm_team_draw((v_d->>'id')::uuid);
perform pg_temp.as_user(14); perform public.set_my_position(v_p,'attacker');
perform pg_temp.as_user(1);
perform pg_temp.assert(((select x from jsonb_array_elements(public.get_team_draws(v_p)) x where x->>'id'=v_d->>'id')->'warnings') ? 'POSITION_CHANGED',
 'mudança de posição sinalizada no sorteio');
-- 17) cancelamento: sorteio e escalações canceladas.
perform public.cancel_team_draw((v_d->>'id')::uuid);
execute 'reset role';
perform pg_temp.assert(not exists(select 1 from public.planned_lineups where draw_id=(v_d->>'id')::uuid and status='active'),'cancelado');
perform set_config('role','authenticated',true);

-- 19) jogador comum não sorteia; assistente sorteia.
perform pg_temp.as_user(9);
perform pg_temp.expect_error(format('select pg_temp.legacy(%L,%L,%L,1)',v_p,v_sel,'single'),'STAFF_REQUIRED');
perform pg_temp.expect_error(format('select public.create_team_draw(%L,%L,%L,1)',v_p,v_sel,'single'),'DRAW_ALGORITHM_SUPERSEDED');
perform pg_temp.as_user(5);
perform pg_temp.assert(pg_temp.legacy(v_p, v_sel, 'single', 1) ? 'id','assistente pode sortear');
-- 20) manipulação direta da API.
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select pg_temp.legacy(%L,%L,%L,1)',v_p,v_sel||v_sel[1],'single'),'DRAW_DUPLICATE_PLAYER');
perform pg_temp.expect_error(format('select pg_temp.legacy(%L,%L,%L,1)',v_p,array[v_sel[1],pg_temp.uid(1)],'single'),'DRAW_INVALID_PLAYER');
perform pg_temp.expect_error(format('select pg_temp.legacy(%L,%L,%L,1)',v_p,v_sel[1:1],'single'),'DRAW_TOO_FEW_PLAYERS');
perform pg_temp.expect_error(format('select pg_temp.legacy(%L,%L,%L,13)',v_p,v_sel,'independent'),'DRAW_INVALID_ROUNDS');
perform pg_temp.expect_error(format('select pg_temp.legacy(%L,%L,%L,1)',v_p,v_sel,'tres_times'),'DRAW_INVALID_MODE');
perform pg_temp.expect_error('insert into public.team_draws(pelada_id,mode,rounds_total,seed,input) values(gen_random_uuid(),''single'',1,''x'',''[]'')','permission denied');
perform pg_temp.expect_error('select * from public.team_draw_players','permission denied');
perform pg_temp.expect_error('select private.draw_split(array[''a'',''b''],array[1,2]::numeric[],''x'')','permission denied');
-- Sorteio adulterado no banco é recusado na confirmação.
v_d := pg_temp.draw(v_p, v_sel, 'single', 1, 'adulterado');
execute 'reset role';
update public.team_draw_players set team='A' where draw_id=(v_d->>'id')::uuid;
perform set_config('role','authenticated',true);
perform pg_temp.expect_error(format('select public.confirm_team_draw(%L)',v_d->>'id'),'DRAW_UNBALANCED');
-- Quem não é da pelada não lê sorteios nem escalações.
perform pg_temp.as_user(30);
perform pg_temp.expect_error(format('select public.get_team_draws(%L)',v_p),'PELADA_NOT_FOUND');
perform pg_temp.expect_error(format('select public.get_lineups(%L)',v_p),'PELADA_NOT_FOUND');

-- Escalação manual: alerta de desequilíbrio é do app; o banco aceita (11.12), só exige times válidos.
perform pg_temp.as_user(1);
v_l := public.save_lineup(v_p, null, 'Quinta', array[v_gk[1],v_gk[2]], array[pg_temp.mem(v_p,13)]);
perform pg_temp.assert(v_l->>'source'='manual' and jsonb_array_length(v_l->'players')=3,'manual com dois goleiros no mesmo time é permitida');
perform pg_temp.expect_error(format('select public.save_lineup(%L,null,%L,%L,%L)',v_p,'x',array[v_gk[1]],array[v_gk[1]]),'LINEUP_INVALID');
perform pg_temp.as_user(9);
perform pg_temp.expect_error(format('select public.save_lineup(%L,null,%L,%L,%L)',v_p,'x',array[v_gk[1]],array[v_gk[2]]),'STAFF_REQUIRED');
perform pg_temp.assert(jsonb_array_length(public.get_lineups(v_p)) >= 1,'jogador vê as escalações');

-- Escalação depois do jogo (grátis) e Duelo.
perform pg_temp.as_user(1);
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(9);
-- rascunho não aparece para jogador
perform pg_temp.expect_error(format('select public.get_match_lineup(%L)',v_x),'MATCH_NOT_FOUND');
execute 'reset role';
update public.matches set status='finalized', finalized_at=now() where id=v_x;
perform set_config('role','authenticated',true);
v_r := public.get_match_lineup(v_x);
perform pg_temp.assert(jsonb_array_length(v_r->'players')=16 and v_r->>'team_a_name'='Time A'
 and (select count(*) from jsonb_array_elements(v_r->'players') x where x->>'team'='A')=8,'escalação pós-jogo no Básico (sem Premium)');
-- 18) Premium expirado: sem sorteio, sem Duelo, sem escalação antecipada.
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select pg_temp.legacy(%L,%L,%L,1)',v_p,v_sel,'single'),'PREMIUM_REQUIRED');
perform pg_temp.expect_error(format('select public.save_lineup(%L,null,%L,%L,%L)',v_p,'x',array[v_gk[1]],array[v_gk[2]]),'PREMIUM_REQUIRED');
perform pg_temp.expect_error(format('select public.get_player_duel(%L,%L,%L)',v_s,v_gk[1],v_gk[2]),'PREMIUM_REQUIRED');
execute 'reset role';
update private.app_config set value='true'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
v_r := public.get_player_duel(v_s, v_gk[1], pg_temp.mem(v_p,13));
perform pg_temp.assert(v_r->'a'->>'name'='Jogador 01' and (v_r->'b'->'card'->>'overall') is not null
 and (v_r->'a'->'stats'->>'avg_rating') is null,'Duelo com dados oficiais, sem inventar média');
perform pg_temp.expect_error(format('select public.get_player_duel(%L,%L,%L)',v_s,v_gk[1],v_gk[1]),'DUEL_SAME_PLAYER');
perform pg_temp.expect_error(format('select public.get_player_duel(%L,%L,%L)',v_s,v_gk[1],gen_random_uuid()),'DUEL_INVALID_PLAYER');
perform pg_temp.as_user(30);
perform pg_temp.expect_error(format('select public.get_player_duel(%L,%L,%L)',v_s,v_gk[1],v_gk[2]),'SEASON_NOT_FOUND');

-- ===== Teste de propriedade: 1.500 combinações aleatórias de posições e quantidades =====
execute 'reset role';
for v_trial in 1..1500 loop
 v_n := 2 + floor(random()*29)::int;
 v_pos := array(select (array['goalkeeper','defender','midfielder','attacker',null])[1 + floor(random()*(case when v_trial % 3 = 0 then 5 else 4 end))::int]
                from generate_series(1,v_n));
 v_ov := array(select round((random()*60 + 30)::numeric, 2) from generate_series(1,v_n));
 v_t := private.draw_split(v_pos, v_ov, 'prop-'||v_trial, 8);
 if not (cardinality(v_t)=v_n and private.draw_balanced(v_pos, v_t)) then v_fail := v_fail + 1; end if;
 -- exatamente dois goleiros: um em cada time
 if (select count(*) from unnest(v_pos) p where p='goalkeeper')=2 then
  v_gk2 := v_gk2 + 1;
  if (select count(*) from unnest(v_pos, v_t) x(p,t) where p='goalkeeper' and t='A') <> 1 then v_fail := v_fail + 1; end if;
 end if;
end loop;
perform pg_temp.assert(v_fail=0, 'propriedade violada em '||v_fail||' de 1500 sorteios');
perform pg_temp.assert(v_gk2 > 50, 'casos com 2 goleiros cobertos: '||v_gk2);
-- Conferência independente da própria função de validação (casos inválidos são reprovados).
perform pg_temp.assert(not private.draw_balanced(array['defender','defender','defender','defender','midfielder','midfielder'],
 array['A','A','A','B','B','B']),'4 zagueiros 3 x 1 é inválido mesmo com totais iguais');
perform pg_temp.assert(not private.draw_balanced(array['goalkeeper','goalkeeper','defender','defender'],array['A','A','B','B']),
 'dois goleiros no mesmo time é inválido');

raise exception 'PASS: 032_draws_duel_lineups (propriedade: 1500 sorteios, % com 2 goleiros)', v_gk2;
end $test$;
