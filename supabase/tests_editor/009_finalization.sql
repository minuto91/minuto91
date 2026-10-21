-- Encerramento, notas e prêmios (migração 013). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 009_finalization" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('90000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.res(p_match uuid, p_mem uuid) returns public.match_player_results language sql as
 $$ select * from public.match_player_results where match_id=p_match and membership_id=p_mem $$;
-- Eleitor n confirma e envia (como usuário n).
create function pg_temp.vote(p_match uuid, p_session uuid, n int, p_scores jsonb, p_craque uuid, p_bola uuid) returns jsonb language plpgsql as
 $$ begin
  perform pg_temp.as_user(n);
  perform public.confirm_match_sheet(p_match,(select sheet_version from public.matches where id=p_match));
  return public.submit_ballot(p_session,(select sheet_version from public.matches where id=p_match),
    p_scores,p_craque,p_bola,'chave-'||p_session||'-'||n);
 end $$;

do $test$
declare
  v_pid uuid; v_tok text; v_g uuid; v_mgr uuid; v_parts jsonb; v_events jsonb;
  v_x1 uuid; v_s1 uuid; v_x2 uuid; v_s2 uuid; v_x3 uuid; v_r jsonb; v_sc jsonb; m uuid[];
  v_res public.match_player_results;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-f'||n||'@example.invalid','',now(),now(),now() from generate_series(1,10) n;

-- 9 eleitores: 1 atacante (admin), 2 zagueiro, 3..9 meias. 10 = de fora.
perform set_config('role','authenticated',true);
for i in 1..10 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Resultado','attacker');
v_tok := public.create_pelada_invite(v_pid);
perform pg_temp.as_user(2); perform public.join_pelada(v_tok,'defender');
for i in 3..9 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,'midfielder'); end loop;
perform pg_temp.as_user(1);
v_g := public.create_guest(v_pid,'Convidado',true);
execute 'reset role';
insert into public.pelada_memberships(pelada_id,user_id,player_name,preferred_position)
values(v_pid,null,'Sem Celular','defender') returning id into v_mgr;
m := array(select pg_temp.mem(v_pid,i) from generate_series(1,9) i);
-- Ímpares + convidado no A; pares + sem-conta no B.
select jsonb_agg(jsonb_build_object('membership_id',m[i],'team',case when i%2=1 then 'A' else 'B' end)) into v_parts from generate_series(1,9) i;
v_parts := v_parts || jsonb_build_array(jsonb_build_object('guest_id',v_g,'team','A','position','attacker'),
                                        jsonb_build_object('membership_id',v_mgr,'team','B'));
-- A 3 x 0 B: jogador 1 dois gols, convidado um gol, assistência do 3, cartão vermelho do 2.
v_events := jsonb_build_array(
  jsonb_build_object('membership_id',m[1],'type','goal','quantity',2),
  jsonb_build_object('guest_id',v_g,'type','goal','quantity',1),
  jsonb_build_object('membership_id',m[3],'type','assist','quantity',1),
  jsonb_build_object('membership_id',m[2],'type','red_card','quantity',1));

perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_x1 := public.create_match(v_pid,now());
perform public.save_match_sheet(v_x1,v_parts,v_events);
v_s1 := (public.publish_match(v_x1)->>'session_id')::uuid;
execute 'reset role';
update public.voting_sessions set minimum_numeric_ratings=1 where id=v_s1; -- permite deixar em branco

