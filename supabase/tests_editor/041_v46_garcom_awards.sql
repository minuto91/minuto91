-- V4.6 (migração 049): Garçom da Partida, Garçom do Mês e cor dos times.
--  1) Garçom da Partida: mínimo 1 assistência, empate premia todos, sem assistência sem prêmio, correção reprocessa,
--     rodar de novo não muda nada (idempotente), uma pelada não mexe na outra.
--  2) Garçom do Mês: mínimo 2, data da partida no fuso da pelada, desempates (total, média exata, partidas com
--     assistência, todos), top_assist não é mais concedido, reprocessamento recria o mesmo resultado.
--  3) Sala de Troféus com os cinco troféus; histórico do Garçom.
--  4) Cor dos times: só admin/assistente, paleta fixa, cores diferentes, isolamento.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 041_v46_garcom_awards".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99460000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.mem(p_pelada uuid, n int) returns uuid language sql as
 $$ select id from public.pelada_memberships where pelada_id=p_pelada and user_id=pg_temp.uid(n) $$;
-- Partida finalizada (como dono do banco), como no teste 038. p_rows: [{m, team, pos, g, a}].
create function pg_temp.finish(p_pelada uuid, p_at timestamptz, a int, b int, p_rows jsonb) returns uuid language plpgsql as
 $$ declare v_id uuid; r jsonb; v_part uuid; begin
  insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
  values(p_pelada,private.season_for_date(p_pelada,private.pelada_local_date(p_pelada,p_at)),p_at,'finalized',a,b,now())
  returning id into v_id;
  for r in select * from jsonb_array_elements(p_rows) loop
   insert into public.match_participants(pelada_id,match_id,membership_id,team,primary_position)
   values(p_pelada,v_id,pg_temp.mem(p_pelada,(r->>'m')::int),r->>'team',r->>'pos') returning id into v_part;
   if coalesce((r->>'g')::int,0) > 0 then insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
    values(p_pelada,v_id,v_part,r->>'team','goal',(r->>'g')::int); end if;
   if coalesce((r->>'a')::int,0) > 0 then insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
    values(p_pelada,v_id,v_part,r->>'team','assist',(r->>'a')::int); end if;
   insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,
    objective_rating,final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
   values(p_pelada,v_id,pg_temp.mem(p_pelada,(r->>'m')::int),0,null,5,null,false,coalesce((r->>'g')::int,0),coalesce((r->>'a')::int,0),0,
    case when a=b then 'draw' when (a>b)=(r->>'team'='A') then 'win' else 'loss' end, r->>'pos',1);
  end loop;
  perform private.after_match_finalized(v_id);
  return v_id;
 end $$;
create function pg_temp.at(y int, mo int, d int, h int default 20, mi int default 0) returns timestamptz language sql as
 $$ select make_timestamptz(y, mo, d, h, mi, 0, 'America/Sao_Paulo') $$;
-- Ganhadores ativos (números dos usuários) de um prêmio de partida ou de mês.
create function pg_temp.match_winners(p_match uuid) returns int[] language sql as
 $$ select coalesce(array_agg(right(pm.user_id::text, 12)::int order by right(pm.user_id::text, 12)::int), '{}')
    from public.awards a join public.pelada_memberships pm on pm.id = a.membership_id
    where a.match_id = p_match and a.award_type = 'match_garcom' and a.status = 'active' $$;
create function pg_temp.month_winners(p_pelada uuid, p_month date) returns int[] language sql as
 $$ select coalesce(array_agg(right(pm.user_id::text, 12)::int order by right(pm.user_id::text, 12)::int), '{}')
    from public.awards a join public.pelada_memberships pm on pm.id = a.membership_id
    where a.pelada_id = p_pelada and a.period_month = p_month and a.award_type = 'monthly_garcom' and a.status = 'active' $$;

do $test$
declare v_a uuid; v_b uuid; v_tok text; v_tok_b text; i int; v_m1 uuid; v_m2 uuid; v_mb uuid; v_x uuid; v_rows int; v_notif int;
 s jsonb; h jsonb;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v46g'||n||'@example.invalid','',now(),now(),now() from generate_series(1,8) n;
