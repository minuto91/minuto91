-- Evolução do Card na temporada (migração 033). Cole no SQL Editor do Supabase DEV (ou rode no banco local:
-- supabase/local_db). Termina SEMPRE com o erro proposital "PASS: 027_player_evolution" = tudo certo, nada gravado.
-- As partidas são gravadas já finalizadas (como no teste 023) e passam pela cadeia oficial (014/015).
-- V7.7 (054): anulação com prévia (token) e id do pedido.
create function pg_temp.annul(p_match uuid, p_cat text, p_desc text) returns jsonb language sql as
 $$ select public.annul_match(p_match,p_cat,p_desc,true,public.preview_match_annulment(p_match)->>'preview_token',gen_random_uuid()) $$;
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('c2870000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.finish(p_pelada uuid, p_at timestamptz, p_rows jsonb) returns uuid language plpgsql as
 $$ declare v_id uuid; begin
  insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
  values(p_pelada,private.season_for_date(p_pelada,private.pelada_local_date(p_pelada,p_at)),p_at,'finalized',1,0,now())
  returning id into v_id;
  insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,
   objective_rating,final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
  select p_pelada,v_id,pg_temp.mem(p_pelada,(r->>'m')::int),0,null,5,null,false,coalesce((r->>'g')::int,0),
   coalesce((r->>'a')::int,0),0,r->>'res',r->>'pos',1
  from jsonb_array_elements(p_rows) r;
  perform private.after_match_finalized(v_id);
  return v_id;
 end $$;
create function pg_temp.season_of(p_match uuid) returns uuid language sql as
 $$ select season_id from public.matches where id=p_match $$;
create function pg_temp.evo(n int, p_pelada uuid, p_season uuid) returns jsonb language sql as
 $$ select public.get_player_evolution(pg_temp.mem(p_pelada,n), p_season) $$;

do $test$
declare v_a uuid; v_b uuid; v_tok text; v_old uuid; v_m1 uuid; v_m2 uuid; v_m3 uuid; v_s uuid; v_s2024 uuid; e jsonb;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-ev'||n||'@example.invalid','',now(),now(),now() from generate_series(1,4) n;
perform set_config('role','authenticated',true);
for i in 1..4 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
-- A: 1 (admin), 2 e 3. B: 4 (admin).
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada A','attacker'); v_tok := public.create_pelada_invite(v_a);
perform pg_temp.as_user(2); perform public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(3); perform public.join_pelada(v_tok,'midfielder');
perform pg_temp.as_user(4); v_b := public.create_pelada('Pelada B','attacker');

execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
v_old := pg_temp.finish(v_a, make_timestamptz(2024,6,1,20,0,0,'America/Sao_Paulo'),
 '[{"m":1,"pos":"attacker","res":"win","g":1},{"m":2,"pos":"defender","res":"loss"}]');
v_s2024 := pg_temp.season_of(v_old);
-- 2025 existe: 2024 passa a ser mais antiga que a anterior.
perform pg_temp.finish(v_a, make_timestamptz(2025,6,1,20,0,0,'America/Sao_Paulo'), '[{"m":1,"pos":"attacker","res":"draw"}]');
v_m1 := pg_temp.finish(v_a, now() - interval '3 days',
 '[{"m":1,"pos":"attacker","res":"win","g":2,"a":1},{"m":2,"pos":"defender","res":"loss"}]');
v_m2 := pg_temp.finish(v_a, now() - interval '2 days',
 '[{"m":1,"pos":"attacker","res":"loss"},{"m":2,"pos":"defender","res":"win","g":1}]');
-- 1 não joga a terceira: o snapshot existe (Presença muda para todos), marcado como não jogada.
v_m3 := pg_temp.finish(v_a, now() - interval '1 day', '[{"m":2,"pos":"defender","res":"draw"},{"m":3,"pos":"midfielder","res":"draw"}]');
v_s := pg_temp.season_of(v_m1);
insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count)
values(v_a,v_m1,v_s,pg_temp.mem(v_a,1),'match_craque',3);
perform set_config('role','authenticated',true);

