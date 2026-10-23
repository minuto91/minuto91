-- V4.4 (migração 045): Central do Jogador, Minha Carreira, Sala de Troféus, histórico paginado, convites,
-- notificações por categoria e guia inicial.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 038_v44_central_career".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99450000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Partida finalizada (como dono do banco): súmula com participantes e eventos + resultados oficiais + cadeia oficial.
-- p_rows: [{m, team, pos, g, a}] ; placar a x b.
create function pg_temp.finish(p_pelada uuid, p_at timestamptz, a int, b int, p_rows jsonb) returns uuid language plpgsql as
 $$ declare v_id uuid; r jsonb; v_part uuid; begin
  insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score,finalized_at)
  values(p_pelada,private.season_for_date(p_pelada,private.pelada_local_date(p_pelada,p_at)),p_at,'finalized',a,b,now())
  returning id into v_id;
  for r in select * from jsonb_array_elements(p_rows) loop
   insert into public.match_participants(pelada_id,match_id,membership_id,team,primary_position)
   values(p_pelada,v_id,pg_temp.mem(p_pelada,(r->>'m')::int),r->>'team',r->>'pos') returning id into v_part;
   if coalesce((r->>'g')::int,0) > 0 then insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
    values(p_pelada,v_id,v_part,r->>'team','goal',(r->>'g')::int); end if;
   if coalesce((r->>'a')::int,0) > 0 then insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
    values(p_pelada,v_id,v_part,r->>'team','assist',(r->>'a')::int); end if;
   insert into public.match_player_results(pelada_id,match_id,membership_id,numeric_rating_count,peer_rating,
    objective_rating,final_rating,has_valid_rating,goals,assists,red_cards,match_result,position_snapshot,formula_version)
   values(p_pelada,v_id,pg_temp.mem(p_pelada,(r->>'m')::int),0,null,5,null,false,coalesce((r->>'g')::int,0),coalesce((r->>'a')::int,0),0,
    case when a=b then 'draw' when (a>b)=(r->>'team'='A') then 'win' else 'loss' end, r->>'pos',1);
  end loop;
  perform private.after_match_finalized(v_id);
  return v_id;
 end $$;
create function pg_temp.season_of(p_match uuid) returns uuid language sql as $$ select season_id from public.matches where id=p_match $$;

do $test$
declare v_a uuid; v_b uuid; v_tok text; v_tok_b text; v_old uuid; v_m1 uuid; v_m2 uuid; v_m3 uuid; v_s uuid; v_s2024 uuid;
 c jsonb; s jsonb; h jsonb; v_after jsonb; v_n int; v_ids uuid[] := '{}'; v_lineup jsonb; p jsonb; v_ev uuid; i int; v_bm uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v44c'||n||'@example.invalid','',now(),now(),now() from generate_series(1,8) n;
perform set_config('role','authenticated',true);
for i in 1..8 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
-- A: admin 1, jogadores 2 e 3 (3 com cadastro antigo "Defensor"). B: admin 4; 1 também joga em B.
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada A','ATA'); v_tok := public.create_pelada_invite(v_a);
perform pg_temp.as_user(2); perform public.join_pelada(v_tok,'ZAG');
perform pg_temp.as_user(3); perform public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(4); v_b := public.create_pelada('Pelada B','GOL'); v_tok_b := public.create_pelada_invite(v_b);
perform pg_temp.as_user(1); perform public.join_pelada(v_tok_b,'CA');

-- ===== Central vazia (sem partidas) e guia inicial =====
c := public.get_player_central();
perform pg_temp.assert(jsonb_array_length(c->'peladas') = 2 and c->'last_match' = 'null'::jsonb and jsonb_array_length(c->'next_rounds') = 0,
 'Central: duas peladas, sem último jogo nem próxima rodada');
