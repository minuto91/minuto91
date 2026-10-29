-- V4.3 (migração 040): correções da auditoria V4.2.
-- 5.1 privacidade dos sorteios na exclusão de conta · 5.2 escalação desatualizada bloqueada no servidor ·
-- 5.3 Duelo só com ativos · 5.4 sorteios independentes sem repetição evitável · 5.5 semente do servidor.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 033_v43_audit_fixes".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('97000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.draw(p uuid, s uuid[], m text, r int, seed text) returns jsonb language plpgsql as
 $$ declare v jsonb; begin
  reset role; v := private.create_team_draw_core(p, s, m, r, seed);
  perform set_config('role','authenticated',true); return v; end $$;
-- Quantas composições diferentes (times invertidos = a mesma) há nas rodadas de um sorteio.
create function pg_temp.distinct_rounds(p_draw jsonb) returns int language sql as
 $$ select count(distinct k)::int from (
     select (select string_agg(least(a, b), '') from (select
       (select string_agg(x->>'membership_id', ',' order by x->>'membership_id') from jsonb_array_elements(r->'team_a') x) a,
       (select string_agg(x->>'membership_id', ',' order by x->>'membership_id') from jsonb_array_elements(r->'team_b') x) b) q) k
     from jsonb_array_elements(p_draw->'rounds') r) z $$;
-- Algum texto do banco ligado a sorteios/escalações ainda contém o nome?
create function pg_temp.name_in_draw_data(p_pelada uuid, p_name text) returns boolean language sql as
 $$ select exists(select 1 from public.team_draws where pelada_id=p_pelada and input::text like '%'||p_name||'%')
     or exists(select 1 from public.planned_lineups where pelada_id=p_pelada and (label like '%'||p_name||'%'))
     or exists(select 1 from private.audit_events where pelada_id=p_pelada and event_type like 'team_draw%' and metadata::text like '%'||p_name||'%')
     or exists(select 1 from public.team_draws d where d.pelada_id=p_pelada and private.draw_json(d.id)::text like '%'||p_name||'%')
     or exists(select 1 from public.planned_lineups l where l.pelada_id=p_pelada and private.lineup_json(l.id)::text like '%'||p_name||'%') $$;

-- V8.5 (062): public.create_team_draw recusa novos sorteios por OVR (DRAW_ALGORITHM_SUPERSEDED). Os testes do
-- sorteio histórico (algorithm_version 2) passam a chamar o núcleo antigo como dono do banco, só para manter
-- a regressão do histórico (leitura, confirmação, escalações).
create function pg_temp.legacy(p uuid, s uuid[], m text, r int) returns jsonb language plpgsql as
 $$ declare v jsonb; begin
  reset role; v := private.create_team_draw_core(p, s, m, r, null);
  perform set_config('role','authenticated',true); return v; end $$;
do $test$
declare
 v_p uuid; v_tok text; v_d jsonb; v_d2 jsonb; v_sel uuid[]; v_l jsonb; v_l2 jsonb; v_x uuid; v_s uuid; v_req uuid;
 v_draft uuid; v_conf uuid; v_canc uuid; v_ind uuid; v_n int; v_ok int := 0; v_seed text;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-af'||n||'@example.invalid','',now(),now(),now() from generate_series(1,30) n;
perform set_config('role','authenticated',true);
for i in 1..30 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Atleta '||chr(64+i)||'x',true,true); end loop;

-- Pelada: 1 admin GOL, 2 GOL, 3..8 defensores (legado), 9..14 meias (legado), 15..18 atacantes (legado), 19..20 ZAG.
perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada Auditoria','goalkeeper');
v_tok := public.create_pelada_invite(v_p);
for i in 2..20 loop
 perform pg_temp.as_user(i);
 perform public.join_pelada(v_tok, case when i=2 then 'goalkeeper' when i<=8 then 'defender' when i<=14 then 'midfielder'
  when i<=18 then 'attacker' else 'ZAG' end);
end loop;
perform pg_temp.as_user(1);

