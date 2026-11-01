-- V7.7 (migrações 053-054): motor formula_version 3 pelo fluxo real do app.
--  Versão ativa e pesos; regressão do atacante (LET 91,60); OVR só na 5ª partida; ausência não mexe em DEF/LET/APR
--  nem DIS; segundo amarelo + amarelo = UMA expulsão (-20, sem -8); amarelo -8; partida limpa recupera 6%;
--  disciplina pendente não recupera; goleiro sem registro de defesas = REF 70 e zero é observação; resenha
--  (autovoto, 1 eleitor = indeterminado, 2 eleitores = os dois); cartas com LET ou REF (nunca os dois); histórico
--  v3; sigilo do OVR interno; isolamento entre peladas.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 055_v89_engine".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99770000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Jogadores 1..3 time A, 4..6 time B (1 e 4 goleiros); p_skip = quem falta.
create function pg_temp.sheet(p_pelada uuid, p_skip int) returns jsonb language sql as
 $$ select jsonb_agg(jsonb_build_object('membership_id',pg_temp.mem(p_pelada,n),'team',case when n<=3 then 'A' else 'B' end))
    from generate_series(1,6) n where n is distinct from p_skip $$;
-- Linha completa (inclui o OVR interno, que o app não lê): lida como o dono do banco e volta ao papel do teste.
create function pg_temp.r(p_pelada uuid, n int) returns public.player_ratings language plpgsql as
 $$ declare v public.player_ratings; v_role text := current_setting('role'); begin
  execute 'reset role';
  select * into v from public.player_ratings where membership_id=pg_temp.mem(p_pelada,n);
  if v_role <> 'none' then perform set_config('role', v_role, true); end if;
  return v; end $$;

do $test$
declare v_a uuid; v_b uuid; v_tok text; i int; v_m uuid; v_s uuid; v_m1 uuid; v_x public.player_ratings; v_y public.player_ratings;
 p jsonb; v_gk uuid; r jsonb;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v77-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,9) n;

-- ===== Versão e parâmetros congelados =====
perform pg_temp.assert((private.rating_params_active()).formula_version = 3 and (private.rating_params_active()).version = 2, 'V7.7 ativa');
p := (private.rating_params_active()).params;
perform pg_temp.assert(p->'weights'->'GOL' = '[0.40,0.35,0.10,0.10,0.05]'::jsonb and p->'weights'->'ZAG' = '[0.45,0.30,0.10,0.10,0.05]'::jsonb
 and p->'weights'->'MEI' = '[0.25,0.50,0.10,0.10,0.05]'::jsonb and p->'weights'->'ATA' = '[0.20,0.55,0.10,0.10,0.05]'::jsonb
 and p->'weights'->'PON' = p->'weights'->'ATA' and p->'weights'->'LAT' = p->'weights'->'GOL'
 and p->'weights'->'VOL' = '[0.35,0.40,0.10,0.10,0.05]'::jsonb, 'pesos posicionais');
perform pg_temp.assert(p->'mu_g'->>'ATA' = '0.7' and p->'mu_a'->>'ATA' = '0.3' and (p->>'ref_mu')::int = 3, 'referências V7.5');
-- Regressão obrigatória: 10 gols em 10 partidas, nota 9,0.
perform pg_temp.assert(abs((private.v77_season((select jsonb_agg(jsonb_build_object('played',true,'q',9,'goals',1,'assists',0,'conceded',3,
 'saves',3,'result',1.0/3)) from generate_series(1,10)), 'ATA', null, 0, p)->'last'->>'SEC')::float8 - 91.60479306925015) < 1e-9,
 'LET do atacante = 91,60479306925015');
-- Resenha
perform pg_temp.assert(private.v77_resenha(1,1) is null and private.v77_resenha(2,2) and not private.v77_resenha(1,2)
 and private.v77_resenha(2,3) and not private.v77_resenha(2,4) and private.v77_resenha(0,0) is null, 'regra da resenha');

perform set_config('role','authenticated',true);
for i in 1..9 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1); v_a := public.create_pelada('V77 A','GOL'); v_tok := public.create_pelada_invite(v_a);
for i in 2..6 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok, case when i=4 then 'GOL' when i in (2,5) then 'ZAG' else 'CA' end); end loop;
perform pg_temp.as_user(8); v_b := public.create_pelada('V77 B','MEI');
perform pg_temp.as_user(1);
perform public.set_cards_tracking(v_a, true);

