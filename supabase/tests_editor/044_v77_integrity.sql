-- V7.7 (migrações 053-056): integridade da votação, anulação/restauração, exclusão de conta e Seleção global.
--  1) Voto editado vira versão; retry não duplica; histórico do eleitor; voto e versão não se apagam.
--  2) Sigilo: resumo da gestão só com progresso, sem notas nem resultado provisório.
--  3) Prêmio em branco permitido; empate no 1º lugar = compartilhado; menos de 3 escolhas = sem prêmio.
--  4) Correção da súmula invalida (não apaga) votos de quem saiu e revalida quando volta.
--  5) Uma prorrogação comum só; aviso só para pendentes.
--  6) Publicação automática no fechamento, idempotente, prazo original preservado, "avaliação insuficiente".
--  7) Anulação de partida publicada: placar, eventos, notas e prêmios ocultos no banco; votação suspensa com estado.
--  8) Restauração: publicação original volta sem nova publicação nem duplicidade; mesmos prêmios.
--  9) Anular/restaurar repetido: um aviso coletivo por operação; retry do mesmo pedido não repete; prévia velha recusada.
-- 10) Linha do tempo pública sem descrição/autor; detalhes só para a administração.
-- 11) Votação interrompida: não reabre sozinha; retomar; reabertura 1-24 h, uma por ciclo; prorrogação intacta.
-- 12) Ex-integrante eleitor: vota, recebe lembrete, não acessa outras telas.
-- 13) Seleção 4-3-3 global com posição secundária confirmada; mínimo 11 com goleiro.
-- 14) Exclusão de conta: vaga reservada no limite de 100, recuperação sem duplicar, falha do login não conclui,
--     nova tentativa conclui; votos individuais de sessões publicadas anonimizados.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 044_v77_integrity".
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
-- Súmula: usuários p_from..p_to, metade A, metade B.
create function pg_temp.sheet(p_pelada uuid, p_from int, p_to int) returns jsonb language sql as
 $$ select jsonb_agg(jsonb_build_object('membership_id',pg_temp.mem(p_pelada,n),'team',case when n-p_from < (p_to-p_from+1)/2 then 'A' else 'B' end))
    from generate_series(p_from,p_to) n $$;
create function pg_temp.sheet_without(p_pelada uuid, p_from int, p_to int, p_out int) returns jsonb language sql as
 $$ select jsonb_agg(x) from jsonb_array_elements(pg_temp.sheet(p_pelada,p_from,p_to)) x
    where (x->>'membership_id')::uuid <> pg_temp.mem(p_pelada,p_out) $$;
create function pg_temp.notifs(p_type text, n int) returns int language plpgsql as
 $$ declare v int; v_role text := current_setting('role'); begin
  execute 'reset role';
  select count(*)::int into v from public.notification_events where event_type=p_type and user_id=pg_temp.uid(n);
  if v_role <> 'none' then perform set_config('role', v_role, true); end if;
  return v; end $$;
create function pg_temp.annul(p_match uuid, p_req uuid default gen_random_uuid()) returns jsonb language sql as
 $$ select public.annul_match(p_match,'sheet_error','Súmula lançada com erro no teste',true,
    public.preview_match_annulment(p_match)->>'preview_token',p_req) $$;
create function pg_temp.restore(p_match uuid, p_req uuid default gen_random_uuid()) returns jsonb language sql as
 $$ select public.restore_match(p_match,'Partida aconteceu, anulada por engano',true,
    public.preview_match_restoration(p_match)->>'preview_token',p_req) $$;

do $test$
declare v_y uuid; v_a uuid; v_tok text; i int; v_m uuid; v_m2 uuid; v_s uuid; v_s2 uuid; r jsonb; v_n int; v_ids uuid[]; v_close timestamptz;
 v_req uuid; v_x uuid; v_d uuid; v_tok_d text; v_sel uuid; v_ev jsonb; v_awards_before int; v_sus uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v77-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,200) n;
perform set_config('role','authenticated',true);
for i in 1..200 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||lpad(i::text,3,'0'),true,true); end loop;
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada V77','GOL'); v_tok := public.create_pelada_invite(v_a);
for i in 2..15 loop perform pg_temp.as_user(i);
 perform public.join_pelada(v_tok, (array['ZAG','ATA','ZAG','MEI','MEI','ATA','ZAG','MEI','ATA','ZAG','MEI','ATA','MEI','MEI'])[i-1]);
end loop;

-- Partida M: 1..14 (A = 1..7, B = 8..14), um gol do 3.
perform pg_temp.as_user(1);
v_m := public.create_match(v_a, now() - interval '3 hours');
v_ev := jsonb_build_array(jsonb_build_object('membership_id',pg_temp.mem(v_a,3),'type','goal','quantity',1));
perform public.save_match_sheet(v_m, pg_temp.sheet(v_a,1,14), v_ev);
perform public.publish_match(v_m);
r := public.open_rating_vote(v_m); v_s := (r->>'session_id')::uuid; v_close := (r->>'original_closes_at')::timestamptz;

