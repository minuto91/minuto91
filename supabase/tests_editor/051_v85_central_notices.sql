-- V8.5 (migração 065): Próxima Rodada na Central e avisos direcionados.
-- Termina SEMPRE com o erro proposital "PASS: 051_v85_central_notices".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99853000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
create function pg_temp.as_user(n int) returns void language plpgsql as
 $$ begin perform set_config('request.jwt.claim.sub', pg_temp.uid(n)::text, true); end $$;
create function pg_temp.assert(p_ok boolean, p_msg text) returns void language plpgsql as
 $$ begin if not coalesce(p_ok,false) then raise exception 'FALHOU: %', p_msg; end if; end $$;
create function pg_temp.mem(p_pelada uuid, n int) returns uuid language sql as
 $$ select id from public.pelada_memberships where pelada_id=p_pelada and user_id=pg_temp.uid(n) $$;
create function pg_temp.notes(n int, t text) returns int language sql as
 $$ select count(*)::int from public.notification_events where user_id=pg_temp.uid(n) and event_type=t $$;

do $test$
declare v_p uuid; v_tok text; i int; r jsonb; v_prep uuid; v_ver int; v_comp uuid; v_mems uuid[]; v_m uuid; v_out uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v85c-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,7) n;
update private.app_config set value='true'::jsonb where key='premium_beta_open';
for i in 1..7 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||lpad(i::text,2,'0'),true,true); end loop;
perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada V85C','GOL');
v_tok := public.create_pelada_invite(v_p);
for i in 2..7 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok, (array['GOL','ZAG','ZAG','MEI','MEI','ATA'])[i-1]); end loop;
perform pg_temp.as_user(1);
v_mems := array(select pg_temp.mem(v_p,n) from generate_series(1,7) n);
r := public.open_draw_preparation(v_p, 'single', 1); v_prep := (r->>'id')::uuid; v_ver := (r->>'version')::int;
r := public.set_draw_members(v_prep, v_ver, v_mems[1:6]); v_ver := (r->>'version')::int;
r := public.generate_draw_preview(v_prep, v_ver, gen_random_uuid());
r := public.confirm_draw_preview((r->'preview'->>'id')::uuid, v_ver, null, null, gen_random_uuid());
v_comp := (r->'compositions'->0->>'id')::uuid;
perform pg_temp.assert(pg_temp.notes(2,'lineup_published')=1 and pg_temp.notes(7,'lineup_published')=0 and pg_temp.notes(1,'lineup_published')=0,
 'escalação: só quem está nela (e não quem confirmou)');

-- ajuste: só quem mudou de time
select pid into v_out from public.team_composition_members where composition_id=v_comp and version_to is null and membership_id=v_mems[3];
r := public.apply_composition_ops(v_comp, 1, jsonb_build_array(jsonb_build_object('op','transfer','pid',v_out)), gen_random_uuid());
perform pg_temp.assert(pg_temp.notes(3,'lineup_changed')=1 and pg_temp.notes(4,'lineup_changed')=0, 'aviso só para quem mudou');

-- Próxima Rodada
r := public.pre_register_matches(v_p, jsonb_build_array(jsonb_build_object('composition_id',v_comp,'round',1,'played_at',now()+interval '2 days')), false, false, gen_random_uuid());
v_m := (r->'items'->0->>'match_id')::uuid;
perform pg_temp.as_user(2);
r := public.get_player_central();
perform pg_temp.assert(r->'next_rounds'->0->>'match_id' = v_m::text and r->'next_rounds'->0->>'scheduled_at' is not null, 'Próxima Rodada com data');
perform pg_temp.as_user(7);
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements(public.get_player_central()->'next_rounds') x where x->>'match_id'=v_m::text),
 'fora da escalação prevista: não aparece');
perform pg_temp.as_user(1);
perform public.reschedule_match_v85(v_m, now()+interval '5 days', 'keep', gen_random_uuid());
perform pg_temp.assert(pg_temp.notes(2,'round_rescheduled')=1 and pg_temp.notes(7,'round_rescheduled')=0, 'remarcação: só prevista');
perform public.cancel_match(v_m, null);
perform pg_temp.assert(pg_temp.notes(2,'round_cancelled')=1, 'cancelamento avisado');
perform pg_temp.as_user(2);
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements(public.get_player_central()->'next_rounds') x where x->>'match_id'=v_m::text),
 'cancelada some da Próxima Rodada');

raise exception 'PASS: 051_v85_central_notices';
end $test$;
