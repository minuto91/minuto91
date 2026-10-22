-- V4.3 (migrações 041 e 042): dez posições oficiais com transição das posições antigas, e formações 4-3-3 / 4-4-2.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 034_v43_positions_formations".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('98000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.memrow(p_pelada uuid, n int) returns public.pelada_memberships language sql as
 $$ select * from public.pelada_memberships where pelada_id=p_pelada and user_id=pg_temp.uid(n) $$;
-- Slots de uma formação na ordem dada dos jogadores.
create function pg_temp.slots(p_members uuid[], p_formation text) returns jsonb language sql as
 $$ select jsonb_agg(jsonb_build_object('membership_id', p_members[i], 'slot', (case p_formation when '4-3-3' then array['GOL','LE','ZAG1','ZAG2','LD','MEI1','VOL','MEI2','PE','CA','PD']
      else array['GOL','LE','ZAG1','ZAG2','LD','MEI1','VOL1','VOL2','MEI2','CA','ATA'] end)[i]))
    from generate_subscripts(p_members, 1) i $$;
create function pg_temp.team(p_lineup jsonb, p_team text) returns uuid[] language sql as
 $$ select array_agg((x->>'membership_id')::uuid order by x->>'membership_id') from jsonb_array_elements(p_lineup->'players') x
    where x->>'team'=p_team $$;

do $test$
declare
 v_p uuid; v_tok text; v_codes text[] := array['GOL','ZAG','LD','LE','VOL','MEI','CA','PD','PE','ATA']; v_m public.pelada_memberships;
 v_a uuid[]; v_b uuid[]; v_l jsonb; v_l2 jsonb; v_d jsonb; v_x uuid; v_s uuid; v_r jsonb; v_g uuid; v_ov numeric; v_n int;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-pf'||n||'@example.invalid','',now(),now(),now() from generate_series(1,40) n;
perform set_config('role','authenticated',true);
for i in 1..40 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||lpad(i::text,2,'0'),true,true); end loop;

-- ===================== Dez posições no cadastro =====================
perform pg_temp.as_user(1);
v_p := public.create_pelada('Pelada Posições','GOL');
v_tok := public.create_pelada_invite(v_p);
-- 2..11: uma de cada posição (o 2 entra como GOL, 3 ZAG, ... 11 ATA).
for i in 2..11 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok, v_codes[i-1]); end loop;
for i in 2..11 loop
 v_m := pg_temp.memrow(v_p, i);
 perform pg_temp.assert(v_m.position_code = v_codes[i-1] and v_m.preferred_position = private.position_sector(v_codes[i-1]),
  'cadastro '||v_codes[i-1]||' guarda a posição e o setor');
end loop;
perform pg_temp.assert((pg_temp.memrow(v_p,1)).position_code='GOL','criador GOL');
perform pg_temp.expect_error(format('select public.join_pelada(%L,%L)',v_tok,'LAT'),'INVALID_POSITION');

-- ===================== Posições antigas (versões anteriores do app) =====================
-- 12 Goleiro -> GOL automático; 13 Defensor, 14 Meio-campista, 15 Atacante ficam pendentes (nada é inventado).
perform pg_temp.as_user(12); perform public.join_pelada(v_tok,'goalkeeper');
perform pg_temp.as_user(13); perform public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(14); perform public.join_pelada(v_tok,'midfielder');
perform pg_temp.as_user(15); perform public.join_pelada(v_tok,'attacker');
perform pg_temp.assert((pg_temp.memrow(v_p,12)).position_code='GOL','Goleiro antigo vira GOL');
perform pg_temp.assert((pg_temp.memrow(v_p,13)).position_code is null and (pg_temp.memrow(v_p,13)).preferred_position='defender',
 'Defensor não vira ZAG sozinho');
