-- V5 (migrações 050-052): votação pós-partida v2, motor de OVR e dados novos.
--  Votação: abertura só após partida oficial e só pela gestão; 24 participantes; admin participante vota;
--  autovoto, não participante e outra pelada bloqueados; notas 0, 7 (confirmada) e 10; passo de 0,5; reenvio não
--  duplica; correção substitui; ordem fixa por eleitor e diferente entre eleitores; pular 1x reaparece, 2x vai para
--  a revisão; prorrogação antes do prazo, bloqueada depois; voto após o prazo bloqueado; encerramento automático;
--  lembretes só para pendentes e refeitos após prorrogação; publicação só pela gestão, após o prazo, idempotente;
--  nota = 50/50 companheiros x adversários; só um grupo = avaliação insuficiente; sigilo (nenhum papel lê
--  private.rating_votes; resumo do admin sem autoria); correção de gols durante a votação avisa quem avaliou o jogador
--  e não mexe nas notas; ATU integrado; OVR oculto com menos de 5 partidas; isolamento entre peladas.
--  Dados: posição exige admin após a 1ª partida oficial (pedido + aprovação, transição registrada); defesas difíceis
--  só pela gestão e só para goleiro; DIS 70 sem registro de cartões; amarelo -8 com registro.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 042_v5_rating_votes".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99500000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Súmula: usuários 1..12 time A, 13..24 time B; p_events já no formato da RPC.
create function pg_temp.sheet(p_pelada uuid, p_from int, p_to int) returns jsonb language sql as
 $$ select jsonb_agg(jsonb_build_object('membership_id',pg_temp.mem(p_pelada,n),'team',case when n-p_from < (p_to-p_from+1)/2 then 'A' else 'B' end))
    from generate_series(p_from,p_to) n $$;
create function pg_temp.notifs(p_type text, n int) returns int language plpgsql as
 $$ declare v int; v_role text := current_setting('role'); begin
  execute 'reset role';
  select count(*)::int into v from public.notification_events where event_type=p_type and user_id=pg_temp.uid(n);
  if v_role <> 'none' then perform set_config('role', v_role, true); end if;
  return v; end $$;

do $test$
declare v_a uuid; v_b uuid; v_tok text; v_tok_b text; i int; v_m uuid; v_draft uuid; v_s uuid; v_mb uuid; v_sb uuid;
 r jsonb; r2 jsonb; v_cur uuid; v_first uuid; v_seq1 jsonb; v_n int; v_ok boolean; v_x numeric; v_m2 uuid; v_req uuid;
 v_gk uuid; v_ev jsonb;
begin
-- V7.7 (053): este teste confere as fórmulas da V5; roda com a V5 ativa, que é exatamente o caminho de rollback
-- (desativar a versão 2 de private.rating_params). A V7.7 tem o teste 044.
update private.rating_params set active=false where version=2;
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v5-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,30) n;
perform set_config('role','authenticated',true);
for i in 1..30 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||lpad(i::text,2,'0'),true,true); end loop;
-- A: admin 1 (GOL), 2..25 jogadores; 25 não joga. B: admin 28, jogadores 2, 29, 30.
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada A','GOL'); v_tok := public.create_pelada_invite(v_a);
for i in 2..25 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok, case when i=13 then 'GOL' when i%3=0 then 'ATA' when i%3=1 then 'ZAG' else 'MEI' end); end loop;
perform pg_temp.as_user(28); v_b := public.create_pelada('Pelada B','MEI'); v_tok_b := public.create_pelada_invite(v_b);
foreach i in array array[2,29,30] loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok_b,'ATA'); end loop;

-- ===== Partida oficial: publicar a súmula finaliza na hora (sem cédula antiga) =====
perform pg_temp.as_user(1);
v_draft := public.create_match(v_a, now() - interval '3 hours');
perform public.save_match_sheet(v_draft, pg_temp.sheet(v_a,1,24),
 jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_a,3),'type','goal','quantity',2),
  jsonb_build_object('membership_id',pg_temp.mem(v_a,4),'type','assist','quantity',1)));
