-- Prévia do convite (migração 034) e as regras de entrada que continuam na join_pelada (004).
-- Cole no SQL Editor do Supabase DEV (ou rode no banco local: supabase/local_db).
-- Termina SEMPRE com o erro proposital "PASS: 028_invite_preview" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('c2880000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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

do $test$
declare v_a uuid; v_b uuid; v_tok text; v_tok_b text; v_old text; p jsonb; v_m1 uuid; v_m2 uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-iv'||n||'@example.invalid','',now(),now(),now() from generate_series(1,4) n;
perform set_config('role','authenticated',true);
for i in 1..4 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada Convite','attacker'); v_tok := public.create_pelada_invite(v_a);
perform pg_temp.as_user(4); v_b := public.create_pelada('Outra Pelada','attacker'); v_tok_b := public.create_pelada_invite(v_b, 1, 1);

-- ===== Prévia: só o nome; nada de membros, escudo ou números =====
perform pg_temp.as_user(2);
p := public.get_invite_preview(v_tok);
perform pg_temp.assert((p->>'valid')::boolean and p->>'pelada_name'='Pelada Convite' and not (p->>'already_member')::boolean
 and p->'pelada_id'='null'::jsonb, 'convite válido mostra só o nome');
-- V4.4 (045): + o que acontece ao entrar (pode entrar, precisa escolher posição, situação anterior DA PRÓPRIA PESSOA) e o prazo.
perform pg_temp.assert((select array_agg(k order by k) from jsonb_object_keys(p) k)=array['already_member','can_join','expires_at','membership_status','needs_position','pelada_id','pelada_name','valid'],
 'nenhum outro dado');
perform pg_temp.assert(not (public.get_invite_preview(repeat('a',64))->>'valid')::boolean, 'token inexistente');
perform pg_temp.assert(not (public.get_invite_preview('nao-e-token')->>'valid')::boolean, 'formato inválido');
perform pg_temp.assert(not (public.get_invite_preview(null)->>'valid')::boolean, 'nulo');
-- A prévia não consome uso nem cria associação.
perform pg_temp.assert(not exists(select 1 from public.pelada_memberships where user_id=pg_temp.uid(2)), 'prévia não associa');

-- ===== Entrar; depois a prévia reconhece o membro e devolve a pelada =====
v_m1 := public.join_pelada(v_tok,'defender');
p := public.get_invite_preview(v_tok);
perform pg_temp.assert((p->>'already_member')::boolean and (p->>'pelada_id')::uuid=v_a, 'membro: abre a pelada');
-- Duplicidade: entrar de novo devolve a mesma associação, sem gastar outro registro.
v_m2 := public.join_pelada(v_tok,'defender');
perform pg_temp.assert(v_m1=v_m2 and (select count(*) from public.pelada_memberships where user_id=pg_temp.uid(2) and pelada_id=v_a)=1,
 'sem associação duplicada');

-- ===== Limite de uso, revogação e expiração =====
perform pg_temp.as_user(3);
perform public.join_pelada(v_tok_b,'defender'); -- usa o único uso
perform pg_temp.as_user(2);
perform pg_temp.assert(not (public.get_invite_preview(v_tok_b)->>'valid')::boolean, 'esgotado');
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)', v_tok_b, 'attacker'), 'INVALID_OR_EXPIRED_INVITE');
perform pg_temp.as_user(1);
v_old := v_tok;
perform public.revoke_pelada_invites(v_a);
perform pg_temp.as_user(3);
perform pg_temp.assert(not (public.get_invite_preview(v_old)->>'valid')::boolean, 'revogado');
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)', v_old, 'attacker'), 'INVALID_OR_EXPIRED_INVITE');
perform pg_temp.as_user(1);
v_tok := public.create_pelada_invite(v_a);
execute 'reset role';
update private.pelada_invites set expires_at=now()-interval '1 minute' where pelada_id=v_a and revoked_at is null;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform pg_temp.assert(not (public.get_invite_preview(v_tok)->>'valid')::boolean, 'expirado');

-- ===== Só o admin cria e revoga convites =====
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format('select public.create_pelada_invite(%L)', v_a), 'ADMIN_REQUIRED');
perform pg_temp.expect_error(format('select public.revoke_pelada_invites(%L)', v_a), 'ADMIN_REQUIRED');

-- ===== Sem login e permissões =====
perform set_config('request.jwt.claim.sub','',true);
perform pg_temp.expect_error(format('select public.get_invite_preview(%L)', v_tok), 'AUTH_REQUIRED');
execute 'reset role';
perform pg_temp.assert(not has_function_privilege('anon','public.get_invite_preview(text)','execute'), 'anon sem acesso');
perform pg_temp.assert(has_function_privilege('authenticated','public.get_invite_preview(text)','execute'), 'authenticated com acesso');

raise exception 'PASS: 028_invite_preview (rollback proposital - nada foi gravado)';
end
$test$;
