-- V8.1 ciclo de vida da temporada (migração 059). Cole no SQL Editor do Supabase DEV.
-- Termina SEMPRE com o erro proposital "PASS: 046_v81_season_lifecycle" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('30000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
declare v_pid uuid; v_tok text; v_m2 uuid; v_s uuid; v_ev int; v_before jsonb; v_j jsonb;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-l'||n||'@example.invalid','',now(),now(),now() from generate_series(1,4) n;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1); perform public.complete_onboarding('Admin',true,true);
perform pg_temp.as_user(2); perform public.complete_onboarding('Assis',true,true);
perform pg_temp.as_user(3); perform public.complete_onboarding('Joga',true,true);
perform pg_temp.as_user(4); perform public.complete_onboarding('Fora',true,true);
perform pg_temp.as_user(1);
v_pid := public.create_pelada('Pelada Ciclo','attacker');
v_tok := public.create_pelada_invite(v_pid);
perform pg_temp.as_user(2); v_m2 := public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(3); perform public.join_pelada(v_tok,'midfielder');
perform pg_temp.as_user(1); perform public.set_assistant(v_pid,v_m2,true);
execute 'reset role';
select id into v_s from public.seasons where pelada_id=v_pid;
perform pg_temp.assert((select lifecycle='normal' from public.seasons where id=v_s),'nasce normal');

-- ===== permissões e validações =====
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
perform pg_temp.expect_error(format($q$select public.cancel_season(%L,'motivo valido')$q$,v_s),'ADMIN_REQUIRED');
perform pg_temp.expect_error(format($q$select public.suspend_season(%L,'motivo valido')$q$,v_s),'ADMIN_REQUIRED');
perform pg_temp.as_user(3);
perform pg_temp.expect_error(format($q$select public.cancel_season(%L,'motivo valido')$q$,v_s),'ADMIN_REQUIRED');
perform pg_temp.as_user(4);
perform pg_temp.expect_error(format($q$select public.cancel_season(%L,'motivo valido')$q$,v_s),'SEASON_NOT_FOUND');
perform pg_temp.expect_error(format($q$select public.get_season_lifecycle(%L)$q$,v_s),'SEASON_NOT_FOUND');
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format($q$select public.cancel_season(%L,'  ')$q$,v_s),'REASON_REQUIRED');
perform pg_temp.expect_error(format($q$select public.suspend_season(%L,null)$q$,v_s),'REASON_REQUIRED');
perform pg_temp.expect_error(format($q$select public.reactivate_season(%L,'motivo valido')$q$,v_s),'INVALID_SEASON_STATE');
perform pg_temp.expect_error(format($q$select public.resume_season(%L,'motivo valido')$q$,v_s),'INVALID_SEASON_STATE');
perform pg_temp.expect_error(format($q$update public.seasons set lifecycle='cancelled' where id=%L$q$,v_s),'permission denied');
perform pg_temp.expect_error('select * from private.season_lifecycle_events','permission denied');

-- ===== 043: suspensão formal =====
perform public.suspend_season(v_s,'Reforma da quadra');
execute 'reset role';
perform pg_temp.assert((select lifecycle='suspended' from public.seasons where id=v_s),'suspensa');
perform pg_temp.assert((select (private.season_consolidation(v_s)->>'ready')::boolean=false),'suspensa nunca consolida');
update public.seasons set ends_on=private.pelada_today(pelada_id)-1 where id=v_s;
perform private.sync_season_status(v_pid);
perform pg_temp.assert((select status='active' and closed_at is null from public.seasons where id=v_s),'suspensa segue em disputa após o fim do calendário');
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform pg_temp.expect_error(format($q$select public.suspend_season(%L,'de novo aqui')$q$,v_s),'INVALID_SEASON_STATE');
perform public.resume_season(v_s,'Quadra liberada');
execute 'reset role';
perform pg_temp.assert((select lifecycle='normal' and status='closed' from public.seasons where id=v_s),'retomada volta a seguir o calendário');
perform pg_temp.assert((select (private.season_consolidation(v_s)->>'ready')::boolean=true),'normal e encerrada pode consolidar');

