-- Correções P1 da V4.2 (migração 036): A01 votos de súmula antiga, A10 reenvio do último voto,
-- A02 anonimização na exclusão, A03 vínculo imutável da assinatura, A04 retenção do aposentado,
-- A05 estados e reconciliação dos eventos da loja. Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 030_p1_integrity" = tudo certo, nada gravado.
-- V5 (052): a súmula publicada vira oficial na hora. Este teste cobre o fluxo antigo de cédula (010-013), que
-- continua valendo para sessões abertas antes da 052; o bloco abaixo religa esse fluxo só durante o teste (desfeito no fim).
create or replace function private.open_voting_session(p_match uuid, p_closes_at timestamptz,
 p_duration integer, p_fixed boolean) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c_min_voters constant integer := 6;
 v_m public.matches; v_s public.pelada_settings; v_count integer; v_id uuid;
begin
 select * into v_m from public.matches where id=p_match;
 select count(*) into v_count from private.match_voters(p_match);
 if v_count < c_min_voters then
  perform private.finalize_match_without_voting(p_match);
  return null;
 end if;
 select * into v_s from public.pelada_settings where pelada_id=v_m.pelada_id;
 insert into public.voting_sessions(pelada_id,match_id,closes_at,duration_minutes,fixed_close,sheet_version,
  bola_murcha_required,minimum_numeric_ratings,formula_version,eligible_voter_count)
 values(v_m.pelada_id,p_match,p_closes_at,p_duration,p_fixed,v_m.sheet_version,
  coalesce(v_s.bola_murcha_enabled,true) and private.pelada_has_premium(v_m.pelada_id),
  v_s.minimum_numeric_ratings,v_m.formula_version,v_count)
 returning id into v_id;
 insert into public.voting_eligible_members(pelada_id,session_id,membership_id,participant_id)
 select v_m.pelada_id,v_id,v.membership_id,v.participant_id from private.match_voters(p_match) v;
 update public.matches set status='voting_open' where id=p_match;
 return v_id;
end $$;
-- V7.7 (054): anulação com prévia (token) e id do pedido.
create function pg_temp.annul(p_match uuid, p_cat text, p_desc text) returns jsonb language sql as
 $$ select public.annul_match(p_match,p_cat,p_desc,true,public.preview_match_annulment(p_match)->>'preview_token',gen_random_uuid()) $$;
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('93000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Nota 7 para todos os colegas elegíveis da sessão (menos o próprio eleitor).
create function pg_temp.scores(p_session uuid, p_self uuid) returns jsonb language sql as
 $$ select jsonb_agg(jsonb_build_object('membership_id',membership_id,'rating',7))
    from public.voting_eligible_members where session_id=p_session and membership_id<>p_self $$;
-- Eleitor n confirma a súmula atual e envia (chave fixa por sessão/eleitor/rodada).
create function pg_temp.vote(p_match uuid, p_session uuid, p_pelada uuid, n int, p_round text) returns jsonb language plpgsql as
 $$ declare v_me uuid := pg_temp.mem(p_pelada,n); v_craque uuid; begin
  perform pg_temp.as_user(n);
  select membership_id into v_craque from public.voting_eligible_members where session_id=p_session and membership_id<>v_me limit 1;
  perform public.confirm_match_sheet(p_match,(select sheet_version from public.matches where id=p_match));
  return public.submit_ballot(p_session,(select sheet_version from public.matches where id=p_match),
    pg_temp.scores(p_session,v_me),v_craque,null,'chave-'||p_round||'-'||n);
 end $$;
create function pg_temp.ev(p_id text, p_type text, n int, p_exp timestamptz, p_minute int, p_extra jsonb default '{}')
returns text language plpgsql as
 $$ declare r text; begin
  perform set_config('role','service_role',true);
  r := public.apply_subscription_event(jsonb_build_object('id',p_id,'type',p_type,'app_user_id',pg_temp.uid(n)::text,
   'product_id','m91_pelada_premium_mensal','expiration_at_ms',extract(epoch from p_exp)*1000,
   'event_timestamp_ms',extract(epoch from now()-interval '1 day'+p_minute*interval '1 minute')*1000) || p_extra);
  execute 'reset role';
  return r;
 end $$;
create function pg_temp.premium(p uuid) returns boolean language sql as $$ select private.pelada_has_premium(p) $$;

do $test$
declare
 v_p1 uuid; v_p2 uuid; v_p3 uuid; v_p9 uuid; v_tok text; v_tok2 uuid; v_tok3 text; v_parts jsonb; v_events jsonb;
 v_x uuid; v_s uuid; v_x2 uuid; v_s2 uuid; v_r jsonb; v_old jsonb; v_m uuid[]; v_req uuid; v_season uuid;
 v_h1 uuid; v_h2 uuid; v_ret uuid; v_b1 uuid; v_b2 uuid; v_until timestamptz := date_trunc('second', now()+interval '30 days');
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-p1-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,12) n;
perform set_config('role','authenticated',true);
for i in 1..12 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;