perform pg_temp.assert((pg_temp.memrow(v_p,14)).position_code is null and (pg_temp.memrow(v_p,15)).position_code is null,'Meia e Atacante pendentes');
perform pg_temp.as_user(13);
v_r := public.get_position_migration_status(v_p);
perform pg_temp.assert((v_r->>'mine_needs_update')::boolean and (v_r->>'legacy_members')::int=3,'aviso discreto: 3 a atualizar');
-- Simulação da migração 041 sobre dados antigos: um registro antigo sem código.
execute 'reset role';
update public.pelada_memberships set position_code=null where id=pg_temp.mem(v_p,12);
perform pg_temp.assert((pg_temp.memrow(v_p,12)).position_code='GOL','goleiro sempre GOL (não fica pendente)');
-- Invariante: nenhum código fora do setor (o gatilho corrige escrita direta incoerente).
update public.pelada_memberships set position_code='ZAG' where id=pg_temp.mem(v_p,15);
perform pg_temp.assert((pg_temp.memrow(v_p,15)).position_code is null,'ZAG num Atacante é recusado (vira pendente)');
perform pg_temp.assert(not exists(select 1 from public.pelada_memberships where position_code is not null
 and private.position_sector(position_code) <> preferred_position),'nenhum código incoerente no banco');
perform set_config('role','authenticated',true);

-- Atualização para cada uma das posições do setor (o próprio jogador), com auditoria de/para.
perform pg_temp.as_user(13);
foreach v_tok in array array['ZAG','LD','LE'] loop perform public.set_my_position(v_p, v_tok);
 perform pg_temp.assert((pg_temp.memrow(v_p,13)).position_code=v_tok,'Defensor -> '||v_tok); end loop;
perform pg_temp.as_user(14);
foreach v_tok in array array['VOL','MEI'] loop perform public.set_my_position(v_p, v_tok);
 perform pg_temp.assert((pg_temp.memrow(v_p,14)).position_code=v_tok,'Meio-campista -> '||v_tok); end loop;
perform pg_temp.as_user(15);
foreach v_tok in array array['CA','PD','PE','ATA'] loop perform public.set_my_position(v_p, v_tok);
 perform pg_temp.assert((pg_temp.memrow(v_p,15)).position_code=v_tok,'Atacante -> '||v_tok); end loop;
perform pg_temp.expect_error(format('select public.set_my_position(%L,%L)',v_p,'LAT'),'INVALID_POSITION');
execute 'reset role';
perform pg_temp.assert(exists(select 1 from private.audit_events where event_type='position_changed' and subject_membership_id=pg_temp.mem(v_p,13)
 and metadata->>'from_position_code' is null and metadata->>'position_code'='ZAG' and metadata->>'from_position'='defender'),
 'auditoria: de Defensor para ZAG');
perform pg_temp.assert((select count(*) from private.audit_events where event_type='position_changed' and subject_membership_id=pg_temp.mem(v_p,15))=4,
 'cada mudança registrada');
perform set_config('role','authenticated',true);
-- Ninguém muda a posição de outro jogador (permissão inalterada).
perform pg_temp.as_user(1);
perform pg_temp.expect_error(format('update public.pelada_memberships set position_code=%L where id=%L','ZAG',pg_temp.mem(v_p,15)),'permission denied');
perform pg_temp.as_user(13);
v_r := public.get_position_migration_status(v_p);
perform pg_temp.assert(not (v_r->>'mine_needs_update')::boolean and (v_r->>'legacy_members')::int=0,'nenhum pendente');
v_r := public.get_player_profile(pg_temp.uid(13));
perform pg_temp.assert(v_r->'peladas'->0->>'position'='LE','perfil mostra a sigla');
-- Volta a ser legado só se escolher outro setor por uma versão antiga do app.
perform public.set_my_position(v_p,'midfielder');
perform pg_temp.assert((pg_temp.memrow(v_p,13)).position_code is null and (pg_temp.memrow(v_p,13)).preferred_position='midfielder','setor antigo sem sigla');
perform public.set_my_position(v_p,'LE');