-- ===================== 5.5 Sementes =====================
v_sel := (select array_agg(pg_temp.mem(v_p,i)) from generate_series(1,12) i);
v_d := pg_temp.legacy(v_p, v_sel, 'single', 1);
perform pg_temp.assert(v_d->>'seed_source'='server' and (v_d->>'algorithm_version')::int=2 and v_d->>'seed' ~ '^[0-9a-f]{32}$',
 'semente gerada no servidor (128 bits), origem e versão registradas');
v_d2 := pg_temp.legacy(v_p, v_sel, 'single', 1);
perform pg_temp.assert(v_d->>'seed' <> v_d2->>'seed','cada sorteio oficial tem semente própria');
perform pg_temp.expect_error(format('select public.create_team_draw(%L,%L,%L,1,%L)',v_p,v_sel,'single','minha-semente'),'does not exist');
perform pg_temp.expect_error(format('select private.create_team_draw_core(%L,%L,%L,1,%L)',v_p,v_sel,'single','x'),'permission denied');
perform pg_temp.expect_error(format('select private.draw_split_v2(%L,%L,%L,%L)','{a,b}','{1,2}',array[gen_random_uuid(),gen_random_uuid()],'x'),'permission denied');
execute 'reset role';
perform pg_temp.assert((select metadata->>'seed'=v_d2->>'seed' and metadata->>'seed_source'='server' and (metadata->>'algorithm_version')::int=2
 from private.audit_events where event_type='team_draw_created' and metadata->>'draw_id'=v_d2->>'id'),'auditoria guarda semente, origem e versão');
-- Reprodutibilidade: a mesma semente e os mesmos jogadores dão os mesmos times (auditoria interna).
perform set_config('role','authenticated',true);
v_d := pg_temp.draw(v_p, v_sel, 'independent', 3, v_d2->>'seed');
perform pg_temp.assert(v_d->>'seed_source'='manual_test','semente manual marcada como teste');
v_d2 := pg_temp.draw(v_p, v_sel, 'independent', 3, v_d2->>'seed');
perform pg_temp.assert(v_d->'rounds'=v_d2->'rounds','reproduzível pela semente registrada');

-- ===================== 5.4 Diversidade nos sorteios independentes =====================
-- 12 jogadores (2 GOL + 6 DEF + 4 MEI): muitas divisões válidas -> 6 rodadas diferentes.
for k in 1..15 loop
 v_d := pg_temp.draw(v_p, v_sel, 'independent', 6, 'div-'||k);
 if pg_temp.distinct_rounds(v_d)=6 and not (v_d->'warnings' ? 'LIMITED_DIVERSITY') and (v_d->'diversity'->>'distinct')::int=6 then v_ok := v_ok+1; end if;
end loop;
perform pg_temp.assert(v_ok=15,'sem repetição quando há alternativas: '||v_ok||' de 15');
-- O sorteio oficial (semente do servidor) também.
v_d := pg_temp.legacy(v_p, v_sel, 'independent', 8);
perform pg_temp.assert(pg_temp.distinct_rounds(v_d)=8,'8 rodadas independentes diferentes');
-- 2 goleiros apenas: uma composição possível -> repete e avisa, sem quebrar a regra.
v_d := pg_temp.draw(v_p, array[pg_temp.mem(v_p,1),pg_temp.mem(v_p,2)], 'independent', 3, 'pouca');
perform pg_temp.assert(pg_temp.distinct_rounds(v_d)=1 and (v_d->'warnings') ? 'LIMITED_DIVERSITY'
 and (v_d->'diversity'->>'limited')::boolean,'diversidade limitada informada');
for r in 0..2 loop
 perform pg_temp.assert(jsonb_array_length(v_d->'rounds'->r->'team_a')=1 and jsonb_array_length(v_d->'rounds'->r->'team_b')=1,'1 x 1 em toda rodada');