-- ===== O próprio jogador: um ponto por partida finalizada da temporada, em ordem =====
perform pg_temp.as_user(1);
e := pg_temp.evo(1, v_a, v_s);
perform pg_temp.assert(jsonb_array_length(e->'points')=3, '3 snapshots na temporada atual');
perform pg_temp.assert((e->'points'->0->>'match_id')::uuid=v_m1 and (e->'points'->2->>'match_id')::uuid=v_m3, 'ordem por data');
perform pg_temp.assert((e->'points'->0->>'played')::boolean and not (e->'points'->2->>'played')::boolean, 'marca se jogou');
perform pg_temp.assert((e->'points'->0) ?& array['overall','finishing','assisting','attendance','winning','peer_rating','tier','position','is_provisional'],
 'cinco atributos, overall, categoria, posição e provisório');
perform pg_temp.assert((e->'current'->>'overall')::numeric is not distinct from (select case when formula_version >= 2 then ovr_display else overall end from public.player_cards where membership_id=pg_temp.mem(v_a,1) and season_id=v_s),
 'atual = Card oficial');
perform pg_temp.assert((e->>'craque')::int=1, 'um Craque na temporada');
perform pg_temp.assert(jsonb_array_length(e->'monthly_king')=0, 'sem Rei do Mês');
-- Valores reais: o último ponto é o Card depois da última partida.
perform pg_temp.assert((e->'points'->2->>'overall')::numeric is not distinct from (e->'current'->>'overall')::numeric, 'último ponto = Card atual (V5: os dois nulos antes de 5 partidas)');

-- ===== Outro membro da mesma pelada também vê (Cards já são visíveis dentro da pelada) =====
perform pg_temp.as_user(3);
perform pg_temp.assert(jsonb_array_length(pg_temp.evo(1, v_a, v_s)->'points')=3, 'colega da pelada vê a evolução');

-- ===== Isolamento: quem não é da pelada não vê; membro de outra pelada não entra pela temporada errada =====
perform pg_temp.as_user(4);
perform pg_temp.expect_error(format('select public.get_player_evolution(%L,%L)', pg_temp.mem(v_a,1), v_s), 'SEASON_NOT_FOUND');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.get_player_evolution(%L,%L)', pg_temp.mem(v_b,4), v_s), 'MEMBER_NOT_FOUND');

-- ===== Premium: grátis vê a temporada atual e a anterior; 2024 é mais antiga =====
perform pg_temp.expect_error(format('select public.get_player_evolution(%L,%L)', pg_temp.mem(v_a,1), v_s2024), 'PREMIUM_REQUIRED');
execute 'reset role';
update private.app_config set value='true'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.assert(jsonb_array_length(pg_temp.evo(1, v_a, v_s2024)->'points')=1, 'com Premium, 2024 aparece');
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);

-- ===== Anulação: a partida sai da evolução; o Card atual é o recalculado =====
perform pg_temp.as_user(1);
perform pg_temp.annul(v_m2,'match_not_played','Lançada por engano no teste 027');
e := pg_temp.evo(1, v_a, v_s);
perform pg_temp.assert(jsonb_array_length(e->'points')=2 and not exists(select 1 from jsonb_array_elements(e->'points') p
 where (p->>'match_id')::uuid=v_m2), 'partida anulada fora do histórico');
perform pg_temp.assert((e->'current'->>'overall')::numeric is not distinct from (select case when formula_version >= 2 then ovr_display else overall end from public.player_cards where membership_id=pg_temp.mem(v_a,1) and season_id=v_s),
 'atual continua igual ao Card oficial depois da anulação');

-- ===== Sem login e sem permissão =====
perform pg_temp.as_user(1);
perform set_config('request.jwt.claim.sub','',true);
perform pg_temp.expect_error(format('select public.get_player_evolution(%L,%L)', pg_temp.mem(v_a,1), v_s), 'AUTH_REQUIRED');
execute 'reset role';
perform pg_temp.assert(not has_function_privilege('anon','public.get_player_evolution(uuid,uuid)','execute'), 'anon sem acesso');
perform pg_temp.assert(has_function_privilege('authenticated','public.get_player_evolution(uuid,uuid)','execute'), 'authenticated com acesso');

raise exception 'PASS: 027_player_evolution (rollback proposital - nada foi gravado)';
end
$test$;
