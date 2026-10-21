-- Anulação de partida (migração 020). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 013_annulment" = tudo certo, nada gravado.
-- Os resultados das partidas são gravados direto (como a finalização da 013 faria).
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('d0000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.active(p_mem uuid) returns text[] language sql as
 $$ select coalesce(array_agg(d.code order by d.code),'{}') from public.player_sticker_unlocks u
    join public.sticker_definitions d on d.id=u.sticker_definition_id
    where u.membership_id=p_mem and u.status='active' $$;
create function pg_temp.annul_sql(p_match uuid, p_cat text, p_desc text, p_confirm boolean) returns text language sql as
 $$ select format('select public.annul_match(%L,%L,%L,%L)',p_match,p_cat,p_desc,p_confirm) $$;

do $test$
declare
  v_pid uuid; v_tok text; v_month date; v_base timestamptz; v_x uuid[] := '{}'; v_id uuid; v_draft uuid; v_r jsonb;
  pos text[] := array['attacker','goalkeeper','defender','defender','defender','defender',
                      'midfielder','midfielder','midfielder','attacker','attacker'];
  m1 uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-an'||n||'@example.invalid','',now(),now(),now() from generate_series(1,12) n;
perform set_config('role','authenticated',true);
for i in 1..12 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Anulacao','attacker');
v_tok := public.create_pelada_invite(v_pid);
for i in 2..11 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,pos[i]); end loop;
perform pg_temp.as_user(1);
v_draft := public.create_match(v_pid,now());
execute 'reset role';
m1 := pg_temp.mem(v_pid,1);

-- Mês passado: jogador 1 vence 3 partidas com gol e nota 8 (assistência na 2).
-- Na partida 3 jogam os 11 com nota (Seleção) e o jogador 1 é o Craque.
v_month := (date_trunc('month', private.pelada_today(v_pid)) - interval '1 month')::date;
v_base := (v_month + 2 + time '20:00') at time zone 'America/Sao_Paulo';
for k in 1..3 loop
 insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
 values(v_pid,private.season_for_date(v_pid,private.pelada_local_date(v_pid,v_base+(k-1)*interval '1 day')),
  v_base+(k-1)*interval '1 day','finalized',1,0,now()) returning id into v_id;
 v_x := v_x || v_id;
 insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,
  objective_rating,final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
 values(v_pid,v_id,m1,8,7.5,8,8,true,1,case when k=2 then 1 else 0 end,0,'win','attacker',1);
 if k = 3 then
  insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,
   objective_rating,final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
  select v_pid,v_id,pg_temp.mem(v_pid,i),6,6,5,6,true,0,0,0,'loss',pos[i],1 from generate_series(2,11) i;
  insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count)
  select v_pid,v_id,season_id,m1,'match_craque',6 from public.matches where id=v_id;
 end if;
 perform private.after_match_finalized(v_id);
end loop;
perform pg_temp.assert(pg_temp.active(m1) = array['artilheiro_1','craque_1','garcom_1','nota_alta_1','pe_quente_3',
  'presenca_1','rei_do_mes_1','selecao_1'],'antes: '||pg_temp.active(m1)::text);
perform pg_temp.assert(exists(select 1 from public.round_selections where match_id=v_x[3] and status='published'),'Seleção da partida 3');

-- ===== Validações =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.preview_match_annulment(%L)',v_x[3]),'ADMIN_REQUIRED');
perform pg_temp.expect_error(pg_temp.annul_sql(v_x[3],'sheet_error','Placar lançado errado',true),'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(pg_temp.annul_sql(v_x[3],'chuva','Placar lançado errado',true),'INVALID_REASON_CATEGORY');
perform pg_temp.expect_error(pg_temp.annul_sql(v_x[3],'sheet_error','curto',true),'DESCRIPTION_REQUIRED');
perform pg_temp.expect_error(pg_temp.annul_sql(v_x[3],'sheet_error','Placar lançado errado',false),'CONFIRMATION_REQUIRED');
perform pg_temp.expect_error(pg_temp.annul_sql(v_draft,'other','Rascunho não pode ser anulado',true),'MATCH_NOT_FINALIZED');
execute 'reset role';
update public.matches set finalized_at=now()-interval '8 days' where id=v_x[1];
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(pg_temp.annul_sql(v_x[1],'duplicate_match','Partida lançada duas vezes',true),'ANNULMENT_WINDOW_EXPIRED');

-- ===== Prévia dos efeitos =====
v_r := public.preview_match_annulment(v_x[3]);
perform pg_temp.assert((v_r->>'can_annul')::boolean and (v_r->>'players_affected')::int=11
  and jsonb_array_length(v_r->'awards_revoked')=1 and (v_r->>'has_round_selection')::boolean
  and (v_r->>'month_awards_recomputed')::boolean,'prévia: '||v_r::text);

-- ===== Anular a partida 3 =====
v_r := public.annul_match(v_x[3],'match_not_played','Essa partida não aconteceu, foi lançada por engano',true);
perform pg_temp.assert((v_r->>'annulled')::boolean and not (v_r->>'already_annulled')::boolean,'anulada');
v_r := public.annul_match(v_x[3],'other','Repetindo a anulação para testar',true);
perform pg_temp.assert((v_r->>'already_annulled')::boolean,'idempotente');
perform pg_temp.assert((select count(*)=1 from public.match_annulments where match_id=v_x[3]),'membro vê a anulação');
execute 'reset role';

perform pg_temp.assert((select status='annulled' from public.matches where id=v_x[3]),'partida não apagada, só anulada');
perform pg_temp.assert((select count(*)=11 from public.match_player_results where match_id=v_x[3]),'resultados guardados');
perform pg_temp.assert((select status='revoked' from public.awards where match_id=v_x[3] and award_type='match_craque'),'Craque revogado');
perform pg_temp.assert((select status='revoked' from public.round_selections where match_id=v_x[3]),'Seleção revogada');
perform pg_temp.assert((select matches_played=2 and goals=2 and craque_awards=0 from public.player_season_stats
  where membership_id=m1),'estatísticas recalculadas');
perform pg_temp.assert((select matches_played=2 from public.player_cards where membership_id=m1),'carta recalculada');
perform pg_temp.assert((select count(*)=0 from public.player_cards where membership_id=pg_temp.mem(v_pid,5)),'quem só jogou a anulada perde a carta');
perform pg_temp.assert((select count(*)=0 from public.awards where pelada_id=v_pid and award_type='monthly_king' and status='active'),'Rei do Mês revogado (só 2 notas)');
perform pg_temp.assert(pg_temp.active(m1) = array['artilheiro_1','garcom_1','nota_alta_1','presenca_1'],'figurinhas depois: '||pg_temp.active(m1)::text);
perform pg_temp.assert((select count(*)=1 and bool_and(match_id=v_x[2] and highlight_type='garcom_round')
  from public.highlights where pelada_id=v_pid and expires_at is null),'destaque volta para a partida 2');
perform pg_temp.assert((select count(*)=1 from private.audit_events where pelada_id=v_pid and event_type='match_annulled'),'auditoria única');

perform set_config('role','authenticated',true);
perform pg_temp.as_user(12);
perform pg_temp.assert((select count(*)=0 from public.match_annulments where match_id=v_x[3]),'de fora não vê');

  raise exception 'PASS: 013_annulment (rollback proposital - nada foi gravado)';
end
$test$;