perform pg_temp.assert((c->'pending'->'profile'->>'photo')::boolean and (c->'pending'->'profile'->>'foot')::boolean, 'perfil incompleto (sem foto e sem pé)');
perform pg_temp.assert(not (c->'guide'->>'dismissed')::boolean, 'guia aparece no início');
perform pg_temp.assert((select x->'setup'->>'members' from jsonb_array_elements(c->'peladas') x where (x->>'id')::uuid=v_a)::int = 3
 and (select (x->'setup'->>'invited')::boolean from jsonb_array_elements(c->'peladas') x where (x->>'id')::uuid=v_a)
 and (select x->'setup' from jsonb_array_elements(c->'peladas') x where (x->>'id')::uuid=v_b) = 'null'::jsonb,
 'passos do admin só nas peladas que administra');
perform pg_temp.as_user(3);
c := public.get_player_central();
perform pg_temp.assert(jsonb_array_length(c->'pending'->'positions') = 1, 'cadastro antigo: atualizar posição');
perform public.set_my_position(v_a, 'LD');
perform pg_temp.assert(jsonb_array_length(public.get_player_central()->'pending'->'positions') = 0, 'posição atualizada some das pendências');
perform pg_temp.assert(public.get_player_central()->'peladas'->0->'setup' = 'null'::jsonb, 'jogador comum não recebe números da pelada');

-- ===== Pelada principal =====
perform pg_temp.as_user(1);
perform public.set_primary_pelada(v_b);
c := public.get_player_central();
perform pg_temp.assert((c->>'primary_pelada_id')::uuid = v_b and (c->'peladas'->0->>'id')::uuid = v_b and (c->'peladas'->0->>'is_primary')::boolean,
 'principal aparece primeiro e marcada');
perform pg_temp.expect_error(format('select public.set_primary_pelada(%L)', gen_random_uuid()), 'PELADA_NOT_FOUND');
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.set_primary_pelada(%L)', v_b), 'PELADA_NOT_FOUND'); -- não é membro de B
perform pg_temp.as_user(1);
perform public.set_primary_pelada(null);
perform pg_temp.assert(public.get_player_central()->'primary_pelada_id' = 'null'::jsonb, 'principal removida');

-- ===== Guia: passos vistos e dispensar =====
perform public.set_guide_state('career');
perform pg_temp.assert((public.get_player_central()->'guide'->'seen'->>'career')::boolean, 'passo Minha Carreira visto');
perform public.set_guide_state('dismiss');
perform pg_temp.assert((public.get_player_central()->'guide'->>'dismissed')::boolean, 'guia dispensado (não volta sozinho)');
perform pg_temp.expect_error('select public.set_guide_state(''qualquer'')', 'INVALID_GUIDE_STEP');
perform pg_temp.assert((select count(*) from public.user_app_state) = 1, 'RLS: cada um vê só o próprio estado');

-- ===== Partidas oficiais, prêmios e Sala de Troféus =====
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
v_old := pg_temp.finish(v_a, make_timestamptz(2024,6,1,20,0,0,'America/Sao_Paulo'), 1, 0,
 '[{"m":1,"team":"A","pos":"attacker","g":1},{"m":2,"team":"B","pos":"defender"}]');
v_s2024 := pg_temp.season_of(v_old);
insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count) values(v_a,v_old,v_s2024,pg_temp.mem(v_a,1),'match_craque',3);
perform pg_temp.finish(v_a, make_timestamptz(2025,6,1,20,0,0,'America/Sao_Paulo'), 0, 0, '[{"m":1,"team":"A","pos":"attacker"},{"m":2,"team":"B","pos":"defender"}]');
v_m1 := pg_temp.finish(v_a, now() - interval '3 days', 3, 1,
 '[{"m":1,"team":"A","pos":"attacker","g":2,"a":1},{"m":2,"team":"B","pos":"defender","g":1}]');