-- ===== Partida 1: cartões =====
v_m1 := public.create_match(v_a, now() - interval '10 days');
perform public.save_match_sheet(v_m1, pg_temp.sheet(v_a,null), jsonb_build_array(
 jsonb_build_object('membership_id',pg_temp.mem(v_a,3),'type','goal','quantity',1),
 jsonb_build_object('membership_id',pg_temp.mem(v_a,3),'type','yellow_card','quantity',1),
 jsonb_build_object('membership_id',pg_temp.mem(v_a,3),'type','second_yellow','quantity',1),
 jsonb_build_object('membership_id',pg_temp.mem(v_a,5),'type','yellow_card','quantity',1)));
perform public.publish_match(v_m1);
v_x := pg_temp.r(v_a,3);
perform pg_temp.assert(v_x.formula_version = 3 and v_x.atu is null and v_x.def is not null, 'linha v3 sem ATU/EST/PEQ');
perform pg_temp.assert(v_x.dis = 50, 'amarelo + segundo amarelo = uma expulsão: 70-20 (sem -8 a mais)');
perform pg_temp.assert((pg_temp.r(v_a,5)).dis = 62, 'amarelo: 70-8');
perform pg_temp.assert(abs((pg_temp.r(v_a,6)).dis - (70 + 0.06*29)) < 1e-6, 'partida limpa: +6% da distância até 99');
perform pg_temp.assert((pg_temp.r(v_a,3)).sec_code = 'LET' and (pg_temp.r(v_a,1)).sec_code = 'REF', 'LET para linha, REF para goleiro');
perform pg_temp.assert((pg_temp.r(v_a,1)).sec = 70 and (pg_temp.r(v_a,4)).sec = 70, 'goleiro sem registro de defesas: REF 70');
perform pg_temp.assert(not (pg_temp.r(v_a,3)).eligible and (pg_temp.r(v_a,3)).ovr_display is null, '1 partida: OVR não publicado');

-- ===== Defesas: zero é observação; voltar a "sem registro" restaura =====
select id into v_gk from public.match_participants where match_id=v_m1 and membership_id=pg_temp.mem(v_a,1);
perform public.set_match_hard_saves(v_m1, jsonb_build_array(jsonb_build_object('participant_id',v_gk,'hard_saves',0)));
perform pg_temp.assert((pg_temp.r(v_a,1)).sec < 70, 'zero defesas difíceis registradas = observação real');
perform public.set_match_hard_saves(v_m1, jsonb_build_array(jsonb_build_object('participant_id',v_gk,'hard_saves',null)));
perform pg_temp.assert((pg_temp.r(v_a,1)).sec = 70, 'registro apagado: volta a sem informação');

-- ===== Partida 2: 6 falta =====
v_y := pg_temp.r(v_a,6);
v_m := public.create_match(v_a, now() - interval '9 days');
perform public.save_match_sheet(v_m, pg_temp.sheet(v_a,6), '[]');
perform public.publish_match(v_m);
v_x := pg_temp.r(v_a,6);
perform pg_temp.assert(v_x.def = v_y.def and v_x.sec = v_y.sec and v_x.apr = v_y.apr and v_x.dis = v_y.dis,
 'ausência não muda DEF, LET, APR nem DIS');
perform pg_temp.assert(v_x.res < v_y.res, 'ausência reduz a frequência do RES');

-- ===== Partidas 3 a 5: OVR na 5ª =====
for i in 3..5 loop
 v_m := public.create_match(v_a, now() - make_interval(days => 10 - i));
 perform public.save_match_sheet(v_m, pg_temp.sheet(v_a,null), '[]');
 perform public.publish_match(v_m);
 perform pg_temp.assert(((pg_temp.r(v_a,2)).ovr_display is not null) = (i = 5), 'OVR publicado só na 5ª partida (rodada '||i||')');
end loop;
perform pg_temp.assert((pg_temp.r(v_a,6)).ovr_display is null and (pg_temp.r(v_a,6)).matches_played = 4, 'quem tem 4 partidas segue em avaliação');
perform pg_temp.assert((pg_temp.r(v_a,2)).ovr_display = floor((pg_temp.r(v_a,2)).ovr + 0.5), 'OVR exibido = arredondamento do interno');