-- ===================== Card, Duelo e súmula =====================
execute 'reset role';
select id into v_s from public.seasons where pelada_id=v_p order by starts_on desc limit 1;
insert into public.player_cards(pelada_id,season_id,membership_id,position,finishing,assisting,attendance,winning,peer_rating,overall,tier,is_provisional,matches_played,formula_version)
select v_p, v_s, m.id, m.preferred_position, 50,50,50,50,50, 61.5, 'prata', false, 6, 1
from public.pelada_memberships m where m.pelada_id=v_p and m.status='active';
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_r := public.get_player_duel(v_s, pg_temp.mem(v_p,3), pg_temp.mem(v_p,13));
perform pg_temp.assert(v_r->'a'->>'position'='ZAG' and v_r->'b'->>'position'='LE','Duelo com as siglas (posições diferentes comparáveis)');
-- Mudança de posição não altera overall nem atributos do Card.
perform pg_temp.as_user(3); perform public.set_my_position(v_p,'LD');
execute 'reset role';
perform pg_temp.assert((select overall=61.5 and position='defender' and finishing=50 from public.player_cards where membership_id=pg_temp.mem(v_p,3) and season_id=v_s),
 'Card inalterado (fórmulas por setor)');
perform set_config('role','authenticated',true);
-- Card de um setor antigo (jogador mudou de setor): o Duelo mostra a posição do Card.
perform pg_temp.as_user(4); perform public.set_my_position(v_p,'VOL'); -- era LD (defesa); Card é de defesa
perform pg_temp.as_user(1);
v_r := public.get_player_duel(v_s, pg_temp.mem(v_p,4), pg_temp.mem(v_p,3));
perform pg_temp.assert(v_r->'a'->>'position'='defender' and v_r->'b'->>'position'='LD','Card de outro setor mostra o setor do Card');

-- Súmula: guarda a sigla do momento; mudar depois não altera o histórico.
perform pg_temp.as_user(1);
v_x := public.create_match(v_p, now() - interval '1 hour', 'Azul', 'Dourado');
v_g := public.create_guest(v_p, 'Convidado Lateral', true);
perform public.save_match_sheet(v_x, jsonb_build_array(
 jsonb_build_object('membership_id',pg_temp.mem(v_p,3),'team','A'), jsonb_build_object('membership_id',pg_temp.mem(v_p,1),'team','A'),
 jsonb_build_object('guest_id',v_g,'team','B','position','LE'), jsonb_build_object('membership_id',pg_temp.mem(v_p,2),'team','B')), '[]');
execute 'reset role';
perform pg_temp.assert((select position_code='LD' and primary_position='defender' from public.match_participants where match_id=v_x and membership_id=pg_temp.mem(v_p,3)),
 'súmula guarda LD (e o setor para as fórmulas)');
perform pg_temp.assert((select position_code='LE' and primary_position='defender' from public.match_participants where match_id=v_x and guest_id=v_g),
 'convidado com sigla');
perform set_config('role','authenticated',true);
perform pg_temp.as_user(3); perform public.set_my_position(v_p,'ZAG');
execute 'reset role';
perform pg_temp.assert((select position_code='LD' from public.match_participants where match_id=v_x and membership_id=pg_temp.mem(v_p,3)),
 'histórico da partida preservado');
update public.matches set status='finalized', finalized_at=now() where id=v_x;
-- Partida antiga (antes da V4.3): participante sem sigla mostra o setor.
update public.match_participants set position_code=null where match_id=v_x and membership_id=pg_temp.mem(v_p,2);
perform set_config('role','authenticated',true);
perform pg_temp.as_user(1);
v_r := public.get_match_lineup(v_x);
perform pg_temp.assert((select x->>'position' from jsonb_array_elements(v_r->'players') x where x->>'membership_id'=pg_temp.mem(v_p,3)::text)='LD'
 and (select x->>'position' from jsonb_array_elements(v_r->'players') x where x->>'membership_id'=pg_temp.mem(v_p,2)::text)='goalkeeper',
 'escalação pós-jogo: sigla registrada ou setor das partidas antigas');
perform pg_temp.assert(v_r->>'team_a_formation' is null,'partida antiga sem formação inventada');

-- ===================== Sorteio com as dez posições e grupos legados =====================
-- 16..31: mais jogadores para ter repetição por posição; 30 e 31 legados.
perform pg_temp.as_user(1); v_tok := public.create_pelada_invite(v_p);
for i in 16..31 loop perform pg_temp.as_user(i);
 perform public.join_pelada(v_tok, case when i=30 then 'defender' when i=31 then 'defender' else v_codes[2 + (i % 9)] end); end loop;