v_m2 := pg_temp.finish(v_a, now() - interval '2 days', 0, 2, '[{"m":1,"team":"A","pos":"attacker"},{"m":2,"team":"B","pos":"defender","g":2}]');
v_m3 := pg_temp.finish(v_b, now() - interval '1 day', 2, 2, '[{"m":4,"team":"A","pos":"goalkeeper"},{"m":1,"team":"B","pos":"attacker","g":1,"a":1}]');
v_s := pg_temp.season_of(v_m1);
insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count) values(v_a,v_m1,v_s,pg_temp.mem(v_a,1),'match_craque',3);
insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count) values(v_a,v_m2,v_s,pg_temp.mem(v_a,1),'bola_murcha',2)
 returning id into v_bm;
insert into public.awards(pelada_id,season_id,membership_id,award_type,period_month) values(v_a,v_s,pg_temp.mem(v_a,1),'monthly_king',date_trunc('month',now())::date);
-- um prêmio revogado não conta
insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count,status,revoked_at) values(v_a,v_m2,v_s,pg_temp.mem(v_a,1),'match_craque',1,'revoked',now());
-- prêmios que NÃO são troféus (existem desde a 015) ficam fora da Sala de Troféus
insert into public.awards(pelada_id,season_id,membership_id,award_type,period_month) values(v_a,v_s,pg_temp.mem(v_a,1),'top_scorer',date_trunc('month',now())::date);
perform set_config('role','authenticated',true);

perform pg_temp.as_user(1);
c := public.get_player_central();
perform pg_temp.assert((c->'last_match'->>'match_id')::uuid = v_m3 and c->'last_match'->>'pelada_name' = 'Pelada B'
 and c->'last_match'->>'result' = 'draw' and (c->'last_match'->>'goals')::int = 1 and (c->'last_match'->>'assists')::int = 1
 and c->'last_match'->>'my_team' = 'B' and (c->'last_match'->>'official')::boolean, 'último jogo entre todas as peladas, com meus gols e assistências');

-- Carreira (Básico: temporada atual e a anterior; 2024 fica de fora)
s := public.get_player_career_summary(pg_temp.uid(1));
perform pg_temp.assert((s->>'visible')::boolean and (s->>'partial')::boolean, 'carreira parcial no Básico');
perform pg_temp.assert((s->'totals'->>'matches_played')::int = 4 and (s->'totals'->>'goals')::int = 3 and (s->'totals'->>'assists')::int = 2,
 'totais = partidas das temporadas visíveis (A: 2025 + 2 atuais; B: 1)');
perform pg_temp.assert((s->'trophies'->>'match_craque')::int = 1 and (s->'trophies'->>'monthly_king')::int = 1 and (s->'trophies'->>'bola_murcha')::int = 1,
 'troféus: Craque (sem o revogado e sem o de 2024), Rei do Mês, Bola Murcha');
perform pg_temp.assert(not (s->'trophies' ? 'top_scorer'), 'só as três premiações oficiais');
perform pg_temp.assert((select count(*) from jsonb_array_elements(s->'peladas') x, jsonb_array_elements(x->'seasons') y where y->'card' <> 'null'::jsonb) >= 2,
 'cada Card fica na sua pelada e temporada (nenhum overall somado)');
perform pg_temp.assert(not (s->'totals' ? 'overall'), 'total geral não tem overall');
-- os troféus batem com a fonte oficial e com o álbum (mesma tabela de prêmios)
perform pg_temp.assert((s->'trophies'->>'match_craque')::int = (select count(*) from public.awards where membership_id = pg_temp.mem(v_a,1)
 and award_type = 'match_craque' and status = 'active' and season_id = v_s), 'Craque da Sala = prêmios oficiais ativos (mesma tabela do álbum e das estatísticas)');
-- Pelada Premium: histórico completo
execute 'reset role';
update private.app_config set value='true'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
s := public.get_player_career_summary(pg_temp.uid(1));
perform pg_temp.assert(not (s->>'partial')::boolean and (s->'trophies'->>'match_craque')::int = 2 and (s->'totals'->>'matches_played')::int = 5,
 'Premium: histórico completo (2024 entra)');

