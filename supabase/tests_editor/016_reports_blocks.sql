-- Denúncia e bloqueio (migração 023). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 016_reports_blocks" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('11000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
declare v_pid uuid; v_other uuid; v_tok text; v_m2 uuid; v_r1 uuid; v_r2 uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-rep'||n||'@example.invalid','',now(),now(),now() from generate_series(1,3) n;
perform set_config('role','authenticated',true);
for i in 1..3 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Denuncia','attacker');
v_tok := public.create_pelada_invite(v_pid);
perform pg_temp.as_user(2); v_m2 := public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(3); v_other := public.create_pelada('Pelada de Fora','attacker');

-- ===== Denúncia =====
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('select public.report_content(%L,%L,%L,%L)',v_pid,'member_name',v_m2,'feio'),'INVALID_REASON');
perform pg_temp.expect_error(format('select public.report_content(%L,%L,%L,%L)',v_pid,'pelada',v_other,'offensive'),'INVALID_REPORT_TARGET');
perform pg_temp.expect_error(format('select public.report_content(%L,%L,%L,%L)',v_other,'pelada',v_other,'offensive'),'PELADA_NOT_FOUND');
v_r1 := public.report_content(v_pid,'member_name',v_m2,'offensive','Apelido ofensivo');
perform pg_temp.assert(public.report_content(v_pid,'member_name',v_m2,'offensive')=v_r1,'denúncia repetida não duplica');
v_r2 := public.report_content(v_pid,'profile',pg_temp.uid(2),'inappropriate_image');
perform pg_temp.assert((select count(*)=2 from public.content_reports),'denunciante vê as próprias denúncias');
perform pg_temp.as_user(2);
perform pg_temp.assert((select count(*)=0 from public.content_reports),'denunciado não vê a denúncia');
perform pg_temp.expect_error(format('select public.resolve_content_report(%L,true)',v_r1),'permission denied');

-- ===== Suporte oculta o conteúdo =====
perform set_config('role','service_role',true);
perform public.resolve_content_report(v_r1,true);
perform public.resolve_content_report(v_r2,false);
execute 'reset role';
perform pg_temp.assert((select player_name='Jogador' from public.pelada_memberships where id=v_m2),'apelido substituído');
perform pg_temp.assert((select status='hidden' and resolved_at is not null from public.content_reports where id=v_r1),'denúncia resolvida');
perform pg_temp.assert((select status='dismissed' from public.content_reports where id=v_r2),'denúncia descartada');

-- ===== Bloqueio =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.assert((select count(*)=1 from public.profiles where id=pg_temp.uid(2)),'antes: vê o perfil');
perform pg_temp.expect_error(format('select public.block_user(%L)',pg_temp.uid(1)),'INVALID_USER');
perform public.block_user(pg_temp.uid(2));
perform public.block_user(pg_temp.uid(2)); -- repetido
perform pg_temp.assert((select count(*)=0 from public.profiles where id=pg_temp.uid(2)),'bloqueado some para quem bloqueou');
perform pg_temp.assert((select count(*)=1 from public.user_blocks),'lista de bloqueios');
perform pg_temp.as_user(2);
perform pg_temp.assert((select count(*)=1 from public.profiles where id=pg_temp.uid(1)),'quem bloqueou continua visível');
perform pg_temp.assert((select count(*)=0 from public.user_blocks),'bloqueado não vê quem o bloqueou');
perform pg_temp.as_user(1);
perform public.unblock_user(pg_temp.uid(2));
perform pg_temp.assert((select count(*)=1 from public.profiles where id=pg_temp.uid(2)),'desbloqueado volta a aparecer');

  raise exception 'PASS: 016_reports_blocks (rollback proposital - nada foi gravado)';
end
$test$;