-- ===== 1) Versões =====
perform pg_temp.as_user(2);
perform public.cast_rating_vote(v_s, pg_temp.mem(v_a,3), 7);
perform public.cast_rating_vote(v_s, pg_temp.mem(v_a,3), 8);
perform public.cast_rating_vote(v_s, pg_temp.mem(v_a,3), 8); -- retry de rede
r := public.get_my_rating_vote_history(v_m);
perform pg_temp.assert(jsonb_array_length(r->'versions')=2, 'nota editada = 2 versões, retry não cria a terceira: '||r::text);
perform pg_temp.assert((r->'versions'->0->>'rating')::numeric=7 and not (r->'versions'->0->>'current')::boolean
 and (r->'versions'->1->>'rating')::numeric=8 and (r->'versions'->1->>'current')::boolean, 'última versão é a que vale');
perform pg_temp.assert(not (r->>'read_only')::boolean, 'editável dentro do prazo');
perform pg_temp.as_user(3);
perform pg_temp.assert(jsonb_array_length(public.get_my_rating_vote_history(v_m)->'versions')=0, 'histórico só do próprio eleitor');
perform pg_temp.as_user(15);
perform pg_temp.expect_error(format('select public.get_my_rating_vote_history(%L)',v_m),'NOT_ELIGIBLE_VOTER');
perform pg_temp.expect_error('select count(*) from private.rating_vote_versions','permission denied');
execute 'reset role';
perform pg_temp.expect_error(format('delete from private.rating_votes where session_id=%L',v_s),'VOTE_DELETE_FORBIDDEN');
perform pg_temp.expect_error(format('update private.rating_vote_versions set rating=1 where session_id=%L',v_s),'VOTE_HISTORY_IMMUTABLE');
perform pg_temp.expect_error(format('delete from private.rating_vote_versions where session_id=%L',v_s),'VOTE_HISTORY_IMMUTABLE');
perform set_config('role','authenticated',true);

-- ===== 2) Sigilo da gestão =====
perform pg_temp.as_user(1);
r := public.get_rating_vote_admin(v_s);
perform pg_temp.assert(not (r ? 'average_rating') and not (r ? 'players') and not (r::text like '%"rating"%')
 and not (r::text like '%"valid"%'), 'resumo da gestão sem notas, média ou validade: '||r::text);
perform pg_temp.assert((select x->>'progress' from jsonb_array_elements(r->'voters') x where (x->>'membership_id')::uuid=pg_temp.mem(v_a,2))='in_progress'
 and (select x->>'progress' from jsonb_array_elements(r->'voters') x where (x->>'membership_id')::uuid=pg_temp.mem(v_a,5))='not_started',
 'progresso operacional por eleitor');
perform pg_temp.expect_error('select count(*) from private.rating_votes','permission denied');

-- ===== 3) Prêmios: empate compartilhado, em branco =====
foreach i in array array[2,4,6] loop perform pg_temp.as_user(i); perform public.set_rating_vote_awards(v_s, pg_temp.mem(v_a,3), null); end loop;
foreach i in array array[8,9,10] loop perform pg_temp.as_user(i); perform public.set_rating_vote_awards(v_s, pg_temp.mem(v_a,12), null); end loop;
perform pg_temp.as_user(11);
perform public.set_rating_vote_awards(v_s, pg_temp.mem(v_a,3), pg_temp.mem(v_a,5));
perform public.set_rating_vote_awards(v_s, null, pg_temp.mem(v_a,5)); -- Craque em branco
r := public.get_my_rating_vote_history(v_m);
perform pg_temp.assert((select count(*) from jsonb_array_elements(r->'versions') x where x->>'kind'='craque')=2
 and exists(select 1 from jsonb_array_elements(r->'versions') x where x->>'kind'='craque' and x->>'target_membership_id' is null
  and (x->>'current')::boolean), 'em branco vira versão e vale');
perform pg_temp.assert((public.get_rating_vote(v_m)->'my_awards') ? 'bola_murcha' and not ((public.get_rating_vote(v_m)->'my_awards') ? 'craque'),
 'escolha atual: só Bola Murcha');

-- ===== 4) Invalidação e revalidação =====
perform pg_temp.as_user(13); perform public.cast_rating_vote(v_s, pg_temp.mem(v_a,3), 8);
-- V10.0 (076, REV-136): nota válida exige 7 votos recebidos; votos extras de 8 para o jogador 3 (mesma média).
foreach i in array array[4,6,7,9,10,11,12] loop perform pg_temp.as_user(i); perform public.cast_rating_vote(v_s, pg_temp.mem(v_a,3), 8); end loop;
perform pg_temp.as_user(2); perform public.cast_rating_vote(v_s, pg_temp.mem(v_a,13), 6);
perform pg_temp.as_user(1);
perform public.correct_match_sheet(v_m, pg_temp.sheet_without(v_a,1,14,13), v_ev, 'o 13 não jogou');
execute 'reset role';
perform pg_temp.assert((select count(*) from private.rating_votes where session_id=v_s and invalidated_at is not null
 and (voter_membership_id=pg_temp.mem(v_a,13) or target_membership_id=pg_temp.mem(v_a,13)))=2, 'votos de/para o 13 invalidados, não apagados');
perform pg_temp.assert((select count(*) from private.rating_vote_versions where session_id=v_s and kind='invalidated')=2, 'invalidação registrada');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(13);
perform pg_temp.assert(not (public.get_rating_vote(v_m)->>'is_voter')::boolean, '13 deixou de votar');
perform pg_temp.assert(jsonb_array_length(public.get_my_rating_vote_history(v_m)->'versions')=1, 'mas vê o que registrou');
perform pg_temp.as_user(1);
perform public.correct_match_sheet(v_m, pg_temp.sheet(v_a,1,14), v_ev, 'o 13 jogou sim');
execute 'reset role';
perform pg_temp.assert((select count(*) from private.rating_votes where session_id=v_s and invalidated_at is null
 and (voter_membership_id=pg_temp.mem(v_a,13) or target_membership_id=pg_temp.mem(v_a,13)))=2, 'elegibilidade restabelecida revalida');