perform pg_temp.expect_error(format('select public.open_rating_vote(%L)',v_draft),'MATCH_NOT_OFFICIAL');
r := public.get_rating_vote(v_draft);
perform pg_temp.assert(r->>'state'='unavailable', 'rascunho: votação indisponível');
r := public.publish_match(v_draft); v_m := v_draft;
perform pg_temp.assert((select status from public.matches where id=v_m)='finalized', 'súmula publicada = partida oficial');
perform pg_temp.assert(not exists(select 1 from public.voting_sessions where match_id=v_m), 'fluxo antigo não abre sessão');
perform pg_temp.assert(public.get_rating_vote(v_m)->>'state'='ready', 'oficial sem sessão = pronta para abertura');

-- ===== Abertura =====
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select public.open_rating_vote(%L)',v_m),'STAFF_REQUIRED');
perform pg_temp.as_user(28);
perform pg_temp.expect_error(format('select public.open_rating_vote(%L)',v_m),'STAFF_REQUIRED'); -- admin de outra pelada
perform pg_temp.as_user(1);
r := public.open_rating_vote(v_m); v_s := (r->>'session_id')::uuid;
perform pg_temp.assert(r->>'state'='open', 'aberta');
perform pg_temp.assert(abs(extract(epoch from ((r->>'closes_at')::timestamptz - (select opened_at from public.rating_vote_sessions where id=v_s))) - 6*3600) < 1, 'janela de 6 horas');
perform pg_temp.assert((select count(*) from public.rating_vote_participants where session_id=v_s)=24, 'mais de 22 participantes elegíveis (24)');
perform pg_temp.expect_error(format('select public.open_rating_vote(%L)',v_m),'VOTING_ALREADY_OPENED');
perform pg_temp.assert(pg_temp.notifs('voting_opened',7)=1 and pg_temp.notifs('voting_opened',25)=0, 'aviso de abertura só para os participantes');

-- ===== Elegibilidade e sigilo do eleitor =====
perform pg_temp.assert((r->>'is_voter')::boolean and jsonb_array_length(r->'targets')=23, 'admin participante vota (23 alvos, ele fora)');
perform pg_temp.expect_error(format('select public.cast_rating_vote(%L,%L,8)',v_s,pg_temp.mem(v_a,1)),'SELF_VOTE_NOT_ALLOWED');
perform pg_temp.as_user(25);
perform pg_temp.expect_error(format('select public.cast_rating_vote(%L,%L,8)',v_s,pg_temp.mem(v_a,2)),'NOT_ELIGIBLE_VOTER');
perform pg_temp.assert(not (public.get_rating_vote(v_m)->>'is_voter')::boolean, 'membro fora da súmula não vota');
perform pg_temp.as_user(29);
perform pg_temp.expect_error(format('select public.cast_rating_vote(%L,%L,8)',v_s,pg_temp.mem(v_a,2)),'SESSION_NOT_FOUND');
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.cast_rating_vote(%L,%L,8)',v_s,pg_temp.mem(v_b,29)),'TARGET_NOT_ELIGIBLE');
perform pg_temp.expect_error(format('select public.cast_rating_vote(%L,%L,7.3)',v_s,pg_temp.mem(v_a,3)),'INVALID_RATING');
perform pg_temp.expect_error(format('select public.cast_rating_vote(%L,%L,10.5)',v_s,pg_temp.mem(v_a,3)),'INVALID_RATING');
perform pg_temp.expect_error('select count(*) from private.rating_votes','permission denied');
perform pg_temp.expect_error('select count(*) from private.rating_vote_progress','permission denied');

