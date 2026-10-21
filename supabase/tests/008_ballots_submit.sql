-- Cédulas e envio de votos (migrações 011 e 012). Rodar SOMENTE em banco local descartável. Tudo em transação com ROLLBACK.
\set ON_ERROR_STOP on
begin;
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('80000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Notas para os colegas do eleitor n: os k primeiros "não vi jogar", os demais com p_rating.
create function pg_temp.scores(p_session uuid, p_pelada uuid, n int, p_rating numeric, k int default 0, p_limit int default 99)
returns jsonb language sql as
 $$ select coalesce(jsonb_agg(case when rn<=k then jsonb_build_object('membership_id',membership_id,'not_seen',true)
                                   else jsonb_build_object('membership_id',membership_id,'rating',p_rating) end),'[]')
    from (select e.membership_id, row_number() over (order by e.membership_id) rn
          from public.voting_eligible_members e
          where e.session_id=p_session and e.membership_id<>pg_temp.mem(p_pelada,n)) x where rn<=p_limit $$;
create function pg_temp.submit_sql(p_session uuid, p_version int, p_scores jsonb, p_craque uuid, p_bola uuid, p_key text) returns text language sql as
 $$ select format('select public.submit_ballot(%L,%L,%L,%L,%L,%L)',p_session,p_version,p_scores,p_craque,p_bola,p_key) $$;

do $test$
declare
  v_pid uuid; v_tok text; v_mgr uuid; v_x uuid; v_s uuid; v_s_old uuid; v_r jsonb; v_sc jsonb; v_parts jsonb;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-b'||n||'@example.invalid','',now(),now(),now() from generate_series(1,8) n;

perform set_config('role','authenticated',true);
for i in 1..8 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Cedulas','attacker');
v_tok := public.create_pelada_invite(v_pid);
for i in 2..7 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,'midfielder'); end loop;
execute 'reset role';
insert into public.pelada_memberships(pelada_id,user_id,player_name,preferred_position)
values(v_pid,null,'Sem Celular','defender') returning id into v_mgr;
select jsonb_agg(jsonb_build_object('membership_id',id,'team',case when user_id in (pg_temp.uid(1),pg_temp.uid(3),pg_temp.uid(5),pg_temp.uid(7)) then 'A' else 'B' end))
 into v_parts from public.pelada_memberships where pelada_id=v_pid;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_x := public.create_match(v_pid,now());
perform public.save_match_sheet(v_x,v_parts,'[]');
v_s := (public.publish_match(v_x)->>'session_id')::uuid;
-- 7 eleitores (sem-conta não vota nem recebe nota); Bola Murcha exigida (beta Premium).

-- ===== Sigilo: ninguém lê cédulas nem chaves =====
perform pg_temp.expect_error('select * from private.secret_ballots','permission denied');
perform pg_temp.expect_error('select * from private.ballot_scores','permission denied');
perform pg_temp.expect_error('select * from private.ballot_voter_links','permission denied');
perform pg_temp.expect_error(format('select idempotency_key from public.vote_receipts where session_id=%L',v_s),'permission denied');

-- ===== Rascunho =====
perform pg_temp.as_user(8);
perform pg_temp.expect_error(format('select public.save_ballot_draft(%L,%L)',v_s,'[]'),'NOT_ELIGIBLE_VOTER');
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.save_ballot_draft(%L,%L)',v_s,
  jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_pid,2),'rating',7))),'INVALID_RATING_TARGET');
perform pg_temp.expect_error(format('select public.save_ballot_draft(%L,%L)',v_s,
  jsonb_build_array(jsonb_build_object('membership_id',v_mgr,'rating',7))),'INVALID_RATING_TARGET');
perform pg_temp.expect_error(format('select public.save_ballot_draft(%L,%L)',v_s,
  jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_pid,1),'rating',7.25))),'INVALID_RATING');
perform pg_temp.expect_error(format('select public.save_ballot_draft(%L,%L)',v_s,
  jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_pid,1),'rating',11))),'INVALID_RATING');