perform set_config('role','authenticated',true);
for i in 1..8 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
-- A: admin 1, jogadores 2..6. B: admin 7; o jogador 2 também joga em B.
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada A','ATA'); v_tok := public.create_pelada_invite(v_a);
for i in 2..6 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,'MEI'); end loop;
perform pg_temp.as_user(7); v_b := public.create_pelada('Pelada B','GOL'); v_tok_b := public.create_pelada_invite(v_b);
perform pg_temp.as_user(2); perform public.join_pelada(v_tok_b,'CA');
execute 'reset role';

-- ===== 1) Garçom da Partida =====
-- Empate em 2 assistências: os dois recebem, compartilhado; quem deu 1 não recebe.
v_m1 := pg_temp.finish(v_a, pg_temp.at(2026,8,5), 3, 2,
 '[{"m":2,"team":"A","pos":"midfielder","a":2},{"m":3,"team":"A","pos":"midfielder","a":2},{"m":4,"team":"B","pos":"midfielder","a":1},{"m":5,"team":"B","pos":"midfielder","a":1}]');
perform pg_temp.assert(pg_temp.match_winners(v_m1) = array[2,3], 'Garçom da Partida: empate premia todos os líderes');
perform pg_temp.assert((select bool_and(is_shared) from public.awards where match_id=v_m1 and award_type='match_garcom' and status='active'),
 'empate marcado como compartilhado');
-- Sem assistência: sem prêmio.
v_m2 := pg_temp.finish(v_a, pg_temp.at(2026,8,12), 1, 0, '[{"m":2,"team":"A","pos":"midfielder","g":1},{"m":3,"team":"B","pos":"midfielder"}]');
perform pg_temp.assert(pg_temp.match_winners(v_m2) = '{}', 'ninguém com assistência: sem Garçom da Partida');
-- Idempotente: rodar de novo não grava nada nem avisa de novo.
select count(*) into v_rows from public.awards where award_type in ('match_garcom','monthly_garcom');
select count(*) into v_notif from public.notification_events;
perform private.grant_match_garcom(v_m1); perform private.grant_match_garcom(v_m2);
perform pg_temp.assert((select count(*) from public.awards where award_type in ('match_garcom','monthly_garcom')) = v_rows
 and (select count(*) from public.notification_events) = v_notif, 'reprocessar sem mudança não grava nem notifica');
-- Correção dos dados: o 4 passa a ter 3 assistências -> só ele, sem compartilhar; os antigos ficam revogados (histórico).
update public.match_player_results set assists = 3 where match_id = v_m1 and membership_id = pg_temp.mem(v_a,4);
perform private.grant_match_garcom(v_m1);
perform pg_temp.assert(pg_temp.match_winners(v_m1) = array[4], 'correção reprocessa o Garçom da Partida');
perform pg_temp.assert((select not is_shared from public.awards where match_id=v_m1 and award_type='match_garcom' and status='active'), 'ganhador único não é compartilhado');
perform pg_temp.assert((select count(*) from public.awards where match_id=v_m1 and award_type='match_garcom' and status='revoked') = 2, 'revogados ficam no histórico');
update public.match_player_results set assists = 1 where match_id = v_m1 and membership_id = pg_temp.mem(v_a,4);
perform private.grant_match_garcom(v_m1);
perform pg_temp.assert(pg_temp.match_winners(v_m1) = array[2,3], 'voltar o dado volta o resultado');
perform pg_temp.assert((select count(*) from public.awards where match_id=v_m1 and award_type='match_garcom' and status='active') = 2, 'sem duplicidade');
-- Isolamento: o jogador 2 dá 5 assistências na pelada B; os prêmios de A não mudam e o de B fica em B.
v_mb := pg_temp.finish(v_b, pg_temp.at(2026,8,5), 1, 0, '[{"m":2,"team":"A","pos":"attacker","a":5},{"m":7,"team":"B","pos":"goalkeeper"}]');
perform pg_temp.assert(pg_temp.match_winners(v_mb) = array[2] and (select pelada_id from public.awards where match_id=v_mb and award_type='match_garcom') = v_b
 and (select membership_id from public.awards where match_id=v_mb and award_type='match_garcom') = pg_temp.mem(v_b,2), 'Garçom da Partida independente por pelada');