-- ===== Disciplina pendente não conta como partida limpa =====
v_y := pg_temp.r(v_a,6);
perform public.set_match_discipline_status(v_m, 'pending');
perform pg_temp.assert((pg_temp.r(v_a,6)).dis < v_y.dis, 'pendente: a recuperação daquela partida sai');

-- ===== Resenha na votação =====
perform public.set_match_discipline_status(v_m, 'confirmed');
r := public.open_rating_vote(v_m); v_s := (r->>'session_id')::uuid;
perform pg_temp.assert((r->>'resenha_enabled')::boolean and r->'my_resenha' = 'null'::jsonb, 'pergunta disponível, sem resposta ainda');
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.set_rating_vote_resenha(%L,%L::uuid[])',v_s,array[pg_temp.mem(v_a,2)]),'SELF_VOTE_NOT_ALLOWED');
perform public.set_rating_vote_resenha(v_s, array[pg_temp.mem(v_a,3), pg_temp.mem(v_a,5)]);
perform pg_temp.as_user(4); perform public.set_rating_vote_resenha(v_s, array[pg_temp.mem(v_a,3)]);
perform pg_temp.as_user(6); perform public.set_rating_vote_resenha(v_s, array[]::uuid[]);
perform pg_temp.expect_error('select count(*) from private.rating_vote_resenha','permission denied');
execute 'reset role';
update public.rating_vote_sessions set closes_at=clock_timestamp()-interval '1 second' where id=v_s;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1); perform public.publish_rating_vote(v_s);
perform pg_temp.assert((select resenha from public.match_player_results where match_id=v_m and membership_id=pg_temp.mem(v_a,3)), '3 eleitores, 2 sim => sim');
perform pg_temp.assert((select resenha = false from public.match_player_results where match_id=v_m and membership_id=pg_temp.mem(v_a,5)), '3 eleitores, 1 sim => não');
perform pg_temp.assert((select resenha = false from public.match_player_results where match_id=v_m and membership_id=pg_temp.mem(v_a,2)), 'sem o próprio: 2 eleitores, nenhum sim => não');

-- ===== Cartas, histórico, leitura e sigilo =====
perform pg_temp.assert((select formula_version=3 and sec_code='LET' and def is not null and atu is null from public.player_cards
 where membership_id=pg_temp.mem(v_a,2) and season_id=(select season_id from public.matches where id=v_m)), 'carta v3 com DEF/LET/APR');
perform pg_temp.assert((select sec_code from public.player_cards where membership_id=pg_temp.mem(v_a,1)
 and season_id=(select season_id from public.matches where id=v_m))='REF', 'carta do goleiro com REF');
r := public.get_player_rating(pg_temp.mem(v_a,2));
perform pg_temp.assert((r->>'formula_version')::int=3 and r->>'sec_code'='LET' and r->'atu'='null'::jsonb and jsonb_array_length(r->'history')>0,
 'get_player_rating v3 com histórico');
perform pg_temp.assert(exists(select 1 from public.player_rating_history where membership_id=pg_temp.mem(v_a,2) and formula_version=3
 and event='votes_published' and def is not null), 'histórico registra a publicação com os atributos v3');
perform pg_temp.expect_error('select ovr from public.player_season_ratings','permission denied');
perform pg_temp.expect_error('select ovr from public.player_ratings','permission denied');
perform pg_temp.as_user(8);
perform pg_temp.assert(not exists(select 1 from public.player_season_ratings where pelada_id=v_a), 'outra pelada não lê');
perform pg_temp.assert(not exists(select 1 from public.player_ratings where pelada_id=v_b and matches_played>0), 'pelada B intacta');

-- ===== V8.9 (071): prêmios de temporada usam sempre os parâmetros V5 (versão 1), mesmo com a V7.7 ativa =====
perform set_config('role','postgres',true);
perform pg_temp.assert((select version from private.rating_params_active()) = 2, 'V7.7 ativa');
perform pg_temp.assert(private.v87_ref_at(pg_temp.mem(v_a,1), 'infinity') is not null, 'REF do encerramento calculável com a V7.7 ativa');
perform pg_temp.assert(position('version = 1' in pg_get_functiondef('private.v87_ref_at(uuid,timestamptz)'::regprocedure)) > 0
 and position('version = 1' in pg_get_functiondef('private.paredao_ranking(uuid,date)'::regprocedure)) > 0, 'prêmios fixados na versão 1');

raise exception 'PASS: 055_v89_engine';
end $test$;