-- Pelada 1: 7 eleitores (1 admin atacante, 2..7 meias).
perform pg_temp.as_user(1);
v_p1 := public.create_pelada('Pelada Integridade','attacker');
v_tok := public.create_pelada_invite(v_p1);
for i in 2..7 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,'midfielder'); end loop;
v_m := array(select pg_temp.mem(v_p1,i) from generate_series(1,7) i);
select jsonb_agg(jsonb_build_object('membership_id',v_m[i],'team',case when i%2=1 then 'A' else 'B' end)) into v_parts
from generate_series(1,7) i;
execute 'reset role';
update public.pelada_settings set bola_murcha_enabled=false where pelada_id=v_p1; -- foco nas notas
perform set_config('role','authenticated',true);

-- ================= A01: correção antes dos votos =================
perform pg_temp.as_user(1);
v_x := public.create_match(v_p1, now());
perform public.save_match_sheet(v_x, v_parts, '[]');
v_s := (public.publish_match(v_x, 240)->>'session_id')::uuid;
v_events := jsonb_build_array(jsonb_build_object('membership_id',v_m[1],'type','goal','quantity',1));
perform public.correct_match_sheet(v_x, v_parts, v_events, 'gol esquecido');
execute 'reset role';
perform pg_temp.assert((select sheet_version=2 from public.voting_sessions where id=v_s),'sessão acompanha a versão 2');
perform pg_temp.assert(not exists(select 1 from private.audit_events where event_type='ballots_invalidated'
 and metadata->>'session_id'=v_s::text),'sem votos, nada invalidado');
perform set_config('role','authenticated',true);

-- ================= A01: correção durante a votação =================
perform pg_temp.vote(v_x, v_s, v_p1, 2, 'r1');
perform pg_temp.vote(v_x, v_s, v_p1, 3, 'r1');
perform pg_temp.as_user(1);
v_events := v_events || jsonb_build_array(jsonb_build_object('membership_id',v_m[2],'type','goal','quantity',1));
perform public.correct_match_sheet(v_x, v_parts, v_events, 'gol do time B');
execute 'reset role';
perform pg_temp.assert((select count(*) from private.secret_ballots where session_id=v_s and status='submitted')=0,
 'votos da súmula antiga deixam de valer');
perform pg_temp.assert((select count(*) from private.secret_ballots where session_id=v_s and status='draft')=2,
 'conteúdo fica como rascunho do eleitor');
perform pg_temp.assert(not exists(select 1 from public.vote_receipts where session_id=v_s),'recibos apagados: pendência volta');
perform pg_temp.assert((select (metadata->>'ballots')::int=2 from private.audit_events where event_type='ballots_invalidated'
 and metadata->>'session_id'=v_s::text),'auditoria registra quantos votos foram invalidados');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.assert((public.get_my_voting_state(v_x)->>'submitted')::boolean = false,'estado do eleitor: precisa votar de novo');
perform pg_temp.expect_error(format('select public.submit_ballot(%L,%s,%L,%L,null,%L)',v_s,3,
 pg_temp.scores(v_s,v_m[2]),v_m[1],'chave-r1-2'),'SHEET_NOT_CONFIRMED');