-- ===== Ordem fixa por eleitor, diferente entre eleitores; nota inicial 7 só vale confirmada =====
r := public.get_rating_vote(v_m); v_seq1 := r->'targets';
perform pg_temp.assert(public.get_rating_vote(v_m)->'targets' = v_seq1, 'mesma ordem ao reabrir');
perform pg_temp.assert((r->>'rated')::int = 0, 'nada registrado antes de confirmar (7,0 inicial não é voto)');
perform pg_temp.as_user(3);
perform pg_temp.assert((select array_agg(x->>'membership_id') from jsonb_array_elements(public.get_rating_vote(v_m)->'targets') x)
 is distinct from (select array_agg(x->>'membership_id') from jsonb_array_elements(v_seq1) x), 'ordens diferentes entre eleitores');
perform pg_temp.assert((select bool_or((x->>'is_teammate')::boolean) and bool_or(not (x->>'is_teammate')::boolean)
 from (select x from jsonb_array_elements(public.get_rating_vote(v_m)->'targets') x limit 8) t), 'companheiros e adversários misturados');

-- ===== Fluxo do eleitor 2: confirmar, pular, segunda passada, revisão =====
perform pg_temp.as_user(2);
r := public.get_rating_vote(v_m); v_first := (r->>'current')::uuid;
r := public.cast_rating_vote(v_s, v_first, 7); -- 7,0 confirmado explicitamente
r := public.cast_rating_vote(v_s, v_first, 7); -- reenvio (falha de conexão) não duplica
perform pg_temp.assert((r->>'rated')::int = 1 and (r->>'current')::uuid <> v_first, 'nota salva e avançou');
v_cur := (r->>'current')::uuid;
r := public.skip_rating_vote(v_s, v_cur);
perform pg_temp.assert((r->>'current')::uuid <> v_cur and (r->>'rated')::int = 1, 'pular não registra nota');
for i in 1..21 loop r := public.cast_rating_vote(v_s, (r->>'current')::uuid, 6); end loop;
perform pg_temp.assert(r->>'phase'='second' and (r->>'current')::uuid = v_cur, 'pulado reaparece uma vez no fim');
r := public.skip_rating_vote(v_s, v_cur);
perform pg_temp.assert(r->>'phase'='review', 'pulado de novo: vai para a revisão, sem repetir');
perform pg_temp.assert((select (x->>'skipped')::boolean and x->>'my_rating' is null from jsonb_array_elements(r->'targets') x
 where (x->>'membership_id')::uuid = v_cur), 'na revisão aparece sem nota');
r := public.cast_rating_vote(v_s, v_first, 9.5); -- revisão: substitui
perform pg_temp.assert((select (x->>'my_rating')::numeric from jsonb_array_elements(r->'targets') x where (x->>'membership_id')::uuid=v_first)=9.5,
 'correção substitui a nota anterior');
-- Retomada: outro "aparelho" lê o mesmo estado.
perform pg_temp.assert(public.get_rating_vote(v_m)->>'phase'='review' and (public.get_rating_vote(v_m)->>'rated')::int=22, 'progresso retomado do servidor');
execute 'reset role';
perform pg_temp.assert((select count(*) from private.rating_votes where session_id=v_s and voter_membership_id=pg_temp.mem(v_a,2))=22,
 'um voto ativo por eleitor e avaliado');
perform set_config('role','authenticated',true);