perform pg_temp.assert(pg_temp.match_winners(v_m1) = array[2,3], 'outra pelada não mexe nos prêmios de A');
-- Partida que deixa de ser oficial (anulada): o prêmio sai.
update public.matches set status='annulled' where id = v_m2;
perform private.grant_match_garcom(v_m1);
v_x := pg_temp.finish(v_a, pg_temp.at(2026,8,14), 1, 0, '[{"m":6,"team":"A","pos":"midfielder","a":1},{"m":3,"team":"B","pos":"midfielder"}]');
update public.matches set status='annulled' where id = v_x;
perform private.grant_match_garcom(v_x);
perform pg_temp.assert(pg_temp.match_winners(v_x) = '{}', 'partida anulada não tem Garçom da Partida');

-- ===== 2) Garçom do Mês (agosto/2026, pelada A) =====
-- Até aqui em agosto (oficiais): v_m1 (2:2, 3:2, 4:1, 5:1), v_m2 anulada, v_x anulada.
perform pg_temp.finish(v_a, pg_temp.at(2026,8,19), 2, 1,
 '[{"m":3,"team":"A","pos":"midfielder","a":1},{"m":5,"team":"A","pos":"midfielder","a":1},{"m":2,"team":"B","pos":"midfielder"}]');
perform pg_temp.finish(v_a, pg_temp.at(2026,8,26), 2, 1,
 '[{"m":5,"team":"A","pos":"midfielder","a":1},{"m":3,"team":"B","pos":"midfielder"}]');
-- Totais: 2 = 2 (2 jogos, 1 com assist.); 3 = 3 (3 jogos, 2 com assist.); 5 = 3 (3 jogos, 3 com assist.).
-- Total empata 3 x 5 com 3 cada; média igual (3 jogos); desempate 3: mais partidas com assistência -> 5.
perform pg_temp.assert(pg_temp.month_winners(v_a, date '2026-08-01') = array[5], 'Garçom do Mês: desempate por partidas com assistência');
perform pg_temp.assert(not exists(select 1 from public.awards where pelada_id=v_a and award_type='top_assist' and status='active'), 'top_assist não é mais concedido');
perform pg_temp.assert(pg_temp.month_winners(v_b, date '2026-08-01') = array[2], 'mês da pelada B independente (5 assistências em 1 jogo)');

-- Setembro: 2 faz 2 assistências em 1 jogo; 3 faz 2 em 2 jogos (mais partidas com assistência, mas média menor) -> 2.
perform pg_temp.finish(v_a, pg_temp.at(2026,9,2), 1, 0, '[{"m":2,"team":"A","pos":"midfielder","a":2},{"m":3,"team":"B","pos":"midfielder","a":1}]');
perform pg_temp.finish(v_a, pg_temp.at(2026,9,9), 1, 0, '[{"m":3,"team":"A","pos":"midfielder","a":1},{"m":4,"team":"B","pos":"midfielder"}]');
perform pg_temp.assert(pg_temp.month_winners(v_a, date '2026-09-01') = array[2], 'Garçom do Mês: média por partida vem antes de partidas com assistência');

-- Julho: empate em tudo -> os dois, compartilhado.
perform pg_temp.finish(v_a, pg_temp.at(2026,7,8), 2, 2, '[{"m":2,"team":"A","pos":"midfielder","a":2},{"m":4,"team":"B","pos":"midfielder","a":2}]');
perform pg_temp.assert(pg_temp.month_winners(v_a, date '2026-07-01') = array[2,4], 'empate persistente premia todos');
perform pg_temp.assert((select bool_and(is_shared) from public.awards where pelada_id=v_a and period_month='2026-07-01' and award_type='monthly_garcom' and status='active'), 'empate do mês compartilhado');

-- Junho: 1 assistência em 10/06 + 1 em 30/06 23h30 de Brasília (já 1º/07 em UTC): conta em junho -> 2 assistências.
perform pg_temp.finish(v_a, pg_temp.at(2026,6,10), 1, 0, '[{"m":6,"team":"A","pos":"midfielder","a":1},{"m":3,"team":"B","pos":"midfielder"}]');
perform pg_temp.assert(pg_temp.month_winners(v_a, date '2026-06-01') = '{}', 'mínimo de 2 assistências no mês');
perform pg_temp.finish(v_a, pg_temp.at(2026,6,30,23,30), 1, 0, '[{"m":6,"team":"A","pos":"midfielder","a":1},{"m":3,"team":"B","pos":"midfielder"}]');
perform pg_temp.assert(pg_temp.month_winners(v_a, date '2026-06-01') = array[6], 'mês pela data da partida no fuso da pelada');
perform pg_temp.assert(pg_temp.month_winners(v_a, date '2026-07-01') = array[2,4], 'partida de 30/06 23h30 não entra em julho');

