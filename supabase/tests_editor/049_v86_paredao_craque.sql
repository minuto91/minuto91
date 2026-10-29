-- V8.6 (migração 063): Paredão do Mês e Craque da Temporada.
-- Cobre PM-01..PM-11, CT-01..CT-13, V01..V30 (sigilo, turnos, quórum, prorrogação, empates, reinício, retificação) e F01..F04 (fail-closed).
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 049_v86_paredao_craque" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99860000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.at(y int, mo int, d int, h int default 20) returns timestamptz language sql as
 $$ select make_timestamptz(y, mo, d, h, 0, 0, 'America/Sao_Paulo') $$;
-- p_rows: [{m, team, pos, g}]
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
   insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,
    objective_rating,final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
   values(p_pelada,v_id,pg_temp.mem(p_pelada,(r->>'m')::int),0,null,5,null,false,coalesce((r->>'g')::int,0),0,0,
    case when a=b then 'draw' when (a>b)=(r->>'team'='A') then 'win' else 'loss' end, r->>'pos',1);
  end loop;
  perform private.after_match_finalized(v_id);
  return v_id;
 end $$;
create function pg_temp.saves(p_match uuid, n int, s int) returns void language plpgsql as
 $$ begin
  insert into public.match_keeper_saves(pelada_id,match_id,participant_id,hard_saves)
  select x.pelada_id, x.match_id, x.id, s from public.match_participants x
  where x.match_id=p_match and x.membership_id=pg_temp.mem((select pelada_id from public.matches where id=p_match), n)
  on conflict (match_id, participant_id) do update set hard_saves=excluded.hard_saves;
 end $$;
create function pg_temp.winners(p_pelada uuid, p_month date, p_type text) returns int[] language sql as
 $$ select coalesce(array_agg(right(pm.user_id::text, 12)::int order by right(pm.user_id::text, 12)::int), '{}')
    from public.awards a join public.pelada_memberships pm on pm.id = a.membership_id
    where a.pelada_id = p_pelada and a.period_month = p_month and a.award_type = p_type and a.status = 'active' $$;
create function pg_temp.craque_winner(p_season uuid) returns int[] language sql as
 $$ select coalesce(array_agg(right(pm.user_id::text, 12)::int), '{}')
    from public.awards a join public.pelada_memberships pm on pm.id = a.membership_id
    where a.season_id = p_season and a.award_type = 'season_craque' and a.status = 'active' $$;
create function pg_temp.st(p_season uuid) returns text language sql as
 $$ select coalesce((select status from private.season_craque_polls where season_id=p_season and status<>'cancelled'), 'none') $$;
create function pg_temp.poll(p_season uuid) returns uuid language sql as
 $$ select id from private.season_craque_polls where season_id=p_season and status<>'cancelled' $$;
-- Vence o relógio do turno corrente (como dono do banco).
create function pg_temp.expire(p_season uuid) returns void language plpgsql as
 $$ begin
  update private.season_craque_polls set
   r1_closes_at = case when status='round1' then now() - interval '1 hour' else r1_closes_at end,
   r2_closes_at = case when status='round2' then now() - interval '1 hour' else r2_closes_at end
  where season_id=p_season and status in ('round1','round2');
 end $$;
create function pg_temp.cands(p_season uuid) returns int[] language sql as
 $$ select coalesce(array_agg(right(pm.user_id::text, 12)::int order by right(pm.user_id::text, 12)::int), '{}')
    from private.season_craque_polls p, jsonb_array_elements(p.candidates) e
    join public.pelada_memberships pm on pm.id=(e->>'membership_id')::uuid
    where p.season_id=p_season and p.status<>'cancelled' $$;

do $test$
declare v_a uuid; v_tok text; i int; v_s uuid; m_a1 uuid; m_a2 uuid; m_a3 uuid; m_j1 uuid; m_j2 uuid; m_jn uuid; j jsonb; v_poll uuid;
 v_ovr numeric; k int;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v86-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,11) n;
