-- Exclusão de conta com 30 dias para recuperar (migração 021). Rodar SOMENTE em banco local descartável. Tudo em transação com ROLLBACK.
\set ON_ERROR_STOP on
begin;
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('e0000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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

do $test$
declare v_pid uuid; v_tok text; v_x uuid; v_s uuid; v_m1 uuid; v_m3 uuid; v_m5 uuid; v_r jsonb; v_req uuid;
 v_season uuid; v_sc jsonb; v_err text;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-del'||n||'@example.invalid','',now(),now(),now() from generate_series(1,7) n;
perform set_config('role','authenticated',true);
for i in 1..7 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Exclusao','attacker');
v_tok := public.create_pelada_invite(v_pid);
for i in 2..7 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,'midfielder'); end loop;
perform pg_temp.as_user(1);
perform public.set_assistant(v_pid,pg_temp.mem(v_pid,2),true);
execute 'reset role';
v_m1 := pg_temp.mem(v_pid,1); v_m3 := pg_temp.mem(v_pid,3); v_m5 := pg_temp.mem(v_pid,5);

-- Votação aberta com 7 eleitores; o jogador 3 já votou.
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_x := public.create_match(v_pid,now());
perform public.save_match_sheet(v_x,(select jsonb_agg(jsonb_build_object('membership_id',pg_temp.mem(v_pid,i),
  'team',case when i%2=1 then 'A' else 'B' end)) from generate_series(1,7) i),'[]');
v_s := (public.publish_match(v_x)->>'session_id')::uuid;
perform pg_temp.as_user(3);
perform public.confirm_match_sheet(v_x,1);
select jsonb_agg(jsonb_build_object('membership_id',pg_temp.mem(v_pid,i),'rating',7)) into v_sc
 from generate_series(1,7) i where i<>3;
perform public.submit_ballot(v_s,1,v_sc,v_m1,v_m5,'chave-del-3');

-- ===== Pedido de exclusão do admin =====
perform pg_temp.as_user(1);
perform pg_temp.expect_error('select public.request_account_deletion(false)','CONFIRMATION_REQUIRED');
v_r := public.request_account_deletion(true);
perform pg_temp.assert((v_r->>'purge_after')::timestamptz=now()+interval '30 days','apaga em 30 dias');
perform pg_temp.assert((public.request_account_deletion(true)->>'already_requested')::boolean,'pedido único');
perform pg_temp.assert((public.get_account_status()->>'deletion_pending')::boolean,'conta em exclusão');
perform pg_temp.expect_error($q$select public.create_pelada('Nova Pelada','attacker')$q$,'ACCOUNT_DELETION_PENDING');
execute 'reset role';
perform pg_temp.assert((select status='retired' and player_name='Aposentado' and role='player'
  from public.pelada_memberships where id=v_m1),'vira Aposentado na hora');
perform pg_temp.assert((select role='admin' from public.pelada_memberships where id=pg_temp.mem(v_pid,2)),'sucessão: assistente vira admin');
perform pg_temp.assert((select eligible_voter_count=6 from public.voting_sessions where id=v_s)
  and not exists(select 1 from public.voting_eligible_members where session_id=v_s and membership_id=v_m1),'sai da votação sem travar');

-- ===== Quem já votou: voto anônimo fica, vínculo some =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3); perform public.request_account_deletion(true);
execute 'reset role';
perform pg_temp.assert((select count(*)=0 from private.ballot_voter_links where session_id=v_s and voter_membership_id=v_m3),'vínculo apagado');
perform pg_temp.assert((select count(*)=1 from private.secret_ballots where session_id=v_s and status='submitted'),'voto conta');
perform pg_temp.assert((select eligible_voter_count=6 from public.voting_sessions where id=v_s),'votante continua contando');

-- ===== Aposentado: sem perfil, sem carta, sem prêmio novo =====
select season_id into v_season from public.matches where id=v_x;
insert into public.player_cards(pelada_id,season_id,membership_id,position,finishing,assisting,attendance,winning,
 peer_rating,overall,tier,is_provisional,matches_played,formula_version)
select v_pid,v_season,m,'midfielder',0,0,0,0,50,50,'bronze',true,1,1 from unnest(array[v_m1,v_m5]) m;
perform private.grant_month_award(v_pid,v_season,date_trunc('month',now())::date,'top_scorer',array[v_m1,v_m5]);
perform pg_temp.assert((select array_agg(membership_id)=array[v_m5] and not bool_or(is_shared) from public.awards
  where pelada_id=v_pid and award_type='top_scorer'),'Aposentado não recebe prêmio novo');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(5);
perform pg_temp.assert((select count(*)=0 from public.profiles where id=pg_temp.uid(1)),'perfil do Aposentado oculto');
perform pg_temp.assert((select array_agg(membership_id)=array[v_m5] from public.player_cards where pelada_id=v_pid),'carta do Aposentado oculta');

-- ===== Recuperar em até 30 dias =====
perform pg_temp.as_user(1);
perform pg_temp.assert((public.cancel_account_deletion()->>'restored_memberships')::int=1,'recuperou 1 pelada');
perform pg_temp.assert(not (public.get_account_status()->>'deletion_pending')::boolean,'exclusão cancelada');
perform pg_temp.expect_error('select public.cancel_account_deletion()','NO_PENDING_DELETION');
execute 'reset role';
perform pg_temp.assert((select status='active' and role='player' and player_name='Jogador 1'
  from public.pelada_memberships where id=v_m1),'volta com o nome, como jogador');

-- ===== Depois de 30 dias: apaga =====
select id into v_req from private.account_deletion_requests where user_id=pg_temp.uid(3) and status='pending';
perform private.purge_account(v_req); -- ainda no prazo: nada acontece
perform pg_temp.assert((select status='pending' from private.account_deletion_requests where id=v_req),'respeita o prazo');
update private.account_deletion_requests set purge_after=now()-interval '1 minute' where id=v_req;
perform private.purge_account(v_req);
select error_code into v_err from private.account_deletion_requests where id=v_req;
perform pg_temp.assert((select status='completed' and memberships_snapshot='[]'::jsonb from private.account_deletion_requests where id=v_req),'exclusão concluída');
perform pg_temp.assert(not exists(select 1 from public.profiles where id=pg_temp.uid(3)),'perfil apagado');
perform pg_temp.assert((select user_id is null and player_name='Aposentado' from public.pelada_memberships where id=v_m3),'registro esportivo sem identidade');
perform pg_temp.assert(v_err is null and not exists(select 1 from auth.users where id=pg_temp.uid(3)),
  'conta de login apagada (erro: '||coalesce(v_err,'nenhum')||')');

  raise notice 'OK: 014_account_deletion';
end
$test$;
rollback;
\echo 'PASS: 014_account_deletion'