end loop;
-- 2 GOL + 2 ZAG: só 2 composições -> 4 rodadas usam as 2 e avisam.
v_d := pg_temp.draw(v_p, array[pg_temp.mem(v_p,1),pg_temp.mem(v_p,2),pg_temp.mem(v_p,19),pg_temp.mem(v_p,20)], 'independent', 4, 'duas');
perform pg_temp.assert(pg_temp.distinct_rounds(v_d)=2 and (v_d->'warnings') ? 'LIMITED_DIVERSITY','usa todas as composições possíveis (2)');
perform pg_temp.assert((select bool_and((select count(*) from jsonb_array_elements(r->'by_position') x where abs((x->>'a')::int-(x->>'b')::int)>1)=0)
 from jsonb_array_elements(v_d->'rounds') r),'regra por posição mantida mesmo repetindo');
-- Modo único: uma composição só (reutilizável), sem aviso de diversidade.
v_d := pg_temp.draw(v_p, v_sel, 'single', 5, 'unico');
perform pg_temp.assert(jsonb_array_length(v_d->'rounds')=1 and not (v_d->'warnings' ? 'LIMITED_DIVERSITY'),'único reutilizável');
perform pg_temp.assert((v_d->'warnings') ? 'LEGACY_POSITIONS','avisa que há posições a atualizar');

-- ===================== 5.1 Privacidade dos sorteios =====================
-- Atleta Jx (10, ativo) e Atleta Kx (11, sai antes de excluir) em sorteios confirmado, rascunho, cancelado e independente.
v_sel := (select array_agg(pg_temp.mem(v_p,i)) from generate_series(1,14) i);
v_d := pg_temp.legacy(v_p, v_sel, 'single', 2); v_conf := (v_d->>'id')::uuid;
perform public.confirm_team_draw(v_conf);
v_d := pg_temp.legacy(v_p, v_sel, 'independent', 3); v_ind := (v_d->>'id')::uuid;
perform public.confirm_team_draw(v_ind);
v_d := pg_temp.legacy(v_p, v_sel, 'single', 1); v_canc := (v_d->>'id')::uuid;
perform public.cancel_team_draw(v_canc);
v_d := pg_temp.legacy(v_p, v_sel, 'single', 1); v_draft := (v_d->>'id')::uuid;
v_l := public.save_lineup(v_p, null, 'Quinta', array[pg_temp.mem(v_p,10)], array[pg_temp.mem(v_p,11)]);
execute 'reset role';
perform pg_temp.assert(not exists(select 1 from public.team_draws where pelada_id=v_p and input::text like '%Atleta%'),
 'nenhum nome copiado no input dos sorteios novos');
-- Mesmo que alguém tente gravar um nome no input, o gatilho remove.
update public.team_draws set input = input || jsonb_build_array(jsonb_build_object('membership_id',gen_random_uuid(),'name','Atleta Jx'))
where id=v_draft;
perform pg_temp.assert(not exists(select 1 from public.team_draws where id=v_draft and input::text like '%Atleta Jx%'),'gatilho remove nomes');
perform set_config('role','authenticated',true);
perform pg_temp.assert(public.get_team_draws(v_p)::text like '%Atleta Jx%','enquanto ativo, o nome aparece (lido ao vivo)');
-- Ex-integrante: sai e depois exclui a conta.
perform pg_temp.as_user(11); perform public.leave_pelada(v_p); perform public.request_account_deletion(true);
-- Ativo exclui a conta.
perform pg_temp.as_user(10); perform public.request_account_deletion(true);
perform pg_temp.as_user(1);
execute 'reset role';
perform pg_temp.assert(not pg_temp.name_in_draw_data(v_p,'Atleta Jx') and not pg_temp.name_in_draw_data(v_p,'Atleta Kx'),
 'pedido de exclusão: nomes somem do histórico de sorteios e escalações');
-- Exclusão definitiva (30 dias) e nova consulta / recomputação.
update private.account_deletion_requests set purge_after=now()-interval '1 minute' where user_id in (pg_temp.uid(10),pg_temp.uid(11)) and status='pending';
for v_req in select id from private.account_deletion_requests where user_id in (pg_temp.uid(10),pg_temp.uid(11)) and status='pending' loop
 perform private.purge_account(v_req);