-- Histórico de troféus sob demanda (paginado)
h := public.get_trophy_history(pg_temp.uid(1), 'match_craque', null, 1);
perform pg_temp.assert(jsonb_array_length(h->'items') = 1 and (h->'items'->0->>'match_id')::uuid = v_m1 and h->'next' <> 'null'::jsonb, 'Craque mais recente primeiro');
h := public.get_trophy_history(pg_temp.uid(1), 'match_craque', h->'next', 1);
perform pg_temp.assert(jsonb_array_length(h->'items') = 1 and (h->'items'->0->>'match_id')::uuid = v_old and h->'next' = 'null'::jsonb, 'segunda página e fim');
h := public.get_trophy_history(pg_temp.uid(1), 'monthly_king');
perform pg_temp.assert(h->'items'->0->>'period_month' = to_char(date_trunc('month',now()),'YYYY-MM-DD') and h->'items'->0->>'pelada_name' = 'Pelada A', 'Rei do Mês com mês e pelada');
h := public.get_trophy_history(pg_temp.uid(1), 'bola_murcha');
perform pg_temp.assert((h->'items'->0->>'id')::uuid = v_bm, 'Bola Murcha com a partida');
perform pg_temp.expect_error(format('select public.get_trophy_history(%L,%L)', pg_temp.uid(1), 'top_scorer'), 'INVALID_TROPHY');
perform pg_temp.expect_error(format('select public.get_trophy_history(%L,%L,%L::jsonb)', pg_temp.uid(1), 'match_craque', '{"at":"x"}'), 'INVALID_CURSOR');

-- Histórico de partidas paginado (todas as peladas e só uma)
v_after := null; v_n := 0;
loop
 h := public.get_my_match_history(null, v_after, 2);
 for p in select x from jsonb_array_elements(h->'items') x loop v_ids := v_ids || (p->>'match_id')::uuid; end loop;
 v_after := h->'next';
 exit when v_after = 'null'::jsonb;
end loop;
perform pg_temp.assert(cardinality(v_ids) = 5 and v_ids[1] = v_m3 and v_ids[5] = v_old, 'histórico completo, mais recente primeiro, sem repetir');
h := public.get_my_match_history(v_b);
perform pg_temp.assert(jsonb_array_length(h->'items') = 1 and h->'items'->0->>'match_result' = 'draw', 'filtro por pelada');
perform pg_temp.assert(not (h->'items'->0 ? 'final_rating'), 'histórico não expõe notas');

-- ===== Privacidade e bloqueio =====
perform pg_temp.as_user(2);
perform pg_temp.assert((public.get_player_career_summary(pg_temp.uid(1))->>'visible')::boolean, 'colega de pelada vê (padrão: minhas peladas)');
perform pg_temp.as_user(5);
perform pg_temp.assert(not (public.get_player_career_summary(pg_temp.uid(1))->>'visible')::boolean, 'quem não joga com ele não vê');
perform pg_temp.assert(not (public.get_trophy_history(pg_temp.uid(1),'match_craque')->>'visible')::boolean, 'nem os troféus');
perform pg_temp.as_user(1);
perform public.set_my_privacy('peladas', 'private');
perform pg_temp.as_user(2);
perform pg_temp.assert(not (public.get_player_career_summary(pg_temp.uid(1))->>'visible')::boolean, 'carreira privada');
perform pg_temp.as_user(1);
perform pg_temp.assert((public.get_player_career_summary(pg_temp.uid(1))->>'visible')::boolean, 'o próprio sempre vê');
perform public.set_my_privacy('peladas', 'peladas');
perform pg_temp.as_user(2);
perform public.block_user(pg_temp.uid(1));
perform pg_temp.assert(not (public.get_player_career_summary(pg_temp.uid(1))->>'visible')::boolean, 'bloqueio esconde a carreira');
perform public.unblock_user(pg_temp.uid(1));
-- carreira pública: quem não joga naquela pelada vê o troféu, a pelada e a data, mas não placar nem times
perform pg_temp.as_user(1);
perform public.set_my_privacy('public', 'public');
perform pg_temp.as_user(5);
h := public.get_trophy_history(pg_temp.uid(1), 'match_craque');
perform pg_temp.assert((h->>'visible')::boolean and h->'items'->0->>'pelada_name' = 'Pelada A' and h->'items'->0->'team_a_name' = 'null'::jsonb
 and h->'items'->0->'match_id' = 'null'::jsonb, 'perfil público: sem placar nem times de pelada alheia');