perform set_config('role','authenticated',true);
for i in 1..11 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
-- Pelada A: admin 1; GOL oficiais 2 e 3; 4 é meio-campista (goleiro improvisado); 5..9 linha; 10 fica fora de jogo; 11 de outra pelada.
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada A','ATA'); v_tok := public.create_pelada_invite(v_a);
for i in 2..10 loop perform pg_temp.as_user(i);
 perform public.join_pelada(v_tok, case when i in (2,3) then 'GOL' else 'MEI' end); end loop;
execute 'reset role';
update private.v86_activation set activated_at = '2026-01-01';

-- ============================ PAREDÃO DO MÊS ============================
-- Julho: 2 e 3 empatados em tudo (2 partidas no gol, 3 defesas difíceis cada).
m_j1 := pg_temp.finish(v_a, pg_temp.at(2026,7,4), 1, 1,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":5,"team":"A","pos":"midfielder"},{"m":3,"team":"B","pos":"goalkeeper"},{"m":7,"team":"B","pos":"midfielder"}]');
m_j2 := pg_temp.finish(v_a, pg_temp.at(2026,7,11), 0, 0,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":5,"team":"A","pos":"midfielder"},{"m":3,"team":"B","pos":"goalkeeper"},{"m":7,"team":"B","pos":"midfielder"}]');
-- Agosto
m_a1 := pg_temp.finish(v_a, pg_temp.at(2026,8,5), 2, 1,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":4,"team":"A","pos":"midfielder"},{"m":6,"team":"A","pos":"attacker","g":2},{"m":3,"team":"B","pos":"goalkeeper"},{"m":7,"team":"B","pos":"midfielder"},{"m":5,"team":"B","pos":"attacker"}]');
m_a2 := pg_temp.finish(v_a, pg_temp.at(2026,8,12), 1, 0,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":8,"team":"A","pos":"midfielder"},{"m":6,"team":"A","pos":"attacker","g":1},{"m":4,"team":"B","pos":"goalkeeper"},{"m":9,"team":"B","pos":"midfielder"}]');
m_a3 := pg_temp.finish(v_a, pg_temp.at(2026,8,19), 1, 0,
 '[{"m":3,"team":"A","pos":"goalkeeper"},{"m":7,"team":"A","pos":"midfielder"},{"m":5,"team":"A","pos":"attacker","g":1},{"m":4,"team":"B","pos":"goalkeeper"},{"m":1,"team":"B","pos":"midfielder"}]');
perform pg_temp.saves(m_j1,2,3); perform pg_temp.saves(m_j1,3,3); perform pg_temp.saves(m_j2,2,3); perform pg_temp.saves(m_j2,3,3);
perform pg_temp.saves(m_a1,2,6); perform pg_temp.saves(m_a2,2,4); perform pg_temp.saves(m_a1,3,2); perform pg_temp.saves(m_a3,3,3);
perform pg_temp.saves(m_a2,4,9); perform pg_temp.saves(m_a3,4,9); -- 4 é MEI cadastrado: não concorre (PM-03), mesmo com mais defesas
perform private.close_month(v_a, '2026-07-01'); perform private.close_month(v_a, '2026-08-01');

-- PM-08: nada é publicado antes da confirmação; PM-03: 4 não concorre; PM-01/02/04: 2 vence agosto.
perform pg_temp.assert(pg_temp.winners(v_a,'2026-08-01','monthly_goalkeeper') = '{}', 'nada publicado antes do admin');
perform pg_temp.assert((select winners from private.monthly_goalkeeper_results where pelada_id=v_a and period_month='2026-08-01' and version=1)
 = array[pg_temp.mem(v_a,2)], 'Paredão de agosto: goleiro 2 (4 improvisado fora)');
perform pg_temp.assert((select status from private.monthly_goalkeeper_results where pelada_id=v_a and period_month='2026-08-01') = 'awaiting_admin', 'aguardando admin');
-- PM-06: tudo igual em julho -> compartilhado
perform pg_temp.assert((select winners from private.monthly_goalkeeper_results where pelada_id=v_a and period_month='2026-07-01')
 @> array[pg_temp.mem(v_a,2), pg_temp.mem(v_a,3)], 'julho compartilhado 2 e 3');

perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.confirm_monthly_goalkeeper(%L,%L)', v_a, '2026-08-01'), 'ADMIN_REQUIRED');
perform pg_temp.assert((public.get_monthly_goalkeeper(v_a,'2026-08-01')->'pending') = 'null'::jsonb, 'jogador comum não vê proposta pendente');
perform pg_temp.as_user(1);
perform pg_temp.assert(jsonb_array_length(public.get_monthly_goalkeeper(v_a,'2026-08-01')->'pending'->'ranking') >= 3, 'admin vê o ranking');
perform public.confirm_monthly_goalkeeper(v_a, '2026-08-01'); perform public.confirm_monthly_goalkeeper(v_a, '2026-07-01');
perform pg_temp.expect_error(format('select public.confirm_monthly_goalkeeper(%L,%L)', v_a, '2026-08-01'), 'NOTHING_TO_CONFIRM');
execute 'reset role';
perform pg_temp.assert(pg_temp.winners(v_a,'2026-08-01','monthly_goalkeeper') = '{2}', 'agosto publicado: 2');
perform pg_temp.assert(pg_temp.winners(v_a,'2026-07-01','monthly_goalkeeper') = '{2,3}', 'julho publicado compartilhado');
perform pg_temp.assert((select bool_and(is_shared) from public.awards where award_type='monthly_goalkeeper' and period_month='2026-07-01'), 'is_shared');

-- PM-11: reprocessar sem mudança mantém o publicado; correção que muda o resultado abre versão 2 e NÃO troca em silêncio.
perform private.close_month(v_a, '2026-08-01');
perform pg_temp.assert(pg_temp.winners(v_a,'2026-08-01','monthly_goalkeeper') = '{2}', 'reprocesso idêntico mantém o prêmio');
perform pg_temp.assert((select count(*) from private.monthly_goalkeeper_results where period_month='2026-08-01') = 1, 'sem versão nova');
perform pg_temp.saves(m_a1,3,14); perform pg_temp.saves(m_a3,3,14);
perform private.close_month(v_a, '2026-08-01');
perform pg_temp.assert(pg_temp.winners(v_a,'2026-08-01','monthly_goalkeeper') = '{2}', 'publicado continua até o admin confirmar');
perform pg_temp.assert((select status from private.monthly_goalkeeper_results where period_month='2026-08-01' and version=2) = 'awaiting_admin', 'retificação pendente');
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform public.confirm_monthly_goalkeeper(v_a, '2026-08-01');
execute 'reset role';
perform pg_temp.assert(pg_temp.winners(v_a,'2026-08-01','monthly_goalkeeper') = '{3}', 'retificação confirmada: 3');
perform pg_temp.assert((select status from private.monthly_goalkeeper_results where period_month='2026-08-01' and version=1) = 'superseded', 'versão 1 preservada como superseded');
perform pg_temp.assert((select count(*) from private.v86_events where subject='monthly_goalkeeper' and kind='rectification_proposed') = 1, 'trilha de retificação');

-- PM-02/PM-07: menos de 2 partidas no gol = sem prêmio. PM-10: mês anterior à ativação não gera nada.
update private.v86_activation set activated_at = '2026-07-15' where feature='monthly_goalkeeper';
m_jn := pg_temp.finish(v_a, pg_temp.at(2026,6,6), 1, 0,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":5,"team":"A","pos":"midfielder"},{"m":3,"team":"B","pos":"goalkeeper"},{"m":7,"team":"B","pos":"midfielder"}]');
perform private.close_month(v_a, '2026-06-01');
perform pg_temp.assert(not exists(select 1 from private.monthly_goalkeeper_results where period_month='2026-06-01'), 'PM-10: sem retroativo');
update private.v86_activation set activated_at = '2026-01-01' where feature='monthly_goalkeeper';
perform private.close_month(v_a, '2026-06-01');
perform pg_temp.assert((select status from private.monthly_goalkeeper_results where period_month='2026-06-01') = 'no_winner', 'PM-02/07: 1 partida no gol = sem prêmio');

-- ======================= CRAQUE DA TEMPORADA =======================
select id into v_s from public.seasons where pelada_id = v_a;
-- Cartas: OVR publicado (não provisório) para todos; 6 tem 95 mas só 2 de 6 partidas (< 50%).
insert into public.player_cards(pelada_id,season_id,membership_id,position,finishing,assisting,attendance,winning,peer_rating,
 overall,tier,is_provisional,matches_played,formula_version)
select v_a, v_s, pg_temp.mem(v_a,n),'midfielder',50,50,50,50,50, ov,'ouro',false,1,2
from (values (1,50),(2,90),(3,85),(4,80),(5,78),(6,95),(7,70),(8,60),(9,55)) t(n,ov)
on conflict (season_id, membership_id) do update set overall=excluded.overall, is_provisional=false;
-- 2 tem dois Craques da Partida (vaga repetida com a do maior OVR).
insert into public.awards(pelada_id,season_id,membership_id,award_type,match_id)
values (v_a,v_s,pg_temp.mem(v_a,2),'match_craque',m_a1),(v_a,v_s,pg_temp.mem(v_a,2),'match_craque',m_a2);

-- Temporada ainda em curso: não abre.
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.open_season_craque_poll(%L)', v_s), 'SEASON_NOT_CLOSED');
execute 'reset role';
update public.seasons set starts_on='2026-01-01', ends_on='2026-09-30' where id=v_s;
perform private.sync_season_status(v_a);

-- CT-02/05/06/07/09: candidatos = 2 (OVR), 6 (artilheiro, sem 50%), 3 (substituto do Craque repetido, com 50%).
perform pg_temp.assert(private.craque_candidate_set(v_s)->>'blocked' is null, 'sem bloqueio');
perform pg_temp.assert((select array_agg((e->>'slot') order by e->>'slot') from jsonb_array_elements(private.craque_candidate_set(v_s)->'candidates') e)
 = array['craque','goals','ovr'], 'três vagas');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.open_season_craque_poll(%L)', v_s), 'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
perform pg_temp.assert((public.get_season_craque(v_s)->>'can_open')::boolean, 'admin pode abrir');
perform public.open_season_craque_poll(v_s);
perform pg_temp.expect_error(format('select public.open_season_craque_poll(%L)', v_s), 'POLL_ALREADY_EXISTS');
execute 'reset role';
perform pg_temp.assert(pg_temp.cands(v_s) = '{2,3,6}', 'candidatos 2, 3, 6');
perform pg_temp.assert((select count(*) from private.season_craque_electors where round=1) = 9, 'V01/V17: 9 eleitores congelados (10 e 11 não jogaram)');
perform pg_temp.assert((select r1_closes_at - r1_opens_at from private.season_craque_polls where season_id=v_s) = interval '72 hours', 'V06: 72h');

-- V02/V24/V30 e validações do voto.
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.cast_season_craque_vote(%L,%L)', v_s, pg_temp.mem(v_a,2)), 'SELF_VOTE_NOT_ALLOWED');
perform pg_temp.expect_error(format('select public.cast_season_craque_vote(%L,%L)', v_s, pg_temp.mem(v_a,5)), 'INVALID_CANDIDATE');
perform pg_temp.as_user(10);
perform pg_temp.expect_error(format('select public.cast_season_craque_vote(%L,%L)', v_s, pg_temp.mem(v_a,2)), 'NOT_ELIGIBLE_VOTER');
perform pg_temp.as_user(11);
perform pg_temp.expect_error(format('select public.cast_season_craque_vote(%L,%L)', v_s, pg_temp.mem(v_a,2)), 'SEASON_NOT_FOUND');
-- V07: voto substituível. 1 vota 3 depois 2; V08: o admin vota em segredo como os demais.
perform pg_temp.as_user(1); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,3)); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
perform pg_temp.assert((public.get_season_craque(v_s)->>'my_vote')::uuid = pg_temp.mem(v_a,2), 'o eleitor vê só o próprio voto');
-- Sigilo: nem mesmo o admin lê as urnas; sem parciais (V10).
perform pg_temp.expect_error('select * from private.season_craque_ballots', 'permission denied');
perform pg_temp.assert(public.get_season_craque(v_s)->'tally1' = 'null'::jsonb and public.get_season_craque(v_s)->'winner_membership_id' = 'null'::jsonb, 'sem parciais');
perform pg_temp.assert(position(pg_temp.mem(v_a,3)::text in (public.get_season_craque(v_s)->>'my_vote')) = 0, 'resposta não vaza outros votos');
-- Restante: 2->{2:1 já}, queremos 3x3x3. Votos 1:2 (feito), 4:2, 5:2 ; 7:6, 8:6, 9:6 ; 2:3, 3:6, 6:3
perform pg_temp.as_user(4); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
perform pg_temp.as_user(5); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,3));
perform pg_temp.as_user(7); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(8); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(9); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(2); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,3));
perform pg_temp.as_user(3); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
perform pg_temp.as_user(6); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,3));
execute 'reset role';
-- V04/V16: empate triplo (2:3, 3:3, 6:3) -> 2º turno só entre os três; eleitores do 2º = 9 - 3 = 6; V11: 24h.
perform pg_temp.expire(v_s);
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
j := public.get_season_craque(v_s);
perform pg_temp.assert(j->>'status' = 'round2' and (j->>'round')::int = 2, 'segundo turno aberto');
perform pg_temp.assert((j->>'i_am_elector')::boolean, 'admin (não finalista) vota no 2º turno');
execute 'reset role';
perform pg_temp.assert((select count(*) from private.season_craque_electors where round=2) = 6, 'V16: finalistas fora do 2º turno');
perform pg_temp.assert((select r2_closes_at - r2_opens_at from private.season_craque_polls where season_id=v_s) = interval '24 hours', 'V11');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.cast_season_craque_vote(%L,%L)', v_s, pg_temp.mem(v_a,3)), 'NOT_ELIGIBLE_VOTER'); -- finalista
perform pg_temp.as_user(1); perform pg_temp.expect_error(format('select public.cast_season_craque_vote(%L,%L)', v_s, pg_temp.mem(v_a,5)), 'INVALID_CANDIDATE');
-- 2º turno: 6 recebe 3, 2 recebe 2, 3 recebe 1 (não é preciso ter votado antes).
perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
perform pg_temp.as_user(4); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(5); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(7); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(8); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
perform pg_temp.as_user(9); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,3));
execute 'reset role';
perform pg_temp.expire(v_s);
perform set_config('role','authenticated',true); perform pg_temp.as_user(4);
j := public.get_season_craque(v_s);
perform pg_temp.assert(j->>'status' = 'awaiting_admin', 'aguardando admin');
perform pg_temp.assert(j->'tally2' = 'null'::jsonb and j->'winner_membership_id' = 'null'::jsonb, 'V10/V13: nada visível antes da publicação');
perform pg_temp.expect_error(format('select public.confirm_season_craque(%L)', v_s), 'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('select public.cast_season_craque_vote(%L,%L)', v_s, pg_temp.mem(v_a,6)), 'VOTING_NOT_OPEN');
perform pg_temp.as_user(1);
perform pg_temp.assert((public.get_season_craque(v_s)->>'winner_membership_id')::uuid = pg_temp.mem(v_a,6), 'admin vê o vencedor: 6');
perform pg_temp.assert(public.get_season_craque(v_s)->>'decided_by' = 'votes', 'decidido por votos');
perform public.confirm_season_craque(v_s);
perform pg_temp.expect_error(format('select public.confirm_season_craque(%L)', v_s), 'NOTHING_TO_CONFIRM');
execute 'reset role';
perform pg_temp.assert(pg_temp.craque_winner(v_s) = '{6}', 'Craque da Temporada: 6 (ex: CT-01 por votação)');
-- Sala de Troféus
perform set_config('role','authenticated',true); perform pg_temp.as_user(6);
perform pg_temp.assert((public.get_player_career_summary(pg_temp.uid(6))->'trophies'->>'season_craque')::int = 1, 'Sala de Troféus: season_craque');
perform pg_temp.assert(jsonb_array_length(public.get_trophy_history(pg_temp.uid(6),'season_craque')->'items') = 1, 'histórico do troféu');
perform pg_temp.as_user(3);
perform pg_temp.assert((public.get_player_career_summary(pg_temp.uid(3))->'trophies'->>'monthly_goalkeeper')::int = 2, 'Paredão na Sala de Troféus (julho + agosto)');
execute 'reset role';

-- V19: correção depois da publicação não muda nada em silêncio; apenas sinaliza retificação.
update public.player_cards set is_provisional=true where season_id=v_s and membership_id=pg_temp.mem(v_a,3);
perform private.craque_sync(v_s);
perform pg_temp.assert(pg_temp.craque_winner(v_s) = '{6}', 'prêmio publicado intacto');
perform pg_temp.assert((select rectification_pending from private.season_craque_polls where season_id=v_s), 'V19: retificação sinalizada');
update public.player_cards set is_provisional=false where season_id=v_s and membership_id=pg_temp.mem(v_a,3);

-- ---- Recomeço do zero para os demais cenários (como dono do banco) ----
delete from public.awards where award_type='season_craque';
delete from private.season_craque_polls where season_id=v_s;

-- V18/V25: correção que muda candidatos durante a votação cancela e reinicia desde o 1º turno.
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform public.open_season_craque_poll(v_s);
perform pg_temp.as_user(4); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
execute 'reset role';
update public.player_cards set is_provisional=true where season_id=v_s and membership_id=pg_temp.mem(v_a,3); -- substituto 3 perde o OVR publicado -> entra 4
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
j := public.get_season_craque(v_s);
execute 'reset role';
perform pg_temp.assert(j->>'status' = 'awaiting_open' and (j->>'cycle')::int = 2, 'V25: novo ciclo aguardando abertura do admin');
perform pg_temp.assert(not exists(select 1 from private.season_craque_ballots), 'votos do ciclo invalidado descartados');
perform pg_temp.assert((select count(*) from private.season_craque_polls where season_id=v_s and status='cancelled') = 1, 'ciclo antigo preservado como cancelado');
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform public.open_season_craque_poll(v_s);
execute 'reset role';
perform pg_temp.assert(pg_temp.cands(v_s) = '{2,4,6}', 'candidatos corrigidos: 2, 4, 6');
update public.player_cards set is_provisional=false where season_id=v_s and membership_id=pg_temp.mem(v_a,3);
perform private.craque_sync(v_s);
perform pg_temp.assert(pg_temp.st(v_s) = 'awaiting_open', 'nova correção reinicia de novo');
delete from private.season_craque_polls where season_id=v_s;

-- V09/V14/V15/V26: sem quórum -> prorroga uma vez (24h) e depois não concede. 9 eleitores -> quórum 5; 1 voto.
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform public.open_season_craque_poll(v_s);
perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
execute 'reset role';
perform pg_temp.expire(v_s); perform private.craque_sync(v_s);
perform pg_temp.assert(pg_temp.st(v_s) = 'round1' and (select r1_extended from private.season_craque_polls where season_id=v_s), 'prorrogou uma vez');
perform pg_temp.assert((select r1_closes_at > now() + interval '22 hours' from private.season_craque_polls where season_id=v_s), '+24h');
perform pg_temp.expire(v_s); perform private.craque_sync(v_s);
perform pg_temp.assert(pg_temp.st(v_s) = 'no_winner' and (select no_winner_reason from private.season_craque_polls where season_id=v_s) = 'sem_quorum', 'sem quórum: não concede');
delete from private.season_craque_polls where season_id=v_s;

-- Quórum exato: 5 de 9 vale (ceil). Vencedor direto no 1º turno: 2 com 3 votos x 6 com 1 x 3 com 1.
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform public.open_season_craque_poll(v_s);
perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
perform pg_temp.as_user(4); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
perform pg_temp.as_user(5); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
perform pg_temp.as_user(7); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(8); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,3));
execute 'reset role';
perform pg_temp.expire(v_s); perform private.craque_sync(v_s);
perform pg_temp.assert(pg_temp.st(v_s) = 'awaiting_admin' and (select winner_membership_id from private.season_craque_polls where season_id=v_s) = pg_temp.mem(v_a,2), 'quórum 5/9 vale; 2 vence');
delete from private.season_craque_polls where season_id=v_s;

