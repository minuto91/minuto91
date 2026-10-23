-- Estatísticas, cartas, rankings, prêmios do mês e Seleção (migrações 014, 015 e 016).
-- Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 010_stats_rankings_selection" = tudo certo, nada gravado.
-- Os resultados das partidas são gravados direto (como a finalização da 013 faria) e o
-- processamento pós-finalização é chamado; as contas esperadas estão nos comentários.
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
-- V5 (051): as cartas da temporada atual passaram a usar o OVR v2. Este teste confere a fórmula v1 da planilha;
-- o bloco abaixo usa a carta v1 só durante o teste (desfeito no fim).
create or replace function private.recompute_card(p_season uuid, p_membership uuid, p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 perform private.recompute_card_v1(p_season, p_membership, p_match);
end $$;
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('a0000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Partida finalizada com resultados prontos. p_rows: [{"m":n,"pos":..,"res":..,"g":..,"a":..,"v":..,"f":..,"n":..}]
create function pg_temp.finish(p_pelada uuid, p_at timestamptz, p_a int, p_b int, p_rows jsonb) returns uuid language plpgsql as
 $$ declare v_id uuid; begin
  insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
  values(p_pelada,private.season_for_date(p_pelada,private.pelada_local_date(p_pelada,p_at)),p_at,'finalized',p_a,p_b,now())
  returning id into v_id;
  insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,
   objective_rating,final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
  select p_pelada,v_id,pg_temp.mem(p_pelada,(r->>'m')::int),coalesce((r->>'n')::int,0),(r->>'v')::numeric,5,
   (r->>'f')::numeric,r ? 'v',coalesce((r->>'g')::int,0),coalesce((r->>'a')::int,0),0,r->>'res',r->>'pos',1
  from jsonb_array_elements(p_rows) r;
  return v_id;
 end $$;

do $test$
declare
  v_pid uuid; v_tok text; v_base timestamptz; v_season uuid; v_x uuid[] := '{}'; v_rows jsonb; v_res text[];
  v_month date; v_c public.player_cards; v_s public.player_season_stats; v_sel uuid;
  pos text[] := array['attacker','midfielder','defender','goalkeeper','goalkeeper','defender','defender',
                      'midfielder','midfielder','attacker','attacker','attacker'];
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-r'||n||'@example.invalid','',now(),now(),now() from generate_series(1,13) n;
perform set_config('role','authenticated',true);
for i in 1..13 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Ranking','attacker');
v_tok := public.create_pelada_invite(v_pid);
for i in 2..12 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,pos[i]); end loop;
execute 'reset role';

-- 6 partidas no mês passado (dias 3..8, 20h no fuso da pelada).
v_month := (date_trunc('month', private.pelada_today(v_pid)) - interval '1 month')::date;
v_base := (v_month + 2 + time '20:00') at time zone 'America/Sao_Paulo';
v_res := array['win','win','win','loss','loss','draw'];
for k in 1..6 loop
 -- 1 atacante: 1 gol, V 7, nota 8 | 2 meia: 1 assistência, V 7,5, nota 8 | 3 zagueiro: V 6, nota 6
 -- (meia na partida 5) | 4 goleiro: só nas partidas 1..3, sem nota válida.
 v_rows := jsonb_build_array(
  jsonb_build_object('m',1,'pos','attacker','res',v_res[k],'g',1,'v',7,'f',8,'n',8),
  jsonb_build_object('m',2,'pos','midfielder','res',v_res[k],'a',1,'v',7.5,'f',8,'n',8),
  jsonb_build_object('m',3,'pos',case when k=5 then 'midfielder' else 'defender' end,'res',v_res[k],'v',6,'f',6,'n',6));
 if k <= 3 then v_rows := v_rows || jsonb_build_object('m',4,'pos','goalkeeper','res','win','n',2); end if;
 if k = 6 then
  -- Mais 8 jogadores com nota: 11 elegíveis para a Seleção.
  v_rows := v_rows || jsonb_build_array(
   jsonb_build_object('m',5,'pos','goalkeeper','res','draw','v',6,'f',6,'n',6),
   jsonb_build_object('m',6,'pos','defender','res','draw','v',7,'f',7,'n',6),
   jsonb_build_object('m',7,'pos','defender','res','draw','v',6.5,'f',6.5,'n',6),
   jsonb_build_object('m',8,'pos','midfielder','res','draw','v',7,'f',7,'n',6),
   jsonb_build_object('m',9,'pos','midfielder','res','draw','v',6.8,'f',6.8,'n',6),
   jsonb_build_object('m',10,'pos','attacker','res','draw','v',7.5,'f',7.5,'n',6),
   jsonb_build_object('m',11,'pos','attacker','res','draw','v',7.5,'f',7.5,'n',5),
   jsonb_build_object('m',12,'pos','attacker','res','draw','v',7,'f',7.5,'n',5));
 end if;
 v_x := v_x || pg_temp.finish(v_pid, v_base + (k-1) * interval '1 day',
  (array[3,2,4,0,1,2])[k], (array[0,1,0,1,2,2])[k], v_rows);
 if k = 2 then -- Craque da partida 2: jogador 2 (desempate do Rei do Mês)
  insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count)
  select v_pid, v_x[2], season_id, pg_temp.mem(v_pid,2), 'match_craque', 4 from public.matches where id=v_x[2];
 end if;
 perform private.after_match_finalized(v_x[k]);