perform pg_temp.assert((select count(*) from private.rating_vote_versions where session_id=v_s and kind='revalidated')=2, 'revalidação registrada');
perform set_config('role','authenticated',true);

-- ===== 5) Prorrogação comum: uma só =====
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select public.extend_rating_vote(%L,30)',v_s),'STAFF_REQUIRED');
perform pg_temp.as_user(1);
r := public.extend_rating_vote(v_s, 30);
perform pg_temp.assert((r->>'extension_used')::boolean, 'prorrogação registrada');
perform pg_temp.expect_error(format('select public.extend_rating_vote(%L,30)',v_s),'EXTENSION_ALREADY_USED');
perform pg_temp.assert(pg_temp.notifs('voting_extended',5)=1 and pg_temp.notifs('voting_extended',15)=0, 'aviso só para eleitores pendentes');

-- ===== 6) Publicação automática =====
execute 'reset role';
update public.rating_vote_sessions set closes_at=clock_timestamp()-interval '1 second' where id=v_s;
perform private.rating_vote_tick();
perform pg_temp.assert((select status='published' and published_by is null and original_closes_at=v_close
 from public.rating_vote_sessions where id=v_s), 'publicada pelo servidor, prazo original preservado');
v_n := (select count(*) from public.awards where match_id=v_m);
perform private.rating_vote_tick();
perform pg_temp.assert(v_n=(select count(*) from public.awards where match_id=v_m), 'novo ciclo do agendador não duplica');
perform pg_temp.assert((select count(*) from public.awards where match_id=v_m and award_type='match_craque' and status='active' and is_shared)=2,
 'empate 3x3 no Craque: prêmio compartilhado para os dois');
perform pg_temp.assert(not exists(select 1 from public.awards where match_id=v_m and award_type='bola_murcha'), 'Bola Murcha com 1 escolha: sem prêmio');
perform pg_temp.assert((select final_rating from public.match_player_results where match_id=v_m and membership_id=pg_temp.mem(v_a,3))=8,
 'nota do 3: 0,5*8 (companheiro) + 0,5*8 (adversário)');
perform pg_temp.assert((select final_rating is null and not has_valid_rating from public.match_player_results
 where match_id=v_m and membership_id=pg_temp.mem(v_a,5)), 'sem votos suficientes: avaliação insuficiente, sem nota inventada');
select array_agg(id order by id) into v_ids from public.awards where match_id=v_m and status='active';
v_n := (select count(*) from private.rating_vote_results where session_id=v_s);
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.assert((public.get_my_rating_vote_history(v_m)->>'read_only')::boolean, 'histórico só leitura depois do encerramento');
-- V10.0 (080, REV-148): o Perfil lista só as partidas em que EU votei; (082, REV-057) o Último Jogo olha todas as peladas.
perform pg_temp.assert(exists(select 1 from jsonb_array_elements(public.get_my_vote_histories()) x where (x->>'match_id')::uuid=v_m), 'REV-148: lista a partida em que votei');
perform pg_temp.assert(public.get_my_home_last_game()->'game'->>'match_id' is not null
 and public.get_my_home_last_game()->'game'->>'participation' in ('played','listed','none'), 'REV-057: Último Jogo agregado devolve uma partida oficial concluída');
perform pg_temp.expect_error(format('select public.cast_rating_vote(%L,%L,9)',v_s,pg_temp.mem(v_a,3)),'VOTING_CLOSED');

-- ===== 7) Anular a partida publicada =====
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select public.preview_match_annulment(%L)',v_m),'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
r := public.preview_match_annulment(v_m);
perform pg_temp.assert(r->>'voting'='suspend_published' and (r->>'goals')::int=1 and (r->>'awards')::int=2 and (r->>'finance_unchanged')::boolean,
 'prévia compacta: '||r::text);
perform pg_temp.expect_error(format('select public.annul_match(%L,%L,%L,true,%L,%L)',v_m,'sheet_error','Súmula lançada com erro no teste',
 'velho',gen_random_uuid()),'PREVIEW_OUTDATED');
perform pg_temp.expect_error(format('select public.annul_match(%L,%L,%L,true,%L,null)',v_m,'sheet_error','Súmula lançada com erro no teste',
 r->>'preview_token'),'REQUEST_ID_REQUIRED');