-- ===== Partida 1: todos votam (fecha sozinha) =====
-- Notas recebidas:
--  jogador 1: eleitor k dá k (2..9) -> 8 notas, tira 2 e 9 -> média de 3..8 = 5,5
--  jogador 2: 6 (k=1), 8 (k=3), 7 (k=7,8,9); "não vi" de 4,5,6 -> mediana de 6,7,7,7,8 = 7
--  jogador 3: 7 de todos -> 8 notas, média aparada = 7
--  jogador 4: só k=1,2 dão 5 -> 2 notas -> sem nota oficial
--  jogadores 5..9: 6 de todos
-- Craque: jogador 1 (k=2..5) e jogador 3 (k=1,6,7,8) empatam com 4; k=9 vota no 5.
-- Bola Murcha: jogador 8 (todos menos ele, que vota no 7).
perform set_config('role','authenticated',true);
for k in 1..9 loop
 select jsonb_agg(x) into v_sc from (
  select case
   when t=1 then jsonb_build_object('membership_id',m[t],'rating',k)
   when t=2 and k in (4,5,6) then jsonb_build_object('membership_id',m[t],'not_seen',true)
   when t=2 then jsonb_build_object('membership_id',m[t],'rating',case k when 1 then 6 when 3 then 8 else 7 end)
   when t=3 then jsonb_build_object('membership_id',m[t],'rating',7)
   when t=4 and k in (1,2) then jsonb_build_object('membership_id',m[t],'rating',5)
   when t=4 then null
   else jsonb_build_object('membership_id',m[t],'rating',6) end x
  from generate_series(1,9) t where t<>k) q where x is not null;
 v_r := pg_temp.vote(v_x1,v_s1,k,v_sc,
  m[case when k between 2 and 5 then 1 when k in (1,6,7,8) then 3 else 5 end],
  m[case when k=8 then 7 else 8 end]);
 perform pg_temp.assert((v_r->>'all_voted')::boolean = (k=9),'fecha só no último voto');
end loop;
execute 'reset role';

perform pg_temp.assert((select status='finalized' and is_valid and finalized_at is not null from public.voting_sessions where id=v_s1),'sessão finalizada e válida');
perform pg_temp.assert((select status='finalized' from public.matches where id=v_x1),'partida finalizada');
perform pg_temp.assert((select count(*)=0 from private.ballot_voter_links where session_id=v_s1),'vínculos eleitor-cédula apagados');
perform pg_temp.assert((select count(*)=9 from private.secret_ballots where session_id=v_s1 and status='submitted'),'cédulas anônimas mantidas');

v_res := pg_temp.res(v_x1,m[1]);
perform pg_temp.assert(v_res.numeric_rating_count=8 and v_res.peer_rating=5.5 and v_res.objective_rating=10
  and v_res.final_rating=6.4 and v_res.has_valid_rating and v_res.goals=2 and v_res.match_result='win','jogador 1: 0,8x5,5 + 0,2x10 = 6,4');
v_res := pg_temp.res(v_x1,m[2]);
perform pg_temp.assert(v_res.numeric_rating_count=5 and v_res.peer_rating=7 and v_res.objective_rating=4
  and v_res.final_rating=6 and v_res.red_cards=1 and v_res.match_result='loss','jogador 2 (zagueiro): 7 - 1 cartão = 6');
v_res := pg_temp.res(v_x1,m[3]);
perform pg_temp.assert(v_res.peer_rating=7 and v_res.objective_rating=7 and v_res.final_rating=7 and v_res.assists=1,'jogador 3: 7');
v_res := pg_temp.res(v_x1,m[4]);
perform pg_temp.assert(v_res.numeric_rating_count=2 and not v_res.has_valid_rating and v_res.final_rating is null,'jogador 4: menos de 3 notas');
v_res := pg_temp.res(v_x1,v_mgr);
perform pg_temp.assert(v_res.numeric_rating_count=0 and not v_res.has_valid_rating and v_res.objective_rating=4,'sem-conta: só estatística');
perform pg_temp.assert((select count(*)=10 from public.match_player_results where match_id=v_x1),'9 eleitores + sem-conta; convidado sem linha');

perform pg_temp.assert((select count(*)=2 and bool_and(is_shared) and bool_and(votes_count=4)
  and bool_and(membership_id in (m[1],m[3])) from public.awards where match_id=v_x1 and award_type='match_craque'),'Craque empatado e compartilhado');
perform pg_temp.assert((select count(*)=1 and bool_and(not is_shared) and bool_and(votes_count=8) and bool_and(membership_id=m[8])
  from public.awards where match_id=v_x1 and award_type='bola_murcha'),'Bola Murcha do jogador 8');

