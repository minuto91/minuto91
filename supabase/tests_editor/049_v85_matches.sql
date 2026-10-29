-- V8.5 (migração 063): pré-cadastro, escalação prevista local, confirmação coletiva, súmula versionada,
-- revisão, linha do tempo, remarcação/cancelamento e lista de partidas.
-- Termina SEMPRE com o erro proposital "PASS: 049_v85_matches".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99851000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
declare v_p uuid; v_tok text; i int; r jsonb; v_prep uuid; v_ver int; v_g uuid; v_comp uuid; v_mems uuid[];
 v_m uuid; v_m2 uuid; v_dv int; v_req uuid; v_today date := (now() at time zone 'America/Sao_Paulo')::date;
 v_future timestamptz := now() + interval '3 days'; v_present jsonb; v_x uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v85m-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,14) n;
update private.app_config set value='true'::jsonb where key='premium_beta_open';
for i in 1..14 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||lpad(i::text,2,'0'),true,true); end loop;
perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada V85M','GOL');
v_tok := public.create_pelada_invite(v_p);
for i in 2..12 loop perform pg_temp.as_user(i);
 perform public.join_pelada(v_tok, (array['GOL','ZAG','ZAG','LD','LE','VOL','MEI','CA','PD','ATA','ATA'])[i-1]);
end loop;
perform pg_temp.as_user(1);
v_mems := array(select pg_temp.mem(v_p,n) from generate_series(1,10) n);

-- composição oficial com convidado sem posição
r := public.open_draw_preparation(v_p, 'single', 2); v_prep := (r->>'id')::uuid; v_ver := (r->>'version')::int;
r := public.set_draw_members(v_prep, v_ver, v_mems); v_ver := (r->>'version')::int;
r := public.add_draw_guest(v_prep, v_ver, null, 'Convidado', null, true); v_ver := (r->>'version')::int; v_g := (r->>'guest_id')::uuid;
r := public.generate_draw_preview(v_prep, v_ver, gen_random_uuid());
r := public.confirm_draw_preview((r->'preview'->>'id')::uuid, v_ver, null, null, gen_random_uuid());
v_comp := (r->'compositions'->0->>'id')::uuid;

-- ===== pré-cadastro futuro (Etapa 6/10), sem duplicar =====
v_req := gen_random_uuid();
r := public.pre_register_matches(v_p, jsonb_build_array(jsonb_build_object('composition_id',v_comp,'round',1,'played_at',v_future),
 jsonb_build_object('composition_id',v_comp,'round',2,'played_at',v_future + interval '7 days')), false, false, v_req);
perform pg_temp.assert(r->'items'->0->>'result'='CREATED' and r->'items'->1->>'result'='CREATED', 'duas rodadas criadas');
perform pg_temp.assert((public.pre_register_matches(v_p, '[]'::jsonb, false, false, v_req)->>'replayed')::boolean, 'idempotente');
v_m := (r->'items'->0->>'match_id')::uuid; v_m2 := (r->'items'->1->>'match_id')::uuid;
perform pg_temp.assert((select count(*) from public.match_planned_players where match_id=v_m)=11, 'prevista copiada');
perform pg_temp.assert((select count(*) from public.match_participants where match_id=v_m)=0, 'pré-cadastro não registra presença');
r := public.pre_register_matches(v_p, jsonb_build_array(jsonb_build_object('composition_id',v_comp,'round',1,'played_at',v_future)), false, false, gen_random_uuid());
perform pg_temp.assert(r->'items'->0->>'result'='EXISTS' and (select count(*) from public.matches where composition_id=v_comp)=2, 'Etapa 11: não duplica');
perform pg_temp.expect_error(format('select public.pre_register_matches(%L,%L,false,false,%L)',v_p,
 jsonb_build_array(jsonb_build_object('composition_id',v_comp,'round',1,'played_at',v_future),jsonb_build_object('composition_id',v_comp,'round',1,'played_at',v_future)),
 gen_random_uuid()),'DUPLICATE_ROUND');

-- ===== partida futura não publica =====
perform pg_temp.assert(public.get_match_sheet_review(v_m)->'blocking' ? 'MATCH_IN_FUTURE', 'revisão bloqueia data futura');
-- mesmo com times montados, o gatilho impede publicar antes da data
insert into public.match_participants(pelada_id,match_id,membership_id,team,primary_position)
 values(v_p,v_m2,v_mems[1],'A','goalkeeper'),(v_p,v_m2,v_mems[2],'B','goalkeeper');
update public.matches set participation_confirmed_at=now() where id=v_m2;
perform pg_temp.expect_error(format('select public.publish_match(%L)',v_m2),'MATCH_IN_FUTURE');
delete from public.match_participants where match_id=v_m2;
update public.matches set participation_confirmed_at=null where id=v_m2;