execute 'reset role';
v_awards_before := (select count(*) from public.notification_events where event_type like 'award\_%');
perform set_config('role','authenticated',true);
v_req := gen_random_uuid();
r := pg_temp.annul(v_m, v_req);
perform pg_temp.assert((r->>'annulled')::boolean, 'anulada');
r := pg_temp.annul(v_m, v_req);
perform pg_temp.assert((r->>'already_processed')::boolean, 'retry do mesmo pedido');
perform pg_temp.assert((select count(*) from public.matches where id=v_m and status='annulled')=1, 'continua no histórico, anulada');
perform pg_temp.assert((select public_team_a_score is null and public_team_b_score is null from public.matches where id=v_m), 'placar oculto');
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select team_a_score from public.matches where id=%L',v_m),'permission denied');
perform pg_temp.assert((select count(*) from public.matches where id=v_m)=1, 'jogador vê a partida (data, equipes, status)');
perform pg_temp.assert((select count(*) from public.match_events where match_id=v_m)=0, 'gols ocultos');
perform pg_temp.assert((select count(*) from public.match_player_results where match_id=v_m)=0, 'notas ocultas');
perform pg_temp.assert((select count(*) from public.awards where match_id=v_m)=0, 'prêmios ocultos');
perform pg_temp.assert((select count(*) from public.match_versions where match_id=v_m)=0, 'súmulas versionadas ocultas');
perform pg_temp.assert(public.get_rating_vote(v_m)->>'state'='suspended' and not (public.get_rating_vote(v_m) ? 'targets'), 'votação suspensa e sem dados');
perform pg_temp.assert(public.get_match_lineup(v_m)->'team_a_score' = 'null'::jsonb, 'escalação sem placar');
perform pg_temp.as_user(1);
perform pg_temp.assert((select count(*) from public.match_events where match_id=v_m)=1, 'administração vê os dados');
execute 'reset role';
perform pg_temp.assert((select status from public.rating_vote_sessions where id=v_s)='cancelled'
 and (select previous_status from private.rating_vote_suspensions where session_id=v_s and resolved_at is null)='published',
 'sessão suspensa guardando o estado anterior');
perform pg_temp.assert((select count(*) from private.rating_votes where session_id=v_s) > 0, 'votos preservados');
perform pg_temp.assert(not exists(select 1 from public.awards where match_id=v_m and status='active'), 'prêmios revogados');
perform pg_temp.assert(pg_temp.notifs('match_annulled',5)=1 and pg_temp.notifs('match_annulled',1)=1, 'um aviso coletivo por operação');
perform pg_temp.assert(v_awards_before=(select count(*) from public.notification_events where event_type like 'award\_%'),
 'nenhum aviso de prêmio recalculado: '||(select string_agg(event_type||' '||dedupe_key,', ') from public.notification_events where event_type like 'award\_%'));
perform set_config('role','authenticated',true);

-- ===== 8) Restaurar =====
perform pg_temp.as_user(1);
r := public.preview_match_restoration(v_m);
perform pg_temp.assert(r->>'voting'='restore_publication', 'prévia: publicação volta');
r := pg_temp.restore(v_m);
perform pg_temp.assert(r->>'voting'='publication_restored', 'publicação original restaurada');
execute 'reset role';
perform pg_temp.assert((select status from public.rating_vote_sessions where id=v_s)='published', 'sessão publicada de novo');
perform pg_temp.assert(v_n=(select count(*) from private.rating_vote_results where session_id=v_s), 'sem segunda apuração');
perform pg_temp.assert(v_ids=(select array_agg(id order by id) from public.awards where match_id=v_m and status='active'),
 'os mesmos prêmios voltam, sem linhas novas');
perform pg_temp.assert((select final_rating from public.match_player_results where match_id=v_m and membership_id=pg_temp.mem(v_a,3))=8, 'nota volta');
perform pg_temp.assert((select count(*) from private.audit_events where event_type='rating_vote_published' and (metadata->>'session_id')::uuid=v_s)=1,
 'uma publicação só');
perform pg_temp.assert(pg_temp.notifs('match_restored',5)=1, 'aviso coletivo de restauração');
perform pg_temp.assert(v_awards_before=(select count(*) from public.notification_events where event_type like 'award\_%'), 'restauração sem aviso de prêmio');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(5);
perform pg_temp.assert((select public_team_a_score from public.matches where id=v_m) is not null and
 (select count(*) from public.match_events where match_id=v_m)=1, 'dados válidos voltam');

-- ===== 9) Repetir =====
perform pg_temp.as_user(1);
perform pg_temp.annul(v_m);
v_req := gen_random_uuid();
perform pg_temp.restore(v_m, v_req);
r := public.restore_match(v_m,'qualquer justificativa aqui',true,'velho',v_req);
perform pg_temp.assert((r->>'already_processed')::boolean, 'retry da restauração');
perform pg_temp.assert(pg_temp.notifs('match_annulled',5)=2 and pg_temp.notifs('match_restored',5)=2, 'cada operação avisa uma vez');
perform pg_temp.expect_error(format('select public.restore_match(%L,%L,true,%L,%L)',v_m,'Partida aconteceu de verdade','x',gen_random_uuid()),'MATCH_NOT_ANNULLED');

-- ===== 10) Linha do tempo =====
perform pg_temp.as_user(5);
r := public.get_match_status_history(v_m);
perform pg_temp.assert(jsonb_array_length(r->'events')=4 and not (r::text like '%Súmula lançada%') and not (r::text like '%actor%'),
 'linha do tempo resumida sem descrição nem autor: '||r::text);
perform pg_temp.expect_error(format('select public.get_match_status_history_admin(%L)',v_m),'ADMIN_REQUIRED');
perform pg_temp.as_user(20);
perform pg_temp.expect_error(format('select public.get_match_status_history(%L)',v_m),'MATCH_NOT_FOUND');
perform pg_temp.as_user(1);
r := public.get_match_status_history_admin(v_m);
perform pg_temp.assert(r::text like '%Súmula lançada%' and (r->'events'->0->>'actor_name') is not null, 'administração vê detalhes');

