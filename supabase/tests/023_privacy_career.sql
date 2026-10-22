-- Privacidade do perfil e da carreira e carreira global (migrações 029 e 030). Rodar SOMENTE em banco local descartável. Tudo em transação com ROLLBACK.
\set ON_ERROR_STOP on
begin;
-- Os resultados das partidas são gravados direto (como a finalização da 013 faria), como no teste 010.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('c2830000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Partida finalizada com resultados prontos. p_rows: [{"m":n,"pos":..,"res":..,"g":..}]
create function pg_temp.finish(p_pelada uuid, p_at timestamptz, p_rows jsonb) returns uuid language plpgsql as
 $$ declare v_id uuid; begin
  insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
  values(p_pelada,private.season_for_date(p_pelada,private.pelada_local_date(p_pelada,p_at)),p_at,'finalized',1,0,now())
  returning id into v_id;
  insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,
   objective_rating,final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
  select p_pelada,v_id,pg_temp.mem(p_pelada,(r->>'m')::int),0,null,5,null,false,coalesce((r->>'g')::int,0),0,0,
   r->>'res',r->>'pos',1
  from jsonb_array_elements(p_rows) r;
  perform private.after_match_finalized(v_id);
  return v_id;
 end $$;
create function pg_temp.award(p_match uuid, n int, p_type text) returns void language sql as
 $$ insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count)
  select m.pelada_id, m.id, m.season_id, pg_temp.mem(m.pelada_id,n), p_type, 3 from public.matches m where m.id=p_match $$;
-- A carreira de n vista pelo usuário atual.
create function pg_temp.career(n int) returns jsonb language sql as
 $$ select public.get_player_career(pg_temp.uid(n)) $$;
create function pg_temp.sees_career(n int) returns boolean language sql as
 $$ select (public.get_player_career(pg_temp.uid(n))->>'visible')::boolean $$;
create function pg_temp.sees_profile(n int) returns boolean language sql as
 $$ select (public.get_player_profile(pg_temp.uid(n))->>'visible')::boolean $$;
create function pg_temp.pelada(c jsonb, p uuid) returns jsonb language sql as
 $$ select e from jsonb_array_elements(c->'peladas') e where (e->>'pelada_id')::uuid=p $$;

do $test$
declare v_a uuid; v_b uuid; v_c uuid; v_tok text; v_m2024 uuid; v_m2025 uuid; v_m1 uuid; v_m2 uuid; v_mb uuid;
 c jsonb; pa jsonb;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-pv'||n||'@example.invalid','',now(),now(),now() from generate_series(1,6) n;
perform set_config('role','authenticated',true);
for i in 1..6 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
-- A: 1 (admin), 2 e 5. B: 6 (admin) e 1. C: 3. O 4 não tem pelada.
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada A','attacker'); v_tok := public.create_pelada_invite(v_a);
perform pg_temp.as_user(2); perform public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(5); perform public.join_pelada(v_tok,'midfielder');
perform pg_temp.as_user(6); v_b := public.create_pelada('Pelada B','defender'); v_tok := public.create_pelada_invite(v_b);
perform pg_temp.as_user(1); perform public.join_pelada(v_tok,'attacker');
perform pg_temp.as_user(3); v_c := public.create_pelada('Pelada C','goalkeeper');

-- ===== Jogador sem partidas =====
perform pg_temp.as_user(1);
c := pg_temp.career(1);
perform pg_temp.assert((c->>'visible')::boolean and (c->'totals'->>'matches_played')::int=0
 and jsonb_array_length(c->'peladas')=2 and jsonb_array_length(c->'achievements')=0,'carreira vazia, duas peladas');

-- ===== Histórico: 2024, 2025 e duas partidas recentes em A; uma em B =====
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
v_m2024 := pg_temp.finish(v_a, make_timestamptz(2024,6,1,20,0,0,'America/Sao_Paulo'),
 '[{"m":1,"pos":"attacker","res":"win","g":1},{"m":2,"pos":"defender","res":"loss"}]');
v_m2025 := pg_temp.finish(v_a, make_timestamptz(2025,6,1,20,0,0,'America/Sao_Paulo'),
 '[{"m":1,"pos":"attacker","res":"win","g":1},{"m":2,"pos":"defender","res":"loss"}]');
v_m1 := pg_temp.finish(v_a, now() - interval '2 days',
 '[{"m":1,"pos":"attacker","res":"win","g":2},{"m":2,"pos":"defender","res":"loss"}]');
v_m2 := pg_temp.finish(v_a, now() - interval '1 day',
 '[{"m":1,"pos":"attacker","res":"loss","g":1},{"m":2,"pos":"defender","res":"win","g":3}]');