-- Fechar de novo não recalcula nem duplica.
perform set_config('role','authenticated',true);
perform pg_temp.as_user(4);
v_r := public.finalize_voting_session(v_s1);
perform pg_temp.assert(v_r->>'session_status'='finalized' and (v_r->>'submitted_count')::int=9,'retorna o resultado existente');
perform pg_temp.assert((select count(*)=3 from public.awards where match_id=v_x1),'sem prêmio duplicado');
perform pg_temp.as_user(10);
perform pg_temp.assert((select count(*)=0 from public.match_player_results where match_id=v_x1),'de fora não vê');
perform pg_temp.expect_error(format('select public.finalize_voting_session(%L)',v_s1),'SESSION_NOT_FOUND');
perform pg_temp.as_user(1);
perform pg_temp.expect_error('update public.match_player_results set final_rating=10','permission denied');

-- ===== Partida 2: só 4 de 9 votam -> inválida =====
perform pg_temp.as_user(1);
v_x2 := public.create_match(v_pid,now());
perform public.save_match_sheet(v_x2,v_parts,v_events);
v_s2 := (public.publish_match(v_x2)->>'session_id')::uuid;
execute 'reset role';
update public.voting_sessions set minimum_numeric_ratings=1 where id=v_s2;
perform set_config('role','authenticated',true);
for k in 1..4 loop
 perform pg_temp.vote(v_x2,v_s2,k,jsonb_build_array(jsonb_build_object('membership_id',m[case when k=9 then 1 else 9 end],'rating',8)),
  m[case when k=1 then 2 else 1 end],m[case when k=8 then 7 else 8 end]);
end loop;
perform pg_temp.as_user(5);
perform public.save_ballot_draft(v_s2,'[]'); -- rascunho nunca conta
perform pg_temp.expect_error(format('select public.finalize_voting_session(%L)',v_s2),'VOTING_STILL_OPEN');
execute 'reset role';
update public.voting_sessions set closes_at=now()-interval '1 minute' where id=v_s2;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(9);
v_r := public.finalize_voting_session(v_s2);
perform pg_temp.assert(v_r->>'session_status'='finalized' and not (v_r->>'is_valid')::boolean,'4 de 9: inválida');
execute 'reset role';
perform pg_temp.assert((select count(*)=0 from private.secret_ballots where session_id=v_s2 and status='draft'),'rascunho descartado');
perform pg_temp.assert((select bool_and(not has_valid_rating) from public.match_player_results where match_id=v_x2),'inválida: ninguém tem nota');
perform pg_temp.assert((select goals=2 from public.match_player_results where match_id=v_x2 and membership_id=m[1]),'inválida: gols contam');
perform pg_temp.assert((select count(*)=0 from public.awards where match_id=v_x2),'inválida: sem prêmios');

-- Quem não votou não vê o resultado detalhado (mas vê o da partida em que votou).
perform set_config('role','authenticated',true);
perform pg_temp.as_user(9);
perform pg_temp.assert((select count(*)=0 from public.match_player_results where match_id=v_x2),'não votante bloqueado');
perform pg_temp.assert((select count(*)=10 from public.match_player_results where match_id=v_x1),'votante vê a partida 1');
perform pg_temp.as_user(2);
perform pg_temp.assert((select count(*)=10 from public.match_player_results where match_id=v_x2),'votante vê a partida 2');

-- ===== Partida 3: menos de 6 eleitores -> só estatística objetiva =====
perform pg_temp.as_user(1);
v_x3 := public.create_match(v_pid,now());
perform public.save_match_sheet(v_x3,(select jsonb_agg(p) from jsonb_array_elements(v_parts) p
  where (p->>'membership_id')::uuid = any(m[1:5]) or p ? 'guest_id'),
  jsonb_build_array(jsonb_build_object('membership_id',m[1],'type','goal','quantity',1)));
v_r := public.publish_match(v_x3);
execute 'reset role';
perform pg_temp.assert(v_r->>'status'='finalized','5 eleitores: finalizada sem votação');
perform pg_temp.assert((select count(*)=5 and bool_and(not has_valid_rating) from public.match_player_results where match_id=v_x3),'resultados objetivos gravados');
perform pg_temp.assert((select objective_rating=8 from public.match_player_results where match_id=v_x3 and membership_id=m[1]),'jogador 1: 5 + 2 + vitória 1 = 8');

  raise exception 'PASS: 009_finalization (rollback proposital - nada foi gravado)';
end
$test$;