-- ===== Notas controladas para o jogador 5 (time A) e 14 (time B) =====
-- Jogador 5: companheiros 10 e 10, adversário 6 => 0,5*10 + 0,5*6 = 8. Jogador 14: só companheiro => insuficiente.
perform pg_temp.as_user(6); perform public.cast_rating_vote(v_s, pg_temp.mem(v_a,5), 10);
perform pg_temp.as_user(7); perform public.cast_rating_vote(v_s, pg_temp.mem(v_a,5), 10);
perform pg_temp.as_user(15); perform public.cast_rating_vote(v_s, pg_temp.mem(v_a,5), 6);
perform pg_temp.as_user(16); perform public.cast_rating_vote(v_s, pg_temp.mem(v_a,14), 10);
perform public.cast_rating_vote(v_s, pg_temp.mem(v_a,3), 0);
perform pg_temp.as_user(4); perform public.cast_rating_vote(v_s, pg_temp.mem(v_a,3), 10); -- companheiro do 3
perform pg_temp.as_user(3); perform public.set_rating_vote_awards(v_s, pg_temp.mem(v_a,5), null);
perform pg_temp.expect_error(format('select public.set_rating_vote_awards(%L,%L,null)',v_s,pg_temp.mem(v_a,3)),'SELF_VOTE_NOT_ALLOWED');
-- Voto 2 do jogador 2 sobre o 5 e o 14 entrou no fluxo (6 ou 9,5): sobrescreve com valores conhecidos.
execute 'reset role';
perform set_config('minuto91.vote_purge','on',true); -- só o teste: V7.7 (053) proíbe apagar voto
delete from private.rating_votes where session_id=v_s and voter_membership_id=pg_temp.mem(v_a,2)
 and target_membership_id in (pg_temp.mem(v_a,5), pg_temp.mem(v_a,14), pg_temp.mem(v_a,3));
perform set_config('role','authenticated',true);

-- ===== Resumo do admin: só agregados =====
perform pg_temp.as_user(1);
r := public.get_rating_vote_admin(v_s);
perform set_config('minuto91.vote_purge','',true);
perform pg_temp.assert((r->>'participants')::int=24 and (r->>'voters_complete')::int + (r->>'voters_in_progress')::int >= 6, 'contagens do admin');
perform pg_temp.assert(not (r ? 'average_rating') and not exists(select 1 from jsonb_array_elements(r->'players') x), 'V7.7: sem média nem validade provisória');
perform pg_temp.assert(not (r::text like '%voter%rating%') and not exists(select 1 from jsonb_array_elements(r->'players') x
 where x ? 'rating' or x ? 'votes' or x ? 'voters'), 'resumo do admin sem autoria nem notas individuais');
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select public.get_rating_vote_admin(%L)',v_s),'STAFF_REQUIRED');

-- ===== Correção de gols durante a votação =====
perform pg_temp.as_user(1);
perform public.correct_match_sheet(v_m, pg_temp.sheet(v_a,1,24),
 jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_a,3),'type','goal','quantity',2),
  jsonb_build_object('membership_id',pg_temp.mem(v_a,5),'type','goal','quantity',1),
  jsonb_build_object('membership_id',pg_temp.mem(v_a,4),'type','assist','quantity',1)), 'gol esquecido');
perform pg_temp.assert(pg_temp.notifs('sheet_corrected',6)=1 and pg_temp.notifs('sheet_corrected',15)=1,
 'quem avaliou o jogador corrigido é avisado');
perform pg_temp.assert(pg_temp.notifs('sheet_corrected',16)=0, 'quem não avaliou o jogador corrigido não é avisado');
perform pg_temp.as_user(6);
perform pg_temp.assert((select (x->>'goals')::int from jsonb_array_elements(public.get_rating_vote(v_m)->'targets') x
 where (x->>'membership_id')::uuid=pg_temp.mem(v_a,5))=1 and (select (x->>'my_rating')::numeric from jsonb_array_elements(public.get_rating_vote(v_m)->'targets') x
 where (x->>'membership_id')::uuid=pg_temp.mem(v_a,5))=10, 'gols atualizados na votação, nota mantida');

