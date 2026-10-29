-- V8.5 (migrações 061/062): preparação, prévia exata, confirmação e composições versionadas.
-- Termina SEMPRE com o erro proposital "PASS: 048_v85_draw_flow".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99850000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
declare v_p uuid; v_tok text; i int; r jsonb; r2 jsonb; v_prep uuid; v_ver int; v_g uuid; v_g2 uuid; v_prev uuid;
 v_req uuid; v_comp uuid; v_cv int; v_mems uuid[]; v_a uuid; v_b uuid; v_cnt int; v_x uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v85-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,16) n;
update private.app_config set value='true'::jsonb where key='premium_beta_open';
-- Roda como dono (leituras diretas de conferência); RPCs dependem só do usuário da sessão (auth.uid()).
for i in 1..16 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||lpad(i::text,2,'0'),true,true); end loop;
perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada V85','GOL');
v_tok := public.create_pelada_invite(v_p);
for i in 2..12 loop perform pg_temp.as_user(i);
 perform public.join_pelada(v_tok, (array['GOL','ZAG','ZAG','LD','LE','VOL','MEI','CA','PD','ATA','ATA'])[i-1]);
end loop;
perform pg_temp.as_user(1);
v_mems := array(select pg_temp.mem(v_p,n) from generate_series(1,12) n);

-- ===== sorteio antigo por OVR encerrado =====
perform pg_temp.expect_error(format('select public.create_team_draw(%L,%L,%L,1)',v_p,v_mems,'single'),'DRAW_ALGORITHM_SUPERSEDED');

-- ===== permissões =====
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select public.open_draw_preparation(%L)',v_p),'STAFF_REQUIRED');
perform pg_temp.expect_error(format('select public.get_draw_preparation(%L)',v_p),'STAFF_REQUIRED');
perform pg_temp.as_user(1);

-- ===== preparação: abrir, recuperar, membros, duplicidade =====
r := public.open_draw_preparation(v_p, 'single', 3); v_prep := (r->>'id')::uuid; v_ver := (r->>'version')::int;
perform pg_temp.assert((public.open_draw_preparation(v_p)->>'id')::uuid = v_prep, 'REV-37: devolve a preparação aberta');
r := public.set_draw_members(v_prep, v_ver, v_mems || v_mems[3]); v_ver := (r->>'version')::int;
perform pg_temp.assert(r->>'notice'='DUPLICATES_MERGED' and jsonb_array_length(r->'participants')=12, 'REV-71: duplicado mantido uma vez');
perform pg_temp.expect_error(format('select public.set_draw_members(%L,%s,%L)',v_prep,v_ver-1,v_mems),'VERSION_CONFLICT');
perform pg_temp.expect_error(format('select public.set_draw_members(%L,%s,%L)',v_prep,v_ver,array[pg_temp.uid(1)]),'DRAW_INVALID_PLAYER');

-- ===== convidados (REV-24/30) =====
perform pg_temp.expect_error(format('select public.add_draw_guest(%L,%s,null,%L,null,true)',v_prep,v_ver,' '),'GUEST_NAME_REQUIRED');
perform pg_temp.expect_error(format('select public.add_draw_guest(%L,%s,null,%L,%L,true)',v_prep,v_ver,'Zé','XX'),'INVALID_POSITION');
r := public.add_draw_guest(v_prep, v_ver, null, 'Convidado Sem Posição', null, true); v_ver := (r->>'version')::int; v_g := (r->>'guest_id')::uuid;
r := public.add_draw_guest(v_prep, v_ver, null, 'Convidado Goleiro', 'GOL', true); v_ver := (r->>'version')::int; v_g2 := (r->>'guest_id')::uuid;
perform pg_temp.assert(jsonb_array_length(r->'participants')=14, '14 participantes');
perform pg_temp.assert(exists(select 1 from jsonb_array_elements(r->'participants') x where (x->>'pid')::uuid=v_g and x->>'group'='none'),
 'REV-02: convidado sem posição no grupo próprio');
r := public.add_draw_guest(v_prep, v_ver, v_g2, null, 'ZAG', false); v_ver := (r->>'version')::int;
perform pg_temp.assert(exists(select 1 from jsonb_array_elements(r->'participants') x where (x->>'pid')::uuid=v_g2 and x->>'group'='ZAG'),
 'REV-30: posição do convidado editável na preparação');