-- ===== ajuste local (Etapa 7): não muda composição nem a outra rodada =====
v_dv := (select draft_version from public.matches where id=v_m);
r := public.adjust_match_planned(v_m, v_dv, jsonb_build_array(jsonb_build_object('op','remove','pid',v_mems[10]),
 jsonb_build_object('op','add','membership_id',pg_temp.mem(v_p,11),'team','A')), gen_random_uuid());
v_dv := (r->>'draft_version')::int;
perform pg_temp.assert(jsonb_array_length(r->'planned')=11, 'remove + adiciona');
perform pg_temp.assert((select count(*) from public.match_planned_players where match_id=v_m2 and pid=v_mems[10])=1, 'outra rodada intacta');
perform pg_temp.assert((select version from public.team_compositions where id=v_comp)=1, 'composição intacta');
perform pg_temp.expect_error(format('select public.adjust_match_planned(%L,%s,%L,%L)',v_m,v_dv-1,
 jsonb_build_array(jsonb_build_object('op','transfer','pid',v_mems[1])),gen_random_uuid()),'VERSION_CONFLICT');
r := public.get_substitution_candidates(v_m, v_mems[2]);
perform pg_temp.assert(jsonb_array_length(r) >= 1, 'candidatos sem escolha automática');

-- ===== Etapa 11 reforçada: atualizar rascunho exige confirmação =====
r := public.pre_register_matches(v_p, jsonb_build_array(jsonb_build_object('composition_id',v_comp,'round',2)), true, false, gen_random_uuid());
perform pg_temp.assert(r->'items'->0->>'result'='UPDATED', 'rascunho sem presença atualiza com confirmação');

-- ===== remarcação para hoje e confirmação coletiva (Etapa 2/30) =====
r := public.reschedule_match_v85(v_m, now() - interval '1 hour', 'keep', gen_random_uuid());
perform pg_temp.assert((select originally_scheduled_at is not null from public.matches where id=v_m), 'REV-77: mesma linha, data original guardada');
v_dv := (select draft_version from public.matches where id=v_m);
perform pg_temp.expect_error(format('select public.publish_match(%L)',v_m),'TEAMS_INCOMPLETE');
select jsonb_agg(case when guest_id is not null then jsonb_build_object('guest_id',guest_id,'team',team)
  else jsonb_build_object('membership_id',membership_id,'team',team) end) into v_present
 from public.match_planned_players where match_id=v_m;
perform pg_temp.expect_error(format('select public.confirm_match_participation(%L,%s,%L,%L)',v_m,v_dv,v_present,gen_random_uuid()),'GUEST_POSITION_REQUIRED');
select jsonb_agg(case when guest_id is not null then jsonb_build_object('guest_id',guest_id,'team',team,'position','MEI')
  else jsonb_build_object('membership_id',membership_id,'team',team) end) into v_present
 from public.match_planned_players where match_id=v_m and pid <> v_mems[9]; -- ausente não entra
r := public.confirm_match_participation(v_m, v_dv, v_present, gen_random_uuid()); v_dv := (r->>'draft_version')::int;
perform pg_temp.assert((select count(*) from public.match_participants where match_id=v_m)=10, 'quem não entrou não conta');
perform pg_temp.assert((select status from public.matches where id=v_m)='draft', 'confirmar não publica');

-- ===== súmula versionada (Etapa 21) e revisão (Etapa 15) =====
select membership_id into v_x from public.match_participants where match_id=v_m and team='A' and membership_id is not null limit 1;
v_req := gen_random_uuid();
r := public.save_match_sheet_v85(v_m, v_dv, (select jsonb_agg(case when guest_id is not null then jsonb_build_object('guest_id',guest_id,'team',team,'position',primary_position)
  else jsonb_build_object('membership_id',membership_id,'team',team) end) from public.match_participants where match_id=v_m),
 jsonb_build_array(jsonb_build_object('membership_id',v_x,'type','goal','quantity',2),
  jsonb_build_object('team','B','type','unattributed_goal','quantity',1),
  jsonb_build_object('membership_id',v_x,'type','yellow_card','quantity',1)), v_req);
