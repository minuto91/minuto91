-- V8.9 / 073: motor V7.7 em todo o histórico.
--  1) cutover_date da versão 2 = 0001-01-01.
--  2) Partidas de uma temporada já encerrada (ano anterior) publicam carta formula_version 3 com DEF/LET/APR/RES/DIS.
--  3) Discriminação: com o corte antigo (data de hoje) a carta da temporada encerrada NÃO vira v3; voltar ao corte
--     da 073 e recalcular a partir da temporada mais antiga (o mesmo que a 073 faz) leva as duas temporadas para v3.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 056_v89_cutover_full_history".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99780000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
create function pg_temp.as_user(n int) returns void language plpgsql as
 $$ begin perform set_config('request.jwt.claim.sub', pg_temp.uid(n)::text, true); end $$;
create function pg_temp.assert(p_ok boolean, p_msg text) returns void language plpgsql as
 $$ begin if not coalesce(p_ok,false) then raise exception 'FALHOU: %', p_msg; end if; end $$;
create function pg_temp.mem(p_pelada uuid, n int) returns uuid language sql as
 $$ select id from public.pelada_memberships where pelada_id=p_pelada and user_id=pg_temp.uid(n) $$;
create function pg_temp.sheet(p_pelada uuid) returns jsonb language sql as
 $$ select jsonb_agg(jsonb_build_object('membership_id',pg_temp.mem(p_pelada,n),'team',case when n<=3 then 'A' else 'B' end))
    from generate_series(1,6) n $$;

do $test$
declare v_a uuid; v_tok text; i int; v_m uuid; v_old uuid; v_cur uuid; v_y int := extract(year from now())::int - 1;
 v_fv_old int; v_fv_cur int; v_role text;
begin
perform pg_temp.assert((select params->>'cutover_date' from private.rating_params where version = 2) = '0001-01-01',
 '073: corte da versão 2 desde o início');
perform pg_temp.assert((private.rating_params_active()).version = 2, 'versão 2 (V7.7) ativa');

insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v89c-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,6) n;

perform set_config('role','authenticated',true);
for i in 1..6 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1); v_a := public.create_pelada('V89 corte','GOL'); v_tok := public.create_pelada_invite(v_a);
for i in 2..6 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok, case when i=4 then 'GOL' when i in (2,5) then 'ZAG' else 'CA' end); end loop;
perform pg_temp.as_user(1);

-- Cinco partidas no ano anterior (temporada já encerrada) e uma no ano atual.
for i in 1..5 loop
 v_m := public.create_match(v_a, make_timestamptz(v_y, 6, i, 12, 0, 0, 'America/Sao_Paulo'));
 perform public.save_match_sheet(v_m, pg_temp.sheet(v_a), '[]');
 perform public.publish_match(v_m);
end loop;
v_m := public.create_match(v_a, now() - interval '1 day');
perform public.save_match_sheet(v_m, pg_temp.sheet(v_a), '[]');
perform public.publish_match(v_m);

v_role := current_setting('role');
execute 'reset role';
select id into v_old from public.seasons where pelada_id = v_a and ends_on < current_date order by starts_on limit 1;
select id into v_cur from public.seasons where pelada_id = v_a and current_date between starts_on and ends_on;
perform pg_temp.assert(v_old is not null and v_cur is not null and v_old <> v_cur, 'duas temporadas: a anterior encerrada');

select formula_version into v_fv_old from public.player_cards where season_id = v_old and membership_id = pg_temp.mem(v_a,3);
select formula_version into v_fv_cur from public.player_cards where season_id = v_cur and membership_id = pg_temp.mem(v_a,3);
perform pg_temp.assert(v_fv_old = 3, 'temporada encerrada publica carta V7.7 (formula_version 3)');
perform pg_temp.assert(v_fv_cur = 3, 'temporada atual publica carta V7.7');
perform pg_temp.assert((select def is not null and sec is not null and apr is not null and atu is null
 from public.player_cards where season_id = v_old and membership_id = pg_temp.mem(v_a,3)),
 'carta antiga com DEF/LET/APR e sem ATU');
perform pg_temp.assert((select sec_code from public.player_cards where season_id = v_old and membership_id = pg_temp.mem(v_a,1)) = 'REF',
 'goleiro na temporada antiga com REF');

-- Discriminação: o corte antigo (data de hoje) deixaria a temporada encerrada fora da V7.7.
update private.rating_params set params = jsonb_set(params,'{cutover_date}',to_jsonb(to_char(current_date,'YYYY-MM-DD'))) where version = 2;
update public.player_cards set formula_version = 2, def = null, sec = null, apr = null, sec_code = null
 where season_id = v_old;
perform private.recompute_cards(v_old, null);
perform pg_temp.assert((select bool_and(formula_version < 3) from public.player_cards where season_id = v_old),
 'com o corte antigo a temporada encerrada não é recalculada pela V7.7');

-- Mesmo procedimento da 073: corte desde o início e recálculo a partir da temporada mais antiga.
update private.rating_params set params = jsonb_set(params,'{cutover_date}',to_jsonb('0001-01-01'::text)) where version = 2;
perform private.recompute_cards(v_old, null);
perform pg_temp.assert((select bool_and(formula_version = 3) from public.player_cards where season_id = v_old),
 '073: temporada encerrada recalculada pela V7.7');
perform pg_temp.assert((select bool_and(formula_version = 3) from public.player_cards where season_id = v_cur),
 '073: temporada atual continua V7.7 (propagação)');

raise exception 'PASS: 056_v89_cutover_full_history';
end $test$;