-- ===== capitães (REV-21/25) =====
perform pg_temp.expect_error(format('select public.set_draw_captains(%L,%s,%L,%L)',v_prep,v_ver,v_mems[1],v_mems[2]),'CAPTAINS_DISABLED');
r := public.set_draw_preparation_options(v_prep, v_ver, 'independent', 3, null, true); v_ver := (r->>'version')::int;
perform pg_temp.expect_error(format('select public.set_draw_captains(%L,%s,%L,%L)',v_prep,v_ver,v_mems[1],v_mems[1]),'CAPTAINS_MUST_DIFFER');
perform pg_temp.expect_error(format('select public.generate_draw_preview(%L,%s,%L)',v_prep,v_ver,gen_random_uuid()),'CAPTAINS_REQUIRED');
r := public.set_draw_captains(v_prep, v_ver, v_mems[1], v_g2); v_ver := (r->>'version')::int; -- convidado capitão (REV-25)

-- ===== prévia exata, idempotência, substituição =====
v_req := gen_random_uuid();
r := public.generate_draw_preview(v_prep, v_ver, v_req);
r2 := public.generate_draw_preview(v_prep, v_ver, v_req);
perform pg_temp.assert((r2->>'replayed')::boolean and r2->'preview'->>'id' = r->'preview'->>'id', 'REV-20: mesmo request_id não repete');
perform pg_temp.assert((public.get_v85_operation(v_req)->>'found')::boolean, 'REV-40: resultado consultável');
perform pg_temp.assert(jsonb_array_length(r->'preview'->'rounds')=3, 'independente: 3 rodadas');
for i in 0..2 loop
 perform pg_temp.assert(((r->'preview'->'rounds'->i->'summary'->>'size_a')::int - (r->'preview'->'rounds'->i->'summary'->>'size_b')::int) = 0,
  'REV-05: 7 x 7');
 perform pg_temp.assert((r->'preview'->'rounds'->i->'summary'->>'cost')::int = (r->'preview'->'rounds'->i->'optimal'->>'cost')::int,
  'REV-31: custo da prévia = ótimo exato');
 perform pg_temp.assert(exists(select 1 from jsonb_array_elements(r->'preview'->'rounds'->i->'players') x
   where (x->>'pid')::uuid=v_mems[1] and x->>'team'='A' and (x->>'captain')::boolean)
  and exists(select 1 from jsonb_array_elements(r->'preview'->'rounds'->i->'players') x where (x->>'pid')::uuid=v_g2 and x->>'team'='B'),
  'REV-21: capitães fixos');
 perform pg_temp.assert(not (r->'preview'->'rounds'->i->'players'->0 ? 'overall'), 'sem OVR na prévia');
end loop;
v_prev := (r->'preview'->>'id')::uuid;
r := public.generate_draw_preview(v_prep, v_ver, gen_random_uuid());
perform pg_temp.assert((select status from public.draw_previews where id=v_prev)='replaced'
 and (select count(*) from public.draw_previews where prep_id=v_prep and status='active')=1, 'REV-38: uma prévia ativa');
perform pg_temp.expect_error(format('select public.confirm_draw_preview(%L,%s,null,null,%L)',v_prev,v_ver,gen_random_uuid()),'DRAW_STALE');
v_prev := (r->'preview'->>'id')::uuid;

-- ===== prévia obsoleta (REV-23/36/72) =====
perform pg_temp.as_user(4); perform public.set_my_position(v_p, 'MEI'); perform pg_temp.as_user(1);
perform pg_temp.assert((public.get_draw_preparation(v_p)->'preview'->>'stale')::boolean, 'mudança de posição marca a prévia');
perform pg_temp.expect_error(format('select public.confirm_draw_preview(%L,%s,null,null,%L)',v_prev,v_ver,gen_random_uuid()),'DRAW_STALE');
perform pg_temp.as_user(4); perform public.set_my_position(v_p, 'ZAG'); perform pg_temp.as_user(1);
r := public.remove_draw_participant(v_prep, v_ver, v_g); v_ver := (r->>'version')::int;
perform pg_temp.assert(r->'preview' is null or r->'preview' = 'null'::jsonb, 'mudança na preparação invalida a prévia');
perform pg_temp.assert((select status from public.draw_previews where id=v_prev)='invalidated', 'prévia invalidada');
r := public.generate_draw_preview(v_prep, v_ver, gen_random_uuid()); v_prev := (r->'preview'->>'id')::uuid;

-- ===== elegibilidade perdida (REV-27) =====
update public.pelada_memberships set status='suspended' where id=v_mems[12];
perform pg_temp.expect_error(format('select public.confirm_draw_preview(%L,%s,null,null,%L)',v_prev,v_ver,gen_random_uuid()),'DRAW_STALE');
update public.pelada_memberships set status='active' where id=v_mems[12];