v_dv := (r->>'draft_version')::int;
perform pg_temp.assert((r->>'team_a_score')::int=2 and (r->>'team_b_score')::int=1, 'placar 2 x 1, gol sem autor');
perform pg_temp.assert((public.save_match_sheet_v85(v_m, 0, '[]', '[]', v_req)->>'replayed')::boolean, 'retry não regrava');
perform pg_temp.expect_error(format('select public.save_match_sheet_v85(%L,%s,%L,%L,%L)',v_m,v_dv-1,'[]','[]',gen_random_uuid()),'VERSION_CONFLICT');
r := public.get_match_sheet_review(v_m);
perform pg_temp.assert((r->>'can_publish')::boolean and r->'warnings'->0->>'code'='UNATTRIBUTED_GOALS', 'aviso não bloqueante');
-- linha do tempo opcional
r := public.set_match_timeline(v_m, v_dv, jsonb_build_array(jsonb_build_object('type','goal','membership_id',v_x,'minute',12),
 jsonb_build_object('type','goal','membership_id',v_x)));
v_dv := (r->>'draft_version')::int;
perform pg_temp.expect_error(format('select public.set_match_timeline(%L,%s,%L)',v_m,v_dv,
 jsonb_build_array(jsonb_build_object('type','goal','membership_id',v_x),jsonb_build_object('type','goal','membership_id',v_x),
  jsonb_build_object('type','goal','membership_id',v_x))),'TIMELINE_EXCEEDS_SHEET');
r := public.get_match_detail_v85(v_m);
perform pg_temp.assert((r->'timeline'->0->>'minute')::int=12 and r->'timeline'->1->'minute'='null'::jsonb, 'minuto só quando informado');

-- ===== jogador vê previsto mas não a súmula do rascunho =====
perform pg_temp.as_user(7);
r := public.get_match_detail_v85(v_m2);
perform pg_temp.assert(jsonb_array_length(r->'planned')=11 and r->'team_a_score'='null'::jsonb and r->'draft_version'='null'::jsonb, 'previsto sem súmula');
perform pg_temp.expect_error(format('select public.get_match_sheet_review(%L)',v_m),'STAFF_REQUIRED');
perform pg_temp.as_user(1);
v_x := public.create_match(v_p, now());
perform pg_temp.as_user(7);
perform pg_temp.expect_error(format('select public.get_match_detail_v85(%L)',v_x),'MATCH_NOT_FOUND');
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements(public.get_pelada_matches_v85(v_p)->'items') it where (it->>'id')::uuid=v_x),
 'rascunho manual some para jogador');
perform pg_temp.as_user(1);
perform public.discard_match_draft(v_x);

-- ===== publicar =====
r := public.publish_match(v_m);
perform pg_temp.assert((select status from public.matches where id=v_m) <> 'draft', 'publicada');
perform pg_temp.expect_error(format('select public.adjust_match_planned(%L,null,%L,%L)',v_m,
 jsonb_build_array(jsonb_build_object('op','transfer','pid',v_mems[1])),gen_random_uuid()),'MATCH_NOT_DRAFT');
r := public.pre_register_matches(v_p, jsonb_build_array(jsonb_build_object('composition_id',v_comp,'round',1)), true, true, gen_random_uuid());
perform pg_temp.assert(r->'items'->0->>'result'='PROTECTED', 'REV-78: publicada protegida');

-- ===== cancelamento preserva (REV-76) e remarcação limpa previsão (Etapa 30) =====
perform public.cancel_match(v_m2, 'Chuva');
r := public.get_match_detail_v85(v_m2);
perform pg_temp.assert(r->>'status'='cancelled' and r->'planned'='null'::jsonb and r->>'cancel_reason'='Chuva', 'cancelada sem escalação ativa');
perform pg_temp.assert((select count(*) from public.match_planned_players where match_id=v_m2)=11, 'histórico preservado');
r := public.reschedule_match_v85(v_m2, v_future + interval '14 days', 'clear', gen_random_uuid());
perform pg_temp.assert(r->>'planned_status'='cleared' and (select status from public.matches where id=v_m2)='draft', 'remarcada e limpa');

-- ===== lista (Etapas 8/22/23) =====
r := public.get_pelada_matches_v85(v_p, '{}'::jsonb, null, 1);
perform pg_temp.assert(jsonb_array_length(r->'items')=1 and r->>'next_cursor' is not null, 'paginação');
r := public.get_pelada_matches_v85(v_p, '{}'::jsonb, r->>'next_cursor', 10);
perform pg_temp.assert(jsonb_array_length(r->'items')=1, 'segunda página');
r := public.get_pelada_matches_v85(v_p, '{"status":["cancelled"]}'::jsonb, null, 10);
perform pg_temp.assert(jsonb_array_length(r->'items')=0, 'filtro de status');
r := public.get_pelada_matches_v85(v_p, jsonb_build_object('q', to_char(v_today,'DD/MM')), null, 10);
perform pg_temp.assert(jsonb_array_length(r->'items')>=1, 'busca por data');

raise exception 'PASS: 049_v85_matches';
end $test$;