-- ===== 11) Votação interrompida =====
v_m2 := public.create_match(v_a, now() - interval '2 hours');
perform public.save_match_sheet(v_m2, pg_temp.sheet(v_a,1,14), '[]');
perform public.publish_match(v_m2);
r := public.open_rating_vote(v_m2); v_s2 := (r->>'session_id')::uuid;
perform pg_temp.as_user(2); perform public.cast_rating_vote(v_s2, pg_temp.mem(v_a,9), 6);
-- V10.0 (076, REV-136): 7 votos recebidos para o jogador 9 (adversários 6; companheiros 8), mesma média.
foreach i in array array[3,4,6,7] loop perform pg_temp.as_user(i); perform public.cast_rating_vote(v_s2, pg_temp.mem(v_a,9), 6); end loop;
foreach i in array array[11,12] loop perform pg_temp.as_user(i); perform public.cast_rating_vote(v_s2, pg_temp.mem(v_a,9), 8); end loop;

-- 12) Ex-integrante continua eleitor da partida que jogou.
v_x := pg_temp.mem(v_a,3); -- o ex-integrante não lê a lista de membros (RLS)
perform pg_temp.as_user(14);
perform public.leave_pelada(v_a);
r := public.get_rating_vote(v_m2);
perform pg_temp.assert((r->>'is_voter')::boolean and (r->>'is_former_member')::boolean and not (r->>'can_manage')::boolean, 'ex-integrante eleitor');
perform public.cast_rating_vote(v_s2, v_x, 7);
perform pg_temp.assert(exists(select 1 from jsonb_array_elements(public.get_my_pending_rating_votes()) x
 where (x->>'match_id')::uuid=v_m2 and (x->>'former_member')::boolean), 'pendência aparece para o ex-integrante');
perform pg_temp.assert((select count(*) from public.matches where id=v_m2)=0, 'sem acesso às outras telas da pelada');
perform pg_temp.expect_error(format('select public.get_match_lineup(%L)',v_m2),'MATCH_NOT_FOUND');
execute 'reset role';
update public.rating_vote_sessions set opened_at=now()-interval '3 hours' where id=v_s2;
perform private.rating_vote_tick();
perform pg_temp.assert(pg_temp.notifs('voting_closing_soon',14)=1, 'lembrete chega ao ex-integrante');
perform set_config('role','authenticated',true);

perform pg_temp.as_user(1);
perform pg_temp.annul(v_m2);
r := pg_temp.restore(v_m2);
perform pg_temp.assert(r->>'voting'='admin_decision', 'restauração não reabre sozinha');
perform pg_temp.assert(public.get_rating_vote(v_m2)->>'state'='interrupted', 'estado: interrompida, aguardando a gestão');
perform pg_temp.expect_error(format('select public.reactivate_rating_vote(%L,%L,null,%L)',v_s2,'publish','retomar'),'ORIGINAL_DEADLINE_NOT_PASSED');
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select public.reactivate_rating_vote(%L,%L,null,%L)',v_s2,'resume','retomar'),'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
r := public.reactivate_rating_vote(v_s2, 'resume', null, 'partida restaurada');
perform pg_temp.assert(r->>'state'='open', 'retomada no prazo original');
perform pg_temp.as_user(2);
perform pg_temp.assert((select (x->>'my_rating')::numeric from jsonb_array_elements(public.get_rating_vote(v_m2)->'targets') x
 where (x->>'membership_id')::uuid=pg_temp.mem(v_a,9))=6, 'voto anterior preservado');

-- Novo ciclo com o prazo original vencido: reabertura excepcional.
perform pg_temp.as_user(1);
perform pg_temp.annul(v_m2);
execute 'reset role';
update private.rating_vote_suspensions set previous_closes_at=clock_timestamp()-interval '1 hour' where session_id=v_s2 and resolved_at is null;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.restore(v_m2);
perform pg_temp.expect_error(format('select public.reactivate_rating_vote(%L,%L,null,%L)',v_s2,'resume','retomar'),'ORIGINAL_DEADLINE_PASSED');
perform pg_temp.expect_error(format('select public.reactivate_rating_vote(%L,%L,0,%L)',v_s2,'reopen','reabrir'),'INVALID_REOPEN_HOURS');
perform pg_temp.expect_error(format('select public.reactivate_rating_vote(%L,%L,25,%L)',v_s2,'reopen','reabrir'),'INVALID_REOPEN_HOURS');
r := public.reactivate_rating_vote(v_s2, 'reopen', 2, 'muitos não votaram');
perform pg_temp.assert(r->>'state'='open' and (r->>'reopened')::boolean and not (r->>'extension_used')::boolean,
 'reaberta por 2 h; a prorrogação comum continua disponível');
perform pg_temp.assert(abs(extract(epoch from ((r->>'closes_at')::timestamptz - clock_timestamp())) - 7200) < 60, 'novo prazo explícito');
perform pg_temp.expect_error(format('select public.reactivate_rating_vote(%L,%L,2,%L)',v_s2,'reopen','de novo'),'NOTHING_TO_REACTIVATE');
perform pg_temp.assert(pg_temp.notifs('voting_reopened',5)=1 and pg_temp.notifs('voting_reopened',14)=1, 'eleitores avisados, ex-integrante incluído');
perform pg_temp.as_user(10); perform public.cast_rating_vote(v_s2, pg_temp.mem(v_a,9), 8);
execute 'reset role';
perform pg_temp.assert((select reopening_id is not null from private.rating_vote_versions where session_id=v_s2
 and voter_membership_id=pg_temp.mem(v_a,10) order by id desc limit 1), 'voto vinculado à reabertura');