-- Reprocessamento: idempotente; apagar e recalcular dá o mesmo resultado.
select count(*) into v_rows from public.awards where award_type = 'monthly_garcom';
perform private.grant_monthly_garcom(v_a, date '2026-08-01'); perform private.grant_monthly_garcom(v_a, date '2026-09-15');
perform pg_temp.assert((select count(*) from public.awards where award_type = 'monthly_garcom') = v_rows, 'reprocessar o mês sem mudança não grava nada');
perform private.close_month(v_a, date '2026-08-01');
perform pg_temp.assert(pg_temp.month_winners(v_a, date '2026-08-01') = array[5], 'fechar o mês de novo mantém o ganhador');
perform pg_temp.assert((select count(*) from public.awards where pelada_id=v_a and period_month='2026-08-01' and award_type='monthly_garcom' and status='active') = 1, 'sem duplicidade no mês');
-- Mês que ainda não acabou: nada.
perform private.grant_monthly_garcom(v_a, date_trunc('month', now())::date);
perform pg_temp.assert(pg_temp.month_winners(v_a, date_trunc('month', now())::date) = '{}', 'mês em andamento não tem Garçom do Mês');

-- ===== 3) Sala de Troféus =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
s := public.get_player_career_summary(pg_temp.uid(2));
perform pg_temp.assert(s->'trophies' ?& array['match_craque','monthly_king','bola_murcha','match_garcom','monthly_garcom'], 'cinco troféus na Sala');
perform pg_temp.assert((s->'trophies'->>'match_garcom')::int = (select count(*) from public.awards a join public.pelada_memberships pm on pm.id=a.membership_id
  where pm.user_id=pg_temp.uid(2) and a.award_type='match_garcom' and a.status='active'), 'contagem do Garçom da Partida = prêmios ativos (A e B)');
perform pg_temp.assert((s->'trophies'->>'monthly_garcom')::int = 3, 'Garçom do Mês: julho e setembro em A, agosto em B');
h := public.get_trophy_history(pg_temp.uid(2), 'monthly_garcom');
perform pg_temp.assert(jsonb_array_length(h->'items') = 3 and (h->'items'->0->>'period_month')::date = '2026-09-01', 'histórico do Garçom do Mês, mais novo primeiro');
perform pg_temp.assert(jsonb_array_length(public.get_trophy_history(pg_temp.uid(2), 'match_garcom')->'items') >= 2, 'histórico do Garçom da Partida');

-- ===== 4) Cor dos times =====
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.set_match_team_colors(%L,%L,%L)', v_m1, 'azul', 'laranja'), 'STAFF_REQUIRED');
perform pg_temp.as_user(7);
perform pg_temp.expect_error(format('select public.set_match_team_colors(%L,%L,%L)', v_m1, 'azul', 'laranja'), 'MATCH_NOT_FOUND');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.set_match_team_colors(%L,%L,%L)', v_m1, 'verde-limão', 'azul'), 'INVALID_TEAM_COLOR');
perform pg_temp.expect_error(format('select public.set_match_team_colors(%L,%L,%L)', v_m1, 'azul', 'azul'), 'TEAM_COLORS_EQUAL');
perform pg_temp.expect_error(format('select public.set_match_team_colors(%L,%L,%L)', v_m2, 'azul', 'laranja'), 'MATCH_ANNULLED');
perform public.set_match_team_colors(v_m1, 'azul', 'laranja');
perform pg_temp.assert((select team_a_color = 'azul' and team_b_color = 'laranja' from public.matches where id = v_m1), 'admin define as cores');
perform public.set_match_team_colors(v_m1, null, 'branco');
perform pg_temp.assert((select team_a_color is null and team_b_color = 'branco' from public.matches where id = v_m1), 'cor opcional');
perform pg_temp.as_user(3);
perform pg_temp.assert((select team_b_color from public.matches where id = v_m1) = 'branco', 'jogador da pelada lê as cores');

raise exception 'PASS: 041_v46_garcom_awards';
end $test$;