end loop;
select id into v_s from public.seasons where pelada_id=v_p order by starts_on desc limit 1;
perform private.recompute_stats(v_p, v_s);
perform pg_temp.assert(not pg_temp.name_in_draw_data(v_p,'Atleta Jx') and not pg_temp.name_in_draw_data(v_p,'Atleta Kx'),
 'depois da exclusão definitiva e do recálculo, nenhum nome volta');
perform pg_temp.assert((select count(*) from public.team_draw_players where draw_id in (v_conf,v_ind,v_canc,v_draft))
 = 14*(1+3+1+1),'resultados esportivos dos sorteios preservados');
perform set_config('role','authenticated',true);
perform pg_temp.assert(public.get_team_draws(v_p)::text like '%Aposentado%' and public.get_team_draws(v_p)::text not like '%Atleta Jx%',
 'histórico consultado mostra Aposentado');
perform pg_temp.assert(public.get_lineups(v_p)::text not like '%Atleta Jx%' and public.get_lineups(v_p)::text not like '%Atleta Kx%','escalações sem o nome');
perform pg_temp.expect_error(format('select public.confirm_team_draw(%L)',v_draft),'DRAW_STALE');

-- ===================== 5.2 Escalações desatualizadas =====================
perform pg_temp.as_user(1);
v_l := public.save_lineup(v_p, null, 'Sábado', array[pg_temp.mem(v_p,1),pg_temp.mem(v_p,3),pg_temp.mem(v_p,9)],
 array[pg_temp.mem(v_p,2),pg_temp.mem(v_p,4),pg_temp.mem(v_p,12)]);
-- Refinar a posição no mesmo setor (Defensor -> ZAG) não invalida.
perform pg_temp.as_user(3); perform public.set_my_position(v_p,'ZAG');
perform pg_temp.as_user(1);
v_l2 := (select x from jsonb_array_elements(public.get_lineups(v_p)) x where x->>'id'=v_l->>'id');
perform pg_temp.assert(not (v_l2->>'needs_review')::boolean,'Defensor -> ZAG é a mesma função: segue válida');
-- Mudança real de posição (ZAG -> VOL): revisão obrigatória, bloqueada no servidor.
perform pg_temp.as_user(3); perform public.set_my_position(v_p,'VOL');
perform pg_temp.as_user(1);
v_l2 := (select x from jsonb_array_elements(public.get_lineups(v_p)) x where x->>'id'=v_l->>'id');
perform pg_temp.assert((v_l2->>'needs_review')::boolean and v_l2->>'review_reason'='POSITION_CHANGED','escalação marcada para revisão');
perform pg_temp.expect_error(format('select public.use_lineup_in_match(%L)',v_l->>'id'),'LINEUP_NEEDS_REVIEW');
-- Requisição direta sem permissão.
perform pg_temp.as_user(9);
perform pg_temp.expect_error(format('select public.revalidate_lineup(%L)',v_l->>'id'),'STAFF_REQUIRED');
perform pg_temp.expect_error(format('select public.use_lineup_in_match(%L)',v_l->>'id'),'STAFF_REQUIRED');
perform pg_temp.as_user(1);
v_l2 := public.revalidate_lineup((v_l->>'id')::uuid);
perform pg_temp.assert(not (v_l2->>'needs_review')::boolean,'revalidada pelo admin');
-- Mudança entre posições específicas (ZAG -> LD) também exige revisão.
v_l2 := public.save_lineup(v_p, null, 'Domingo', array[pg_temp.mem(v_p,1),pg_temp.mem(v_p,19)], array[pg_temp.mem(v_p,2),pg_temp.mem(v_p,20)]);
perform pg_temp.as_user(19); perform public.set_my_position(v_p,'LD');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.use_lineup_in_match(%L)',v_l2->>'id'),'LINEUP_NEEDS_REVIEW');
-- Uso válido; escalação de 1 rodada não pode ser usada duas vezes.
v_x := public.use_lineup_in_match((v_l->>'id')::uuid, now());
perform pg_temp.assert(v_x is not null,'escalação revalidada vira rascunho de súmula');
perform pg_temp.expect_error(format('select public.use_lineup_in_match(%L)',v_l->>'id'),'LINEUP_INVALID');
-- Jogador sai: bloqueada e não pode ser revalidada.
v_l := public.save_lineup(v_p, null, 'Terça', array[pg_temp.mem(v_p,1),pg_temp.mem(v_p,5)], array[pg_temp.mem(v_p,2),pg_temp.mem(v_p,6)]);
perform pg_temp.as_user(5); perform public.leave_pelada(v_p);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.use_lineup_in_match(%L)',v_l->>'id'),'DRAW_STALE');
perform pg_temp.expect_error(format('select public.revalidate_lineup(%L)',v_l->>'id'),'DRAW_STALE');
-- Jogador suspenso: idem.
v_l := public.save_lineup(v_p, null, 'Quarta', array[pg_temp.mem(v_p,1),pg_temp.mem(v_p,7)], array[pg_temp.mem(v_p,2),pg_temp.mem(v_p,8)]);
execute 'reset role';
update public.pelada_memberships set status='suspended' where id=pg_temp.mem(v_p,7);
perform set_config('role','authenticated',true);
perform pg_temp.expect_error(format('select public.use_lineup_in_match(%L)',v_l->>'id'),'DRAW_STALE');
-- Escalação cancelada.
v_l := public.save_lineup(v_p, null, 'Sexta', array[pg_temp.mem(v_p,1),pg_temp.mem(v_p,13)], array[pg_temp.mem(v_p,2),pg_temp.mem(v_p,14)]);
perform public.cancel_lineup((v_l->>'id')::uuid);
perform pg_temp.expect_error(format('select public.use_lineup_in_match(%L)',v_l->>'id'),'LINEUP_INVALID');
-- Escalação adulterada no banco (time vazio) é recusada.
v_l := public.save_lineup(v_p, null, 'Adulterada', array[pg_temp.mem(v_p,1)], array[pg_temp.mem(v_p,2)]);
execute 'reset role';
update public.planned_lineup_players set team='A' where lineup_id=(v_l->>'id')::uuid;
perform set_config('role','authenticated',true);
perform pg_temp.expect_error(format('select public.use_lineup_in_match(%L)',v_l->>'id'),'LINEUP_INVALID');
perform pg_temp.expect_error('select * from public.planned_lineup_players','permission denied');