end loop;
select season_id into v_season from public.matches where id=v_x[1];

-- ===== Carta do atacante (6 jogos) =====
-- Pesos: partidas 6..2 = 2, partida 1 = 1 (soma 11). Finalização 100; Garçom 0; Presença 100;
-- Pé Quente = 100 x (0,5x2 + 0 + 0 + 1x2 + 1x2 + 1x1)/11 = 54,545455; Resenha 70.
-- Overall = 0,35x100 + 0,15x0 + 0,15x100 + 0,15x54,545455 + 0,20x70 = 72,181818 -> 72 Prata.
select * into v_c from public.player_cards where season_id=v_season and membership_id=pg_temp.mem(v_pid,1);
perform pg_temp.assert(v_c.finishing=100 and v_c.assisting=0 and v_c.attendance=100 and v_c.winning=54.545455
  and v_c.peer_rating=70 and v_c.overall=72.181818 and v_c.tier='prata' and not v_c.is_provisional
  and v_c.position='attacker' and v_c.matches_played=6,'carta do atacante = planilha');
perform pg_temp.assert((select count(*)=6 from public.card_snapshots where card_id=v_c.id),'um snapshot por partida');

-- ===== Carta do goleiro (3 jogos, provisória, sem nota) =====
-- Presença 3/6 = 50; Pé Quente 100; Resenha 50 (sem nota) -> calculado 0,20x50 + 0,25x100 + 0,50x50 = 60.
-- Provisório: (50x2 + 60x3)/5 = 56 -> Bronze.
select * into v_c from public.player_cards where season_id=v_season and membership_id=pg_temp.mem(v_pid,4);
perform pg_temp.assert(v_c.attendance=50 and v_c.winning=100 and v_c.peer_rating=50 and v_c.overall=56
  and v_c.tier='bronze' and v_c.is_provisional,'carta provisória do goleiro');

-- ===== Estatísticas e sequências =====
select * into v_s from public.player_season_stats where season_id=v_season and membership_id=pg_temp.mem(v_pid,1);
perform pg_temp.assert(v_s.matches_played=6 and v_s.wins=3 and v_s.draws=1 and v_s.losses=2 and v_s.goals=6
  and v_s.valid_ratings=6 and v_s.avg_final_rating=8 and v_s.high_ratings=6
  and v_s.best_win_streak=3 and v_s.current_win_streak=0 and v_s.best_unbeaten_streak=3
  and v_s.current_unbeaten_streak=1 and v_s.best_high_rating_streak=6,'estatísticas e sequências (V V V D D E)');
perform pg_temp.assert((select matches_played=6 from public.player_career_stats where membership_id=pg_temp.mem(v_pid,1)),'carreira');
perform pg_temp.assert((select craque_awards=1 from public.player_season_stats where season_id=v_season
  and membership_id=pg_temp.mem(v_pid,2)),'Craque contado');

-- ===== Prêmios do mês =====
perform pg_temp.assert((select count(*)=1 from public.monthly_closures where pelada_id=v_pid and period_month=v_month),'mês fechado');
perform pg_temp.assert((select array_agg(membership_id)=array[pg_temp.mem(v_pid,2)] from public.awards
  where pelada_id=v_pid and award_type='monthly_king' and status='active'),'Rei do Mês: empate em 8,0 decidido pelo Craque');
perform pg_temp.assert((select array_agg(membership_id)=array[pg_temp.mem(v_pid,1)] from public.awards
  where pelada_id=v_pid and award_type='top_scorer' and status='active'),'artilheiro do mês');
perform pg_temp.assert((select array_agg(membership_id)=array[pg_temp.mem(v_pid,2)] from public.awards
  where pelada_id=v_pid and award_type='monthly_garcom' and status='active'),'Garçom do Mês (V4.6: 6 assistências)');
