-- Escudo da pelada (migração 028). Rodar SOMENTE em banco local descartável. Tudo em transação com ROLLBACK.
\set ON_ERROR_STOP on
begin;
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('c2810000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.crest(p uuid, f int, ext text default 'png') returns text language sql as
 $$ select p::text || '/' || ('e0000000-0000-4000-8000-' || lpad(f::text,12,'0')) || '.' || ext $$;
create function pg_temp.visible(p_name text) returns boolean language sql as
 $$ select exists(select 1 from storage.objects where bucket_id='crests' and name=p_name) $$;

do $test$
declare v_p uuid; v_q uuid; v_tok text; v_old text;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-cr'||n||'@example.invalid','',now(),now(),now() from generate_series(1,4) n;
perform set_config('role','authenticated',true);
for i in 1..4 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada do Escudo','attacker');
v_tok := public.create_pelada_invite(v_p);
perform pg_temp.as_user(2); perform public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(4); v_q := public.create_pelada('Outra Pelada','attacker');

-- ===== Bucket privado =====
execute 'reset role';
perform pg_temp.assert((select not public and file_size_limit=1048576
 and allowed_mime_types=array['image/png','image/jpeg'] from storage.buckets where id='crests'),'bucket privado, PNG/JPEG até 1 MB');
perform set_config('role','authenticated',true);

-- ===== Upload só pelo admin, na pasta da pelada, com nome aleatório =====
perform pg_temp.as_user(1);
insert into storage.objects(bucket_id,name) values('crests',pg_temp.crest(v_p,1));
perform pg_temp.expect_error(format('insert into storage.objects(bucket_id,name) values(%L,%L)',
 'crests',v_p||'/escudo.png'),'row-level security');
perform pg_temp.expect_error(format('insert into storage.objects(bucket_id,name) values(%L,%L)',
 'crests',pg_temp.crest(v_q,1)),'row-level security');
perform pg_temp.expect_error(format('insert into storage.objects(bucket_id,name) values(%L,%L)',
 'crests','nao-e-uuid/'||'e0000000-0000-4000-8000-000000000001.png'),'row-level security');
perform pg_temp.assert(pg_temp.visible(pg_temp.crest(v_p,1)),'admin vê o que enviou');
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('insert into storage.objects(bucket_id,name) values(%L,%L)',
 'crests',pg_temp.crest(v_p,2)),'row-level security');
perform pg_temp.assert(not pg_temp.visible(pg_temp.crest(v_p,1)),'jogador não vê escudo ainda não definido');

-- ===== Escudo só por RPC do admin =====
perform pg_temp.expect_error(format('select public.set_pelada_crest(%L,%L)',v_p,pg_temp.crest(v_p,1)),'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('select public.clear_pelada_crest(%L)',v_p),'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('update public.peladas set crest_path=null where id=%L',v_p),'permission denied');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.set_pelada_crest(%L,%L)',v_p,pg_temp.crest(v_q,1)),'INVALID_CREST_PATH');
perform pg_temp.expect_error(format('select public.set_pelada_crest(%L,%L)',v_p,v_p||'/../x.png'),'INVALID_CREST_PATH');
perform pg_temp.expect_error(format('select public.update_pelada_profile(%L,%L,null,%L,null,null,null)',
 v_p,'Pelada do Escudo',pg_temp.crest(v_p,1)),'INVALID_CREST_PATH');
perform pg_temp.assert(public.set_pelada_crest(v_p,pg_temp.crest(v_p,1)) is null,'primeiro escudo');
perform public.update_pelada_profile(v_p,'Pelada do Escudo FC',null,pg_temp.crest(v_p,1),null,null,null);
perform pg_temp.assert((select name='Pelada do Escudo FC' and crest_path=pg_temp.crest(v_p,1) from public.peladas where id=v_p),
 'editar o perfil mantém o escudo');

-- ===== Quem vê o escudo =====
perform pg_temp.as_user(2);
perform pg_temp.assert(pg_temp.visible(pg_temp.crest(v_p,1)),'membro vê');
perform pg_temp.as_user(3);
perform pg_temp.assert(not pg_temp.visible(pg_temp.crest(v_p,1)),'quem não é da pelada não vê');
perform pg_temp.as_user(4);
perform pg_temp.assert(not pg_temp.visible(pg_temp.crest(v_p,1)),'admin de outra pelada não vê');
perform pg_temp.expect_error(format('select public.set_pelada_crest(%L,%L)',v_p,pg_temp.crest(v_p,1)),'ADMIN_REQUIRED');

-- ===== Troca e remoção: o antigo deixa de ser visível =====
perform pg_temp.as_user(1);
insert into storage.objects(bucket_id,name) values('crests',pg_temp.crest(v_p,3,'jpg'));
v_old := public.set_pelada_crest(v_p,pg_temp.crest(v_p,3,'jpg'));
perform pg_temp.assert(v_old=pg_temp.crest(v_p,1),'devolve o escudo antigo para apagar');
perform pg_temp.as_user(2);
perform pg_temp.assert(not pg_temp.visible(pg_temp.crest(v_p,1)) and pg_temp.visible(pg_temp.crest(v_p,3,'jpg')),'membro vê só o atual');
perform pg_temp.as_user(1);
perform pg_temp.assert(public.clear_pelada_crest(v_p)=pg_temp.crest(v_p,3,'jpg'),'remoção devolve o antigo');
perform pg_temp.as_user(2);
perform pg_temp.assert(not pg_temp.visible(pg_temp.crest(v_p,3,'jpg')),'removido some para o membro');

-- ===== Troca de admin: o antigo perde o poder, o novo ganha =====
perform pg_temp.as_user(1);
perform public.set_pelada_crest(v_p,pg_temp.crest(v_p,1));
perform public.leave_pelada(v_p);
perform pg_temp.expect_error(format('select public.clear_pelada_crest(%L)',v_p),'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('insert into storage.objects(bucket_id,name) values(%L,%L)',
 'crests',pg_temp.crest(v_p,4)),'row-level security');
perform pg_temp.assert(not pg_temp.visible(pg_temp.crest(v_p,1)),'quem saiu não vê mais');
perform pg_temp.as_user(2);
perform pg_temp.assert(public.clear_pelada_crest(v_p)=pg_temp.crest(v_p,1),'novo admin remove');

perform set_config('role','anon',true);
perform pg_temp.expect_error(format('select public.set_pelada_crest(%L,%L)',v_p,pg_temp.crest(v_p,1)),'permission denied');
execute 'reset role';
perform pg_temp.assert(not has_function_privilege('authenticated','public.crest_paths_in_use(text[])','EXECUTE'),'lista de escudos em uso é só do servidor');

  raise notice 'OK: 022_pelada_crest';
end
$test$;
rollback;
\echo 'PASS: 022_pelada_crest'