perform pg_temp.as_user(1);
v_a := (select array_agg(id) from public.pelada_memberships where pelada_id=v_p and status='active');
v_d := public.create_team_draw(v_p, v_a, 'single', 1);
perform pg_temp.assert(not exists(select 1 from jsonb_array_elements(v_d->'rounds'->0->'by_position') x where abs((x->>'a')::int-(x->>'b')::int)>1),
 'cada uma das posições com diferença <= 1');
perform pg_temp.assert(exists(select 1 from jsonb_array_elements(v_d->'rounds'->0->'by_position') x where x->>'position'='defender' and (x->>'a')::int=1 and (x->>'b')::int=1),
 'legados formam grupo próprio (2 Defensores 1 x 1)');
perform pg_temp.assert((v_d->'warnings') ? 'LEGACY_POSITIONS','aviso: atualizar posições melhora o sorteio');
perform pg_temp.assert((select count(*) from jsonb_array_elements(v_d->'rounds'->0->'by_position') x where x->>'position' = any(v_codes)) >= 9,
 'posições específicas separadas');

-- ===================== Formações 4-3-3 e 4-4-2 =====================
-- 22 jogadores ativos: 11 x 11.
v_a := (select array_agg(id order by id) from (select id from public.pelada_memberships where pelada_id=v_p and status='active' order by id limit 11) q);
v_b := (select array_agg(id order by id) from (select id from public.pelada_memberships where pelada_id=v_p and status='active' order by id offset 11 limit 11) q);
perform pg_temp.assert(cardinality(v_a)=11 and cardinality(v_b)=11,'11 x 11 disponíveis');
-- 1) e 4) Time A em 4-3-3 e B em 4-4-2 (formações diferentes), com jogadores fora da posição sugerida (permitido).
v_l := public.save_lineup(v_p, null, 'Final', v_a, v_b, 'Azul', 'Dourado', '4-3-3', '4-4-2',
 pg_temp.slots(v_a,'4-3-3') || pg_temp.slots(v_b,'4-4-2'));
perform pg_temp.assert(v_l->>'team_a_formation'='4-3-3' and v_l->>'team_b_formation'='4-4-2' and (v_l->>'version')::int=1,'formações por time');
perform pg_temp.assert((select count(*) from jsonb_array_elements(v_l->'players') x where x->>'slot' is not null)=22,'22 posições visuais');
perform pg_temp.assert((select bool_and(x->>'position_at_creation' is not null) from jsonb_array_elements(v_l->'players') x),'posição cadastral guardada');
-- 11) salva e reabre igual.
v_l2 := (select x from jsonb_array_elements(public.get_lineups(v_p)) x where x->>'id'=v_l->>'id');
perform pg_temp.assert(v_l2->'players'=v_l->'players' and v_l2->>'team_b_formation'='4-4-2','reaberta igual');
-- 2) e 3) 10 x 12 com formação: recusado; sem formação: lista por setor.
perform pg_temp.expect_error(format('select public.save_lineup(%L,null,%L,%L,%L,null,null,%L,null,%L)',v_p,'x',v_a[1:10],v_a[11:11]||v_b,'4-3-3',
 pg_temp.slots(v_a[1:10],'4-3-3')),'LINEUP_FORMATION_SIZE');
perform pg_temp.expect_error(format('select public.save_lineup(%L,null,%L,%L,%L,null,null,null,%L,%L)',v_p,'x',v_a[1:10],v_a[11:11]||v_b,'4-4-2',
 pg_temp.slots(v_a[11:11]||v_b[1:10],'4-4-2')),'LINEUP_FORMATION_SIZE');
v_l2 := public.save_lineup(v_p, null, 'Dez x doze', v_a[1:10], v_a[11:11]||v_b);
perform pg_temp.assert(v_l2->>'team_a_formation' is null and jsonb_array_length(v_l2->'players')=22,'sem formação para 10 x 12');
-- Slots inválidos.
perform pg_temp.expect_error(format('select public.save_lineup(%L,null,%L,%L,%L,null,null,%L,null,%L)',v_p,'x',v_a,v_b,'4-3-3',
 pg_temp.slots(v_a[1:10],'4-3-3')),'LINEUP_SLOTS_INVALID'); -- faltou um