-- ===== 044: cancelamento preserva tudo =====
v_before := (select to_jsonb(s) - 'lifecycle' - 'updated_at' from public.seasons s where id=v_s);
perform set_config('role','authenticated',true); perform pg_temp.as_user(1);
perform public.cancel_season(v_s,'Pelada parou o ano todo');
perform pg_temp.expect_error(format($q$select public.cancel_season(%L,'cancelar de novo')$q$,v_s),'INVALID_SEASON_STATE');
execute 'reset role';
perform pg_temp.assert((select lifecycle='cancelled' from public.seasons where id=v_s),'cancelada');
perform pg_temp.assert((select (private.season_consolidation(v_s)->>'ready')::boolean=false),'cancelada não consolida (sem título sazonal)');
perform pg_temp.assert(v_before = (select to_jsonb(s) - 'lifecycle' - 'updated_at' from public.seasons s where id=v_s),'identidade e datas intactas');

-- ===== 045: reativação excepcional =====
perform set_config('role','authenticated',true); perform pg_temp.as_user(2);
perform pg_temp.expect_error(format($q$select public.reactivate_season(%L,'motivo valido')$q$,v_s),'ADMIN_REQUIRED');
perform pg_temp.as_user(1);
perform public.reactivate_season(v_s,'Erro do admin ao cancelar');
perform pg_temp.expect_error(format($q$select public.reactivate_season(%L,'reativar de novo')$q$,v_s),'INVALID_SEASON_STATE');
execute 'reset role';
perform pg_temp.assert((select lifecycle='normal' from public.seasons where id=v_s),'reativada com o mesmo id');
perform pg_temp.assert(v_before = (select to_jsonb(s) - 'lifecycle' - 'updated_at' from public.seasons s where id=v_s),'mesmos nome e datas');
perform pg_temp.assert((select count(*)=1 from public.seasons where pelada_id=v_pid),'nenhuma temporada duplicada');
perform pg_temp.assert((select count(*)=0 from public.awards where season_id=v_s),'nenhum prêmio concedido pela reativação');

-- ===== auditoria e linha do tempo =====
select count(*) into v_ev from private.season_lifecycle_events where season_id=v_s;
perform pg_temp.assert(v_ev=4,'4 eventos, achou '||v_ev);
perform pg_temp.assert((select array_agg(kind order by occurred_at, id)=array['suspension','resumption','cancellation','reactivation']
  from private.season_lifecycle_events where season_id=v_s),'ordem dos eventos');
perform pg_temp.assert((select count(*)=4 from private.audit_events where pelada_id=v_pid
  and event_type in ('season_suspension','season_resumption','season_cancellation','season_reactivation')),'4 auditorias');
perform pg_temp.expect_error($q$update private.season_lifecycle_events set reason='xxx'$q$,'SEASON_LIFECYCLE_EVENTS_IMMUTABLE');
perform pg_temp.expect_error($q$delete from private.season_lifecycle_events$q$,'SEASON_LIFECYCLE_EVENTS_IMMUTABLE');

perform set_config('role','authenticated',true);
perform pg_temp.as_user(1); v_j := public.get_season_lifecycle(v_s);
perform pg_temp.assert(v_j->>'lifecycle'='normal' and jsonb_array_length(v_j->'events')=4 and (v_j->'events'->0) ? 'reason','admin vê motivos');
perform pg_temp.assert(v_j->>'last_match_at' is null and v_j->>'days_since_last_match' is null,'sem partidas: informação nula');
perform pg_temp.as_user(3); v_j := public.get_season_lifecycle(v_s);
perform pg_temp.assert(jsonb_array_length(v_j->'events')=4 and not ((v_j->'events'->0) ? 'reason') and not ((v_j->'events'->0) ? 'actor_user_id'),'membro vê só tipo e data');

  raise exception 'PASS: 046_v81_season_lifecycle (rollback proposital - nada foi gravado)';
end
$test$;