-- ===================== 5.3 Duelo: só ativos =====================
execute 'reset role';
select id into v_req from public.pelada_memberships where pelada_id=v_p and status='retired' limit 1;
perform pg_temp.assert(v_req is not null,'há um aposentado');
select id into v_s from public.seasons where pelada_id=v_p order by starts_on desc limit 1;
perform set_config('role','authenticated',true);
perform pg_temp.assert(public.get_player_duel(v_s, pg_temp.mem(v_p,1), pg_temp.mem(v_p,2)) ? 'a','ativos: permitido');
perform pg_temp.expect_error(format('select public.get_player_duel(%L,%L,%L)',v_s,pg_temp.mem(v_p,1),pg_temp.mem(v_p,5)),'DUEL_INVALID_PLAYER'); -- saiu
perform pg_temp.expect_error(format('select public.get_player_duel(%L,%L,%L)',v_s,pg_temp.mem(v_p,1),pg_temp.mem(v_p,7)),'DUEL_INVALID_PLAYER'); -- suspenso
perform pg_temp.expect_error(format('select public.get_player_duel(%L,%L,%L)',v_s,pg_temp.mem(v_p,1),v_req),'DUEL_INVALID_PLAYER'); -- aposentado
-- Jogador de outra pelada.
perform pg_temp.as_user(25); v_x := public.create_pelada('Outra','attacker');
execute 'reset role'; v_draft := pg_temp.mem(v_x,25); perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.get_player_duel(%L,%L,%L)',v_s,pg_temp.mem(v_p,1),v_draft),'DUEL_INVALID_PLAYER');

raise exception 'PASS: 033_v43_audit_fixes';
end $test$;