perform pg_temp.expect_error(format('select public.save_lineup(%L,null,%L,%L,%L,null,null,%L,null,%L)',v_p,'x',v_a,v_b,'4-3-3',
 pg_temp.slots(v_a,'4-4-2')),'LINEUP_SLOTS_INVALID'); -- slots de outra formação
perform pg_temp.expect_error(format('select public.save_lineup(%L,null,%L,%L,%L,null,null,%L,null,%L)',v_p,'x',v_a,v_b,'4-3-3',
 pg_temp.slots(v_b,'4-3-3')),'LINEUP_SLOTS_INVALID'); -- jogadores do outro time
perform pg_temp.expect_error(format('select public.save_lineup(%L,null,%L,%L,%L,null,null,%L,null,%L)',v_p,'x',v_a,v_b,'3-5-2',
 pg_temp.slots(v_a,'4-3-3')),'LINEUP_FORMATION_INVALID');
-- 6) troca de dois jogadores de lugar e 7) mudança de formação, com controle de versão.
v_l2 := public.set_lineup_formation((v_l->>'id')::uuid, '4-3-3', '4-4-2',
 pg_temp.slots(array[v_a[2],v_a[1]] || v_a[3:11],'4-3-3') || pg_temp.slots(v_b,'4-4-2'), 1);
perform pg_temp.assert((v_l2->>'version')::int=2 and (select x->>'slot' from jsonb_array_elements(v_l2->'players') x where x->>'membership_id'=v_a[1]::text)='LE',
 'troca salva (versão 2)');
perform pg_temp.expect_error(format('select public.set_lineup_formation(%L,%L,%L,%L,1)',v_l->>'id','4-4-2','4-4-2',
 pg_temp.slots(v_a,'4-4-2') || pg_temp.slots(v_b,'4-4-2')),'LINEUP_VERSION_CONFLICT');
v_l2 := public.set_lineup_formation((v_l->>'id')::uuid, '4-4-2', null, pg_temp.slots(v_a,'4-4-2'), 2);
perform pg_temp.assert(v_l2->>'team_a_formation'='4-4-2' and v_l2->>'team_b_formation' is null
 and (select count(*) from jsonb_array_elements(v_l2->'players') x where x->>'slot' is not null)=11,'mudou formação; B voltou à lista');
perform pg_temp.assert(pg_temp.team(v_l2,'A')=pg_temp.team(v_l,'A'),'formação não muda os times');
-- 5) jogador sem posição específica cabe em qualquer espaço.
v_g := pg_temp.mem(v_p,30); -- Defensor ainda sem sigla
v_l2 := public.save_lineup(v_p, null, 'Legado', array(select id from public.pelada_memberships where pelada_id=v_p and status='active' and id<>v_g order by id limit 10) || v_g,
 array(select id from public.pelada_memberships where pelada_id=v_p and status='active' and id<>v_g order by id offset 10 limit 11), null, null, '4-3-3', null,
 pg_temp.slots(array(select id from public.pelada_memberships where pelada_id=v_p and status='active' and id<>v_g order by id limit 10) || v_g, '4-3-3'));
perform pg_temp.assert((select x->>'slot'='PD' and x->>'position'='defender' from jsonb_array_elements(v_l2->'players') x where x->>'membership_id'=v_g::text),
 'jogador sem posição específica ocupa um espaço (PD), cadastro intacto');
perform pg_temp.assert((pg_temp.memrow(v_p,30)).position_code is null,'formação não altera o cadastro');
-- 9) escalação gerada por sorteio: formação só define o lugar, nunca o time.
v_d := public.create_team_draw(v_p, v_a || v_b, 'single', 1);
v_d := public.confirm_team_draw((v_d->>'id')::uuid);
v_l := (select x from jsonb_array_elements(public.get_lineups(v_p)) x where x->>'draw_id'=v_d->>'id');
v_l2 := public.set_lineup_formation((v_l->>'id')::uuid, '4-3-3', '4-4-2',
 pg_temp.slots(pg_temp.team(v_l,'A'),'4-3-3') || pg_temp.slots(pg_temp.team(v_l,'B'),'4-4-2'), null);