perform pg_temp.assert((public.get_my_ballot(v_s)->>'status')='draft','rascunho recuperável');

-- 6 de 7 votam a versão 3.
for i in 1..6 loop perform pg_temp.vote(v_x, v_s, v_p1, i, 'r2'); end loop;

-- ================= A01: correção perto do encerramento =================
execute 'reset role';
update public.voting_sessions set closes_at=now()+interval '5 minutes' where id=v_s;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_events := v_events || jsonb_build_array(jsonb_build_object('membership_id',v_m[3],'type','goal','quantity',1));
perform public.correct_match_sheet(v_x, v_parts, v_events, 'mais um gol do time A');
execute 'reset role';
perform pg_temp.assert((select closes_at >= now()+interval '59 minutes' from public.voting_sessions where id=v_s),
 'prazo de pelo menos 1 hora depois da correção');
perform pg_temp.assert((select count(*) from private.secret_ballots where session_id=v_s and status='submitted')=0,
 'os 6 votos da versão 3 também deixam de valer');
perform set_config('role','authenticated',true);

-- Todos votam a versão 4: o último fecha a votação.
for i in 1..6 loop perform pg_temp.vote(v_x, v_s, v_p1, i, 'r3'); end loop;
v_r := pg_temp.vote(v_x, v_s, v_p1, 7, 'r3');
perform pg_temp.assert((v_r->>'all_voted')::boolean,'último voto encerra');
execute 'reset role';
perform pg_temp.assert((select status='finalized' and is_valid from public.voting_sessions where id=v_s),'votação válida');
perform pg_temp.assert((select bool_and(numeric_rating_count=6) from public.match_player_results where match_id=v_x),
 'cada jogador com exatamente as 6 notas da versão final');
perform pg_temp.assert((select (metadata->>'sheet_version')::int=4 from private.audit_events
 where event_type='match_finalized' and metadata->>'match_id'=v_x::text),'finalização registra a versão apurada');

-- ================= A10: reenvio do último voto após o fechamento =================
perform set_config('role','authenticated',true);
perform pg_temp.as_user(7);
v_r := public.submit_ballot(v_s, 4, pg_temp.scores(v_s,v_m[7]), v_m[1], null, 'chave-r3-7');
perform pg_temp.assert((v_r->>'repeated')::boolean and (v_r->>'all_voted')::boolean,'reenvio idempotente após fechar');
perform pg_temp.expect_error(format('select public.submit_ballot(%L,4,%L,%L,null,%L)',v_s,
 pg_temp.scores(v_s,v_m[7]),v_m[1],'outra-chave-7'),'VOTING_NOT_OPEN');

-- ================= A01: correção após todos votarem (já finalizada) =================
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.correct_match_sheet(%L,%L,%L,%L)',v_x,v_parts,'[]','tarde demais'),'SHEET_LOCKED');

-- ================= A01: votação expirada =================
v_x2 := public.create_match(v_p1, now());
perform public.save_match_sheet(v_x2, v_parts, '[]');
v_s2 := (public.publish_match(v_x2, 120)->>'session_id')::uuid;
for i in 2..5 loop perform pg_temp.vote(v_x2, v_s2, v_p1, i, 'e'); end loop;
execute 'reset role';
update public.voting_sessions set closes_at=now()-interval '1 minute' where id=v_s2;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.correct_match_sheet(%L,%L,%L,%L)',v_x2,v_parts,
 jsonb_build_array(jsonb_build_object('membership_id',v_m[1],'type','goal','quantity',1)),'depois do prazo'),'VOTING_EXPIRED');
-- Segunda trava: um voto de versão diferente nunca entra na apuração.
execute 'reset role';
update private.secret_ballots set sheet_version=sheet_version-1
where id=(select id from private.secret_ballots where session_id=v_s2 and status='submitted' limit 1);
perform private.finalize_session(v_s2);
perform pg_temp.assert((select (metadata->>'submitted_count')::int=3 from private.audit_events
 where event_type='match_finalized' and metadata->>'match_id'=v_x2::text),'só os 3 votos da versão atual contam');