select cycle_id, suspension_id into v_x, v_sus from private.rating_vote_reopenings where session_id=v_s2;
perform pg_temp.expect_error(format('insert into private.rating_vote_reopenings(session_id,cycle_id,suspension_id,opened_by,reason,closes_at) values(%L,%L,%L,%L,%L,now())',
 v_s2,v_x,v_sus,pg_temp.uid(1),'x'),'duplicate key');
update public.rating_vote_sessions set closes_at=clock_timestamp()-interval '1 second' where id=v_s2;
perform private.rating_vote_tick();
perform pg_temp.assert((select status from public.rating_vote_sessions where id=v_s2)='published'
 and (select closed_at is not null from private.rating_vote_reopenings where session_id=v_s2), 'reabertura encerrada e publicada');
perform pg_temp.assert((select final_rating from public.match_player_results where match_id=v_m2 and membership_id=pg_temp.mem(v_a,9))=7,
 'votos antigos e da reabertura contam: 0,5*6 (adversário) + 0,5*8 (companheiro)');
perform set_config('role','authenticated',true);

-- ===== 13) Seleção global =====
-- V10.0 (075, REV-147): sem segunda posição; a Seleção usa só a posição principal (retrato da partida).
execute 'reset role';
-- S1: 11 notas válidas, todos cabem nas vagas 1-4-3-3 pela posição principal (o 12 é atacante).
insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
values(v_a,private.season_for_date(v_a,private.pelada_today(v_a)),now()-interval '1 hour','finalized',1,0,now()) returning id into v_x;
insert into public.match_participants(pelada_id,match_id,membership_id,team,primary_position,position_code)
select v_a, v_x, pg_temp.mem(v_a,n), case when n % 2 = 0 then 'A' else 'B' end, p, c
from (values (1,'goalkeeper','GOL'),(2,'defender','ZAG'),(4,'defender','ZAG'),(8,'defender','LD'),(11,'defender','LE'),(5,'midfielder','MEI'),(6,'midfielder','MEI'),
 (9,'midfielder','VOL'),(12,'attacker','ATA'),(3,'attacker','CA'),(7,'attacker','PD')) t(n,p,c);
insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,objective_rating,final_rating,
 has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
select v_a, v_x, pg_temp.mem(v_a,n), 0, f, 5, f, true, 0, 0, 0, 'win', p, 2
from (values (1,'goalkeeper',7.0),(2,'defender',7.0),(4,'defender',7.0),(8,'defender',7.0),(11,'defender',7.0),(5,'midfielder',9.0),
 (6,'midfielder',8.5),(9,'midfielder',8.0),(12,'attacker',7.9),(3,'attacker',6.0),(7,'attacker',5.0)) t(n,p,f);
perform private.compute_round_selection(v_x);
select id into v_sel from public.round_selections where match_id=v_x and status='published';
perform pg_temp.assert(v_sel is not null and (select count(*) from public.round_selection_players where selection_id=v_sel)=11, 'Seleção com 11');
perform pg_temp.assert((select slot_position from public.round_selection_players where selection_id=v_sel and membership_id=pg_temp.mem(v_a,12))='attacker',
 'posição principal ocupa a vaga');
perform pg_temp.assert((select algorithm_version=3 and formation='4-3-3' from public.round_selections where id=v_sel), 'algoritmo v3, 4-3-3 quando o 3º atacante vale mais');
perform pg_temp.assert((select slot_class='ATT' and position_code='CA' from public.round_selection_players where selection_id=v_sel and membership_id=pg_temp.mem(v_a,3)), 'ataque aceita CA; guarda a sigla');
perform pg_temp.assert((select slot_class='LD' from public.round_selection_players where selection_id=v_sel and membership_id=pg_temp.mem(v_a,8)), 'LD na lateral direita');
-- S2: sem goleiro de posição o gol não é fechado por ninguém (sem posição secundária): não publica.
delete from public.round_selections where match_id=v_x;
delete from public.match_player_results where match_id=v_x and membership_id=pg_temp.mem(v_a,1);
insert into public.match_participants(pelada_id,match_id,membership_id,team,primary_position,position_code) values(v_a,v_x,pg_temp.mem(v_a,10),'A','attacker','PE');
insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,objective_rating,final_rating,
 has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
values(v_a,v_x,pg_temp.mem(v_a,10),0,4,5,4,true,0,0,0,'win','attacker',2);
perform private.compute_round_selection(v_x);
perform pg_temp.assert(not exists(select 1 from public.round_selections where match_id=v_x), 'sem goleiro: sem Seleção');
-- S3: 10 notas válidas: não publica.
delete from public.match_player_results where match_id=v_x and membership_id=pg_temp.mem(v_a,7);
perform private.compute_round_selection(v_x);
perform pg_temp.assert(not exists(select 1 from public.round_selections where match_id=v_x), 'menos de 11: sem Seleção');
-- V10.0 (081, REV-101/105/106): versões da Seleção. Volta o goleiro e o 7: 12 notas, vigente v1 (o 10, nota 4, fica de fora).
insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,objective_rating,final_rating,
 has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
