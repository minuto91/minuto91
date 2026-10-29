-- V8.6 (migração 064): decisão A (desempate na formação de candidatos) e C (retificação feita pelo admin).
-- Termina SEMPRE com o erro proposital "PASS: 050_v86_decisions_a_c".
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
declare v_a uuid; v_tok text; i int; v_s uuid; m1 uuid; j jsonb;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v86b-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,6) n;
perform set_config('role','authenticated',true);
for i in 1..6 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada C','ATA'); v_tok := public.create_pelada_invite(v_a);
for i in 2..6 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,'MEI'); end loop;
execute 'reset role';
update private.v86_activation set activated_at = '2026-01-01';
for i in 1..3 loop
 m1 := pg_temp.finish(v_a, pg_temp.at(2026,8,i*7), 1, 0,
  '[{"m":1,"team":"A","pos":"midfielder"},{"m":2,"team":"A","pos":"midfielder"},{"m":3,"team":"A","pos":"attacker","g":1},{"m":4,"team":"B","pos":"midfielder"},{"m":5,"team":"B","pos":"midfielder"},{"m":6,"team":"B","pos":"midfielder"}]');
end loop;
select id into v_s from public.seasons where pelada_id = v_a;
insert into public.player_cards(pelada_id,season_id,membership_id,position,finishing,assisting,attendance,winning,peer_rating,
 overall,tier,is_provisional,matches_played,formula_version)
select v_a, v_s, pg_temp.mem(v_a,n),'midfielder',50,50,50,50,50, ov,'ouro',false,3,2
from (values (1,50),(2,90),(3,85),(4,90),(5,70),(6,60)) t(n,ov)
on conflict (season_id, membership_id) do update set overall=excluded.overall, is_provisional=false;
update public.seasons set starts_on='2026-01-01', ends_on='2026-09-30' where id=v_s;
perform private.sync_season_status(v_a);

-- A: 2 e 4 empatam em OVR (90) e partidas (3): mesma data de entrada -> continua bloqueado.
update public.pelada_memberships set joined_at = '2026-01-01' where pelada_id = v_a;
perform pg_temp.assert(private.craque_candidate_set(v_s)->>'blocked' = 'G03_TIE_UNRESOLVED', 'empate total bloqueia');
-- entrada mais antiga de 4 desempata
update public.pelada_memberships set joined_at = '2025-12-01' where id = pg_temp.mem(v_a,4);
perform pg_temp.assert(private.craque_candidate_set(v_s)->>'blocked' is null, 'entrada mais antiga desempata');
perform pg_temp.assert((private.craque_candidate_set(v_s)->'candidates'->0->>'membership_id')::uuid = pg_temp.mem(v_a,4), 'vaga de OVR: 4');
-- mais partidas vem antes da entrada: tira 4 de uma partida -> 2 passa a frente
delete from public.match_participants where membership_id = pg_temp.mem(v_a,4)
 and match_id = (select id from public.matches where pelada_id=v_a order by played_at limit 1);
perform pg_temp.assert((private.craque_candidate_set(v_s)->'candidates'->0->>'membership_id')::uuid = pg_temp.mem(v_a,2), 'mais partidas vence a entrada');
update public.pelada_memberships set joined_at = '2026-01-01' where id = pg_temp.mem(v_a,4);
update public.player_cards set overall = 60 where season_id=v_s and membership_id = pg_temp.mem(v_a,4);

-- C: candidatos {2 (OVR), 3 (artilheiro)}; 2 vence e é publicado; depois 2 perde o OVR publicado.
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform public.open_season_craque_poll(v_s);
for i in 1..6 loop
 perform pg_temp.as_user(i);
 perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a, case when i in (1,4,5) then 2 else 3 end));
end loop;
-- (2 vota 3 e 3 vota 3: com 2 candidatos o voto próprio é permitido) -> 2: 3 votos, 3: 3 votos? ajusta 6 -> 2
perform pg_temp.as_user(6); perform public.cast_season_craque_vote(v_s, pg_temp.mem(v_a,2));
execute 'reset role';
perform pg_temp.expire(v_s); perform private.craque_sync(v_s);
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.rectify_season_craque(%L)', v_s), 'NOTHING_TO_RECTIFY');
perform public.confirm_season_craque(v_s);
execute 'reset role';
perform pg_temp.assert(pg_temp.craque_winner(v_s) = '{2}', 'publicado: 2');
update public.player_cards set is_provisional = true where season_id=v_s and membership_id = pg_temp.mem(v_a,2);
perform private.craque_sync(v_s);
perform pg_temp.assert((select rectification_pending from private.season_craque_polls where season_id=v_s), 'retificação sinalizada');
perform pg_temp.assert(pg_temp.craque_winner(v_s) = '{2}', 'nada muda sem o admin');
perform set_config('role','authenticated',true); perform pg_temp.as_user(3);
perform pg_temp.expect_error(format('select public.rectify_season_craque(%L)', v_s), 'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
j := public.rectify_season_craque(v_s);
execute 'reset role';
perform pg_temp.assert(not (select rectification_pending from private.season_craque_polls where season_id=v_s), 'sinal limpo');
perform pg_temp.assert((j->>'changed')::boolean = ((select winner_membership_id from private.season_craque_polls where season_id=v_s) <> pg_temp.mem(v_a,2)), 'consistência');
perform pg_temp.assert(not (pg_temp.mem(v_a,2) = any(array(select (e->>'membership_id')::uuid from private.season_craque_polls p, jsonb_array_elements(p.candidates) e where p.season_id=v_s))), 'candidatos atualizados');
perform pg_temp.assert(array_length(pg_temp.craque_winner(v_s),1) = 1, 'um único troféu ativo');
perform pg_temp.assert((select count(*) from private.v86_events where kind='rectified') = 1, 'trilha da retificação');
raise exception 'PASS: 050_v86_decisions_a_c';
end $test$;