-- ===== Lembretes, prorrogação, prazo =====
execute 'reset role';
update public.rating_vote_sessions set opened_at=now()-interval '3 hours' where id=v_s;
perform private.rating_vote_tick();
perform pg_temp.assert(pg_temp.notifs('voting_closing_soon',8)=1, 'lembrete de 2 h para pendente');
perform pg_temp.assert(pg_temp.notifs('voting_closing_soon',2)=0, 'quem concluiu não recebe lembrete');
perform private.rating_vote_tick();
perform pg_temp.assert(pg_temp.notifs('voting_closing_soon',8)=1, 'lembrete não repete');
update public.rating_vote_sessions set closes_at=clock_timestamp()+interval '30 minutes' where id=v_s;
perform private.rating_vote_tick();
perform pg_temp.assert(pg_temp.notifs('voting_closing_soon',8)=2, 'lembrete de 1 h antes do fim');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select public.extend_rating_vote(%L,60)',v_s),'STAFF_REQUIRED');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.extend_rating_vote(%L,5)',v_s),'INVALID_EXTENSION');
r := public.extend_rating_vote(v_s, 60);
perform pg_temp.assert((select count(*) from public.rating_vote_extensions where session_id=v_s and added_minutes=60)=1, 'prorrogação registrada');
execute 'reset role';
update public.rating_vote_sessions set closes_at=clock_timestamp()+interval '50 minutes' where id=v_s;
perform private.rating_vote_tick();
perform pg_temp.assert(pg_temp.notifs('voting_closing_soon',8)=3, 'lembrete refeito para o novo prazo');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.publish_rating_vote(%L)',v_s),'VOTING_STILL_OPEN');
execute 'reset role';
update public.rating_vote_sessions set closes_at=clock_timestamp()-interval '1 second' where id=v_s;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(9);
perform pg_temp.expect_error(format('select public.cast_rating_vote(%L,%L,8)',v_s,pg_temp.mem(v_a,5)),'VOTING_CLOSED');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.extend_rating_vote(%L,60)',v_s),'VOTING_CLOSED');
perform pg_temp.assert(public.get_rating_vote(v_m)->>'state'='awaiting_publication', 'prazo vencido = aguardando publicação');
execute 'reset role';
perform private.rating_vote_tick();
perform pg_temp.assert((select status from public.rating_vote_sessions where id=v_s)='published', 'V7.7: encerramento e publicação automáticos');
perform pg_temp.assert(pg_temp.notifs('voting_closing_soon',8)=3, 'sessão encerrada não gera lembrete');
perform set_config('role','authenticated',true);

-- ===== Publicação =====
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select public.publish_rating_vote(%L)',v_s),'STAFF_REQUIRED');
perform pg_temp.as_user(1);
r := public.publish_rating_vote(v_s);
perform pg_temp.assert(r->>'state'='published', 'publicada');
v_n := (select count(*) from public.awards where match_id=v_m);
r := public.publish_rating_vote(v_s);
perform pg_temp.assert(v_n = (select count(*) from public.awards where match_id=v_m), 'publicação idempotente (prêmios)');
execute 'reset role';
perform pg_temp.assert((select count(*) from private.rating_vote_results where session_id=v_s)=24, 'resultados uma vez');
perform pg_temp.assert(not exists(select 1 from public.awards where match_id=v_m and award_type='match_craque'), 'Craque exige 3 escolhas');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(20);
select final_rating into v_x from public.match_player_results where match_id=v_m and membership_id=pg_temp.mem(v_a,5);
perform pg_temp.assert(v_x = 8, 'nota 50/50: (10+10)/2 e 6 => 8');
perform pg_temp.assert((select final_rating is null and not has_valid_rating from public.match_player_results
 where match_id=v_m and membership_id=pg_temp.mem(v_a,14)), 'só um grupo: avaliação insuficiente, sem nota fictícia');
perform pg_temp.assert((select final_rating from public.match_player_results where match_id=v_m and membership_id=pg_temp.mem(v_a,3))=5,
 'nota 0 e nota 10 aceitas (0,5*0 + 0,5*10)');
perform pg_temp.assert((select numeric_rating_count from public.match_player_results where match_id=v_m and membership_id=pg_temp.mem(v_a,5))=0,
 'quantidade de votos não é pública');