perform pg_temp.assert((select count(*) from public.vote_receipts where session_id=v_s2)=3,'recibo do voto descartado sai');
perform pg_temp.assert((select bool_and(numeric_rating_count<=3) from public.match_player_results where match_id=v_x2),
 'notas só dos votos válidos');

-- ================= A02: ativo em uma pelada, ex-integrante de outra =================
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_p2 := public.create_pelada('Pelada Antiga','attacker');
v_tok3 := public.create_pelada_invite(v_p2);
perform pg_temp.as_user(8);
perform public.join_pelada(v_tok, 'defender');
perform public.join_pelada(v_tok3, 'defender');
perform public.leave_pelada(v_p2);
perform public.request_account_deletion(true);
execute 'reset role';
perform pg_temp.assert((select status='retired' and player_name='Aposentado' from public.pelada_memberships
 where pelada_id=v_p1 and user_id=pg_temp.uid(8)),'pelada atual: Aposentado');
perform pg_temp.assert((select status='left' and player_name='Aposentado' from public.pelada_memberships
 where pelada_id=v_p2 and user_id=pg_temp.uid(8)),'pelada antiga: nome também anonimizado');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(8);
perform public.cancel_account_deletion();
execute 'reset role';
perform pg_temp.assert((select status='active' and player_name='Jogador 8' from public.pelada_memberships
 where pelada_id=v_p1 and user_id=pg_temp.uid(8)),'recuperação devolve a pelada atual');
perform pg_temp.assert((select status='left' and player_name='Jogador 8' from public.pelada_memberships
 where pelada_id=v_p2 and user_id=pg_temp.uid(8)),'recuperação devolve o nome do registro antigo');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(8);
perform public.request_account_deletion(true);
execute 'reset role';
insert into public.user_blocks(blocker_user_id,blocked_user_id) values(pg_temp.uid(8),pg_temp.uid(2));
update private.account_deletion_requests set purge_after=now()-interval '1 minute' where user_id=pg_temp.uid(8) and status='pending';
select id into v_req from private.account_deletion_requests where user_id=pg_temp.uid(8) and status='pending';
perform private.purge_account(v_req);
perform pg_temp.assert(not exists(select 1 from public.pelada_memberships where user_id=pg_temp.uid(8)),'nenhum registro ligado à conta');
perform pg_temp.assert(not exists(select 1 from public.pelada_memberships where player_name='Jogador 8'),'nenhum nome restante');
perform pg_temp.assert(not exists(select 1 from public.profiles where id=pg_temp.uid(8)),'perfil apagado');
perform pg_temp.assert(not exists(select 1 from public.user_blocks where blocker_user_id=pg_temp.uid(8)),'bloqueios apagados');
perform pg_temp.assert(not exists(select 1 from auth.users where id=pg_temp.uid(8)),'login apagado');

-- ================= A04: retenção do aposentado depois da limpeza da temporada =================
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_p3 := public.create_pelada('Pelada Retenção','attacker');
v_tok3 := public.create_pelada_invite(v_p3);
perform pg_temp.as_user(10); perform public.join_pelada(v_tok3,'defender');
perform pg_temp.as_user(11); perform public.join_pelada(v_tok3,'midfielder');
perform pg_temp.as_user(1);
v_parts := jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_p3,1),'team','A'),
 jsonb_build_object('membership_id',pg_temp.mem(v_p3,10),'team','A'),
 jsonb_build_object('membership_id',pg_temp.mem(v_p3,11),'team','B'));
v_h1 := public.create_match(v_p3, (date_trunc('year', now()) - interval '6 months')::timestamptz);
perform public.save_match_sheet(v_h1, v_parts, '[]');
perform public.publish_match(v_h1); -- menos de 6 eleitores: finaliza sem votação
v_h2 := public.create_match(v_p3, (date_trunc('year', now()) - interval '5 months')::timestamptz);
perform public.save_match_sheet(v_h2, v_parts, '[]');
perform public.publish_match(v_h2);
v_ret := pg_temp.mem(v_p3,10);
perform pg_temp.as_user(10); perform public.request_account_deletion(true);
execute 'reset role';
select season_id into v_season from public.matches where id=v_h1;
perform private.cleanup_season(v_season);
perform pg_temp.assert(not exists(select 1 from public.player_cards where membership_id=v_ret)
 and not exists(select 1 from public.player_season_stats where membership_id=v_ret),'limpeza remove o aposentado');
