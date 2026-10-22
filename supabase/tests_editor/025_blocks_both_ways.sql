-- Bloqueio nos dois sentidos (migração 032). Cole no SQL Editor do Supabase DEV DEPOIS de aplicar a 032.
-- Termina SEMPRE com o erro proposital "PASS: 025_blocks_both_ways" = tudo certo, nada gravado.
create function pg_temp.uid(n int) returns uuid language sql as
 $$ select ('c2850000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid $$;
create function pg_temp.as_user(n int) returns void language plpgsql as
 $$ begin perform set_config('request.jwt.claim.sub', pg_temp.uid(n)::text, true); end $$;
create function pg_temp.assert(p_ok boolean, p_msg text) returns void language plpgsql as
 $$ begin if not coalesce(p_ok,false) then raise exception 'FALHOU: %', p_msg; end if; end $$;
-- O usuário atual consegue ler a linha do perfil de n direto da tabela?
create function pg_temp.reads_row(n int) returns boolean language sql as
 $$ select exists(select 1 from public.profiles where id = pg_temp.uid(n)) $$;
create function pg_temp.sees_profile(n int) returns boolean language sql as
 $$ select (public.get_player_profile(pg_temp.uid(n))->>'visible')::boolean $$;
create function pg_temp.sees_career(n int) returns boolean language sql as
 $$ select (public.get_player_career(pg_temp.uid(n))->>'visible')::boolean $$;
-- O usuário atual vê o apelido de n dentro da pelada (acesso legítimo que deve continuar)?
create function pg_temp.sees_member(p_pelada uuid, n int) returns boolean language sql as
 $$ select exists(select 1 from public.pelada_memberships where pelada_id = p_pelada and user_id = pg_temp.uid(n)) $$;

do $test$
declare v_a uuid; v_tok text;
begin
insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
select pg_temp.uid(n),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
 'm91-bl'||n||'@example.invalid','',now(),now(),now() from generate_series(1,4) n;
perform set_config('role','authenticated',true);
for i in 1..4 loop perform pg_temp.as_user(i); perform public.complete_onboarding('Jogador '||i,true,true); end loop;
-- Pelada A: 1 (admin), 2 e 3. O 4 não tem pelada.
perform pg_temp.as_user(1); v_a := public.create_pelada('Pelada A','attacker'); v_tok := public.create_pelada_invite(v_a);
perform pg_temp.as_user(2); perform public.join_pelada(v_tok,'defender');
perform pg_temp.as_user(3); perform public.join_pelada(v_tok,'midfielder');

-- Sem bloqueio: todos se veem.
perform pg_temp.as_user(2); perform pg_temp.assert(pg_temp.reads_row(1) and pg_temp.sees_profile(1),'2 vê 1 antes');
perform pg_temp.as_user(1); perform pg_temp.assert(pg_temp.reads_row(2) and pg_temp.sees_profile(2),'1 vê 2 antes');

-- 1 bloqueia 2.
perform pg_temp.as_user(1); perform public.block_user(pg_temp.uid(2));
-- Quem bloqueou não vê quem foi bloqueado (já era assim na 023).
perform pg_temp.assert(not pg_temp.reads_row(2),'1 não lê a linha de 2');
perform pg_temp.assert(not pg_temp.sees_profile(2) and not pg_temp.sees_career(2),'1 não vê perfil/carreira de 2');
-- Quem foi bloqueado também não vê quem bloqueou (correção da 032).
perform pg_temp.as_user(2);
perform pg_temp.assert(not pg_temp.reads_row(1),'2 não lê a linha de 1 (032)');
perform pg_temp.assert(not pg_temp.sees_profile(1) and not pg_temp.sees_career(1),'2 não vê perfil/carreira de 1');
-- Dentro da pelada o apelido continua (estatísticas, súmula e rankings precisam dele).
perform pg_temp.assert(pg_temp.sees_member(v_a,1),'2 ainda vê o apelido de 1 na pelada');
perform pg_temp.as_user(1); perform pg_temp.assert(pg_temp.sees_member(v_a,2),'1 ainda vê o apelido de 2 na pelada');
-- Terceiros não são afetados.
perform pg_temp.as_user(3); perform pg_temp.assert(pg_temp.reads_row(1) and pg_temp.reads_row(2),'3 vê os dois');

-- Perfil público: bloqueio também vale nos dois sentidos para quem não divide pelada.
perform pg_temp.as_user(1); perform public.set_my_privacy('public','public');
perform pg_temp.as_user(4); perform pg_temp.assert(pg_temp.reads_row(1) and pg_temp.sees_career(1),'4 vê 1 público');
perform pg_temp.as_user(4); perform public.block_user(pg_temp.uid(1));
perform pg_temp.assert(not pg_temp.reads_row(1) and not pg_temp.sees_career(1),'4 bloqueou 1: não vê');
perform pg_temp.as_user(1); perform pg_temp.assert(not pg_temp.reads_row(4),'1 não vê quem o bloqueou');
perform pg_temp.as_user(4); perform public.unblock_user(pg_temp.uid(1));
perform pg_temp.assert(pg_temp.reads_row(1),'desbloqueado: volta a ver');

-- Desbloqueio entre 1 e 2 devolve o acesso nos dois sentidos.
perform pg_temp.as_user(1); perform public.unblock_user(pg_temp.uid(2));
perform pg_temp.assert(pg_temp.reads_row(2),'1 volta a ver 2');
perform pg_temp.as_user(2); perform pg_temp.assert(pg_temp.reads_row(1),'2 volta a ver 1');

  raise exception 'PASS: 025_blocks_both_ways (rollback proposital - nada foi gravado)';
end
$test$;