-- ATU integrado: J=1, m=1, f(8)=80 => 70 + 10/3.
perform pg_temp.assert(abs((select atu from public.player_ratings where membership_id=pg_temp.mem(v_a,5)) - (70 + 10.0/3)) < 1e-5, 'ATU após publicação');
perform pg_temp.assert((select atu from public.player_ratings where membership_id=pg_temp.mem(v_a,14))=70, 'sem nota válida: ATU 70');
perform pg_temp.assert((select ovr_display is null and not eligible from public.player_ratings where membership_id=pg_temp.mem(v_a,5)),
 'menos de 5 partidas: sem OVR exibido');
perform pg_temp.assert((public.get_player_rating(pg_temp.mem(v_a,5))->>'ovr') is null and (public.get_player_rating(pg_temp.mem(v_a,5))->>'matches_needed')::int=4,
 'card em avaliação, faltam 4');
perform pg_temp.assert(exists(select 1 from public.player_rating_history where membership_id=pg_temp.mem(v_a,5) and event='votes_published' and kind='original'),
 'histórico registra a publicação');
perform pg_temp.as_user(1);
-- V7.7 (054): depois da publicação só a correção excepcional, sem mudar eleitorado; nota publicada não muda.
v_ev := jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_a,3),'type','goal','quantity',2),
  jsonb_build_object('membership_id',pg_temp.mem(v_a,5),'type','goal','quantity',1),
  jsonb_build_object('membership_id',pg_temp.mem(v_a,4),'type','assist','quantity',1));
perform pg_temp.expect_error(format('select public.correct_match_sheet(%L,%L,%L,%L)',v_m,pg_temp.sheet(v_a,1,23),v_ev,'tirar um jogador'),'CORRECTION_CHANGES_ELECTORATE');
r := public.correct_match_sheet(v_m, pg_temp.sheet(v_a,1,24), '[]', 'x pós');
perform pg_temp.assert((r->>'exceptional')::boolean, 'correção excepcional aceita');
perform pg_temp.assert((select final_rating from public.match_player_results where match_id=v_m and membership_id=pg_temp.mem(v_a,5))=8, 'nota publicada intacta');
perform pg_temp.assert((select status from public.rating_vote_sessions where id=v_s)='published', 'continua publicada, sem nova publicação');
perform public.correct_match_sheet(v_m, pg_temp.sheet(v_a,1,24), v_ev, 'volta os gols');
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select public.correct_match_sheet(%L,%L,%L,%L)',v_m,pg_temp.sheet(v_a,1,24),'[]','x pós'),'STAFF_REQUIRED');
perform pg_temp.as_user(1);
-- Isolamento: o jogador 2 não tem nada na pelada B.
perform pg_temp.assert(not exists(select 1 from public.player_ratings where membership_id=pg_temp.mem(v_b,2) and matches_played>0), 'peladas isoladas');

-- ===== Cinco partidas: OVR aparece =====
for i in 1..4 loop
 v_m2 := public.create_match(v_a, now() - make_interval(hours => 2 - i*0));
 perform public.save_match_sheet(v_m2, pg_temp.sheet(v_a,1,24), '[]');
 perform public.publish_match(v_m2);
end loop;
perform pg_temp.assert((select eligible and ovr_display between 0 and 99 from public.player_ratings where membership_id=pg_temp.mem(v_a,5)),
 '5 partidas: OVR exibido');
perform pg_temp.assert((select c.tier from public.player_cards c join public.player_ratings r on r.membership_id=c.membership_id
 where c.membership_id=pg_temp.mem(v_a,5) order by c.updated_at desc limit 1) =
 case when (select ovr_display from public.player_ratings where membership_id=pg_temp.mem(v_a,5)) < 65 then 'bronze'
  when (select ovr_display from public.player_ratings where membership_id=pg_temp.mem(v_a,5)) < 80 then 'prata' else 'ouro' end,
 'carta usa o OVR v2 e as faixas 65/80');
perform pg_temp.assert((select dis from public.player_ratings where membership_id=pg_temp.mem(v_a,5))=70, 'sem registro de cartões: DIS 70');