-- ===== permissão revogada (REV-41) =====
update public.pelada_memberships set role='assistant', assistant_since=now() where id=v_mems[2];
perform pg_temp.as_user(2);
perform pg_temp.assert((public.get_draw_preparation(v_p)->>'id')::uuid = v_prep, 'outro administrador recupera a preparação');
update public.pelada_memberships set role='player', assistant_since=null where id=v_mems[2];
perform pg_temp.expect_error(format('select public.confirm_draw_preview(%L,%s,null,null,%L)',v_prev,v_ver,gen_random_uuid()),'STAFF_REQUIRED');
perform pg_temp.as_user(1);

-- ===== confirmação =====
v_req := gen_random_uuid();
r := public.confirm_draw_preview(v_prev, v_ver, 'Azul', 'Dourado', v_req);
perform pg_temp.assert(jsonb_array_length(r->'compositions')=3, '3 composições (uma por rodada)');
perform pg_temp.assert((public.confirm_draw_preview(v_prev, v_ver, 'Azul', 'Dourado', v_req)->>'replayed')::boolean, 'confirmação idempotente');
perform pg_temp.expect_error(format('select public.confirm_draw_preview(%L,%s,null,null,%L)',v_prev,v_ver,gen_random_uuid()),'PREP_CLOSED');
v_comp := (r->'compositions'->0->>'id')::uuid; v_cv := (r->'compositions'->0->>'version')::int;
perform pg_temp.assert((select count(*) from public.team_composition_members where composition_id=v_comp)=13, '13 na composição');

-- ===== leitura de jogador: só vigente, sem resumo (Etapa 36 A) =====
perform pg_temp.as_user(7);
r := public.get_team_compositions(v_p);
perform pg_temp.assert(jsonb_array_length(r)=3 and r->0->'summary' = 'null'::jsonb, 'jogador vê composição vigente, sem análise');
perform pg_temp.expect_error(format('select public.get_composition_history(%L)',v_comp),'STAFF_REQUIRED');
perform pg_temp.expect_error(format('select public.apply_composition_ops(%L,%s,%L,%L)',v_comp,v_cv,'[{"op":"transfer"}]',gen_random_uuid()),'STAFF_REQUIRED');
perform pg_temp.as_user(1);

-- ===== operações manuais =====
-- transferência gera desequilíbrio e é aceita, sem alerta (REV-15, Etapa 32 A)
select pid into v_a from public.team_composition_members where composition_id=v_comp and version_to is null and team='A' and not is_captain limit 1;
r := public.apply_composition_ops(v_comp, v_cv, jsonb_build_array(jsonb_build_object('op','transfer','pid',v_a)), gen_random_uuid());
v_cv := (r->>'version')::int;
v_cnt := (select count(*) from public.team_composition_members where composition_id=v_comp and version_to is null and team='A');
perform pg_temp.assert(v_cv=2 and (r->'summary'->>'size_a')::int=v_cnt and (r->'summary'->>'size_b')::int=13-v_cnt, 'transferência aplicada');
perform pg_temp.assert(not (r ? 'warnings'), 'sem alerta de equilíbrio');
-- inclusão assistida vai para a equipe menor (REV-10)
r := public.apply_composition_ops(v_comp, v_cv, jsonb_build_array(jsonb_build_object('op','add','guest_id',v_g)), gen_random_uuid());
v_cv := (r->>'version')::int;
perform pg_temp.assert(exists(select 1 from jsonb_array_elements(r->'members') x where (x->>'pid')::uuid=v_g
 and x->>'team'=case when v_cnt < 13-v_cnt then 'A' else 'B' end), 'assistida → menor');
-- duplicidade por outro caminho (REV-71)
r := public.apply_composition_ops(v_comp, v_cv, jsonb_build_array(jsonb_build_object('op','add','membership_id',v_mems[5],'team','B')), gen_random_uuid());
v_cv := (r->>'version')::int;
perform pg_temp.assert(r->'notices'->0->>'notice'='ALREADY_IN_COMPOSITION', 'mesma identidade informada');
-- capitão não sai sem substituição (REV-26)
perform pg_temp.expect_error(format('select public.apply_composition_ops(%L,%s,%L,%L)',v_comp,v_cv,
 jsonb_build_array(jsonb_build_object('op','remove','pid',v_mems[1])),gen_random_uuid()),'CAPTAIN_REPLACE_FIRST');
-- lote atômico: segunda operação inválida desfaz a primeira (REV-11/17)
perform pg_temp.expect_error(format('select public.apply_composition_ops(%L,%s,%L,%L)',v_comp,v_cv,
 jsonb_build_array(jsonb_build_object('op','transfer','pid',v_a), jsonb_build_object('op','remove','pid',gen_random_uuid())),gen_random_uuid()),'DRAW_INVALID_PLAYER');