-- V12: empate no 2º turno -> maior OVR. Empate 2x2 no 1º entre 2 e 6 (+1 em 3): finalistas 2 e 6; eleitores 2º = 9-2 = 7.
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform public.open_season_craque_poll(v_s);
perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
perform pg_temp.as_user(4); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
perform pg_temp.as_user(5); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(7); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(8); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,3));
execute 'reset role';
perform pg_temp.expire(v_s); perform private.craque_sync(v_s);
perform pg_temp.assert(pg_temp.st(v_s) = 'round2' and (select count(*) from private.season_craque_electors where round=2) = 7, '2º turno com 7 eleitores');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
perform pg_temp.as_user(4); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(5); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
perform pg_temp.as_user(7); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(3); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2)); -- 3 é candidato não finalista: pode votar (V16)
perform pg_temp.as_user(8); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(8); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2)); -- altera o voto
execute 'reset role';
-- 2: 1,5,3,8 = 4 ; 6: 4,7 = 2  -> vence 2 por voto; para empatar mudo 5 e 3 (voto) -> 2x? Ajusto: 3 passa para 6 e 1 fica em 2.
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(8); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
execute 'reset role';
-- agora 2: 1,5 = 2 ; 6: 4,7,3,8 = 4 -> 6 venceria; para forçar empate 3x3: 8 -> 2? (2: 1,5,8 = 3 ; 6: 4,7,3 = 3)
perform set_config('role','authenticated',true); perform pg_temp.as_user(8); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
execute 'reset role';
perform pg_temp.expire(v_s); perform private.craque_sync(v_s);
perform pg_temp.assert(pg_temp.st(v_s) = 'awaiting_admin' and (select decided_by from private.season_craque_polls where season_id=v_s) = 'tiebreak'
 and (select winner_membership_id from private.season_craque_polls where season_id=v_s) = pg_temp.mem(v_a,6), 'V12: empate 3x3 no 2º turno -> maior OVR (6, 95)');
