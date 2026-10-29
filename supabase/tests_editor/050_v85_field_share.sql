-- V8.5 (migração 064): campo ilustrativo (rascunho/publicação/conflitos) e pacote de compartilhamento.
-- Termina SEMPRE com o erro proposital "PASS: 050_v85_field_share".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99852000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
declare v_p uuid; v_tok text; i int; r jsonb; v_prep uuid; v_ver int; v_comp uuid; v_cv int; v_mems uuid[]; v_pos jsonb;
 v_d int; v_d2 int; v_stamp text; v_g uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v85f-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,8) n;
update private.app_config set value='true'::jsonb where key='premium_beta_open';
for i in 1..8 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||lpad(i::text,2,'0'),true,true); end loop;
perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada V85F','GOL');
v_tok := public.create_pelada_invite(v_p);
for i in 2..8 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok, (array['GOL','ZAG','ZAG','MEI','MEI','ATA','ATA'])[i-1]); end loop;
update public.pelada_memberships set role='assistant', assistant_since=now() where id=pg_temp.mem(v_p,2);
perform pg_temp.as_user(1);
v_mems := array(select pg_temp.mem(v_p,n) from generate_series(1,8) n);
r := public.open_draw_preparation(v_p, 'single', 1); v_prep := (r->>'id')::uuid; v_ver := (r->>'version')::int;
r := public.set_draw_members(v_prep, v_ver, v_mems[1:7]); v_ver := (r->>'version')::int;
r := public.add_draw_guest(v_prep, v_ver, null, 'Visitante', null, true); v_ver := (r->>'version')::int; v_g := (r->>'guest_id')::uuid;
r := public.generate_draw_preview(v_prep, v_ver, gen_random_uuid());
r := public.confirm_draw_preview((r->'preview'->>'id')::uuid, v_ver, null, null, gen_random_uuid());
v_comp := (r->'compositions'->0->>'id')::uuid; v_cv := 1;

-- rascunho com posições fora do campo (área neutra) e inválidas
perform pg_temp.expect_error(format('select public.save_field_draft(%L,null,%L)',v_comp,'{"x":1}'),'FIELD_LAYOUT_INVALID');
v_pos := (select jsonb_object_agg(pid::text, jsonb_build_object('x', 10 + n*10, 'y', case when n=1 then 110 else 50 end))
 from (select pid, row_number() over (order by pid) n from public.team_composition_members where composition_id=v_comp) q);
r := public.save_field_draft(v_comp, null, v_pos); v_d := (r->>'version')::int;
perform pg_temp.assert(jsonb_array_length(r->'missing')=0, 'todos posicionados (um fora do campo é neutro)');
perform pg_temp.expect_error(format('select public.save_field_draft(%L,%s,%L)',v_comp,v_d+5,v_pos),'VERSION_CONFLICT');

-- jogador não vê rascunho
perform pg_temp.as_user(5);
r := public.get_field_layout(v_comp);
perform pg_temp.assert(r->'published'='null'::jsonb and r->'draft'='null'::jsonb, 'jogador: nada publicado, sem rascunho');
perform pg_temp.expect_error(format('select public.save_field_draft(%L,null,%L)',v_comp,v_pos),'STAFF_REQUIRED');

-- dois administradores: o segundo publica antes (REV-61)
perform pg_temp.as_user(2);
r := public.save_field_draft(v_comp, null, v_pos); v_d2 := (r->>'version')::int;
r := public.publish_field_layout(v_comp, v_d2, null, gen_random_uuid());
perform pg_temp.assert((r->>'published_seq')::int=1, 'publicado seq 1');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.publish_field_layout(%L,%s,null,%L)',v_comp,v_d,gen_random_uuid()),'LAYOUT_PUBLISHED_BY_OTHER');

-- composição muda durante a edição (REV-63): posições compatíveis ficam, revisão exigida
r := public.apply_composition_ops(v_comp, v_cv, jsonb_build_array(jsonb_build_object('op','remove','pid',v_g),
 jsonb_build_object('op','add','membership_id',v_mems[8],'team','A')), gen_random_uuid()); v_cv := (r->>'version')::int;
r := public.get_field_layout(v_comp);
perform pg_temp.assert((r->'draft'->>'needs_review')::boolean and not (r->'draft'->'positions' ? v_g::text)
 and r->'draft'->'missing' ? v_mems[8]::text, 'revisão: removido some, novo falta');
perform pg_temp.expect_error(format('select public.publish_field_layout(%L,%s,1,%L)',v_comp,v_d,gen_random_uuid()),'LAYOUT_NEEDS_REVIEW');
r := public.save_field_draft(v_comp, v_d, (r->'draft'->'positions') || jsonb_build_object(v_mems[8]::text, '{"x":50,"y":20}'::jsonb));
v_d := (r->>'version')::int;
r := public.publish_field_layout(v_comp, v_d, 1, gen_random_uuid());
perform pg_temp.assert((r->>'published_seq')::int=2 and not (r->>'needs_review')::boolean, 'publicado seq 2');

-- campo não muda equipe/posição oficial (REV-54)
perform pg_temp.assert((select version from public.team_compositions where id=v_comp)=v_cv, 'composição intacta pelo campo');

-- pacote de compartilhamento: mesma versão, todos, carimbo muda com a composição (REV-65/57)
perform pg_temp.as_user(5);
r := public.get_share_payload(v_comp); v_stamp := r->>'stamp';
perform pg_temp.assert((r->>'count')::int=8 and (r->>'composition_version')::int=v_cv and (r->>'field_seq')::int=2, 'pacote completo');
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements(r->'members') x where x ? 'overall'), 'sem OVR no pacote');
perform pg_temp.as_user(1);
r := public.apply_composition_ops(v_comp, v_cv, jsonb_build_array(jsonb_build_object('op','transfer','pid',v_mems[8])), gen_random_uuid());
perform pg_temp.assert(public.get_share_payload(v_comp)->>'stamp' <> v_stamp, 'nova versão → novo carimbo (nova imagem)');
perform pg_temp.assert((public.get_field_layout(v_comp)->'published'->>'needs_review')::boolean, 'campo publicado sinaliza versão antiga');

raise exception 'PASS: 050_v85_field_share';
end $test$;