perform pg_temp.as_user(2);
h := public.get_trophy_history(pg_temp.uid(1), 'match_craque');
perform pg_temp.assert(h->'items'->0->>'team_a_name' is not null, 'colega da pelada vê o placar');
perform pg_temp.as_user(1);
perform public.set_my_privacy('peladas', 'peladas');

-- ===== Próxima rodada (escalação ativa em que estou) =====
perform pg_temp.as_user(1);
v_lineup := public.save_lineup(v_a, null, 'Quinta', array[pg_temp.mem(v_a,1)], array[pg_temp.mem(v_a,2)], 'Azul', 'Branco');
c := public.get_player_central();
perform pg_temp.assert(jsonb_array_length(c->'next_rounds') = 1 and c->'next_rounds'->0->>'team_name' = 'Azul'
 and c->'next_rounds'->0->>'opponent_name' = 'Branco', 'próxima rodada: meu time e o adversário');
perform pg_temp.as_user(3);
perform pg_temp.assert(jsonb_array_length(public.get_player_central()->'next_rounds') = 0, 'quem não está na escalação não vê como próxima rodada');
perform pg_temp.as_user(1);
perform public.cancel_lineup((v_lineup->>'id')::uuid);
perform pg_temp.assert(jsonb_array_length(public.get_player_central()->'next_rounds') = 0, 'escalação cancelada some');

-- ===== Votação aberta como pendência =====
execute 'reset role';
insert into public.voting_sessions(pelada_id,match_id,closes_at,duration_minutes,sheet_version,bola_murcha_required,formula_version,eligible_voter_count)
values(v_a, v_m2, now() + interval '2 hours', 120, 1, false, 1, 6);
insert into public.voting_eligible_members(session_id, pelada_id, membership_id)
select s.id, v_a, pg_temp.mem(v_a,2) from public.voting_sessions s where s.match_id=v_m2;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.assert(jsonb_array_length(public.get_player_central()->'pending'->'votes') = 1, 'votação aberta aparece nas pendências');
perform pg_temp.as_user(1);
perform pg_temp.assert(jsonb_array_length(public.get_player_central()->'pending'->'votes') = 0, 'só para quem pode votar');

-- ===== Convites inteligentes =====
perform pg_temp.as_user(6);
p := public.get_invite_preview(v_tok);
perform pg_temp.assert((p->>'valid')::boolean and (p->>'can_join')::boolean and (p->>'needs_position')::boolean and p->'membership_status' = 'null'::jsonb,
 'novo jogador: pode entrar e escolhe a posição');
perform public.join_pelada(v_tok, 'VOL');
p := public.get_invite_preview(v_tok);
perform pg_temp.assert((p->>'already_member')::boolean and (p->>'pelada_id')::uuid = v_a, 'já é membro: abre a pelada (sem duplicar)');
perform public.join_pelada(v_tok, 'VOL');
perform pg_temp.assert((select count(*) from public.pelada_memberships where pelada_id=v_a and user_id=pg_temp.uid(6)) = 1, 'nenhuma associação duplicada');
perform public.leave_pelada(v_a);
p := public.get_invite_preview(v_tok);
perform pg_temp.assert((p->>'can_join')::boolean and not (p->>'needs_position')::boolean and p->>'membership_status' = 'left',
 'quem saiu volta sem escolher posição de novo');