perform pg_temp.assert((select tiebreak_trace->'trace'->0->>'step' from private.season_craque_polls where season_id=v_s) = 'ovr', 'trilha do desempate');
delete from private.season_craque_polls where season_id=v_s;

-- V29: ninguém habilitado no 2º turno -> desempate direto (sem exigir votação impossível).
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform public.open_season_craque_poll(v_s);
execute 'reset role';
delete from private.season_craque_electors where round=1 and membership_id not in (pg_temp.mem(v_a,2), pg_temp.mem(v_a,6));
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,6));
perform pg_temp.as_user(6); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
execute 'reset role';
perform pg_temp.expire(v_s); perform private.craque_sync(v_s);
perform pg_temp.assert(pg_temp.st(v_s) = 'awaiting_admin' and (select decided_by from private.season_craque_polls where season_id=v_s) = 'tiebreak'
 and (select count(*) from private.season_craque_electors where round=2) = 0, 'V29: desempate direto (sem 2º turno)');
delete from private.season_craque_polls where season_id=v_s;

-- ===== Desempate (Seção D / F04) =====
-- OVR decide; com OVR igual, Craques da Partida; com tudo igual, BLOQUEIA (ordem dos atributos pendente, F04=A): sem sorteio e sem admin.
perform pg_temp.assert((private.craque_tiebreak(v_s, array[pg_temp.mem(v_a,2), pg_temp.mem(v_a,3)])->>'winner')::uuid = pg_temp.mem(v_a,2), 'OVR 90 > 85');
update public.player_cards set overall = 80 where season_id=v_s and membership_id in (pg_temp.mem(v_a,3), pg_temp.mem(v_a,4));
-- 3 e 4 com OVR 80: partidas 4 x 3 (passo 3) desempata para 3, sem Craques da Partida
perform pg_temp.assert(private.craque_tiebreak(v_s, array[pg_temp.mem(v_a,3), pg_temp.mem(v_a,4)])->>'winner' = pg_temp.mem(v_a,3)::text, 'passo 3 (partidas) decide');
perform pg_temp.assert((private.craque_tiebreak(v_s, array[pg_temp.mem(v_a,3), pg_temp.mem(v_a,4)])->'trace'->0->>'step') = 'ovr', 'ordem dos passos começa em OVR');
update public.player_cards set overall = 70 where season_id=v_s and membership_id in (pg_temp.mem(v_a,8), pg_temp.mem(v_a,9)); -- 8 e 9: 1 partida cada, 0 gols
perform pg_temp.assert((private.craque_tiebreak(v_s, array[pg_temp.mem(v_a,8), pg_temp.mem(v_a,9)])->>'blocked')::boolean, 'F04: empate total bloqueia (fail-closed)');
perform pg_temp.assert(private.craque_tiebreak(v_s, array[pg_temp.mem(v_a,8), pg_temp.mem(v_a,9)])->>'blocked_reason' = 'F04_ATTRIBUTE_ORDER_PENDING', 'motivo registrado');