-- ===== Posição exige admin depois da 1ª partida oficial =====
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select public.set_my_position(%L,%L)',v_a,'ATA'),'POSITION_CHANGE_NEEDS_ADMIN');
v_req := public.request_position_change(v_a, 'ATA');
perform pg_temp.expect_error(format('select public.decide_position_change(%L,true)',v_req),'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
perform public.decide_position_change(v_req, true);
perform pg_temp.assert((select count(*) from public.position_changes where membership_id=pg_temp.mem(v_a,5))=1, 'troca registrada com versão');
perform pg_temp.assert((select transition_k=0 and position='ATA' from public.player_ratings where membership_id=pg_temp.mem(v_a,5)), 'transição iniciada (k=0)');
perform pg_temp.as_user(25);
perform public.set_my_position(v_a, 'VOL'); -- sem partida oficial: o próprio jogador escolhe

-- ===== Defesas difíceis =====
perform pg_temp.as_user(13);
select id into v_gk from public.match_participants where match_id=v_m and membership_id=pg_temp.mem(v_a,13);
perform pg_temp.expect_error(format('select public.set_match_hard_saves(%L,%L)',v_m,jsonb_build_array(jsonb_build_object('participant_id',v_gk,'hard_saves',5))),'STAFF_REQUIRED');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.set_match_hard_saves(%L,%L)',v_m,jsonb_build_array(jsonb_build_object('participant_id',
 (select id from public.match_participants where match_id=v_m and membership_id=pg_temp.mem(v_a,5)),'hard_saves',5))),'NOT_A_GOALKEEPER');
v_x := (select est from public.player_ratings where membership_id=pg_temp.mem(v_a,13));
perform public.set_match_hard_saves(v_m, jsonb_build_array(jsonb_build_object('participant_id',v_gk,'hard_saves',5)));
perform pg_temp.assert((select est from public.player_ratings where membership_id=pg_temp.mem(v_a,13)) > v_x, 'defesas difíceis elevam o EST do goleiro');

-- ===== Cartões =====
perform public.set_cards_tracking(v_a, true);
v_m2 := public.create_match(v_a, now() - interval '30 minutes');
perform public.save_match_sheet(v_m2, pg_temp.sheet(v_a,1,24),
 jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_a,6),'type','yellow_card','quantity',1),
  jsonb_build_object('membership_id',pg_temp.mem(v_a,7),'type','second_yellow','quantity',1)));
perform pg_temp.expect_error(format('select public.save_match_sheet(%L,%L,%L)',v_m2,pg_temp.sheet(v_a,1,24),
 jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_a,6),'type','yellow_card','quantity',2))),'INVALID_EVENT');
perform public.publish_match(v_m2);
perform pg_temp.assert((select discipline_status from public.matches where id=v_m2)='confirmed', 'registro ligado: súmula confirma disciplina');
perform pg_temp.assert((select dis from public.player_ratings where membership_id=pg_temp.mem(v_a,6))=62, 'amarelo: 70-8');
perform pg_temp.assert((select dis from public.player_ratings where membership_id=pg_temp.mem(v_a,7))=50, 'segundo amarelo = um vermelho: 70-20');
perform pg_temp.assert(abs((select dis from public.player_ratings where membership_id=pg_temp.mem(v_a,8)) - (70+0.06*29)) < 1e-6, 'partida limpa recupera');
perform public.set_match_discipline_status(v_m2, 'pending');
perform pg_temp.assert((select dis from public.player_ratings where membership_id=pg_temp.mem(v_a,8))=70, 'pendente não conta como limpa');
perform public.set_cards_tracking(v_a, false);
perform pg_temp.assert((select dis from public.player_ratings where membership_id=pg_temp.mem(v_a,6))=70, 'registro desligado: DIS 70');

raise exception 'PASS: 042_v5_rating_votes';
end $test$;