-- V4.6 (049): o antigo top_assist não é mais concedido.
perform pg_temp.assert(not exists(select 1 from public.awards where pelada_id=v_pid and award_type='top_assist' and status='active'),'top_assist não é mais concedido');
perform pg_temp.assert(not exists(select 1 from public.awards where pelada_id=v_pid and award_type='most_improved'
  and status='active' and membership_id=pg_temp.mem(v_pid,3)),'quem mudou de posição não concorre à evolução');
perform pg_temp.assert((select count(*)=0 from public.awards where pelada_id=v_pid and award_type in
  ('monthly_king','top_scorer','monthly_garcom') and status='active' and period_month<>v_month),'só o mês passado');
-- Recalcular o mês não duplica prêmios ativos.
perform private.close_month(v_pid, v_month);
perform pg_temp.assert((select count(*)=1 from public.awards where pelada_id=v_pid and award_type='monthly_king' and status='active'),'mês recalculado sem duplicar');

-- ===== Destaques =====
perform pg_temp.assert((select count(*)=1 and bool_and(highlight_type='garcom_round' and membership_id=pg_temp.mem(v_pid,2)
  and match_id=v_x[6]) from public.highlights where pelada_id=v_pid and expires_at is null),'destaque vigente: Garçom da rodada 6');
perform pg_temp.assert((select expires_at is not null from public.highlights where match_id=v_x[2] and highlight_type='craque'),'Craque da partida 2 expirou');

-- ===== Seleção da Rodada (partida 6) =====
-- Defensores com nota: 3, 6, 7 -> uma vaga de defensor fica vazia (sem adaptar).
-- Atacantes: 1 (8,0), 10 (7,5; 6 notas), 11 (7,5; 5 notas; V 7,5) entram; 12 (7,5; 5 notas; V 7,0) fica fora.
select id into v_sel from public.round_selections where match_id=v_x[6];
perform pg_temp.assert(v_sel is not null,'Seleção publicada com 11 elegíveis');
perform pg_temp.assert((select count(*)=10 from public.round_selection_players where selection_id=v_sel),'10 escalados');
perform pg_temp.assert((select count(*)=3 from public.round_selection_players where selection_id=v_sel and slot_position='defender'),'vaga de defensor vazia');
perform pg_temp.assert((select bool_and(slot_position=official_position and not is_adapted) from public.round_selection_players where selection_id=v_sel),'sem adaptação');
perform pg_temp.assert((select array_agg(membership_id order by rank_order) from public.round_selection_players
  where selection_id=v_sel and slot_position='attacker') = array[pg_temp.mem(v_pid,1),pg_temp.mem(v_pid,10),pg_temp.mem(v_pid,11)],'desempate dos atacantes');
-- 1 e 2 empatam em 8,0 e em 8 notas; desempata a nota dos colegas V (7,5 do jogador 2).
perform pg_temp.assert((select rank_order=1 from public.round_selection_players where selection_id=v_sel and membership_id=pg_temp.mem(v_pid,2)),'desempate geral pela nota V');
perform pg_temp.assert(not exists(select 1 from public.round_selections where match_id=v_x[5]),'menos de 11: sem Seleção');

-- ===== Leituras pelo app =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform pg_temp.assert((select rank_position=1 and metric_value=6 and membership_id=pg_temp.mem(v_pid,1)
  from public.get_season_ranking(v_season,'goals') limit 1),'ranking de gols');
perform pg_temp.assert((select count(*)=2 from public.get_season_ranking(v_season,'avg_rating') where rank_position=1),'empate no ranking de média: 1º, 1º');
perform pg_temp.assert((select count(*)=0 from public.get_season_ranking(v_season,'avg_rating')
  where membership_id=pg_temp.mem(v_pid,4)),'sem nota não entra no ranking de média');
perform pg_temp.assert((public.get_season_records(v_season)->'biggest_win'->0->>'team_a_score')='4','maior goleada 4x0');
perform pg_temp.assert((public.get_season_records(v_season)->'best_win_streak'->>'value')='3','maior sequência de vitórias');
perform pg_temp.expect_error(format('select public.get_season_ranking(%L,%L)',v_season,'red_cards'),'INVALID_METRIC');
perform pg_temp.expect_error(format('select final_rating from public.round_selection_players where selection_id=%L',v_sel),'permission denied');
perform pg_temp.expect_error('update public.player_cards set overall=99','permission denied');
perform pg_temp.assert((select count(*)=12 from public.player_cards where season_id=v_season),'membro vê as cartas');
perform pg_temp.as_user(13);
perform pg_temp.expect_error(format('select * from public.get_season_ranking(%L,%L)',v_season,'goals'),'SEASON_NOT_FOUND');
perform pg_temp.assert((select count(*)=0 from public.player_cards where season_id=v_season),'de fora não vê cartas');

  raise exception 'PASS: 010_stats_rankings_selection (rollback proposital - nada foi gravado)';
end
$test$;