perform pg_temp.expect_error(format('select public.save_ballot_draft(%L,%L)',v_s,
  jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_pid,1),'rating',7),
                    jsonb_build_object('membership_id',pg_temp.mem(v_pid,1),'rating',8))),'DUPLICATE_RATING');
perform pg_temp.expect_error(format('select public.save_ballot_draft(%L,%L)',v_s,
  '[{"membership_id":"x","rating":7}]'),'INVALID_BALLOT');
perform pg_temp.expect_error(format('select public.save_ballot_draft(%L,%L,null,%L)',v_s,'[]',pg_temp.mem(v_pid,2)),'INVALID_AWARD_TARGET');
perform public.save_ballot_draft(v_s,pg_temp.scores(v_s,v_pid,2,6.5,0,2),pg_temp.mem(v_pid,1));
v_r := public.get_my_ballot(v_s);
perform pg_temp.assert(v_r->>'status'='draft' and jsonb_array_length(v_r->'scores')=2
  and (v_r->>'craque')::uuid=pg_temp.mem(v_pid,1),'rascunho salvo e recuperado');
perform pg_temp.as_user(3);
perform pg_temp.assert(public.get_my_ballot(v_s)->>'status'='none','cada um só vê a própria cédula');

-- ===== Envio: validações =====
perform pg_temp.as_user(2);
v_sc := pg_temp.scores(v_s,v_pid,2,7);
perform pg_temp.expect_error(pg_temp.submit_sql(v_s,1,v_sc,pg_temp.mem(v_pid,1),pg_temp.mem(v_pid,3),'chave-0002'),'SHEET_NOT_CONFIRMED');
perform public.confirm_match_sheet(v_x,1);
perform pg_temp.expect_error(pg_temp.submit_sql(v_s,1,v_sc,pg_temp.mem(v_pid,1),pg_temp.mem(v_pid,3),'curta'),'IDEMPOTENCY_KEY_REQUIRED');
perform pg_temp.expect_error(pg_temp.submit_sql(v_s,1,pg_temp.scores(v_s,v_pid,2,7,4),pg_temp.mem(v_pid,1),pg_temp.mem(v_pid,3),'chave-0002'),'NOT_SEEN_LIMIT');
perform pg_temp.expect_error(pg_temp.submit_sql(v_s,1,pg_temp.scores(v_s,v_pid,2,7,0,5),pg_temp.mem(v_pid,1),pg_temp.mem(v_pid,3),'chave-0002'),'MINIMUM_RATINGS_REQUIRED');
perform pg_temp.expect_error(pg_temp.submit_sql(v_s,1,v_sc,null,pg_temp.mem(v_pid,3),'chave-0002'),'CRAQUE_REQUIRED');
perform pg_temp.expect_error(pg_temp.submit_sql(v_s,1,v_sc,pg_temp.mem(v_pid,1),null,'chave-0002'),'BOLA_MURCHA_REQUIRED');