values(v_a,v_x,pg_temp.mem(v_a,1),0,7,5,7,true,0,0,0,'win','goalkeeper',2),(v_a,v_x,pg_temp.mem(v_a,7),0,5,5,5,true,0,0,0,'win','attacker',2);
perform private.compute_round_selection(v_x);
perform pg_temp.assert((select count(*) from public.round_selections where match_id=v_x)=1 and
 (select version=1 and status='published' from public.round_selections where match_id=v_x), 'v1 vigente');
perform private.compute_round_selection(v_x);
perform pg_temp.assert((select count(*) from public.round_selections where match_id=v_x)=1, 'recalcular igual não cria versão');
-- Mudança que troca alguém: o 10 passa a ter a melhor nota do ataque e tira o 7.
update public.match_player_results set final_rating=9, peer_rating=9 where match_id=v_x and membership_id=pg_temp.mem(v_a,10);
perform private.compute_round_selection(v_x);
perform pg_temp.assert((select count(*) from public.round_selections where match_id=v_x)=2
 and (select count(*) from public.round_selections where match_id=v_x and status='published' and version=2)=1
 and (select count(*) from public.round_selections where match_id=v_x and status='superseded' and version=1)=1, 'v2 vigente, v1 substituída');
perform pg_temp.assert((select count(*) from public.round_selection_players p join public.round_selections s on s.id=p.selection_id
 where s.match_id=v_x and s.version=1)=11, 'versão antiga preservada com os 11');
perform pg_temp.assert((select count(*) from public.round_selection_players p join public.round_selections s on s.id=p.selection_id
 where s.match_id=v_x and s.status='published' and p.membership_id=pg_temp.mem(v_a,7))=0, 'v2 sem o 7');
-- Deixa de haver 11 notas válidas: a vigente é invalidada, nada é apagado.
delete from public.match_player_results where match_id=v_x and membership_id=pg_temp.mem(v_a,7);
delete from public.match_player_results where match_id=v_x and membership_id=pg_temp.mem(v_a,3);
perform private.compute_round_selection(v_x);
perform pg_temp.assert((select count(*) from public.round_selections where match_id=v_x and status='published')=0
 and (select count(*) from public.round_selections where match_id=v_x and status='invalidated')=1
 and (select count(*) from public.round_selections where match_id=v_x)=2, 'invalidada e histórico preservado');
-- V10.0 (084, REV-118): 4-4-2 quando o 2º volante vale mais que o 3º atacante; desempate por gols; depois 4-3-3.
insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
values(v_a,private.season_for_date(v_a,private.pelada_today(v_a)),now()-interval '30 minutes','finalized',1,0,now()) returning id into v_y;
insert into public.match_participants(pelada_id,match_id,membership_id,team,primary_position,position_code)
select v_a, v_y, pg_temp.mem(v_a,n), case when n % 2 = 0 then 'A' else 'B' end, p, c
from (values (1,'goalkeeper','GOL'),(2,'defender','ZAG'),(4,'defender','ZAG'),(8,'defender','LD'),(11,'defender','LE'),(5,'midfielder','MEI'),(6,'midfielder','MEI'),
 (9,'midfielder','VOL'),(12,'midfielder','VOL'),(3,'attacker','CA'),(7,'attacker','PD'),(10,'attacker','PE')) t(n,p,c);
insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,objective_rating,final_rating,
 has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
select v_a, v_y, pg_temp.mem(v_a,n), 0, f, 5, f, true, g, 0, 0, 'win', p, 2
from (values (1,'goalkeeper',7.0,0),(2,'defender',7.0,0),(4,'defender',7.0,0),(8,'defender',7.0,0),(11,'defender',7.0,0),(5,'midfielder',6.0,0),
 (6,'midfielder',6.0,0),(9,'midfielder',8.0,0),(12,'midfielder',7.9,0),(3,'attacker',6.0,0),(7,'attacker',5.0,0),(10,'attacker',4.0,0)) t(n,p,f,g);
perform private.compute_round_selection(v_y);
perform pg_temp.assert((select formation='4-4-2' from public.round_selections where match_id=v_y and status='published'), '4-4-2: o 2º volante (7,9) vale mais que o 3º atacante (4,0)');
perform pg_temp.assert((select count(*)=11 from public.round_selection_players p join public.round_selections s on s.id=p.selection_id where s.match_id=v_y and s.status='published')
 and (select slot_class='VOL' from public.round_selection_players p join public.round_selections s on s.id=p.selection_id where s.match_id=v_y and p.membership_id=pg_temp.mem(v_a,12)), '4-4-2 com 2 VOL e 2 ATT');
-- notas iguais (4,0 = 4,0) e gols iguais: 4-3-3; com mais gols no 2º volante: 4-4-2.
update public.match_player_results set final_rating=4.0, peer_rating=4.0 where match_id=v_y and membership_id=pg_temp.mem(v_a,12);
perform private.compute_round_selection(v_y);
perform pg_temp.assert((select formation='4-3-3' from public.round_selections where match_id=v_y and status='published'), 'notas e gols iguais: 4-3-3');
update public.match_player_results set goals=2 where match_id=v_y and membership_id=pg_temp.mem(v_a,12);
perform private.compute_round_selection(v_y);
perform pg_temp.assert((select formation='4-4-2' from public.round_selections where match_id=v_y and status='published'), 'notas iguais: mais gols no 2º volante vence');
perform pg_temp.assert((select count(*)=3 from public.round_selections where match_id=v_y), 'versões preservadas nas trocas de formação');
-- Cadastro antigo (sem sigla) fica de fora.
update public.match_participants set position_code=null where match_id=v_y and membership_id=pg_temp.mem(v_a,5);
perform private.compute_round_selection(v_y);
perform pg_temp.assert(not exists(select 1 from public.round_selection_players p join public.round_selections s on s.id=p.selection_id
 where s.match_id=v_y and s.status='published' and p.membership_id=pg_temp.mem(v_a,5)), 'sem sigla: fora da Seleção');
