-- Correções P2 da V4.2 (migração 037): A06 histórico Premium no banco, A07 Card das temporadas seguintes,
-- A08 figurinha do Rei do Mês, A09 nome do onboarding, A12 início por pelada, A18 aceite versionado,
-- A20 retrospectiva agregada com empates, 8.3 Card corrigido após anulação.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 031_consistency_p2".
-- V7.7 (054): anulação com prévia (token) e id do pedido.
create function pg_temp.annul(p_match uuid, p_cat text, p_desc text) returns jsonb language sql as
 $$ select public.annul_match(p_match,p_cat,p_desc,true,public.preview_match_annulment(p_match)->>'preview_token',gen_random_uuid()) $$;
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('95000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
-- Partida finalizada sem votação (menos de 6 eleitores), na data pedida.
create function pg_temp.match(p_pelada uuid, p_at timestamptz, p_parts jsonb, p_events jsonb) returns uuid language plpgsql as
 $$ declare v uuid; begin
  perform pg_temp.as_user(1);
  v := public.create_match(p_pelada, p_at);
  perform public.save_match_sheet(v, p_parts, p_events);
  perform public.publish_match(v);
  return v;
 end $$;

do $test$
declare
 v_p uuid; v_q uuid; v_tok text; v_parts jsonb; v_y0 timestamptz := date_trunc('year', now());
 v_old uuid; v_prev uuid; v_cur uuid; v_xa uuid; v_xb uuid; v_ov_before numeric; v_ov_after numeric; v_n int;
 v_r jsonb; v_m2 uuid; v_m3 uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-p2-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,6) n;
perform set_config('role','authenticated',true);
for i in 1..5 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;

perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada Histórico','attacker');
v_tok := public.create_pelada_invite(v_p);
for i in 2..5 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok,'attacker'); end loop;
v_m2 := pg_temp.mem(v_p,2); v_m3 := pg_temp.mem(v_p,3);
v_parts := (select jsonb_agg(jsonb_build_object('membership_id',pg_temp.mem(v_p,i),'team',case when i<=2 then 'A' else 'B' end))
 from generate_series(1,4) i);

-- Três temporadas: retrasada, anterior e atual.
perform pg_temp.match(v_p, v_y0 - interval '2 years' + interval '3 months', v_parts,
 jsonb_build_array(jsonb_build_object('membership_id',v_m2,'type','goal','quantity',2)));
v_xa := pg_temp.match(v_p, v_y0 - interval '1 year' + interval '2 months', v_parts,
 jsonb_build_array(jsonb_build_object('membership_id',v_m2,'type','goal','quantity',4)));
v_xb := pg_temp.match(v_p, v_y0 - interval '1 year' + interval '3 months', v_parts, '[]');
perform pg_temp.match(v_p, now(), v_parts, '[]');
execute 'reset role';
select season_id into v_old from public.matches where pelada_id=v_p and played_at < v_y0 - interval '1 year';
select season_id into v_prev from public.matches where id=v_xa;
select id into v_cur from public.seasons where pelada_id=v_p and starts_on=v_y0::date;

-- ================= A06: temporada retrasada só com Premium =================
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform pg_temp.assert((select count(*) from public.player_cards where season_id=v_old)=0,'Card da retrasada bloqueado sem Premium');
perform pg_temp.assert((select count(*) from public.player_season_stats where season_id=v_old)=0,'estatística da retrasada bloqueada');
perform pg_temp.assert((select count(*) from public.player_cards where season_id=v_prev) > 0,'temporada anterior continua grátis');
perform pg_temp.assert((select count(*) from public.player_cards where season_id=v_cur) > 0,'temporada atual grátis');
perform pg_temp.assert((select count(*) from public.card_snapshots s join public.player_cards c on c.id=s.card_id
 where c.season_id=v_old)=0,'histórico do Card da retrasada bloqueado');
perform pg_temp.assert((select count(*) from public.get_readable_seasons(v_p))=2,'só 2 temporadas liberadas no grátis');
perform pg_temp.assert((select count(*) from public.matches where season_id=v_old)=1,'lista de partidas continua visível');
perform pg_temp.expect_error(format('select public.get_season_retrospective(%L)',v_old),'PREMIUM_REQUIRED');
execute 'reset role';
update private.app_config set value='true'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3);
perform pg_temp.assert((select count(*) from public.player_cards where season_id=v_old) > 0,'Premium libera a retrasada');
perform pg_temp.assert((select count(*) from public.get_readable_seasons(v_p))=3,'Premium: todas as temporadas');
perform pg_temp.as_user(6); -- não é membro
perform pg_temp.assert((select count(*) from public.player_cards where pelada_id=v_p)=0,'quem não é membro não lê nada');

-- ================= A07 + 8.3: anular partida da temporada anterior corrige o Card atual =================
execute 'reset role';
select overall into v_ov_before from public.player_cards where season_id=v_cur and membership_id=v_m2;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
perform pg_temp.annul(v_xa,'sheet_error','gols lançados na partida errada');
execute 'reset role';
set constraints all immediate; -- dispara agora os gatilhos que rodariam no commit
select overall into v_ov_after from public.player_cards where season_id=v_cur and membership_id=v_m2;
perform pg_temp.assert(v_ov_after < v_ov_before,'Card provisório da temporada atual recalculado com a base nova');
perform private.recompute_season_cards(v_cur, null);
perform pg_temp.assert((select overall from public.player_cards where season_id=v_cur and membership_id=v_m2)=v_ov_after,
 'resultado igual a um recálculo do zero');