perform pg_temp.assert((select version from public.team_compositions where id=v_comp)=v_cv, 'lote falho não grava');
-- versão antiga (REV-19)
perform pg_temp.expect_error(format('select public.apply_composition_ops(%L,%s,%L,%L)',v_comp,v_cv-1,
 jsonb_build_array(jsonb_build_object('op','transfer','pid',v_a)),gen_random_uuid()),'VERSION_CONFLICT');
-- troca A×B (REV-16) e operação inversa (REV-18)
select pid into v_b from public.team_composition_members where composition_id=v_comp and version_to is null and team='A' and not is_captain limit 1; -- v_a está em B após a transferência
r := public.apply_composition_ops(v_comp, v_cv, jsonb_build_array(jsonb_build_object('op','swap','a',v_a,'b',v_b)), gen_random_uuid());
v_cv := (r->>'version')::int;
r := public.apply_composition_ops(v_comp, v_cv, jsonb_build_array(jsonb_build_object('op','swap','a',v_a,'b',v_b)), gen_random_uuid());
v_cv := (r->>'version')::int;
-- substituição no mesmo time (REV-13) e desativar capitães (REV-26)
r := public.apply_composition_ops(v_comp, v_cv, jsonb_build_array(jsonb_build_object('op','captains','a',null,'b',null),
 jsonb_build_object('op','substitute','out',v_g2,'membership_id',v_mems[12])), gen_random_uuid());
v_cv := (r->>'version')::int;
perform pg_temp.assert(not (r->>'captains_enabled')::boolean and not exists(select 1 from jsonb_array_elements(r->'members') x where (x->>'captain')::boolean),
 'capitães desativados');
-- histórico completo (REV-51): versão 1 = sorteio original
r := public.get_composition_history(v_comp);
perform pg_temp.assert((r->>'current_version')::int=v_cv and jsonb_array_length(r->'versions')=v_cv, 'todas as versões');
perform pg_temp.assert(exists(select 1 from jsonb_array_elements(r->'versions'->0->'members') x where (x->>'pid')::uuid=v_g2)
 and r->'operations'->0->>'op_type'='created', 'sorteio original preservado');
-- outras rodadas não mudam (Etapa 7 / LAC-01)
perform pg_temp.assert((select version from public.team_compositions where prep_id=v_prep and round_number=2)=1, 'rodada 2 intacta');

-- ===== montagem manual / cópia (Etapa 17/18, REV-80) =====
r := public.copy_composition_to_preparation(v_comp, 'single', 1); v_prep := (r->>'id')::uuid; v_ver := (r->>'version')::int;
perform pg_temp.assert(jsonb_array_length(r->'suggested') = jsonb_array_length(r->'participants'), 'cópia sugere os times');
r2 := public.save_manual_preview(v_prep, v_ver, (select jsonb_agg(x || '{"round":1}'::jsonb) from jsonb_array_elements(r->'suggested') x), gen_random_uuid());
perform pg_temp.assert(r2->'preview'->>'source'='copy' and r2->'preview'->'rounds'->0->'optimal' = 'null'::jsonb, 'cópia não é sorteio otimizado');
r := public.confirm_draw_preview((r2->'preview'->>'id')::uuid, v_ver, null, null, gen_random_uuid());
perform pg_temp.assert(r->'compositions'->0->>'source'='copy', 'composição de origem copy');

-- ===== descarte (REV-79) =====
r := public.open_draw_preparation(v_p, 'single', 1); v_prep := (r->>'id')::uuid; v_ver := (r->>'version')::int;
perform pg_temp.expect_error(format('select public.discard_draw_preparation(%L,%s,false)',v_prep,v_ver),'CONFIRMATION_REQUIRED');
perform public.discard_draw_preparation(v_prep, v_ver, true);
perform pg_temp.assert(public.get_draw_preparation(v_p) is null and (select count(*) from public.team_compositions where pelada_id=v_p and status='active')=4,
 'descarte preserva composições oficiais');

-- ===== limite de tentativas (REV-45) =====
r := public.open_draw_preparation(v_p, 'single', 1); v_prep := (r->>'id')::uuid; v_ver := (r->>'version')::int;
r := public.set_draw_members(v_prep, v_ver, v_mems); v_ver := (r->>'version')::int;
for i in 1..20 loop perform public.generate_draw_preview(v_prep, v_ver, gen_random_uuid()); end loop;
perform pg_temp.expect_error(format('select public.generate_draw_preview(%L,%s,%L)',v_prep,v_ver,gen_random_uuid()),'DRAW_RATE_LIMITED');

-- ===== escrita direta bloqueada =====
perform set_config('role','authenticated',true);
perform pg_temp.expect_error('select * from public.team_compositions','permission denied');
perform pg_temp.expect_error(format('select private.draw_sample(%L,null)',array['GOL','ZAG']),'permission denied');

raise exception 'PASS: 048_v85_draw_flow';
end $test$;