perform set_config('role','authenticated',true);
perform set_config('role','authenticated',true);

-- ===== 14) Exclusão de conta e vagas =====
perform pg_temp.as_user(100); v_d := public.create_pelada('Pelada Cheia','GOL'); v_tok_d := public.create_pelada_invite(v_d, 168, 1000);
for i in 101..199 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok_d,'MEI'); end loop;
perform pg_temp.as_user(200);
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)',v_tok_d,'MEI'),'PELADA_FULL');
perform pg_temp.as_user(199);
perform public.request_account_deletion(true);
execute 'reset role';
perform pg_temp.assert(private.pelada_seat_count(v_d)=100, 'vaga reservada durante os 30 dias');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(200);
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)',v_tok_d,'MEI'),'PELADA_FULL');
perform pg_temp.as_user(199);
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)',v_tok,'MEI'),'ACCOUNT_DELETION_PENDING');
perform pg_temp.assert(public.get_account_status()->>'state'='recoverable', 'estado recuperável');
r := public.cancel_account_deletion();
perform pg_temp.assert((r->>'restored_memberships')::int=1 and jsonb_array_length(r->'not_restored')=0, 'recuperou a vaga');
execute 'reset role';
perform pg_temp.assert((select count(*) from public.pelada_memberships where pelada_id=v_d and user_id=pg_temp.uid(199))=1
 and (select status from public.pelada_memberships where pelada_id=v_d and user_id=pg_temp.uid(199))='active', 'sem associação duplicada');
perform set_config('role','authenticated',true);
-- Exclusão definitiva com falha no login.
perform pg_temp.as_user(199);
perform public.request_account_deletion(true);
execute 'reset role';
select id into v_req from private.account_deletion_requests where user_id=pg_temp.uid(199) and status='pending';
update private.account_deletion_requests set purge_after=now()-interval '1 minute' where id=v_req;
create function pg_temp.block_auth_delete() returns trigger language plpgsql as $f$ begin raise exception 'auth indisponível'; end $f$;
create trigger t_block before delete on auth.users for each row execute function pg_temp.block_auth_delete();
perform private.purge_account(v_req);
perform pg_temp.assert((select status='pending' and attempts=1 and next_attempt_at > now() and last_error_code like 'AUTH_DELETE_FAILED%'
 and (checkpoints->>'personal')::boolean from private.account_deletion_requests where id=v_req), 'falha no login: não conclui, agenda nova tentativa');
perform pg_temp.assert(not (select last_error_code like '%example%' from private.account_deletion_requests where id=v_req), 'erro sem dado pessoal');
perform pg_temp.assert(private.pelada_seat_count(v_d)=99, 'depois do prazo a vaga é liberada');
perform pg_temp.expect_error(format('select public.complete_account_purge_auth(%L)',v_req),'AUTH_USER_STILL_EXISTS');
perform private.run_scheduled_tasks();
perform pg_temp.assert((select attempts from private.account_deletion_requests where id=v_req)=1, 'espera antes de tentar de novo');
drop trigger t_block on auth.users;
update private.account_deletion_requests set next_attempt_at=now()-interval '1 second' where id=v_req;
perform private.run_scheduled_tasks();
perform pg_temp.assert((select status='completed' and (checkpoints->>'auth')::boolean from private.account_deletion_requests where id=v_req),
 'concluída só depois de todas as etapas');
perform pg_temp.assert(not exists(select 1 from auth.users where id=pg_temp.uid(199)), 'login apagado');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(200);
perform public.join_pelada(v_tok_d,'MEI');

-- Votos individuais de quem saiu de vez (sessão publicada) somem; o resultado oficial fica.
perform pg_temp.as_user(13);
perform public.request_account_deletion(true);
execute 'reset role';
select id into v_req from private.account_deletion_requests where user_id=pg_temp.uid(13) and status='pending';
update private.account_deletion_requests set purge_after=now()-interval '1 minute' where id=v_req;
v_n := (select count(*) from private.rating_vote_results where session_id=v_s);
v_x := pg_temp.mem(v_a,13);
perform private.purge_account(v_req);
perform pg_temp.assert(not exists(select 1 from private.rating_vote_versions where session_id=v_s and voter_membership_id=v_x)
 and not exists(select 1 from private.rating_votes v join public.pelada_memberships pm on pm.id=v.voter_membership_id
  where v.session_id=v_s and pm.user_id is null), 'votos individuais anonimizados por remoção');
perform pg_temp.assert(v_n=(select count(*) from private.rating_vote_results where session_id=v_s)
 and (select final_rating from public.match_player_results where match_id=v_m and membership_id=pg_temp.mem(v_a,3))=8, 'resultado oficial preservado');

raise exception 'PASS: 044_v77_integrity';
end $test$;
