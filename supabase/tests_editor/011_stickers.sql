-- Álbum de figurinhas (migrações 017 e 018). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 011_stickers" = tudo certo, nada gravado.
-- Os resultados das partidas são gravados direto (como a finalização da 013 faria).
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('b0000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Figurinhas ativas do membro (códigos, em ordem).
create function pg_temp.active(p_mem uuid) returns text[] language sql as
 $$ select coalesce(array_agg(d.code order by d.code),'{}') from public.player_sticker_unlocks u
    join public.sticker_definitions d on d.id=u.sticker_definition_id
    where u.membership_id=p_mem and u.status='active' $$;

do $test$
declare
  v_pid uuid; v_mem uuid; v_month date; v_base timestamptz; v_x uuid[] := '{}'; v_id uuid; v_n int;
begin
-- ===== Catálogo =====
perform pg_temp.assert((select count(*)=9 from public.sticker_collections),'9 coleções');
perform pg_temp.assert((select count(*)=48 from public.sticker_definitions),'48 figurinhas');
perform pg_temp.assert((select count(*)=4 from public.sticker_definitions where name like '% Lendário' and level=6),'4 Lendários (nível 6)');
perform pg_temp.assert((select array_agg(threshold order by level)=array[3,5,10,15,20] from public.sticker_definitions
  where metric_code='best_win_streak'),'Pé Quente: 3, 5, 10, 15, 20 vitórias seguidas');
perform pg_temp.assert((select name='Craque Lendário' and threshold=100 from public.sticker_definitions where code='craque_100'),'Craque Lendário = 100');

insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-s'||n||'@example.invalid','',now(),now(),now() from generate_series(1,2) n;
perform set_config('role','authenticated',true);
for i in 1..2 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Album','attacker');
execute 'reset role';
select id into v_mem from public.pelada_memberships where pelada_id=v_pid and user_id=pg_temp.uid(1);

-- ===== 3 vitórias no mês passado: 1 gol e nota 8 em cada; Craque na partida 1 =====
v_month := (date_trunc('month', private.pelada_today(v_pid)) - interval '1 month')::date;
v_base := (v_month + 2 + time '20:00') at time zone 'America/Sao_Paulo';
for k in 1..3 loop
 insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
 values(v_pid,private.season_for_date(v_pid,private.pelada_local_date(v_pid,v_base+(k-1)*interval '1 day')),
  v_base+(k-1)*interval '1 day','finalized',1,0,now()) returning id into v_id;
 v_x := v_x || v_id;
 insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,
  objective_rating,final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
 values(v_pid,v_id,v_mem,8,7.5,8,8,true,1,0,0,'win','attacker',1);
 if k = 1 then
  insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count)
  select v_pid,v_id,season_id,v_mem,'match_craque',5 from public.matches where id=v_id;
 end if;
 perform private.after_match_finalized(v_id);
end loop;

-- Artilheiro I (3 gols), Presença I (3 jogos), Pé Quente I (3 seguidas), Nota Alta I,
-- Craque I e Rei do Mês I (média 8 em 3 jogos no mês passado). Garçom e Invencível: não.
perform pg_temp.assert(pg_temp.active(v_mem) = array['artilheiro_1','craque_1','nota_alta_1','pe_quente_3',
  'presenca_1','rei_do_mes_1'],'6 figurinhas desbloqueadas: '||pg_temp.active(v_mem)::text);
perform pg_temp.assert((select count(*)=48 from public.player_sticker_progress where membership_id=v_mem),'progresso de todas as 48');
perform pg_temp.assert((select current_value=3 and target_value=10 and not is_unlocked from public.player_sticker_progress p
  join public.sticker_definitions d on d.id=p.sticker_definition_id where p.membership_id=v_mem and d.code='artilheiro_10'),'Artilheiro II: 3/10 bloqueada');
perform pg_temp.assert((select current_value=3 and target_value=5 from public.player_sticker_progress p
  join public.sticker_definitions d on d.id=p.sticker_definition_id where p.membership_id=v_mem and d.code='invencivel_5'),'Invencível I: 3/5');

-- Idempotente: reprocessar não duplica desbloqueio nem evento.
select count(*) into v_n from private.sticker_events where membership_id=v_mem;
perform private.reconcile_sticker_unlocks(v_mem);
perform private.after_match_finalized(v_x[3]);
perform pg_temp.assert((select count(*) from private.sticker_events where membership_id=v_mem)=v_n,'sem eventos duplicados');
perform pg_temp.assert((select count(*)=6 from public.player_sticker_unlocks where membership_id=v_mem),'sem desbloqueio duplicado');

-- ===== Partida 3 deixa de contar (anulação, 020): revoga o que não vale mais =====
update public.matches set status='annulled' where id=v_x[3];
perform private.close_month(v_pid, v_month); -- a anulação (020) fará este recálculo do mês
perform private.after_match_finalized(v_x[3]);
-- Sobram 2 vitórias e 2 notas válidas: perde Pé Quente I e Rei do Mês I (mínimo de 3 no mês).
perform pg_temp.assert(pg_temp.active(v_mem) = array['artilheiro_1','craque_1','nota_alta_1','presenca_1'],'revogadas: '||pg_temp.active(v_mem)::text);
perform pg_temp.assert((select count(*)=2 from private.sticker_events where membership_id=v_mem and event_type='revoked'),'2 revogações registradas');
perform pg_temp.assert((select count(*)=2 and bool_and(revoked_at is not null) from public.player_sticker_unlocks
  where membership_id=v_mem and status='revoked'),'histórico de revogação guardado');

-- Volta a contar: reativa.
update public.matches set status='finalized' where id=v_x[3];
perform private.after_match_finalized(v_x[3]);
perform pg_temp.assert(array_length(pg_temp.active(v_mem),1)=6,'reativadas');
perform pg_temp.assert((select count(*)=2 from private.sticker_events where membership_id=v_mem and event_type='reactivated'),'2 reativações registradas');

-- ===== Leituras pelo app =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.assert((select count(*)=6 from public.player_sticker_unlocks where membership_id=v_mem and status='active'),'jogador vê o próprio álbum');
perform pg_temp.expect_error('select * from private.sticker_events','permission denied');
perform pg_temp.expect_error('update public.player_sticker_progress set current_value=999','permission denied');
perform pg_temp.expect_error(format('select private.reconcile_sticker_unlocks(%L)',v_mem),'permission denied');
perform pg_temp.as_user(2);
perform pg_temp.assert((select count(*)=48 from public.sticker_definitions),'catálogo visível para todos');
perform pg_temp.assert((select count(*)=0 from public.player_sticker_progress where membership_id=v_mem),'de fora não vê o álbum');

  raise exception 'PASS: 011_stickers (rollback proposital - nada foi gravado)';
end
$test$;