-- ===== Envio válido, edição e idempotência =====
v_r := public.submit_ballot(v_s,1,v_sc,pg_temp.mem(v_pid,1),pg_temp.mem(v_pid,3),'chave-0002');
perform pg_temp.assert(v_r='{"submitted":true,"all_voted":false,"repeated":false}'::jsonb,'voto enviado');
perform pg_temp.assert(public.get_my_ballot(v_s)->>'status'='submitted','cédula enviada');
perform pg_temp.assert((select count(*)=1 from public.vote_receipts where session_id=v_s),'recibo visível');
v_r := public.submit_ballot(v_s,1,v_sc,pg_temp.mem(v_pid,1),pg_temp.mem(v_pid,3),'chave-0002');
perform pg_temp.assert((v_r->>'repeated')::boolean,'mesma chave não reprocessa');
-- Edição: 3 "não vi jogar" (limite = 6 colegas / 2) e as demais notas.
v_r := public.submit_ballot(v_s,1,pg_temp.scores(v_s,v_pid,2,8,3),pg_temp.mem(v_pid,4),pg_temp.mem(v_pid,3),'chave-0002b');
perform pg_temp.assert(not (v_r->>'repeated')::boolean,'edição aceita');
perform pg_temp.assert((select count(*)=1 from public.vote_receipts where session_id=v_s),'editar não cria segundo recibo');
perform pg_temp.expect_error(format('select public.save_ballot_draft(%L,%L)',v_s,'[]'),'BALLOT_ALREADY_SUBMITTED');
execute 'reset role';
perform pg_temp.assert((select count(*)=1 from private.secret_ballots where session_id=v_s and status='submitted'),'uma cédula enviada');
perform pg_temp.assert((select count(*)=3 from private.ballot_scores s join private.ballot_voter_links l on l.ballot_id=s.ballot_id
  where l.session_id=v_s and s.not_seen),'"não vi jogar" guardado separado');

-- Mínimo configurado pela pelada: com mínimo 2, pode deixar colegas em branco.
update public.voting_sessions set minimum_numeric_ratings=2 where id=v_s;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform public.confirm_match_sheet(v_x,1);
perform public.submit_ballot(v_s,1,pg_temp.scores(v_s,v_pid,3,5,0,2),pg_temp.mem(v_pid,1),pg_temp.mem(v_pid,2),'chave-0003');

-- Bola Murcha desligada na abertura: escolha recusada.
execute 'reset role';
update public.voting_sessions set bola_murcha_required=false where id=v_s;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(4);
perform public.confirm_match_sheet(v_x,1);
perform pg_temp.expect_error(pg_temp.submit_sql(v_s,1,pg_temp.scores(v_s,v_pid,4,7),pg_temp.mem(v_pid,1),pg_temp.mem(v_pid,2),'chave-0004'),'BOLA_MURCHA_DISABLED');
execute 'reset role';
update public.voting_sessions set bola_murcha_required=true where id=v_s;

-- Correção da súmula invalida a conferência do jogador 4.
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform public.correct_match_sheet(v_x,v_parts,jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_pid,1),'type','goal','quantity',1)),'Gol do 1');
perform pg_temp.as_user(4);
perform pg_temp.expect_error(pg_temp.submit_sql(v_s,2,pg_temp.scores(v_s,v_pid,4,7),pg_temp.mem(v_pid,1),pg_temp.mem(v_pid,2),'chave-0004'),'SHEET_NOT_CONFIRMED');
perform public.confirm_match_sheet(v_x,2);
perform public.submit_ballot(v_s,2,pg_temp.scores(v_s,v_pid,4,7),pg_temp.mem(v_pid,1),pg_temp.mem(v_pid,2),'chave-0004');

-- Prazo vencido.
execute 'reset role';
update public.voting_sessions set closes_at=now()-interval '1 minute' where id=v_s;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select public.save_ballot_draft(%L,%L)',v_s,'[]'),'VOTING_NOT_OPEN');
execute 'reset role';
update public.voting_sessions set closes_at=now()+interval '1 hour' where id=v_s;

-- ===== Votação reiniciada: cédulas da sessão cancelada somem =====
v_s_old := v_s;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform public.correct_match_sheet(v_x,(select jsonb_agg(p) from jsonb_array_elements(v_parts) p
  where (p->>'membership_id')::uuid<>pg_temp.mem(v_pid,7)),'[]','Jogador 7 não jogou');
execute 'reset role';
perform pg_temp.assert((select count(*)=0 from private.secret_ballots where session_id=v_s_old),'cédulas antigas apagadas');
perform pg_temp.assert((select count(*)=1 from public.voting_sessions where match_id=v_x and status='open' and id<>v_s_old),'nova sessão aberta');

  raise notice 'OK: 008_ballots_submit';
end
$test$;
rollback;
\echo 'PASS: 008_ballots_submit'