v_mb := pg_temp.finish(v_b, now() - interval '3 days', '[{"m":1,"pos":"attacker","res":"draw","g":1}]');
perform pg_temp.award(v_m1, 1, 'match_craque');
perform pg_temp.award(v_m2, 1, 'match_craque');   -- será anulada
perform pg_temp.award(v_m2025, 1, 'bola_murcha'); -- não é conquista
perform set_config('role','authenticated',true);

-- ===== Anulação tira a partida dos totais e o prêmio das conquistas =====
perform pg_temp.as_user(1);
perform public.annul_match(v_m2,'match_not_played','Partida lançada por engano no teste',true);

-- ===== Pelada grátis: só temporada atual e anterior =====
c := pg_temp.career(1);
pa := pg_temp.pelada(c, v_a);
perform pg_temp.assert(not (pa->>'full_history')::boolean and (pa->>'hidden_seasons')::int=1
 and jsonb_array_length(pa->'seasons')=2,'A grátis: 2026 e 2025, 2024 oculta');
perform pg_temp.assert((pa->'totals'->>'matches_played')::int=2 and (pa->'totals'->>'goals')::int=3
 and (pa->'totals'->>'wins')::int=2,'A: totais sem a anulada e sem 2024');
perform pg_temp.assert((pg_temp.pelada(c, v_b)->'totals'->>'goals')::int=1,'B: 1 gol');
perform pg_temp.assert((c->'totals'->>'matches_played')::int=3 and (c->'totals'->>'goals')::int=4
 and (c->'totals'->>'draws')::int=1,'total geral = soma das peladas');
-- V4.1: o fechamento de jun/2025 concede Artilheiro do mês (1 gol), conquista oficial; o teste antigo não previa.
perform pg_temp.assert((select count(*) from jsonb_array_elements(c->'achievements') a where a->>'type'='match_craque')=1
 and not exists(select 1 from jsonb_array_elements(c->'achievements') a where a->>'type'='bola_murcha')
 and (select a->>'pelada_name' from jsonb_array_elements(c->'achievements') a where a->>'type'='match_craque')='Pelada A',
 'só o Craque válido; sem Bola Murcha nem prêmio anulado');
perform pg_temp.assert((pa->'seasons'->0->'card'->>'tier') is not null,'carta da temporada na carreira');
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements(c->'peladas') e, jsonb_array_elements(e->'seasons') s
 where (s->>'matches_played')::int = 0),'sem temporada vazia');

-- ===== Premium (beta): histórico completo =====
execute 'reset role';
update private.app_config set value='true'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
pa := pg_temp.pelada(pg_temp.career(1), v_a);
perform pg_temp.assert((pa->>'full_history')::boolean and (pa->>'hidden_seasons')::int=0
 and (pa->'totals'->>'matches_played')::int=3 and (pa->'totals'->>'goals')::int=4,'Premium: 2024 incluída');

-- ===== Visibilidade padrão: minhas peladas =====
perform pg_temp.assert((public.get_my_profile()->>'career_visibility')='peladas'
 and (public.get_my_profile()->>'profile_visibility')='peladas','padrão minhas peladas');
perform pg_temp.as_user(2); perform pg_temp.assert(pg_temp.sees_career(1) and pg_temp.sees_profile(1),'colega de A vê');
perform pg_temp.as_user(6); perform pg_temp.assert(pg_temp.sees_career(1),'colega de B vê');
perform pg_temp.as_user(3); perform pg_temp.assert(not pg_temp.sees_career(1) and not pg_temp.sees_profile(1),'outra pelada não vê');
perform pg_temp.assert((select count(*)=0 from public.profiles where id=pg_temp.uid(1)),'outra pelada não lê a linha do perfil');
perform pg_temp.as_user(4); perform pg_temp.assert(not pg_temp.sees_career(1),'sem pelada em comum não vê');

-- ===== Consultas diretas: só id, nome e foto; o resto por RPC =====
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select dominant_foot from public.profiles where id=%L',pg_temp.uid(1)),'permission denied');
perform pg_temp.expect_error(format('select career_visibility from public.profiles where id=%L',pg_temp.uid(1)),'permission denied');
perform pg_temp.expect_error(format('select adult_declared_at from public.profiles where id=%L',pg_temp.uid(2)),'permission denied');
perform pg_temp.assert((select display_name='Jogador 1' from public.profiles where id=pg_temp.uid(1)),'colega lê o nome');
perform pg_temp.as_user(3);
perform pg_temp.assert((select count(*)=0 from public.player_season_stats where membership_id=pg_temp.mem(v_a,1)),
 'estatística da pelada continua só para membros');

