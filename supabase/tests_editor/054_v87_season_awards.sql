-- V8.7 (migração 068): Artilheiro da Temporada, Maestro da Temporada, Luva de Ouro, exceção, Sala (contadores) e Meus Prêmios.
-- Cobre A01–A05, B01–B10, C01–C12, F01–F04 e AD01 (ver docs/V8.7_MATRIZ_RASTREABILIDADE.md).
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 054_v87_season_awards" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99870000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.at(y int, mo int, d int, h int default 20) returns timestamptz language sql as
 $$ select make_timestamptz(y, mo, d, h, 0, 0, 'America/Sao_Paulo') $$;
create function pg_temp.idx(p_mem uuid) returns int language sql as
 $$ select right(user_id::text, 12)::int from public.pelada_memberships where id = p_mem $$;
-- Usuários n1..n2 já com onboarding.
create function pg_temp.users(n1 int, n2 int) returns void language plpgsql as
 $$ declare i int; begin
  insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
   'm91-v87-'||n||'@example.invalid','',now(),now(),now() from generate_series(n1,n2) n;
  perform set_config('role','authenticated',true);
  for i in n1..n2 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
  execute 'reset role';
 end $$;
-- Pelada com admin e membros; p_gols = quem se cadastra como GOL.
create function pg_temp.pelada(p_name text, p_admin int, p_members int[], p_gols int[]) returns uuid language plpgsql as
 $$ declare v_a uuid; v_tok text; n int; begin
  perform set_config('role','authenticated',true);
  perform pg_temp.as_user(p_admin); v_a := public.create_pelada(p_name,'ATA'); v_tok := public.create_pelada_invite(v_a);
  foreach n in array p_members loop perform pg_temp.as_user(n);
   perform public.join_pelada(v_tok, case when n = any(p_gols) then 'GOL' else 'MEI' end); end loop;
  execute 'reset role';
  return v_a;
 end $$;
-- Partida finalizada com eventos reais. p_rows: [{m, team, pos, g, a, og}]; p_extra: [{team, type, q}] (sem autoria).
create function pg_temp.finish(p_pelada uuid, p_at timestamptz, a int, b int, p_rows jsonb, p_extra jsonb default '[]') returns uuid
language plpgsql as
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
   if coalesce((r->>'og')::int,0) > 0 then insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
    values(p_pelada,v_id,v_part,r->>'team','own_goal',(r->>'og')::int); end if;
  end loop;
  for r in select * from jsonb_array_elements(p_extra) loop
   insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
   values(p_pelada,v_id,null,r->>'team',r->>'type',(r->>'q')::int);
  end loop;
  perform private.compute_match_results(v_id, null);
  perform private.after_match_finalized(v_id);
  return v_id;
 end $$;
create function pg_temp.saves(p_match uuid, n int, s int) returns void language plpgsql as
 $$ begin
  insert into public.match_keeper_saves(pelada_id,match_id,participant_id,hard_saves)
  select x.pelada_id, x.match_id, x.id, s from public.match_participants x
  where x.match_id=p_match and x.membership_id=pg_temp.mem((select pelada_id from public.matches where id=p_match), n)
  on conflict (match_id, participant_id) do update set hard_saves=excluded.hard_saves;
 end $$;
create function pg_temp.w(p_season uuid, p_cat text) returns int[] language sql as
 $$ select coalesce(array_agg(pg_temp.idx(x) order by pg_temp.idx(x)), '{}')
    from private.season_award_results r, unnest(r.winners) x where r.season_id=p_season and r.category=p_cat and r.is_current $$;
create function pg_temp.st(p_season uuid, p_cat text) returns text language sql as
 $$ select status from private.season_award_results where season_id=p_season and category=p_cat and is_current $$;
create function pg_temp.ver(p_season uuid, p_cat text) returns int language sql as
 $$ select coalesce(max(version),0) from private.season_award_results where season_id=p_season and category=p_cat $$;
create function pg_temp.aw(p_season uuid, p_type text) returns int[] language sql as
 $$ select coalesce(array_agg(pg_temp.idx(a.membership_id) order by pg_temp.idx(a.membership_id)), '{}')
    from public.awards a where a.season_id=p_season and a.award_type=p_type and a.status='active' $$;
create function pg_temp.season(p_pelada uuid, y int) returns uuid language sql as
 $$ select id from public.seasons where pelada_id=p_pelada and starts_on <= make_date(y,6,1) and ends_on >= make_date(y,6,1) $$;
create function pg_temp.notifs(p_type text, p_pelada uuid) returns int language sql as
 $$ select count(*)::int from public.notification_events where event_type=p_type and pelada_id=p_pelada $$;
-- Encerra a temporada de ano y (ela termina em 30/09 para os testes) e atualiza o estado de calendário.
create function pg_temp.end_season(p_pelada uuid, p_season uuid, p_end date) returns void language plpgsql as
 $$ begin
  update public.seasons set ends_on = p_end where id = p_season;
  perform private.sync_season_status(p_pelada);
 end $$;

do $test$
declare v_a uuid; v_o uuid; v_e uuid; i int; r jsonb; j jsonb;
 s25 uuid; s26 uuid; sq uuid; cut26 timestamptz;
 n1 uuid; n2 uuid; n3 uuid; m1 uuid; m2 uuid; m3 uuid; m4 uuid; m5 uuid; m6 uuid; m7 uuid; m8 uuid; m9 uuid; m10 uuid; q1 uuid;
 ref2 numeric; ref3 numeric; v_cnt int; v_cnt2 int; v_ev int;
begin
update private.app_config set value='true'::jsonb where key='premium_beta_open';
perform pg_temp.users(1,12);
-- Pelada A: admin 1; GOL oficiais 2, 3, 4; 5..10 meias (5 vai ao gol como improvisado); 11 é de outra pelada; 12 admin da pelada E.
v_a := pg_temp.pelada('Pelada A', 1, array[2,3,4,5,6,7,8,9,10], array[2,3,4]);
perform pg_temp.as_user(11); perform set_config('role','authenticated',true);
v_o := public.create_pelada('Outra pelada','ATA');
execute 'reset role';
-- Nada é concedido durante a montagem dos dados (ativação adiada): os ganchos não fazem nada.
update private.v87_activation set min_season_end = '2099-01-01';
update private.v86_activation set activated_at = '2026-01-01';