-- Anulação de partida histórica (dentro dos 7 dias) recalcula a temporada.
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.annul(v_h2,'duplicate_match','partida lançada duas vezes');
execute 'reset role';
perform pg_temp.assert(not exists(select 1 from public.player_cards where membership_id=v_ret)
 and not exists(select 1 from public.player_season_stats where membership_id=v_ret),'anulação não traz o aposentado de volta');
perform private.recompute_stats(v_p3, v_season);
perform private.recompute_cards(v_season, v_h1);
perform pg_temp.assert(not exists(select 1 from public.player_cards where membership_id=v_ret)
 and not exists(select 1 from public.player_season_stats where membership_id=v_ret),'recomposição não traz o aposentado de volta');
perform pg_temp.assert(exists(select 1 from public.player_cards where membership_id=pg_temp.mem(v_p3,11) and season_id=v_season),
 'quem continua na pelada mantém o Card');
perform pg_temp.assert((select count(*)=1 from public.match_player_results where match_id=v_h1 and membership_id=v_ret),
 'resultado esportivo da partida continua (só anônimo)');

-- ================= A03 / A05: assinaturas =================
update private.app_config set value='false'::jsonb where key='premium_beta_open';
update private.app_config set value='["m91_pelada_premium_mensal"]'::jsonb where key='premium_product_ids';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_b1 := public.start_premium_purchase(v_p1);
perform pg_temp.assert(pg_temp.ev('p1-1','INITIAL_PURCHASE',1,v_until,10,
 jsonb_build_object('original_transaction_id','tx-A','subscriber_attributes',jsonb_build_object('pelada_id',jsonb_build_object('value',v_p1))))
 ='activated','compra inicial ligada à pelada 1');
perform pg_temp.assert(pg_temp.premium(v_p1) and not pg_temp.premium(v_p2),'só a pelada 1');
-- Expira; o admin começa (e abandona) uma compra para a pelada 2: o atributo passa a ser a pelada 2.
perform pg_temp.assert(pg_temp.ev('p1-2','EXPIRATION',1,now()-interval '1 minute',20,
 '{"original_transaction_id":"tx-A"}')='expired','expirou');
perform pg_temp.as_user(1);
v_b2 := public.start_premium_purchase(v_p2);
-- Reativação atrasada da transação original, com o atributo novo: continua na pelada 1.
perform pg_temp.assert(pg_temp.ev('p1-3','RENEWAL',1,v_until,30,
 jsonb_build_object('original_transaction_id','tx-A','subscriber_attributes',jsonb_build_object('pelada_id',jsonb_build_object('value',v_p2))))
 ='activated','renovação aplicada');
perform pg_temp.assert(pg_temp.premium(v_p1) and not pg_temp.premium(v_p2),'renovação não troca a pelada beneficiária');
perform pg_temp.assert((select status='pending' and store_account_ref is null from public.subscription_purchasers where id=v_b2),
 'intenção da pelada 2 não recebeu a transação');
-- Compra inicial com atributo de outra pelada que não é a intenção pendente: não liga.
perform pg_temp.assert(pg_temp.ev('p1-4','INITIAL_PURCHASE',1,v_until,40,
 jsonb_build_object('original_transaction_id','tx-B','subscriber_attributes',jsonb_build_object('pelada_id',jsonb_build_object('value',v_p3))))
 ='unmatched','atributo sem intenção correspondente não vale');
perform pg_temp.assert((select status='pending_reconciliation' from private.subscription_events where event_id='p1-4'),
 'evento recuperável fica pendente de reconciliação');
