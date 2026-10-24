-- V6.1: isolamento por pelada das leituras diretas que a Central faz (sem RPC), com casos positivos e negativos.
--  Membro lê partida, súmula, sessão de votação e histórico de OVR da própria pelada; quem é só de outra pelada
--  não lê nada disso (nem o OVR via get_player_rating); quem saiu da pelada perde o acesso; colunas privadas
--  do perfil continuam fora do alcance de outros usuários; votos individuais (private.rating_votes) ilegíveis.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 043_v61_isolation".
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('99610000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
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
create function pg_temp.seen(p_match uuid, p_pelada uuid, p_mem uuid) returns int[] language sql as
 $$ select array[
  (select count(*)::int from public.matches where id=p_match),
  (select count(*)::int from public.match_participants where match_id=p_match),
  (select count(*)::int from public.match_events where match_id=p_match),
  (select count(*)::int from public.rating_vote_sessions where match_id=p_match),
  (select count(*)::int from public.player_rating_history where pelada_id=p_pelada),
  (select count(*)::int from public.seasons where pelada_id=p_pelada),
  (select count(*)::int from public.pelada_memberships where id=p_mem)] $$;

do $test$
declare v_a uuid; v_b uuid; v_tok text; v_tok_b text; i int; v_m uuid; r jsonb; v_s int[]; v_mem3 uuid;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-v61-'||n||'@example.invalid','',now(),now(),now() from generate_series(1,14) n;
perform set_config('role','authenticated',true);
for i in 1..14 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||lpad(i::text,2,'0'),true,true); end loop;
-- A: admin 1, jogadores 2..12. B: admin 13, jogador 14 (não tem nada em comum com A).
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada A','GOL'); v_tok := public.create_pelada_invite(v_a);
for i in 2..12 loop perform pg_temp.as_user(i); perform public.join_pelada(v_tok, case when i%2=0 then 'ZAG' else 'ATA' end); end loop;
perform pg_temp.as_user(13); v_b := public.create_pelada('Pelada B','MEI'); v_tok_b := public.create_pelada_invite(v_b);
perform pg_temp.as_user(14); perform public.join_pelada(v_tok_b,'ATA');

perform pg_temp.as_user(1);
v_mem3 := pg_temp.mem(v_a,3);
v_m := public.create_match(v_a, now() - interval '3 hours');
perform public.save_match_sheet(v_m,
 (select jsonb_agg(jsonb_build_object('membership_id',pg_temp.mem(v_a,n),'team',case when n<=6 then 'A' else 'B' end)) from generate_series(1,12) n),
 jsonb_build_array(jsonb_build_object('membership_id',v_mem3,'type','goal','quantity',1)));
r := public.publish_match(v_m);
r := public.open_rating_vote(v_m);

-- Positivo: membro de A vê tudo de A.
perform pg_temp.as_user(3);
v_s := pg_temp.seen(v_m, v_a, v_mem3);
perform pg_temp.assert(v_s[1]=1 and v_s[2]=12 and v_s[3]>=1 and v_s[4]=1 and v_s[5]>=1 and v_s[6]>=1 and v_s[7]=1, 'membro lê a própria pelada: '||v_s::text);
perform pg_temp.assert(public.get_player_rating(v_mem3) is not null, 'membro lê o próprio OVR');

-- Negativo: quem é só de B não vê nada de A.
foreach i in array array[13,14] loop
 perform pg_temp.as_user(i);
 v_s := pg_temp.seen(v_m, v_a, v_mem3);
 perform pg_temp.assert(v_s = array[0,0,0,0,0,0,0], 'usuário '||i||' (outra pelada) não lê A: '||v_s::text);
 perform pg_temp.expect_error(format('select public.get_player_rating(%L)', v_mem3), 'NOT_FOUND');
 perform pg_temp.assert((select count(*) from public.profiles where id=pg_temp.uid(3))=0, 'perfil "peladas" invisível fora da pelada');
end loop;

-- Colunas privadas do perfil: nem colegas de pelada leem.
perform pg_temp.as_user(2);
perform pg_temp.assert((select count(*) from public.profiles where id=pg_temp.uid(3))=1, 'colega lê nome e foto');
perform pg_temp.expect_error(format('select terms_accepted_at from public.profiles where id=%L', pg_temp.uid(3)), 'permission denied');
perform pg_temp.expect_error('select count(*) from private.rating_votes', 'permission denied');

-- Quem sai da pelada perde o acesso.
perform pg_temp.as_user(12); perform public.leave_pelada(v_a);
v_s := pg_temp.seen(v_m, v_a, v_mem3);
perform pg_temp.assert(v_s[1]=0 and v_s[2]=0 and v_s[3]=0 and v_s[4]=0 and v_s[5]=0 and v_s[6]=0, 'ex-membro não lê A: '||v_s::text);

raise exception 'PASS: 043_v61_isolation';
end $test$;