-- ===== Formação de candidatos: G03 (empate de OVR sem desempate aprovado) bloqueia =====
update public.player_cards set overall = 90 where season_id=v_s and membership_id = pg_temp.mem(v_a,3);
perform pg_temp.assert(private.craque_candidate_set(v_s)->>'blocked' = 'G03_TIE_UNRESOLVED', 'G03: dois com o maior OVR bloqueia');
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.open_season_craque_poll(%L)', v_s), 'CANDIDATE_TIE_UNRESOLVED');
execute 'reset role';
update public.player_cards set overall = 85 where season_id=v_s and membership_id = pg_temp.mem(v_a,3);

-- ===== CT-08/CT-11: OVR publicado obrigatório; 2 candidatos votam com voto próprio no 1º turno; 1 candidato = sem prêmio =====
update public.player_cards set is_provisional = true where season_id=v_s and membership_id not in (pg_temp.mem(v_a,2), pg_temp.mem(v_a,6));
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform public.open_season_craque_poll(v_s);
execute 'reset role';
perform pg_temp.assert(pg_temp.cands(v_s) = '{2,6}', 'CT-11: só dois candidatos distintos elegíveis');
perform set_config('role','authenticated',true); perform pg_temp.as_user(2);
perform pg_temp.as_user(2); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2)); -- V24/V30: voto próprio permitido
execute 'reset role';
delete from private.season_craque_polls where season_id=v_s;
update public.player_cards set is_provisional = true where season_id=v_s and membership_id = pg_temp.mem(v_a,6);
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
j := public.open_season_craque_poll(v_s);
execute 'reset role';
perform pg_temp.assert(j->>'status' = 'no_winner' and (select no_winner_reason from private.season_craque_polls where season_id=v_s) = 'candidato_unico', 'CT-11: 1 candidato não premia');

-- Pelada de outra pessoa não acessa a temporada (isolamento).
perform set_config('role','authenticated',true); perform pg_temp.as_user(11);
perform pg_temp.expect_error(format('select public.get_season_craque(%L)', v_s), 'SEASON_NOT_FOUND');
perform pg_temp.expect_error(format('select public.get_monthly_goalkeeper(%L,%L)', v_a, '2026-08-01'), 'PELADA_NOT_FOUND');
execute 'reset role';

raise exception 'PASS: 049_v86_paredao_craque';
end $test$;