perform pg_temp.assert(exists(select 1 from public.card_corrections k join public.player_cards c on c.id=k.card_id
 where c.membership_id=v_m2 and c.season_id=v_prev and k.annulled_match_id=v_xa
  and (k.snapshot_data->>'overall')::numeric=c.overall),'estado corrigido registrado (temporada da partida)');
perform pg_temp.assert(exists(select 1 from public.card_corrections k join public.player_cards c on c.id=k.card_id
 where c.membership_id=v_m2 and c.season_id=v_cur),'estado corrigido registrado (temporada seguinte)');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
v_r := public.get_player_evolution(v_m2, v_prev);
perform pg_temp.assert(jsonb_array_length(v_r->'corrections')=1
 and (v_r->'corrections'->0->>'overall')::numeric is not distinct from (v_r->'current'->>'overall')::numeric,
 'evolução mostra publicado, corrigido e atual coerentes');
perform pg_temp.assert(jsonb_array_length(v_r->'points')=1,'partida anulada fora da linha publicada');

-- ================= A08: Rei do Mês reconcilia a figurinha no mesmo instante =================
execute 'reset role';
insert into public.awards(pelada_id,season_id,membership_id,award_type,period_month)
values(v_p,v_prev,v_m3,'monthly_king',(v_y0 - interval '1 year' + interval '1 month')::date);
set constraints all immediate;
perform pg_temp.assert(exists(select 1 from public.player_sticker_unlocks u join public.sticker_definitions d
 on d.id=u.sticker_definition_id where u.membership_id=v_m3 and d.code='rei_do_mes_1' and u.status='active'),
 'figurinha Rei do Mês liberada sem esperar outra partida');
update public.awards set status='revoked', revoked_at=now() where membership_id=v_m3 and award_type='monthly_king';
set constraints all immediate;
perform pg_temp.assert(exists(select 1 from public.player_sticker_unlocks u join public.sticker_definitions d
 on d.id=u.sticker_definition_id where u.membership_id=v_m3 and d.code='rei_do_mes_1' and u.status='revoked'),
 'revogação do prêmio revoga a figurinha');

-- ================= A20: retrospectiva agregada com empates =================
update public.player_season_stats set goals=case membership_id when pg_temp.mem(v_p,1) then 3 when v_m2 then 3
 when v_m3 then 2 else 2 end where season_id=v_cur;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(2);
v_r := public.get_season_retrospective(v_cur, v_m2);
perform pg_temp.assert(jsonb_array_length(v_r->'scorers')=4,'4 artilheiros: 1, 1, 3, 3 (empatados no último lugar ficam)');
perform pg_temp.assert((select array_agg((x->>'rank')::int order by (x->>'rank')::int) from jsonb_array_elements(v_r->'scorers') x)
 = array[1,1,3,3],'posições de competição');
perform pg_temp.assert((v_r->>'matches')::int=1 and (v_r->'me'->>'goals')::int=3,'números da temporada e os meus');

-- ================= A09: nome do onboarding =================
perform pg_temp.as_user(4);
perform public.complete_onboarding('  ', true, true);
perform pg_temp.assert((select display_name='Jogador 4' from public.profiles where id=pg_temp.uid(4)),'campo vazio mantém o nome');
perform public.complete_onboarding('Quatro', true, true);
perform pg_temp.assert((select player_name='Quatro' from public.pelada_memberships where id=pg_temp.mem(v_p,4)),
 'apelido chega à pelada');

-- ================= A12: início por pelada, sem limite global =================
perform pg_temp.as_user(1);
v_q := public.create_pelada('Pelada Movimentada','attacker');
for i in 1..105 loop perform public.create_match(v_q, now() - (i||' minutes')::interval); end loop;
v_r := public.get_my_home();
perform pg_temp.assert((select (x->>'drafts')::int=105 from jsonb_array_elements(v_r->'peladas') x where x->>'id'=v_q::text),
 'todos os rascunhos contados');
perform pg_temp.assert((select x->'last' is not null and x->'last'<>'null'::jsonb from jsonb_array_elements(v_r->'peladas') x
 where x->>'id'=v_p::text),'a outra pelada continua com a última partida');
perform pg_temp.as_user(3);
perform pg_temp.assert((select (x->>'drafts')::int=0 from jsonb_array_elements(public.get_my_home()->'peladas') x
 where x->>'id'=v_p::text),'jogador não vê rascunhos');

-- ================= A18: aceite versionado =================
perform pg_temp.as_user(5);
perform pg_temp.assert(not (public.get_legal_status()->>'accepted')::boolean,'sem aceite registrado');
perform pg_temp.expect_error('select public.accept_legal_documents(''1.1'',''1.2'')','LEGAL_VERSION_OUTDATED');
perform public.accept_legal_documents('1.2','1.3'); -- V7.7 (057)
perform pg_temp.assert((public.get_legal_status()->>'accepted')::boolean,'aceite da versão vigente');
perform pg_temp.assert((select count(*)=2 from public.legal_acceptances where user_id=pg_temp.uid(5)),'documento + versão + momento');
execute 'reset role';
update private.app_config set value='{"terms":"1.3","privacy":"1.3"}'::jsonb where key='legal_versions';
perform set_config('role','authenticated',true);
perform pg_temp.assert(not (public.get_legal_status()->>'accepted')::boolean,'versão nova pede novo aceite');

raise exception 'PASS: 031_consistency_p2';
end $test$;