perform public.join_pelada(v_tok, null);
perform pg_temp.assert((select status from public.pelada_memberships where pelada_id=v_a and user_id=pg_temp.uid(6)) = 'active', 'voltou à pelada');
perform pg_temp.as_user(1);
perform public.revoke_pelada_invites(v_a);
perform pg_temp.as_user(7);
p := public.get_invite_preview(v_tok);
perform pg_temp.assert(not (p->>'valid')::boolean and p->>'reason' = 'revoked' and p->>'pelada_name' = 'Pelada A', 'convite cancelado: motivo e pelada');
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)', v_tok, 'ATA'), 'INVALID_OR_EXPIRED_INVITE');
perform pg_temp.assert(public.get_invite_preview(repeat('b',64))->>'reason' = 'not_found' and public.get_invite_preview('x')->>'reason' = 'not_found', 'inexistente');
perform pg_temp.as_user(1);
v_tok := public.create_pelada_invite(v_a, 1, 1);
execute 'reset role';
update private.pelada_invites set expires_at = now() - interval '1 minute' where pelada_id = v_a and revoked_at is null;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(7);
p := public.get_invite_preview(v_tok);
perform pg_temp.assert(p->>'reason' = 'expired', 'convite expirado');
perform pg_temp.as_user(1);
v_tok := public.create_pelada_invite(v_a, 24, 1);
perform pg_temp.as_user(7); perform public.join_pelada(v_tok, 'ATA');
perform pg_temp.as_user(8);
perform pg_temp.assert(public.get_invite_preview(v_tok)->>'reason' = 'used_up', 'convite já usado (limite de entradas)');
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)', v_tok, 'ATA'), 'INVALID_OR_EXPIRED_INVITE');

-- ===== Notificações por categoria =====
perform pg_temp.as_user(2);
p := public.get_notification_preferences();
perform pg_temp.assert(p->'categories' = '{"match_voting":true,"voting_reminder":true,"results":true,"awards":true,"pelada":true}'::jsonb,
 'todas as categorias ligadas por padrão');
p := public.set_notification_category('results', false);
perform pg_temp.assert(not (p->'categories'->>'results')::boolean and (p->>'essential')::boolean, 'desliga só resultados');
perform pg_temp.expect_error('select public.set_notification_category(''financeiro'', false)', 'INVALID_PREFERENCES');
execute 'reset role';
insert into public.push_devices(user_id, expo_push_token, platform) values(pg_temp.uid(2), 'ExponentPushToken[v44-2]', 'ios');
perform private.notify(pg_temp.uid(2), v_a, 'result_published', 'essential', 'v44:r', jsonb_build_object('pelada_id', v_a));
perform private.notify(pg_temp.uid(2), v_a, 'admin_succession', 'essential', 'v44:p', jsonb_build_object('pelada_id', v_a));
perform pg_temp.assert(private.push_skip_reason((select id from public.notification_events where dedupe_key='v44:r')) = 'OPTED_OUT',
 'categoria desligada não sai');
perform pg_temp.assert(private.push_skip_reason((select id from public.notification_events where dedupe_key='v44:p')) is null,
 'outra categoria continua saindo');
perform private.notify(pg_temp.uid(2), v_a, 'result_published', 'essential', 'v44:r', jsonb_build_object('pelada_id', v_a));
perform pg_temp.assert((select count(*) from public.notification_events where dedupe_key='v44:r') = 1, 'sem notificação duplicada');
perform pg_temp.assert(not exists(select 1 from public.notification_events where event_type ilike '%financ%' or payload::text ilike '%cents%'),
 'nenhuma notificação financeira');
perform pg_temp.assert(private.notification_category('account_transferred') = 'account' and private.notification_category('award_monthly_king') = 'awards'
 and private.notification_category('voting_closing_soon') = 'voting_reminder', 'mapa de categorias');
perform set_config('role','authenticated',true);

-- ===== Acesso =====
execute 'reset role';
perform set_config('role','anon',true);
perform pg_temp.expect_error('select public.get_player_central()', 'permission denied');
execute 'reset role';

raise exception 'PASS: 038_v44_central_career';
end $test$;