-- ===== Temporada 2025 (3 partidas): o goleiro 2 faz 10 defesas difíceis em cada uma =====
n1 := pg_temp.finish(v_a, pg_temp.at(2025,11,5), 1, 0,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":6,"team":"A","pos":"attacker","g":1},{"m":4,"team":"B","pos":"goalkeeper"},{"m":7,"team":"B","pos":"midfielder"}]');
n2 := pg_temp.finish(v_a, pg_temp.at(2025,11,12), 1, 0,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":9,"team":"A","pos":"attacker","g":1},{"m":8,"team":"A","pos":"midfielder","a":1},{"m":4,"team":"B","pos":"goalkeeper"},{"m":7,"team":"B","pos":"midfielder"}]');
n3 := pg_temp.finish(v_a, pg_temp.at(2025,11,19), 0, 0,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":9,"team":"A","pos":"midfielder"},{"m":4,"team":"B","pos":"goalkeeper"},{"m":7,"team":"B","pos":"midfielder"}]');
perform pg_temp.saves(n1,2,10); perform pg_temp.saves(n2,2,10); perform pg_temp.saves(n3,2,10);

-- ===== Temporada 2026 (10 partidas) =====
m1 := pg_temp.finish(v_a, pg_temp.at(2026,3,7), 2, 1,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":6,"team":"A","pos":"attacker","g":2},{"m":8,"team":"A","pos":"midfielder","a":1},{"m":3,"team":"B","pos":"goalkeeper"},{"m":7,"team":"B","pos":"attacker","g":1}]');
m2 := pg_temp.finish(v_a, pg_temp.at(2026,3,14), 1, 1,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":6,"team":"A","pos":"attacker","g":1},{"m":8,"team":"A","pos":"midfielder","a":1},{"m":3,"team":"B","pos":"goalkeeper"},{"m":7,"team":"B","pos":"attacker","g":1}]');
m3 := pg_temp.finish(v_a, pg_temp.at(2026,3,21), 2, 1,
 '[{"m":4,"team":"A","pos":"goalkeeper"},{"m":7,"team":"A","pos":"attacker","g":2},{"m":9,"team":"A","pos":"midfielder","a":1},{"m":5,"team":"B","pos":"goalkeeper"},{"m":6,"team":"B","pos":"attacker","g":1}]');
m4 := pg_temp.finish(v_a, pg_temp.at(2026,4,4), 1, 1,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":7,"team":"A","pos":"attacker","g":1},{"m":8,"team":"A","pos":"midfielder","a":1},{"m":3,"team":"B","pos":"goalkeeper"},{"m":6,"team":"B","pos":"attacker","g":1}]');
m5 := pg_temp.finish(v_a, pg_temp.at(2026,4,11), 1, 0,
 '[{"m":4,"team":"A","pos":"goalkeeper"},{"m":6,"team":"A","pos":"attacker","g":1},{"m":9,"team":"A","pos":"midfielder","a":1},{"m":5,"team":"B","pos":"goalkeeper"},{"m":7,"team":"B","pos":"attacker"}]');
m6 := pg_temp.finish(v_a, pg_temp.at(2026,5,2), 1, 0,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":7,"team":"A","pos":"attacker","g":1},{"m":8,"team":"A","pos":"midfielder","a":1},{"m":3,"team":"B","pos":"goalkeeper"},{"m":10,"team":"B","pos":"midfielder"}]');
m7 := pg_temp.finish(v_a, pg_temp.at(2026,5,9), 0, 0,
 '[{"m":5,"team":"A","pos":"goalkeeper"},{"m":6,"team":"A","pos":"attacker"},{"m":10,"team":"A","pos":"midfielder"},{"m":4,"team":"B","pos":"goalkeeper"},{"m":7,"team":"B","pos":"attacker"}]');
-- Gol contra e gol sem autoria nunca contam como gol de ninguém (A01/A02 e a regra anterior do Artilheiro).
m8 := pg_temp.finish(v_a, pg_temp.at(2026,6,6), 1, 1,
 '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":6,"team":"A","pos":"attacker","og":1},{"m":3,"team":"B","pos":"goalkeeper"},{"m":8,"team":"B","pos":"midfielder","g":1},{"m":10,"team":"B","pos":"midfielder"}]',
 '[{"team":"A","type":"unattributed_goal","q":1}]');
m9 := pg_temp.finish(v_a, pg_temp.at(2026,6,13), 0, 0,
 '[{"m":5,"team":"A","pos":"goalkeeper"},{"m":9,"team":"A","pos":"midfielder"},{"m":2,"team":"B","pos":"goalkeeper"},{"m":10,"team":"B","pos":"midfielder"}]');
m10 := pg_temp.finish(v_a, pg_temp.at(2026,7,4), 0, 0,
 '[{"m":4,"team":"A","pos":"goalkeeper"},{"m":7,"team":"A","pos":"attacker"},{"m":5,"team":"B","pos":"goalkeeper"},{"m":6,"team":"B","pos":"attacker"}]');
perform pg_temp.saves(m1,2,3); perform pg_temp.saves(m2,2,3); perform pg_temp.saves(m4,2,3); perform pg_temp.saves(m6,2,3); perform pg_temp.saves(m8,2,3); perform pg_temp.saves(m9,2,3);
perform pg_temp.saves(m1,3,5); perform pg_temp.saves(m2,3,5); perform pg_temp.saves(m4,3,5); perform pg_temp.saves(m6,3,5); perform pg_temp.saves(m8,3,5);
perform pg_temp.saves(m3,4,9); perform pg_temp.saves(m5,4,9); perform pg_temp.saves(m7,4,9); perform pg_temp.saves(m10,4,9);
perform pg_temp.saves(m3,5,20); perform pg_temp.saves(m5,5,20); perform pg_temp.saves(m7,5,20); perform pg_temp.saves(m9,5,20); perform pg_temp.saves(m10,5,20);

s25 := pg_temp.season(v_a, 2025); s26 := pg_temp.season(v_a, 2026);
perform pg_temp.end_season(v_a, s26, '2026-09-30');
cut26 := private.v87_season_cutoff(s26);

-- Gol contra / sem autoria não entram na contagem: o jogador 6 marcou 6 e o gol contra da partida 8 não conta.
perform pg_temp.assert((select goals from public.match_player_results where match_id=m8 and membership_id=pg_temp.mem(v_a,6)) = 0, 'gol contra não é gol');
perform pg_temp.assert((select sum(goals) from public.match_player_results where match_id=m8) = 1, 'gol sem autoria não é gol de ninguém');

-- ===== Antes da ativação nada é concedido, e partida pendente adia a apuração (B10) =====
perform pg_temp.assert(private.season_awards_sync(s26)->>'status' = 'BEFORE_ACTIVATION', 'antes da ativação');
perform pg_temp.assert(not exists(select 1 from private.season_award_results), 'nenhum resultado antes da ativação');
update private.v87_activation set min_season_end = '2025-01-01';
insert into public.matches(pelada_id,season_id,played_at,status,team_a_score,team_b_score)
values(v_a, s26, pg_temp.at(2026,7,11), 'finalizing', 0, 0) returning id into q1;
perform pg_temp.assert(private.season_awards_sync(s26)->>'status' = 'SEASON_NOT_READY', 'B10: pendência resolvida primeiro');
perform pg_temp.assert(not exists(select 1 from private.season_award_results where season_id=s26), 'nada publicado com partida pendente');
delete from public.matches where id = q1;

-- REF: a mesma conta do motor (051) quando não há corte; o corte do encerramento só descarta partidas posteriores.
ref2 := private.v87_ref_at(pg_temp.mem(v_a,2), 'infinity');
perform pg_temp.assert(abs(ref2 - round((private.rating_compute(pg_temp.mem(v_a,2))->>'ref')::numeric, 6)) < 0.000001, 'v87_ref_at = REF do motor (goleiro 2)');
perform pg_temp.assert(abs(private.v87_ref_at(pg_temp.mem(v_a,3), 'infinity') - round((private.rating_compute(pg_temp.mem(v_a,3))->>'ref')::numeric, 6)) < 0.000001, 'v87_ref_at = REF do motor (goleiro 3)');
perform pg_temp.assert(ref2 between 76.0 and 76.1, 'REF do 2 atravessa as temporadas (≈76,05)');
perform pg_temp.assert(private.v87_ref_at(pg_temp.mem(v_a,3), 'infinity') = 74.375, 'REF do 3 = 74,375');
perform pg_temp.assert(private.v87_ref_at(pg_temp.mem(v_a,5), 'infinity') > 80, 'goleiro improvisado teria a maior REF, mas não concorre');

-- ===== Publicação conjunta (B10/B01) =====
perform private.season_awards_after_change(v_a, null);
-- Artilheiro: 6 e 7 empatam em 6 gols (A01: título integral para os dois; gol contra e sem autoria fora).
perform pg_temp.assert(pg_temp.w(s26,'top_scorer') = '{6,7}', 'A01: Artilheiro compartilhado 6 e 7');
perform pg_temp.assert(pg_temp.aw(s26,'season_top_scorer') = '{6,7}', 'A01: prêmios ativos 6 e 7');
perform pg_temp.assert((select bool_and(is_shared) from public.awards where season_id=s26 and award_type='season_top_scorer'), 'C03: título compartilhado identificado');
perform pg_temp.assert((select count(*) from public.awards where season_id=s26 and award_type='season_top_scorer' and status='active') = 2, 'C03: cada um recebe troféu integral (uma linha por jogador)');
-- Maestro: 8 (4 assistências) vence 9 (2).
perform pg_temp.assert(pg_temp.w(s26,'maestro') = '{8}', 'A02: Maestro = 8');
perform pg_temp.assert(pg_temp.aw(s26,'season_maestro') = '{8}', 'A02: prêmio do Maestro');
-- Luva: 2 vence 3 só porque a REF do encerramento atravessa a temporada anterior; 4 (4 atuações) e 5 (improvisado) ficam fora.
perform pg_temp.assert(pg_temp.w(s26,'golden_glove') = '{2}', 'A03/B05/C09: Luva = 2 (REF móvel inclui 2025)');
perform pg_temp.assert(pg_temp.aw(s26,'season_golden_glove') = '{2}', 'A03: prêmio da Luva');
perform pg_temp.assert(pg_temp.st(s26,'golden_glove') = 'published' and (select basis from private.season_award_results where season_id=s26 and category='golden_glove') = 'normal', 'base normal');
perform pg_temp.assert((select (criteria->>'required')::int from private.season_award_results where season_id=s26 and category='golden_glove') = 5, 'B06: max(5, ceil(50% de 10)) = 5');
perform pg_temp.assert((select count(*) from private.season_award_results r, jsonb_array_elements(r.ranking) e where r.season_id=s26 and r.category='golden_glove' and (e->>'eligible')::boolean) = 2, 'elegíveis normais: 2 e 3');
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements((select ranking from private.season_award_results where season_id=s26 and category='golden_glove')) e
  where e->>'membership_id' = pg_temp.mem(v_a,5)::text and (e->>'eligible')::boolean), 'B07/B08: improvisado (posição oficial MEI) nunca elegível');
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements((select ranking from private.season_award_results where season_id=s26 and category='golden_glove')) e
  where e->>'membership_id' = pg_temp.mem(v_a,4)::text and (e->>'eligible')::boolean), 'A04: 4 atuações no gol (< 5) não elegível');
-- Temporada 2025: Artilheiro compartilhado 6 e 9; Maestro 8; Luva sem elegível normal (3 atuações) → aguarda a exceção do admin.
perform pg_temp.assert(pg_temp.w(s25,'top_scorer') = '{6,9}' and pg_temp.w(s25,'maestro') = '{8}', '2025: Artilheiro e Maestro');
perform pg_temp.assert(pg_temp.st(s25,'golden_glove') = 'awaiting_exception' and pg_temp.aw(s25,'season_golden_glove') = '{}', 'B09: sem elegível normal, nada concedido e exceção disponível');
-- Cada categoria teve uma versão; trilha auditável (C10).
perform pg_temp.assert((select count(*) from private.v87_events where season_id=s26 and kind='published') = 3, 'C10: três publicações registradas');
perform pg_temp.assert((select bool_and(version = 1 and rules_version = 'v8.7-1') from private.season_award_results where season_id=s26), 'versão 1 e regra versionada');
-- Avisos (C07): cada membro ativo recebe um aviso coletivo (sem vencedores), e cada vencedor, o seu.
perform pg_temp.assert((select count(*) from public.notification_events where event_type='season_awards_published' and dedupe_key like 'season_awards:'||s26||':%') = 10, format('C07: aviso coletivo para os 10 membros ativos (got %s; tipos %s)', (select count(*) from public.notification_events where event_type='season_awards_published'), (select string_agg(distinct event_type||':'||status, ',') from public.notification_events)));
perform pg_temp.assert(pg_temp.notifs('award_season_top_scorer', v_a) = 4 and pg_temp.notifs('award_season_maestro', v_a) = 2 and pg_temp.notifs('award_season_golden_glove', v_a) = 1,
 'C07: aviso individual dos vencedores (4 artilheiros, 2 maestros, 1 luva)');
perform pg_temp.assert(not exists(select 1 from public.notification_events where event_type='season_awards_published' and payload::text like '%membership%'), 'aviso coletivo sem dados de vencedores');

-- ===== Idempotência (B10/C12): repetir não duplica prêmios, versões nem avisos =====
select count(*) into v_cnt from public.awards where season_id in (s25,s26); select count(*) into v_cnt2 from public.notification_events;
perform private.season_awards_sync(s26); perform private.season_awards_sync(s25); perform private.season_awards_after_change(v_a, null);
perform pg_temp.assert((select count(*) from public.awards where season_id in (s25,s26)) = v_cnt, 'sem prêmios duplicados');
perform pg_temp.assert((select count(*) from public.notification_events) = v_cnt2, 'sem avisos duplicados');
perform pg_temp.assert(pg_temp.ver(s26,'top_scorer') = 1 and pg_temp.ver(s26,'golden_glove') = 1, 'sem versões novas');

-- ===== Cancelamento e restauração (B02/B03): partida anulada sai da apuração; restaurada, volta =====
update public.matches set status='annulled' where id = m1;
perform private.close_month(v_a, '2026-03-01');
perform pg_temp.assert(pg_temp.w(s26,'top_scorer') = '{7}' and pg_temp.aw(s26,'season_top_scorer') = '{7}', 'B02: anulada a partida 1, 7 fica sozinho (5 × 4 gols)');
perform pg_temp.assert(not (select is_shared from public.awards where season_id=s26 and award_type='season_top_scorer' and status='active'), 'título deixa de ser compartilhado');
perform pg_temp.assert(pg_temp.ver(s26,'top_scorer') = 2 and (select rectifies is not null from private.season_award_results where season_id=s26 and category='top_scorer' and version=2), 'versão 2 corrige a 1');
perform pg_temp.assert((select status from public.awards where season_id=s26 and award_type='season_top_scorer' and membership_id=pg_temp.mem(v_a,6) order by created_at limit 1) = 'revoked', 'quem perdeu fica revogado (histórico preservado)');
perform pg_temp.assert(pg_temp.notifs('season_award_revoked', v_a) = 1, 'C07: aviso de correção só para quem perdeu o título');
perform pg_temp.assert(pg_temp.ver(s26,'maestro') = 1 and pg_temp.w(s26,'maestro') = '{8}', 'Maestro: mesmo vencedor, sem versão nova (8 segue com 3 assistências)');
perform pg_temp.assert(pg_temp.w(s26,'golden_glove') = '{2}', 'Luva continua 2 (3 cai para 4 atuações; T=9 ⇒ mínimo 5)');
perform pg_temp.assert((select (criteria->>'season_matches')::int from private.season_award_results where season_id=s26 and category='golden_glove') = 9, 'partida anulada fora do denominador');
update public.matches set status='finalized' where id = m1;
perform private.close_month(v_a, '2026-03-01');
perform pg_temp.assert(pg_temp.w(s26,'top_scorer') = '{6,7}' and pg_temp.aw(s26,'season_top_scorer') = '{6,7}', 'restauração reintegra: 6 e 7 de novo');
perform pg_temp.assert(pg_temp.ver(s26,'top_scorer') = 3, 'versão 3 (histórico completo preservado)');
perform pg_temp.assert((select count(*) from public.awards where season_id=s26 and award_type='season_top_scorer' and membership_id=pg_temp.mem(v_a,6)) = 2, 'duas linhas do 6: a revogada e a nova ativa');
perform pg_temp.assert((select count(*) from public.awards where season_id=s26 and award_type='season_top_scorer' and membership_id=pg_temp.mem(v_a,6) and status='active') = 1, 'só uma ativa (índice único)');

-- ===== REF do encerramento × REF atual (F04) =====
-- Quatro partidas depois do encerramento, em que o goleiro 2 não faz nenhuma defesa: a REF ATUAL dele despenca e passa a perder
-- para a do 3; a Luva da temporada 2026 continua com a REF do encerramento.
ref2 := private.v87_ref_at(pg_temp.mem(v_a,2), cut26);
for i in 1..4 loop
 q1 := pg_temp.finish(v_a, pg_temp.at(2026,10,3 + 7*(i-1)), 0, 0,
  '[{"m":2,"team":"A","pos":"goalkeeper"},{"m":6,"team":"A","pos":"attacker"},{"m":4,"team":"B","pos":"goalkeeper"},{"m":7,"team":"B","pos":"attacker"}]');
 perform pg_temp.saves(q1, 2, 0);
end loop;
sq := pg_temp.season(v_a, 2026); -- nova temporada (outubro–dezembro) tem o mesmo ano; pegar a mais nova
select id into sq from public.seasons where pelada_id=v_a order by starts_on desc limit 1;
perform pg_temp.assert(sq <> s26, 'partidas posteriores caíram em outra temporada');
perform pg_temp.assert(private.v87_ref_at(pg_temp.mem(v_a,2), cut26) = ref2, 'F04: REF do encerramento não muda com partidas posteriores');
perform pg_temp.assert((private.rating_compute(pg_temp.mem(v_a,2))->>'ref')::numeric < (private.rating_compute(pg_temp.mem(v_a,3))->>'ref')::numeric,
 'a REF ATUAL do 2 ficou abaixo da do 3');
perform private.season_awards_sync(s26);
perform pg_temp.assert(pg_temp.w(s26,'golden_glove') = '{2}' and pg_temp.ver(s26,'golden_glove') = 1, 'F04: Luva 2026 segue 2 (não usa a REF atual)');

-- ===== Correção de defesas difíceis (B03/F04): recalcula com o estado corrigido no encerramento =====
perform pg_temp.saves(m1,3,99); perform pg_temp.saves(m2,3,99); perform pg_temp.saves(m4,3,99); perform pg_temp.saves(m6,3,99); perform pg_temp.saves(m8,3,99);
perform private.after_rating_inputs_changed(v_a, null, 'hard_saves');
perform pg_temp.assert(pg_temp.w(s26,'golden_glove') = '{3}' and pg_temp.aw(s26,'season_golden_glove') = '{3}', 'correção das defesas do 3: a Luva muda para 3');
perform pg_temp.assert(pg_temp.ver(s26,'golden_glove') = 2 and pg_temp.notifs('season_award_revoked', v_a) = 2, 'versão 2 e aviso ao 2');
perform pg_temp.saves(m1,3,5); perform pg_temp.saves(m2,3,5); perform pg_temp.saves(m4,3,5); perform pg_temp.saves(m6,3,5); perform pg_temp.saves(m8,3,5);
perform private.after_rating_inputs_changed(v_a, null, 'hard_saves');
perform pg_temp.assert(pg_temp.w(s26,'golden_glove') = '{2}' and pg_temp.ver(s26,'golden_glove') = 3, 'correção desfeita: volta para 2 (versão 3)');
perform pg_temp.assert((select count(*) from private.season_award_results where season_id=s26 and category='golden_glove') = 3, 'três versões guardadas');

-- ===== Posição oficial no encerramento (B08/F03) =====
-- O 5 vira GOL oficial DEPOIS do encerramento: no encerramento era MEI, continua inelegível.
insert into public.position_changes(pelada_id, membership_id, from_position, from_position_code, to_position, to_position_code, position_version, changed_at)
values(v_a, pg_temp.mem(v_a,5), 'midfielder', 'MEI', 'goalkeeper', 'GOL', 1, now());
update public.pelada_memberships set position_code='GOL', preferred_position='goalkeeper' where id = pg_temp.mem(v_a,5);
-- O 3 vira MEI depois do encerramento: no encerramento era GOL, continua elegível.
insert into public.position_changes(pelada_id, membership_id, from_position, from_position_code, to_position, to_position_code, position_version, changed_at)
values(v_a, pg_temp.mem(v_a,3), 'goalkeeper', 'GOL', 'midfielder', 'MEI', 1, now());
update public.pelada_memberships set position_code='MEI', preferred_position='midfielder' where id = pg_temp.mem(v_a,3);
perform private.after_rating_inputs_changed(v_a, null, 'position');
perform pg_temp.assert((select eligible from private.glove_candidates(s26,50,5) where membership_id=pg_temp.mem(v_a,3)), 'F03: 3 era GOL no encerramento: elegível');
perform pg_temp.assert(not (select eligible from private.glove_candidates(s26,50,5) where membership_id=pg_temp.mem(v_a,5)), 'B08: 5 era MEI no encerramento: inelegível');
perform pg_temp.assert(pg_temp.w(s26,'golden_glove') = '{2}', 'mudança de posição posterior não muda a Luva');

-- ===== Saída e retorno não apagam (C11/AD01) =====
update public.pelada_memberships set status='left' where id = pg_temp.mem(v_a,8);
perform private.season_awards_after_change(v_a, null);
perform pg_temp.assert(pg_temp.aw(s26,'season_maestro') = '{8}' and pg_temp.w(s26,'maestro') = '{8}', 'C11: ex-integrante mantém o título');
update public.pelada_memberships set status='left' where id = pg_temp.mem(v_a,3);
perform pg_temp.assert((select eligible from private.glove_candidates(s26,50,5) where membership_id=pg_temp.mem(v_a,3)), 'F03: ex-integrante segue elegível pela última posição oficial');
update public.pelada_memberships set status='active' where id in (pg_temp.mem(v_a,8), pg_temp.mem(v_a,3));

-- ===== Exceção da Luva (B09/C08/F01) na temporada 2025 =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(6);
perform pg_temp.expect_error(format('select public.grant_golden_glove_exception(%L,50,3,%L)', s25, 'motivo de teste válido'), 'ADMIN_REQUIRED');
perform pg_temp.as_user(11);
perform pg_temp.expect_error(format('select public.grant_golden_glove_exception(%L,50,3,%L)', s25, 'motivo de teste válido'), 'SEASON_NOT_FOUND');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.grant_golden_glove_exception(%L,50,3,%L)', s25, 'curto'), 'REASON_REQUIRED');
perform pg_temp.expect_error(format('select public.grant_golden_glove_exception(%L,50,2,%L)', s25, 'motivo de teste válido'), 'INVALID_EXCEPTION_PARAMS');
perform pg_temp.expect_error(format('select public.grant_golden_glove_exception(%L,50,5,%L)', s25, 'motivo de teste válido'), 'INVALID_EXCEPTION_PARAMS');
perform pg_temp.expect_error(format('select public.grant_golden_glove_exception(%L,60,3,%L)', s25, 'motivo de teste válido'), 'INVALID_EXCEPTION_PARAMS');
-- Com elegível normal (2026) não existe exceção.
perform pg_temp.expect_error(format('select public.grant_golden_glove_exception(%L,40,3,%L)', s26, 'motivo de teste válido'), 'EXCEPTION_NOT_AVAILABLE');
-- Só o admin enxerga ranking/critérios/candidatos da exceção; os demais veem "pendente".
perform pg_temp.assert((public.get_season_awards(s25)->'categories'->'golden_glove'->>'status') = 'awaiting_exception' and public.get_season_awards(s25)->'golden_glove_exception'->>'available' = 'true', 'admin vê exceção disponível');
perform pg_temp.assert(jsonb_array_length(public.get_season_awards(s25)->'golden_glove_exception'->'candidates') = 2, 'candidatos do piso: 2 e 4 (GOL oficial, ≥3 atuações)');
perform pg_temp.as_user(6);
perform pg_temp.assert((public.get_season_awards(s25)->'categories'->'golden_glove'->>'status') = 'pending', 'membro comum vê só "pendente"');
perform pg_temp.assert(public.get_season_awards(s25)->'categories'->'golden_glove' ? 'ranking' = false and public.get_season_awards(s25) ? 'golden_glove_exception' = false, 'membro comum não vê ranking nem exceção');
perform pg_temp.as_user(1);
j := public.grant_golden_glove_exception(s25, 50, 3, 'Nenhum goleiro chegou a 5 atuações na temporada curta');
perform pg_temp.assert(j->>'status' = 'published' and j->>'basis' = 'exception', 'exceção concede');
execute 'reset role';
-- REF e desempates seguem valendo: 2 (com defesas registradas) vence o 4 (sem registro = REF neutra 65).
perform pg_temp.assert(pg_temp.w(s25,'golden_glove') = '{2}' and pg_temp.aw(s25,'season_golden_glove') = '{2}', 'exceção: vencedor pela REF (não por escolha livre)');
perform pg_temp.assert((select count(*) from private.audit_events where event_type='golden_glove_exception_granted' and pelada_id=v_a) = 1, 'trilha de auditoria da exceção');
perform pg_temp.assert((select count(*) from private.v87_events where kind='exception_granted' and season_id=s25) = 1 and (select reason from private.golden_glove_exceptions where season_id=s25) like 'Nenhum goleiro%', 'justificativa guardada');
perform pg_temp.assert((select min_matches from private.golden_glove_exceptions where season_id=s25) >= 3, 'piso absoluto de 3 atuações');
perform pg_temp.assert(pg_temp.ver(s25,'golden_glove') = 2 and (select basis from private.season_award_results where season_id=s25 and category='golden_glove' and is_current) = 'exception', 'versão 2 com base "exception"');
-- Repetir não duplica.
v_cnt := pg_temp.notifs('award_season_golden_glove', v_a);
perform private.season_awards_sync(s25);
perform pg_temp.assert(pg_temp.ver(s25,'golden_glove') = 2 and pg_temp.notifs('award_season_golden_glove', v_a) = v_cnt, 'exceção idempotente');
-- Revogar a exceção desfaz a concessão (revogação) e volta a aguardar.
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform public.revoke_golden_glove_exception(s25, 'Concedida por engano na primeira análise');
execute 'reset role';
perform pg_temp.assert(pg_temp.st(s25,'golden_glove') = 'awaiting_exception' and pg_temp.aw(s25,'season_golden_glove') = '{}', 'exceção revogada: sem Luva, volta a aguardar');
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform public.grant_golden_glove_exception(s25, 50, 3, 'Reconcedida após conferir as súmulas da temporada');
execute 'reset role';
perform pg_temp.assert(pg_temp.aw(s25,'season_golden_glove') = '{2}', 'reconcedida');

-- ===== Sala de Troféus: só contadores (C02/F02) =====
perform set_config('role','authenticated',true); perform pg_temp.as_user(6);
j := public.get_player_career_summary(pg_temp.uid(6));
perform pg_temp.assert((j->'trophies'->>'season_top_scorer')::int = 2, 'Sala: contador do Artilheiro da Temporada = 2 (2025 e 2026)');
perform pg_temp.assert((j->'trophies'->>'season_maestro')::int = 0 and (j->'trophies'->>'season_golden_glove')::int = 0, 'Sala: outros contadores zerados');
perform pg_temp.assert(j->'trophies' ? 'monthly_goalkeeper' and j->'trophies' ? 'season_craque' and j->'trophies' ? 'match_craque', 'Sala: tipos anteriores intactos');
perform pg_temp.assert((public.get_player_career_summary(pg_temp.uid(2))->'trophies'->>'season_golden_glove')::int = 2, 'Sala: Luva do goleiro 2 = 2 (2025 e 2026)');
perform pg_temp.assert((public.get_trophy_history(pg_temp.uid(6), 'season_top_scorer')->>'counter_only')::boolean and jsonb_array_length(public.get_trophy_history(pg_temp.uid(6), 'season_top_scorer')->'items') = 0,
 'Sala: sem cartões individuais por temporada');
perform pg_temp.assert(jsonb_array_length(public.get_trophy_history(pg_temp.uid(6), 'top_scorer')->'items') >= 1, 'histórico do Artilheiro do Mês continua como antes');
-- ===== AD01: Meus Prêmios =====
execute 'reset role';
insert into public.awards(pelada_id, season_id, membership_id, award_type) values(v_a, s26, pg_temp.mem(v_a,6), 'season_craque');
perform set_config('role','authenticated',true); perform pg_temp.as_user(6);
j := public.get_player_season_titles(pg_temp.uid(6));
perform pg_temp.assert((j->>'visible')::boolean and jsonb_array_length(j->'items') = 3, 'AD01: 3 títulos (Craque 2026, Artilheiro 2026, Artilheiro 2025)');
perform pg_temp.assert((j->'items'->0->>'award_type') = 'season_craque' and (j->'items'->1->>'award_type') = 'season_top_scorer' and (j->'items'->1->>'season_id')::uuid = s26
 and (j->'items'->2->>'season_id')::uuid = s25, 'AD01: ordem pela temporada mais recente, um por linha');
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements(j->'items') e where e->>'award_type' in ('top_scorer','monthly_king','monthly_garcom','monthly_goalkeeper','match_craque','bola_murcha')),
 'AD01: sem prêmios de mês/rodada/partida');
perform pg_temp.assert((j->'items'->1->>'is_shared')::boolean and (j->'items'->1->>'pelada_name') = 'Pelada A' and (j->'items'->1->>'year')::int = 2026, 'AD01: título compartilhado, pelada de origem e ano');
perform pg_temp.assert(jsonb_array_length(public.get_player_season_titles(pg_temp.uid(10))->'items') = 0, 'AD01: sem títulos = lista vazia (o app esconde o bloco)');
-- Privacidade: carreira privada some para os outros; quem não divide pelada não vê com "peladas".
execute 'reset role';
update public.profiles set career_visibility='private' where id = pg_temp.uid(6);
perform set_config('role','authenticated',true); perform pg_temp.as_user(7);
perform pg_temp.assert(not (public.get_player_season_titles(pg_temp.uid(6))->>'visible')::boolean, 'privacidade: carreira privada');
perform pg_temp.as_user(6); perform pg_temp.assert((public.get_player_season_titles(pg_temp.uid(6))->>'visible')::boolean, 'o próprio vê');
execute 'reset role';
update public.profiles set career_visibility='peladas' where id = pg_temp.uid(6);
perform set_config('role','authenticated',true); perform pg_temp.as_user(7);
perform pg_temp.assert((public.get_player_season_titles(pg_temp.uid(6))->>'visible')::boolean, 'quem divide pelada vê');
perform pg_temp.as_user(11);
perform pg_temp.assert(not (public.get_player_season_titles(pg_temp.uid(6))->>'visible')::boolean, 'quem não divide pelada não vê');
-- Revogação sai da lista: anular a partida 1 tira o 6 do Artilheiro 2026.
execute 'reset role';
update public.matches set status='annulled' where id = m1;
perform private.close_month(v_a, '2026-03-01');
perform set_config('role','authenticated',true); perform pg_temp.as_user(6);
perform pg_temp.assert(jsonb_array_length(public.get_player_season_titles(pg_temp.uid(6))->'items') = 2, 'AD01: revogação remove o título da lista');
execute 'reset role';
update public.matches set status='finalized' where id = m1;
perform private.close_month(v_a, '2026-03-01');
perform set_config('role','authenticated',true); perform pg_temp.as_user(6);
perform pg_temp.assert(jsonb_array_length(public.get_player_season_titles(pg_temp.uid(6))->'items') = 3, 'AD01: restauração devolve o título');
-- Várias peladas: o mesmo jogador com título em outra pelada vê as duas origens.
execute 'reset role';
v_e := pg_temp.pelada('Pelada E', 12, array[6], array[]::int[]);
insert into public.seasons(pelada_id,name,kind,starts_on,ends_on) values(v_e,'Temporada 2024','annual','2024-01-01','2024-12-31') returning id into sq;
insert into public.awards(pelada_id, season_id, membership_id, award_type) values(v_e, sq, pg_temp.mem(v_e,6), 'season_maestro');
perform set_config('role','authenticated',true); perform pg_temp.as_user(6);
j := public.get_player_season_titles(pg_temp.uid(6));
perform pg_temp.assert(jsonb_array_length(j->'items') = 4 and exists(select 1 from jsonb_array_elements(j->'items') e where e->>'pelada_name' = 'Pelada E' and e->>'award_type' = 'season_maestro'), 'AD01: múltiplas peladas com a pelada de origem');
execute 'reset role';

-- ===== Retrospectiva (C04) e isolamento (RLS/permissões) =====
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
j := public.get_season_retrospective_official(s26);
perform pg_temp.assert(j->'season_awards'->'top_scorer'->'winners'->0 ? 'name' and jsonb_array_length(j->'season_awards'->'top_scorer'->'winners') = 2, 'C04: retrospectiva traz os vencedores com nome');
perform pg_temp.assert(j->'season_awards'->'golden_glove'->'winners'->0->>'value' is not null and j ? 'version', 'C04: estatística principal e snapshot da V8.1 preservado');
perform pg_temp.as_user(11);
perform pg_temp.expect_error(format('select public.get_season_retrospective_official(%L)', s26), 'SEASON_NOT_FOUND');
perform pg_temp.expect_error(format('select public.get_season_awards(%L)', s26), 'SEASON_NOT_FOUND');
perform pg_temp.assert((select count(*) from public.awards where season_id = s26) = 0, 'RLS: outra pelada não lê os prêmios');
perform pg_temp.expect_error('select * from private.season_award_results', 'permission denied');
perform pg_temp.expect_error('select * from private.golden_glove_exceptions', 'permission denied');
perform pg_temp.expect_error('select * from private.v87_events', 'permission denied');
perform pg_temp.expect_error(format('select private.season_awards_sync(%L)', s26), 'permission denied');
perform pg_temp.expect_error('select public.process_season_awards()', 'permission denied');
perform pg_temp.as_user(7);
perform pg_temp.assert(not (public.get_season_awards(s26) ? 'golden_glove_exception') and not (public.get_season_awards(s26)->'categories'->'top_scorer' ? 'ranking'), 'membro comum: sem ranking');
perform pg_temp.assert(jsonb_array_length(public.get_season_awards(s26)->'categories'->'golden_glove'->'winners') = 1 and public.get_season_awards(s26)->>'ref_note' like '%temporadas anteriores%', 'C09: limitação da REF móvel explícita');
execute 'reset role';
-- Álbum permanece com 48 figurinhas (C06): nada novo foi criado.
perform pg_temp.assert((select count(*) from public.sticker_definitions) = 48, 'C06: álbum com 48 figurinhas');
perform pg_temp.assert(not exists(select 1 from public.sticker_definitions where code ilike '%maestro%' or code ilike '%luva%' or code ilike '%glove%'), 'sem figurinhas novas');
-- Sem logs de autoria de votos (nenhuma tabela V8.7 tem eleitor/voto).
perform pg_temp.assert(not exists(select 1 from information_schema.columns where table_schema='private' and table_name in ('season_award_results','golden_glove_exceptions','v87_events')
 and (column_name ilike '%vot%' or column_name ilike '%ballot%')), 'privacidade: sem dados de voto nas tabelas V8.7');

-- Isolamento: a apuração da pelada A não tocou na outra pelada.
perform pg_temp.assert(not exists(select 1 from public.awards where pelada_id = v_o) and not exists(select 1 from private.season_award_results where pelada_id = v_o), 'isolamento entre peladas');
end $test$;

-- ============ Cenários independentes, cada um numa pelada própria ============
select pg_temp.users(21, 90);

-- ===== Limiares da Luva: 19 / 20 / 21 partidas e ceil (B06/A04) =====
do $t$
declare v_h uuid; s uuid; i int; r record; v_a_ts timestamptz;
begin
update private.v87_activation set min_season_end = '2099-01-01';
v_h := pg_temp.pelada('Pelada H', 51, array[52,53,54], array[52,54]);
for i in 1..19 loop
 perform pg_temp.finish(v_h, pg_temp.at(2022,1,1) + (i*7) * interval '1 day', 0, 0,
  case when i <= 10
   then '[{"m":52,"team":"A","pos":"goalkeeper"},{"m":54,"team":"B","pos":"goalkeeper"},{"m":53,"team":"B","pos":"defender"}]'::jsonb
   else '[{"m":54,"team":"A","pos":"goalkeeper"},{"m":53,"team":"B","pos":"defender"}]'::jsonb end);
end loop;
s := pg_temp.season(v_h, 2022);
select * into r from private.glove_candidates(s,50,5) where membership_id = pg_temp.mem(v_h,52);
perform pg_temp.assert(r.season_matches = 19 and r.required = 10 and r.gk_matches = 10 and r.eligible, 'B06: 19 partidas ⇒ ceil(9,5) = 10; 10 atuações elegível');
perform pg_temp.finish(v_h, pg_temp.at(2022,9,1), 0, 0, '[{"m":54,"team":"A","pos":"goalkeeper"},{"m":53,"team":"B","pos":"defender"}]');
select * into r from private.glove_candidates(s,50,5) where membership_id = pg_temp.mem(v_h,52);
perform pg_temp.assert(r.season_matches = 20 and r.required = 10 and r.eligible, 'B06: 20 partidas ⇒ 10; elegível');
perform pg_temp.finish(v_h, pg_temp.at(2022,9,8), 0, 0, '[{"m":54,"team":"A","pos":"goalkeeper"},{"m":53,"team":"B","pos":"defender"}]');
select * into r from private.glove_candidates(s,50,5) where membership_id = pg_temp.mem(v_h,52);
perform pg_temp.assert(r.season_matches = 21 and r.required = 11 and not r.eligible, 'B06: 21 partidas ⇒ ceil(10,5) = 11; 10 atuações não elegível');
select * into r from private.glove_candidates(s,50,5) where membership_id = pg_temp.mem(v_h,54);
perform pg_temp.assert(r.eligible and r.gk_matches = 21, '21 atuações: elegível');
-- Exceção só reduz: com 40% e piso 3, o requisito é max(3, ceil(8,4)) = 9.
perform pg_temp.assert((select required from private.glove_candidates(s,40,3) limit 1) = 9, 'exceção: max(3, ceil(40% de 21)) = 9');
perform pg_temp.assert((select required from private.glove_candidates(s,0,3) limit 1) = 3, 'piso absoluto de 3 atuações');
-- Publica e confere a Luva (54 com 21 atuações e REF neutra vence; 52 inelegível).
update private.v87_activation set min_season_end = '2020-01-01';
update public.seasons set ends_on = '2022-12-31' where id = s; perform private.sync_season_status(v_h);
perform private.season_awards_after_change(v_h, null);
perform pg_temp.assert(pg_temp.w(s,'golden_glove') = '{54}', 'Luva da temporada longa = 54');
end $t$;

-- ===== Empates da Luva (A05/C03/B04): REF → defesas difíceis/partida → partidas como GOL → compartilhado =====
do $t$
declare v_j uuid; s uuid; i int; q uuid; r record;
begin
update private.v87_activation set min_season_end = '2099-01-01';
v_j := pg_temp.pelada('Pelada J', 41, array[42,43,44,45,46], array[42,43,44,45]);
-- 2023: 42 e 43 em todas as 5 partidas; 99 × 95 defesas difíceis. A REF empata na precisão persistida (6 casas): decide a média.
for i in 1..5 loop
 q := pg_temp.finish(v_j, pg_temp.at(2023,3,1) + (i*7) * interval '1 day', 0, 0,
  '[{"m":42,"team":"A","pos":"goalkeeper"},{"m":43,"team":"B","pos":"goalkeeper"},{"m":46,"team":"B","pos":"defender"}]');
 perform pg_temp.saves(q, 42, 99); perform pg_temp.saves(q, 43, 95);
end loop;
-- 2024: sem nenhum registro de defesas: REF neutra igual, média ausente igual, 5 × 5 atuações ⇒ prêmio compartilhado.
for i in 1..5 loop
 perform pg_temp.finish(v_j, pg_temp.at(2024,3,1) + (i*7) * interval '1 day', 0, 0,
  '[{"m":42,"team":"A","pos":"goalkeeper"},{"m":43,"team":"B","pos":"goalkeeper"},{"m":46,"team":"B","pos":"defender"}]');
end loop;
-- 2025: 42 em 5 partidas, 43 em 6 (uma partida só com 43); sem registro: mais partidas como GOL desempata.
for i in 1..5 loop
 perform pg_temp.finish(v_j, pg_temp.at(2025,3,1) + (i*7) * interval '1 day', 0, 0,
  '[{"m":42,"team":"A","pos":"goalkeeper"},{"m":43,"team":"B","pos":"goalkeeper"},{"m":46,"team":"B","pos":"defender"}]');
end loop;
perform pg_temp.finish(v_j, pg_temp.at(2025,6,1), 0, 0, '[{"m":43,"team":"A","pos":"goalkeeper"},{"m":46,"team":"B","pos":"defender"}]');
update private.v87_activation set min_season_end = '2020-01-01';
perform private.season_awards_after_change(v_j, null);
s := pg_temp.season(v_j, 2023);
select * into r from private.glove_candidates(s,50,5) where membership_id = pg_temp.mem(v_j,42);
perform pg_temp.assert((select count(distinct ref) from private.glove_candidates(s,50,5) where eligible) = 1, 'B04: REFs iguais na precisão persistida (6 casas)');
perform pg_temp.assert(pg_temp.w(s,'golden_glove') = '{42}', 'A05: empate de REF ⇒ maior média de defesas difíceis por partida como GOL (99 × 95)');
s := pg_temp.season(v_j, 2024);
perform pg_temp.assert(pg_temp.w(s,'golden_glove') = '{42,43}' and pg_temp.aw(s,'season_golden_glove') = '{42,43}', 'A05: empate total ⇒ prêmio compartilhado');
perform pg_temp.assert((select bool_and(is_shared) from public.awards where season_id = s and award_type = 'season_golden_glove' and status = 'active'), 'C03: compartilhado, troféu integral para cada');
perform pg_temp.assert((select count(*) from public.awards where season_id = s and award_type = 'season_golden_glove' and status = 'active') = 2, 'dois troféus integrais');
s := pg_temp.season(v_j, 2025);
perform pg_temp.assert(pg_temp.w(s,'golden_glove') = '{43}', 'A05: mais partidas como GOL desempata (6 × 5)');
end $t$;

-- ===== 0 e 1 gol/assistência; gol contra e sem autoria (A01/A02) =====
do $t$
declare v_l uuid; s24 uuid; s25 uuid;
begin
update private.v87_activation set min_season_end = '2099-01-01';
v_l := pg_temp.pelada('Pelada L', 61, array[62,63], array[]::int[]);
-- 2024: só gol contra e gol sem autoria, nenhuma assistência: ninguém ganha.
perform pg_temp.finish(v_l, pg_temp.at(2024,5,4), 2, 0,
 '[{"m":62,"team":"A","pos":"defender","og":1},{"m":63,"team":"B","pos":"midfielder"}]', '[{"team":"B","type":"unattributed_goal","q":1}]');
perform pg_temp.finish(v_l, pg_temp.at(2024,5,11), 0, 0, '[{"m":62,"team":"A","pos":"defender"},{"m":63,"team":"B","pos":"midfielder"}]');
-- 2025: exatamente 1 gol e 1 assistência (mínimo 1 atingido).
perform pg_temp.finish(v_l, pg_temp.at(2025,5,4), 1, 0,
 '[{"m":62,"team":"A","pos":"attacker","g":1},{"m":63,"team":"A","pos":"midfielder","a":1},{"m":61,"team":"B","pos":"defender"}]');
perform pg_temp.finish(v_l, pg_temp.at(2025,5,11), 0, 0, '[{"m":62,"team":"A","pos":"attacker"},{"m":63,"team":"B","pos":"midfielder"}]');
update private.v87_activation set min_season_end = '2020-01-01';
perform private.season_awards_after_change(v_l, null);
s24 := pg_temp.season(v_l, 2024); s25 := pg_temp.season(v_l, 2025);
perform pg_temp.assert(pg_temp.st(s24,'top_scorer') = 'no_winner' and pg_temp.st(s24,'maestro') = 'no_winner', 'zero gol e zero assistência: sem prêmio');
perform pg_temp.assert(pg_temp.aw(s24,'season_top_scorer') = '{}' and pg_temp.aw(s24,'season_maestro') = '{}', 'nenhum prêmio ativo');
perform pg_temp.assert(pg_temp.st(s24,'golden_glove') = 'no_winner' and pg_temp.st(s25,'golden_glove') = 'no_winner', 'sem goleiro: sem Luva e sem exceção disponível');
perform pg_temp.assert(pg_temp.w(s25,'top_scorer') = '{62}' and pg_temp.w(s25,'maestro') = '{63}', '1 gol e 1 assistência bastam (mínimo 1)');
perform pg_temp.assert((select (ranking->0->>'value')::int from private.season_award_results where season_id = s25 and category = 'top_scorer') = 1, 'valor 1');
end $t$;

-- ===== Sem candidato e improvisado: exceção indisponível (B07/F01) =====
do $t$
declare v_c uuid; s uuid; i int;
begin
update private.v87_activation set min_season_end = '2099-01-01';
v_c := pg_temp.pelada('Pelada C', 21, array[22,23,24,25], array[22]);
for i in 1..8 loop
 perform pg_temp.finish(v_c, pg_temp.at(2024,2,1) + (i*7) * interval '1 day', 0, 0,
  case when i <= 2 then '[{"m":22,"team":"A","pos":"goalkeeper"},{"m":23,"team":"B","pos":"goalkeeper"},{"m":24,"team":"B","pos":"defender"}]'::jsonb
   else '[{"m":23,"team":"A","pos":"goalkeeper"},{"m":24,"team":"B","pos":"defender"}]'::jsonb end);
end loop;
update private.v87_activation set min_season_end = '2020-01-01';
perform private.season_awards_after_change(v_c, null);
s := pg_temp.season(v_c, 2024);
perform pg_temp.assert(pg_temp.st(s,'golden_glove') = 'no_winner' and pg_temp.aw(s,'season_golden_glove') = '{}', 'GOL oficial com só 2 atuações (< piso 3) e improvisado com 8: sem Luva');
perform set_config('role','authenticated',true); perform pg_temp.as_user(21);
perform pg_temp.expect_error(format('select public.grant_golden_glove_exception(%L,0,3,%L)', s, 'tentando admitir o improvisado'), 'EXCEPTION_NOT_AVAILABLE');
execute 'reset role';
perform pg_temp.assert(not exists(select 1 from public.awards where season_id = s and award_type = 'season_golden_glove'), 'B07: improvisado nunca recebe a Luva, nem por exceção');
end $t$;

-- ===== Exceção que deixa de valer quando surge elegível normal (C08) =====
do $t$
declare v_c uuid; s uuid; i int; q uuid; ma uuid; j jsonb;
begin
update private.v87_activation set min_season_end = '2099-01-01';
v_c := pg_temp.pelada('Pelada C2', 31, array[32,33,34], array[32]);
for i in 1..9 loop
 q := pg_temp.finish(v_c, pg_temp.at(2024,2,1) + (i*7) * interval '1 day', 0, 0,
  case when i <= 5 then '[{"m":32,"team":"A","pos":"goalkeeper"},{"m":33,"team":"B","pos":"goalkeeper"},{"m":34,"team":"B","pos":"defender"}]'::jsonb
   else '[{"m":33,"team":"A","pos":"goalkeeper"},{"m":34,"team":"B","pos":"defender"}]'::jsonb end);
 if i = 1 then ma := q; end if;
end loop;
s := pg_temp.season(v_c, 2024);
update public.matches set status = 'annulled' where id = ma; -- 8 partidas oficiais; 32 com 4 atuações
update private.v87_activation set min_season_end = '2020-01-01';
perform private.season_awards_after_change(v_c, null);
perform pg_temp.assert(pg_temp.st(s,'golden_glove') = 'awaiting_exception', 'sem elegível normal (4 < max(5, 4)): aguarda a exceção');
perform set_config('role','authenticated',true); perform pg_temp.as_user(31);
j := public.grant_golden_glove_exception(s, 40, 3, 'Temporada curta, o único goleiro oficial jogou 4 de 8 partidas');
execute 'reset role';
perform pg_temp.assert(j->>'status' = 'published' and pg_temp.w(s,'golden_glove') = '{32}', 'exceção (40%, piso 3 ⇒ 4): 32 vence; improvisado 33 (8 atuações) continua fora');
-- Restaurar a partida anulada: 9 partidas, 32 com 5 atuações = mínimo normal 5 ⇒ passa a ser elegível normal; a exceção perde o sentido.
update public.matches set status = 'finalized' where id = ma;
perform private.close_month(v_c, '2024-02-01');
perform pg_temp.assert(pg_temp.w(s,'golden_glove') = '{32}' and (select basis from private.season_award_results where season_id = s and category = 'golden_glove' and is_current) = 'normal', 'elegível normal ⇒ base normal');
perform pg_temp.assert((select status from private.golden_glove_exceptions where season_id = s) = 'void', 'exceção anulada (há elegível normal)');
perform pg_temp.assert(pg_temp.ver(s,'golden_glove') = 3, 'três versões: aguardando, exceção, normal');
perform pg_temp.assert(pg_temp.aw(s,'season_golden_glove') = '{32}' and (select count(*) from public.awards where season_id = s and award_type = 'season_golden_glove' and status = 'active') = 1, 'um único prêmio ativo');
end $t$;

-- ===== Encerramento antecipado, agendador e ciclo de vida (B01/V8.1) =====
do $t$
declare v_f uuid; s uuid; n int;
begin
update private.v87_activation set min_season_end = '2020-01-01';
v_f := pg_temp.pelada('Pelada F', 71, array[72,73,74], array[]::int[]);
perform pg_temp.finish(v_f, pg_temp.at(2026,10,3), 2, 0, '[{"m":72,"team":"A","pos":"attacker","g":2},{"m":73,"team":"A","pos":"midfielder","a":1},{"m":74,"team":"B","pos":"defender"}]');
perform pg_temp.finish(v_f, pg_temp.at(2026,10,10), 1, 0, '[{"m":72,"team":"A","pos":"attacker","g":1},{"m":73,"team":"A","pos":"midfielder","a":1},{"m":74,"team":"B","pos":"defender"}]');
select id into s from public.seasons where pelada_id = v_f;
-- Temporada em andamento: nada.
perform pg_temp.assert(private.process_season_awards() >= 0 and not exists(select 1 from private.season_award_results where season_id = s), 'temporada em andamento não é apurada');
-- Encerramento antecipado (data final no passado) com a temporada SUSPENSA: não apura.
update public.seasons set ends_on = '2026-10-20', lifecycle = 'suspended' where id = s;
perform pg_temp.assert(private.season_awards_sync(s)->>'status' = 'SEASON_NOT_READY', 'suspensa não é apurada');
update public.seasons set lifecycle = 'cancelled' where id = s;
perform pg_temp.assert(private.season_awards_sync(s)->>'status' = 'SEASON_NOT_READY', 'cancelada não é apurada');
update public.seasons set lifecycle = 'normal' where id = s;
perform private.sync_season_status(v_f);
-- Agendador: apura uma vez, depois nada a fazer.
n := private.process_season_awards();
perform pg_temp.assert(n >= 1 and pg_temp.w(s,'top_scorer') = '{72}' and pg_temp.w(s,'maestro') = '{73}', 'B01: encerramento antecipado segue as regras normais (dados até o encerramento)');
perform pg_temp.assert(pg_temp.st(s,'golden_glove') = 'no_winner', 'sem goleiro: sem Luva');
perform pg_temp.assert(private.process_season_awards() = 0, 'agendador idempotente');
perform pg_temp.assert((select count(*) from public.notification_events where event_type = 'season_awards_published' and pelada_id = v_f) = 4, 'aviso coletivo para os 4 membros ativos');
-- O agendador completo continua rodando com o novo passo.
perform private.run_scheduled_tasks();
end $t$;

-- ===== Conta apagada (retired) não recebe o título (RN-106) =====
do $t$
declare v_p uuid; s uuid;
begin
update private.v87_activation set min_season_end = '2099-01-01';
v_p := pg_temp.pelada('Pelada P', 81, array[82,83], array[]::int[]);
perform pg_temp.finish(v_p, pg_temp.at(2024,4,6), 3, 3, '[{"m":82,"team":"A","pos":"attacker","g":3},{"m":83,"team":"B","pos":"attacker","g":3}]');
update private.v87_activation set min_season_end = '2020-01-01';
update public.pelada_memberships set status = 'retired' where id = pg_temp.mem(v_p, 83);
s := pg_temp.season(v_p, 2024);
perform private.season_awards_after_change(v_p, null);
perform pg_temp.assert(pg_temp.w(s,'top_scorer') = '{82}' and pg_temp.aw(s,'season_top_scorer') = '{82}', 'RN-106: o ranking inclui o 83, mas só o 82 recebe');
end $t$;

do $t$ begin
raise exception 'PASS: 054_v87_season_awards';
end $t$;
