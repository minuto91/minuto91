-- Foto do perfil, pé dominante e edição do perfil (migração 027). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 021_profile_photo_foot" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('c2800000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.photo(n int, f int) returns text language sql as
 $$ select pg_temp.uid(n)::text || '/' || ('f0000000-0000-4000-8000-' || lpad(f::text,12,'0')) || '.jpg' $$;
-- Quantas fotos do bucket o usuário atual enxerga.
create function pg_temp.visible(p_name text) returns boolean language sql as
 $$ select exists(select 1 from storage.objects where bucket_id='avatars' and name=p_name) $$;

do $test$
declare v_p uuid; v_tok text; v_old text; v_n int;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-ph'||n||'@example.invalid','',now(),now(),now() from generate_series(1,4) n;
perform set_config('role','authenticated',true);
for i in 1..4 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada das Fotos','attacker');
v_tok := public.create_pelada_invite(v_p);
perform pg_temp.as_user(2); perform public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(3); perform public.join_pelada(v_tok,'goalkeeper');

-- ===== Bucket privado =====
execute 'reset role';
perform pg_temp.assert((select not public and file_size_limit=2097152 and allowed_mime_types=array['image/jpeg']
 from storage.buckets where id='avatars'),'bucket privado, JPEG até 2 MB');
perform set_config('role','authenticated',true);

-- ===== Upload só na própria pasta, com nome aleatório =====
perform pg_temp.as_user(1);
insert into storage.objects(bucket_id,name) values('avatars',pg_temp.photo(1,1));
perform pg_temp.expect_error(format('insert into storage.objects(bucket_id,name) values(%L,%L)',
 'avatars',pg_temp.photo(2,9)),'row-level security');
perform pg_temp.expect_error(format('insert into storage.objects(bucket_id,name) values(%L,%L)',
 'avatars',pg_temp.uid(1)||'/foto.png'),'row-level security');
perform pg_temp.assert(pg_temp.visible(pg_temp.photo(1,1)),'dono vê a própria foto');

-- ===== Foto só por RPC, sempre da própria pasta =====
perform pg_temp.expect_error('update public.profiles set avatar_path=null','permission denied');
perform pg_temp.expect_error(format('select public.set_my_avatar(%L)',pg_temp.photo(2,1)),'INVALID_AVATAR_PATH');
perform pg_temp.expect_error('select public.set_my_avatar(''../x.jpg'')','INVALID_AVATAR_PATH');
perform pg_temp.assert(public.set_my_avatar(pg_temp.photo(1,1)) is null,'primeira foto');

-- ===== Quem vê a foto =====
perform pg_temp.as_user(2);
perform pg_temp.assert(pg_temp.visible(pg_temp.photo(1,1)),'colega de pelada vê');
perform pg_temp.as_user(4);
perform pg_temp.assert(not pg_temp.visible(pg_temp.photo(1,1)),'quem não divide pelada não vê');
perform pg_temp.as_user(3);
perform public.block_user(pg_temp.uid(1));
perform pg_temp.assert(not pg_temp.visible(pg_temp.photo(1,1)),'quem bloqueou não vê');
perform public.unblock_user(pg_temp.uid(1));
perform pg_temp.assert(pg_temp.visible(pg_temp.photo(1,1)),'desbloqueou, vê de novo');

-- ===== Troca e remoção: a foto antiga deixa de ser visível =====
perform pg_temp.as_user(1);
insert into storage.objects(bucket_id,name) values('avatars',pg_temp.photo(1,2));
v_old := public.set_my_avatar(pg_temp.photo(1,2));
perform pg_temp.assert(v_old=pg_temp.photo(1,1),'devolve a foto antiga para apagar');
perform pg_temp.as_user(2);
perform pg_temp.assert(not pg_temp.visible(pg_temp.photo(1,1)) and pg_temp.visible(pg_temp.photo(1,2)),'colega vê só a atual');
perform pg_temp.as_user(1);
perform pg_temp.assert(public.clear_my_avatar()=pg_temp.photo(1,2),'remoção devolve a antiga');
perform pg_temp.as_user(2);
perform pg_temp.assert(not pg_temp.visible(pg_temp.photo(1,2)),'removida some para o colega');

-- ===== Aposentado: foto some para os colegas =====
perform pg_temp.as_user(1);
perform public.set_my_avatar(pg_temp.photo(1,2));
perform pg_temp.as_user(2);
perform public.request_account_deletion(true);
perform pg_temp.as_user(3);
perform pg_temp.assert(pg_temp.visible(pg_temp.photo(1,2)),'colega ativo vê');
perform pg_temp.as_user(1);
perform public.request_account_deletion(true);
perform pg_temp.as_user(3);
perform pg_temp.assert(not pg_temp.visible(pg_temp.photo(1,2)),'foto do Aposentado oculta');

-- ===== Perfil: nome e pé dominante =====
perform pg_temp.as_user(3);
perform public.update_my_profile('  Goleirão  ','left');
perform pg_temp.assert(public.get_my_profile()->>'display_name'='Goleirão' and public.get_my_profile()->>'dominant_foot'='left','perfil salvo');
perform pg_temp.assert((select player_name='Goleirão' from public.pelada_memberships where user_id=pg_temp.uid(3)),'nome atualizado na pelada');
perform public.update_my_profile('Goleirão',null);
perform pg_temp.assert(public.get_my_profile()->>'dominant_foot' is null,'pé é opcional');
perform pg_temp.expect_error('select public.update_my_profile(''Goleirão'',''canhoto'')','INVALID_DOMINANT_FOOT');
perform pg_temp.expect_error('select public.update_my_profile(''   '',''right'')','INVALID_NAME');
perform pg_temp.expect_error('update public.profiles set dominant_foot=''right''','permission denied');
perform pg_temp.assert((select player_name='Aposentado' from public.pelada_memberships where user_id=pg_temp.uid(2)),'Aposentado não muda');
perform pg_temp.as_user(2);
perform pg_temp.expect_error('select public.update_my_profile(''Voltei'',null)','ACCOUNT_DELETION_PENDING');
perform set_config('role','anon',true);
perform pg_temp.expect_error('select public.set_my_avatar(''x'')','permission denied');
execute 'reset role';
perform pg_temp.assert(not has_function_privilege('authenticated','public.avatar_paths_in_use(text[])','EXECUTE'),'lista de fotos em uso é só do servidor');

  raise exception 'PASS: 021_profile_photo_foot (rollback proposital - nada foi gravado)';
end
$test$;