-- Evento repetido de evento aplicado = duplicado; atrasado = stale (rejeitado).
perform pg_temp.assert(pg_temp.ev('p1-3','RENEWAL',1,v_until,30,'{"original_transaction_id":"tx-A"}')='duplicate','duplicado');
perform pg_temp.assert(pg_temp.ev('p1-5','CANCELLATION',1,v_until,25,'{"original_transaction_id":"tx-A"}')='stale','evento atrasado');
perform pg_temp.assert((select status='rejected' from private.subscription_events where event_id='p1-5'),'atrasado rejeitado');
-- Cancelamento (renovação desligada) e reembolso.
perform pg_temp.assert(pg_temp.ev('p1-6','CANCELLATION',1,v_until,50,'{"original_transaction_id":"tx-A"}')='cancelled','cancelado');
perform pg_temp.assert(pg_temp.premium(v_p1),'cancelado mantém o período pago');
perform pg_temp.assert(pg_temp.ev('p1-7','CANCELLATION',1,now()-interval '1 minute',60,
 '{"original_transaction_id":"tx-A","cancel_reason":"CUSTOMER_SUPPORT"}')='refunded','reembolso');
perform pg_temp.assert(not pg_temp.premium(v_p1),'reembolso encerra');
-- Produto e ambiente.
perform pg_temp.assert(pg_temp.ev('p1-8','RENEWAL',1,v_until,70,
 '{"original_transaction_id":"tx-A","product_id":"outro_produto"}')='invalid_product','produto errado');
perform pg_temp.assert(not pg_temp.premium(v_p1),'produto errado não dá Premium');
perform pg_temp.assert(pg_temp.ev('p1-8','RENEWAL',1,v_until,70,'{"original_transaction_id":"tx-A"}')='duplicate',
 'rejeitado é definitivo');
update private.app_config set value='"PRODUCTION"'::jsonb where key='store_environment';
perform pg_temp.assert(pg_temp.ev('p1-9','RENEWAL',1,v_until,80,
 '{"original_transaction_id":"tx-A","environment":"SANDBOX"}')='wrong_environment','sandbox não vale em produção');
perform pg_temp.assert(not pg_temp.premium(v_p1),'ambiente errado não dá Premium');
update private.app_config set value='null'::jsonb where key='store_environment';
-- A05: falha temporária (registrada pelo webhook) seguida de recuperação.
perform pg_temp.as_user(9);
v_p9 := public.create_pelada('Pelada do 9','attacker');
perform set_config('role','service_role',true);
perform public.record_store_event_failure(jsonb_build_object('id','p1-10','type','INITIAL_PURCHASE',
 'app_user_id',pg_temp.uid(9)::text,'product_id','m91_pelada_premium_mensal','original_transaction_id','tx-C',
 'expiration_at_ms',extract(epoch from v_until)*1000,'event_timestamp_ms',extract(epoch from now())*1000),'timeout');
execute 'reset role';
perform pg_temp.assert((select status='received' and last_error='timeout' from private.subscription_events where event_id='p1-10'),
 'falha registrada como recebido');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(9);
perform public.start_premium_purchase(v_p9);
execute 'reset role';
update private.subscription_events set last_attempt_at=now()-interval '1 hour' where event_id in ('p1-10');
perform private.reconcile_store_events();
perform pg_temp.assert((select status='applied' and result='activated' from private.subscription_events where event_id='p1-10'),
 'reconciliação aplica o evento');
perform pg_temp.assert(pg_temp.premium(v_p9),'Premium liberado depois da recuperação');
perform pg_temp.assert(exists(select 1 from private.store_event_alerts where event_id='p1-4')
 or (select attempt_count from private.subscription_events where event_id='p1-4') < 3,'alerta disponível para o suporte');
-- Proteção contra benefício duplicado: a mesma transação não se liga a outra compra.
perform pg_temp.assert(pg_temp.ev('p1-11','INITIAL_PURCHASE',1,v_until,2000,
 jsonb_build_object('original_transaction_id','tx-C'))='activated'
 and (select count(*) from public.subscription_purchasers where store_account_ref='tx-C')=1
 and pg_temp.premium(v_p9) and not pg_temp.premium(v_p2),'transação já ligada continua na mesma pelada');
perform set_config('role','authenticated',true);
perform pg_temp.expect_error('select public.record_store_event_failure(''{}''::jsonb,''x'')','permission denied');
execute 'reset role';

raise exception 'PASS: 030_p1_integrity';
end $test$;