-- ===== Privado =====
perform pg_temp.as_user(1);
perform pg_temp.expect_error('select public.set_my_privacy(''secreto'',''peladas'')','INVALID_VISIBILITY');
perform public.set_my_privacy('private','private');
perform pg_temp.assert(pg_temp.sees_career(1) and pg_temp.sees_profile(1),'dono sempre vê');
perform pg_temp.as_user(2);
perform pg_temp.assert(not pg_temp.sees_career(1) and not pg_temp.sees_profile(1),'privado: colega não vê a área global');
perform pg_temp.assert((select count(*)=1 from public.profiles where id=pg_temp.uid(1))
 and (select count(*)>0 from public.player_cards where membership_id=pg_temp.mem(v_a,1)),
 'privado: dentro da pelada nome, foto e carta continuam');
perform pg_temp.assert((public.get_player_career(pg_temp.uid(1)))=jsonb_build_object('visible',false),'nada além de visible=false');

-- ===== Perfil e carreira independentes =====
perform pg_temp.as_user(1); perform public.set_my_privacy('peladas','private');
perform pg_temp.as_user(2);
perform pg_temp.assert(pg_temp.sees_profile(1) and not pg_temp.sees_career(1)
 and not (public.get_player_profile(pg_temp.uid(1))->>'career_visible')::boolean,'perfil visível, carreira não');

-- ===== Público =====
perform pg_temp.as_user(1); perform public.set_my_privacy('public','public');
perform pg_temp.as_user(4);
perform pg_temp.assert(pg_temp.sees_career(1) and pg_temp.sees_profile(1),'público: qualquer usuário autenticado');
perform pg_temp.assert((select count(*)=1 from public.profiles where id=pg_temp.uid(1)),'público: linha do perfil (nome e foto)');
perform pg_temp.assert(jsonb_array_length(public.get_player_profile(pg_temp.uid(1))->'peladas')=2,'público: lista de peladas');
perform pg_temp.expect_error(format('select dominant_foot from public.profiles where id=%L',pg_temp.uid(1)),'permission denied');

-- ===== Bloqueio nos dois sentidos =====
perform pg_temp.as_user(5); perform public.block_user(pg_temp.uid(1));
perform pg_temp.assert(not pg_temp.sees_career(1) and not pg_temp.sees_profile(1),'quem bloqueou não vê a área global');
perform pg_temp.as_user(1); perform public.block_user(pg_temp.uid(3));
perform pg_temp.as_user(3);
perform pg_temp.assert(not pg_temp.sees_career(1) and (select count(*)=0 from public.profiles where id=pg_temp.uid(1)),
 'bloqueado pelo dono não vê nem o perfil público');
perform pg_temp.as_user(1); perform public.unblock_user(pg_temp.uid(3));
perform pg_temp.as_user(3); perform pg_temp.assert(pg_temp.sees_career(1),'desbloqueado volta a ver');

-- ===== Saída da pelada: histórico fica; o colega daquela pelada deixa de ser "minhas peladas" =====
perform pg_temp.as_user(1); perform public.set_my_privacy('peladas','peladas');
perform public.leave_pelada(v_b);
c := pg_temp.career(1);
perform pg_temp.assert(pg_temp.pelada(c, v_b)->>'status'='left' and (pg_temp.pelada(c, v_b)->'totals'->>'goals')::int=1,
 'pelada que saiu continua na carreira');
perform pg_temp.as_user(6);
perform pg_temp.assert(not pg_temp.sees_career(1),'sem pelada ativa em comum: não vê');

-- ===== Conta em exclusão: some da área global dos outros =====
perform pg_temp.as_user(2); perform public.set_my_privacy('public','public');
perform pg_temp.as_user(1); perform pg_temp.assert(pg_temp.sees_career(2),'antes da exclusão');
perform pg_temp.as_user(2); perform public.request_account_deletion(true);
perform pg_temp.as_user(1); perform pg_temp.assert(not pg_temp.sees_career(2) and not pg_temp.sees_profile(2),'Aposentado sem perfil');

-- ===== Não autenticado =====
perform set_config('role','anon',true);
perform pg_temp.expect_error(format('select public.get_player_career(%L)',pg_temp.uid(1)),'permission denied');
perform pg_temp.expect_error(format('select public.get_player_profile(%L)',pg_temp.uid(1)),'permission denied');
perform pg_temp.expect_error('select public.set_my_privacy(''public'',''public'')','permission denied');

  raise notice 'OK: 023_privacy_career';
end
$test$;
rollback;
\echo 'PASS: 023_privacy_career'