perform pg_temp.assert(pg_temp.team(v_l2,'A')=pg_temp.team(v_l,'A') and pg_temp.team(v_l2,'B')=pg_temp.team(v_l,'B'),
 'sorteio preservado ao aplicar a formação');
perform pg_temp.expect_error(format('select public.save_lineup(%L,%L,%L,%L,%L)',v_p,v_l->>'id','x',pg_temp.team(v_l,'B'),pg_temp.team(v_l,'A')),'LINEUP_INVALID');
-- 14) sem permissão.
perform pg_temp.as_user(5);
perform pg_temp.expect_error(format('select public.set_lineup_formation(%L,%L,null,%L)',v_l->>'id','4-3-3',pg_temp.slots(pg_temp.team(v_l,'A'),'4-3-3')),'STAFF_REQUIRED');
perform pg_temp.as_user(39);
perform pg_temp.expect_error(format('select public.set_lineup_formation(%L,%L,null,%L)',v_l->>'id','4-3-3',pg_temp.slots(pg_temp.team(v_l,'A'),'4-3-3')),'STAFF_REQUIRED');
perform pg_temp.expect_error('select * from public.match_formations','permission denied');
-- 13) uso na súmula: formações vão junto; a escalação pós-jogo mostra enquanto a súmula corresponde.
perform pg_temp.as_user(1);
v_x := public.use_lineup_in_match((v_l->>'id')::uuid, now() - interval '2 hours');
execute 'reset role';
perform pg_temp.assert((select count(*) from public.match_formations where match_id=v_x)=2
 and (select count(*) from public.match_formation_slots where match_id=v_x)=22,'formações registradas na partida');
update public.matches set status='finalized', finalized_at=now() where id=v_x;
perform set_config('role','authenticated',true);
perform pg_temp.as_user(5); -- jogador comum, pós-jogo é grátis para todos da pelada
v_r := public.get_match_lineup(v_x);
perform pg_temp.assert(v_r->>'team_a_formation'='4-3-3' and v_r->>'team_b_formation'='4-4-2'
 and (select count(*) from jsonb_array_elements(v_r->'players') x where x->>'slot' is not null)=22,'pós-jogo com as formações');
-- Súmula corrigida (um jogador a menos no B): B volta para a lista, A segue.
execute 'reset role';
delete from public.match_participants where match_id=v_x and membership_id=(pg_temp.team(v_l,'B'))[1];
perform set_config('role','authenticated',true);
v_r := public.get_match_lineup(v_x);
perform pg_temp.assert(v_r->>'team_a_formation'='4-3-3' and v_r->>'team_b_formation' is null,'formação só quando ainda corresponde');
-- 10) jogador removido da pelada: escalação com formação bloqueada até revisão/edição.
perform pg_temp.as_user(1);
v_l := public.save_lineup(v_p, null, 'Com saída', v_a, v_b, null, null, '4-3-3', '4-3-3', pg_temp.slots(v_a,'4-3-3') || pg_temp.slots(v_b,'4-3-3'));
execute 'reset role';
update public.pelada_memberships set status='left' where id=v_a[5]; -- alguém que está no time A
perform set_config('role','authenticated',true);
perform pg_temp.expect_error(format('select public.use_lineup_in_match(%L)',v_l->>'id'),'DRAW_STALE');
-- Premium expirado: sem escalação antecipada/formação; a pós-jogo continua grátis.
execute 'reset role';
update private.app_config set value='false'::jsonb where key='premium_beta_open';
perform set_config('role','authenticated',true);
perform pg_temp.expect_error(format('select public.set_lineup_formation(%L,null,null,null)',v_l->>'id'),'PREMIUM_REQUIRED');
perform pg_temp.assert(public.get_match_lineup(v_x) ? 'players','pós-jogo no Básico');

raise exception 'PASS: 034_v43_positions_formations';
end $test$;
