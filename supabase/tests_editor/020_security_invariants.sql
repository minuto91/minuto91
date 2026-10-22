-- Invariantes de segurança de TODO o banco (auditoria 21/10/2026). Cole no SQL Editor do Supabase DEV.
-- Pega tabela ou função nova que esqueceu RLS, revoke ou search_path. Não depende de dados.
-- Termina SEMPRE com o erro proposital "PASS: 020_security_invariants" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('c2700000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
declare v_bad text; v_n int;
begin
-- ===== Catálogo =====
select string_agg(c.relname, ', ') into v_bad from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind in ('r','p') and not c.relrowsecurity;
perform pg_temp.assert(v_bad is null, 'tabela pública sem RLS: '||coalesce(v_bad,''));

select string_agg(n.nspname||'.'||c.relname||'('||r.rolname||' '||p.priv||')', ', ') into v_bad
from pg_class c join pg_namespace n on n.oid=c.relnamespace
cross join (values ('anon'),('authenticated')) r(rolname)
cross join (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE')) p(priv)
where n.nspname in ('public','private') and c.relkind in ('r','p','v','m')
 and has_table_privilege(r.rolname, c.oid, p.priv)
 and not (r.rolname='authenticated' and n.nspname='public' and p.priv='SELECT');
perform pg_temp.assert(v_bad is null, 'escrita direta (ou leitura anon/private) liberada: '||coalesce(v_bad,''));

-- Única exceção de escrita direta: nome e foto no próprio perfil (002).
select string_agg(a.attname, ', ') into v_bad from pg_attribute a
where a.attrelid='public.profiles'::regclass and a.attnum>0 and not a.attisdropped
 and has_column_privilege('authenticated', 'public.profiles', a.attname, 'UPDATE')
 and a.attname not in ('display_name','avatar_path');
perform pg_temp.assert(v_bad is null, 'coluna de profiles editável pelo cliente: '||coalesce(v_bad,''));
select string_agg(c.relname||'.'||a.attname, ', ') into v_bad
from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid
where n.nspname='public' and c.relkind='r' and c.relname<>'profiles' and a.attnum>0 and not a.attisdropped
 and (has_column_privilege('authenticated', c.oid, a.attnum, 'UPDATE')
  or has_column_privilege('authenticated', c.oid, a.attnum, 'INSERT'));
perform pg_temp.assert(v_bad is null, 'coluna editável pelo cliente: '||coalesce(v_bad,''));

-- Funções: anon não executa nada nosso (nem entra no schema private); definer sempre com search_path fixo.
perform pg_temp.assert(not has_schema_privilege('anon','private','USAGE'), 'anon entra no schema private');
select string_agg(p.oid::regprocedure::text, ', ') into v_bad
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
 and not exists(select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')
 and has_function_privilege('anon', p.oid, 'EXECUTE');
perform pg_temp.assert(v_bad is null, 'função executável por anon: '||coalesce(v_bad,''));
select string_agg(p.oid::regprocedure::text, ', ') into v_bad
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname in ('public','private') and p.prosecdef
 and not exists(select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')
 and not exists(select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%');
perform pg_temp.assert(v_bad is null, 'security definer sem search_path: '||coalesce(v_bad,''));
select string_agg(f, ', ') into v_bad from unnest(array[
 'public.apply_subscription_event(jsonb)','public.claim_notifications(integer)',
 'public.resolve_content_report(uuid,boolean)']) f
where has_function_privilege('authenticated', f::regprocedure, 'EXECUTE');
perform pg_temp.assert(v_bad is null, 'função de serviço liberada ao app: '||coalesce(v_bad,''));

-- ===== Comportamento: um usuário não mexe no perfil de outro =====
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-si'||n||'@example.invalid','',now(),now(),now() from generate_series(1,2) n;
perform set_config('role','authenticated',true);
for i in 1..2 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
update public.profiles set display_name='Invasor' where id=pg_temp.uid(2);
get diagnostics v_n = row_count;
perform pg_temp.assert(v_n=0, 'não altera perfil de outro');
perform pg_temp.assert((select count(*)=0 from public.profiles where id=pg_temp.uid(2)), 'não vê perfil de quem não divide pelada');
perform pg_temp.expect_error(format('update public.profiles set adult_declared_at=null where id=%L',pg_temp.uid(1)),'permission denied');
perform pg_temp.expect_error('insert into public.peladas(name) values(''Pirata'')','permission denied');
perform pg_temp.expect_error('delete from public.pelada_memberships','permission denied');
perform pg_temp.expect_error('select * from private.app_config','permission denied');
perform set_config('role','anon',true);
perform pg_temp.expect_error('select * from public.peladas','permission denied');
execute 'reset role';

  raise exception 'PASS: 020_security_invariants (rollback proposital - nada foi gravado)';
end
$test$;
