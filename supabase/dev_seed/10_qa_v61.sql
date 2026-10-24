-- SÓ NO SUPABASE DEV. Massa de QA da V6.1: contas COM senha para o Claude entrar no app e revisar as telas.
-- Cria 21 usuários "@qa.minuto91.invalid" (domínio inválido: nenhum e-mail sai), duas peladas e partidas reais,
-- tudo pelas funções do próprio app (mesmas regras e fórmulas). Só um ajuste direto: o prazo de UMA votação
-- da QA Resenha é encurtado para 45 min, para existir o estado "votação urgente".
--
-- Contas que importam (todas com a MESMA senha, sorteada e mostrada no fim):
--   qa.admin@qa.minuto91.invalid    admin da "QA Quinta" e jogador da "QA Resenha" (multi-pelada, admin/jogador)
--   qa.jogador@qa.minuto91.invalid  jogador nas duas, nome bem comprido, com votação aberta e urgente
--   qa.vazio@qa.minuto91.invalid    cadastro completo, sem nenhuma pelada
--   qa.novato@qa.minuto91.invalid   entrou na QA Quinta sem jogar (carta em avaliação)
--   qa.p05..qa.p21                  elenco de apoio
-- QA Quinta: 6 partidas oficiais (OVR já calculado para quem jogou 5+), 1 com votação aberta (6 h) e 1 escalação
-- planejada (próxima rodada). QA Resenha: 1 partida com votação urgente.
--
-- Rodar uma vez. Para recriar: rode 99_qa_v61_apagar.sql antes.
do $$
declare
  v_pw text := 'M91qa-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
  v_hash text;
  v_q uuid; v_r uuid; v_tq text; v_tr text; v_m uuid; i int; k int; r jsonb;
  v_names text[] := array['Rafael QA Admin','Jogador Com Nome Bem Comprido da Silva Santos Júnior','Usuário Sem Pelada','Novato da Quinta'];
  v_pos text[] := array['GOL','ZAG','LD','LE','VOL','MEI','CA','PD','PE','ATA'];
begin
  if exists (select 1 from auth.users where email like '%@qa.minuto91.invalid') then
    raise exception 'A massa de QA já existe. Rode 99_qa_v61_apagar.sql antes de recriar.';
  end if;
  v_hash := extensions.crypt(v_pw, extensions.gen_salt('bf'));

  -- Usuários com senha (login por e-mail) e identidade de e-mail, como o Supabase Auth cria.
  for i in 1..21 loop
    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change)
    values (('c0a61000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated',
      case i when 1 then 'qa.admin' when 2 then 'qa.jogador' when 3 then 'qa.vazio' when 4 then 'qa.novato'
             else 'qa.p' || lpad(i::text, 2, '0') end || '@qa.minuto91.invalid',
      v_hash, now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');
    insert into auth.identities(id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    select gen_random_uuid(), u.id, u.id::text, 'email',
      jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true), now(), now(), now()
    from auth.users u where u.id = ('c0a61000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid;
  end loop;

  -- Cadastro completo (como no onboarding do app).
  perform set_config('role', 'authenticated', true);
  for i in 1..21 loop
    perform set_config('request.jwt.claim.sub', ('c0a61000-0000-4000-8000-' || lpad(i::text, 12, '0')), true);
    perform public.complete_onboarding(coalesce(v_names[i], 'QA Jogador ' || lpad(i::text, 2, '0')), true, true);
  end loop;

  -- QA Quinta: admin 1; jogadores 2, 4..15.
  perform set_config('request.jwt.claim.sub', 'c0a61000-0000-4000-8000-000000000001', true);
  v_q := public.create_pelada('QA Quinta', 'MEI');
  v_tq := public.create_pelada_invite(v_q, 24, 50);
  foreach i in array array[2,4,5,6,7,8,9,10,11,12,13,14,15] loop
    perform set_config('request.jwt.claim.sub', ('c0a61000-0000-4000-8000-' || lpad(i::text, 12, '0')), true);
    perform public.join_pelada(v_tq, case when i in (5,10) then 'GOL' else v_pos[2 + (i % 9)] end);
  end loop;

  -- QA Resenha: admin 16; jogadores 1, 2, 17..21.
  perform set_config('request.jwt.claim.sub', 'c0a61000-0000-4000-8000-000000000016', true);
  v_r := public.create_pelada('QA Resenha', 'ATA');
  v_tr := public.create_pelada_invite(v_r, 24, 50);
  foreach i in array array[1,2,17,18,19,20,21] loop
    perform set_config('request.jwt.claim.sub', ('c0a61000-0000-4000-8000-' || lpad(i::text, 12, '0')), true);
    perform public.join_pelada(v_tr, case when i = 17 then 'GOL' else 'MEI' end);
  end loop;
  execute 'reset role';
  perform set_config('qa.q', v_q::text, false);
  perform set_config('qa.r', v_r::text, false);
  perform set_config('qa.pw', v_pw, false);
end $$;

-- Partidas da QA Quinta: 6 oficiais (uma por semana) + 1 de ontem com votação aberta. Times de 6 (1,2,5,6,7,8 x 9..14).
do $$
declare v_q uuid := current_setting('qa.q')::uuid; v_m uuid; w int; r jsonb;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', 'c0a61000-0000-4000-8000-000000000001', true);
  for w in reverse 7..1 loop
    v_m := public.create_match(v_q, now() - make_interval(days => w * 7 - 6, hours => 3), 'Azul', 'Branco');
    perform public.save_match_sheet(v_m,
      (select jsonb_agg(jsonb_build_object('membership_id', m.id, 'team',
         case when m.user_id::text ~ '-0000000000(01|02|05|06|07|08)$' then 'A' else 'B' end))
       from public.pelada_memberships m
       where m.pelada_id = v_q and m.status = 'active' and m.user_id::text !~ '-0000000000(04|15)$'),
      jsonb_build_array(
        jsonb_build_object('membership_id', (select id from public.pelada_memberships where pelada_id=v_q and user_id='c0a61000-0000-4000-8000-000000000002'), 'type', 'goal', 'quantity', 1 + (w % 2)),
        jsonb_build_object('membership_id', (select id from public.pelada_memberships where pelada_id=v_q and user_id='c0a61000-0000-4000-8000-000000000001'), 'type', 'assist', 'quantity', 1),
        jsonb_build_object('membership_id', (select id from public.pelada_memberships where pelada_id=v_q and user_id='c0a61000-0000-4000-8000-000000000011'), 'type', 'goal', 'quantity', 1 + w % 3)));
    r := public.publish_match(v_m);
    -- A mais recente (w = 1, ontem) fica com a votação pós-partida aberta (janela normal de 6 h a partir de agora).
    if w = 1 then r := public.open_rating_vote(v_m); end if;
  end loop;

  -- Próxima rodada planejada (escalação), com o qa.jogador no Azul.
  perform public.save_lineup(v_q, null, 'Rodada de quinta',
    (select array_agg(id) from public.pelada_memberships where pelada_id=v_q and user_id::text ~ '-0000000000(01|02|05|06|07|08)$'),
    (select array_agg(id) from public.pelada_memberships where pelada_id=v_q and user_id::text ~ '-0000000000(09|10|11|12|13|14)$'),
    'Azul', 'Branco');
  execute 'reset role';
end $$;

-- QA Resenha: 1 partida de 2 h atrás com votação aberta e prazo encurtado para 45 min (estado "urgente").
do $$
declare v_r uuid := current_setting('qa.r')::uuid; v_m uuid; r jsonb;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', 'c0a61000-0000-4000-8000-000000000016', true);
  v_m := public.create_match(v_r, now() - interval '2 hours', 'Laranja', 'Preto');
  perform public.save_match_sheet(v_m,
    (select jsonb_agg(jsonb_build_object('membership_id', m.id, 'team',
       case when m.user_id::text ~ '-0000000000(16|01|17|18)$' then 'A' else 'B' end))
     from public.pelada_memberships m where m.pelada_id = v_r and m.status = 'active'),
    jsonb_build_array(jsonb_build_object('membership_id',
      (select id from public.pelada_memberships where pelada_id=v_r and user_id='c0a61000-0000-4000-8000-000000000002'), 'type', 'goal', 'quantity', 2)));
  r := public.publish_match(v_m);
  r := public.open_rating_vote(v_m);
  execute 'reset role';
  update public.rating_vote_sessions set closes_at = now() + interval '45 minutes', original_closes_at = now() + interval '45 minutes'
  where match_id = v_m;
end $$;

-- Resultado: copie a SENHA e guarde como segredo M91_TEST_PASSWORD no ambiente (ou mande no chat: é só de teste).
select current_setting('qa.pw') as senha_de_teste,
  (select count(*) from auth.users where email like '%@qa.minuto91.invalid') as usuarios,
  (select count(*) from public.matches m join public.peladas p on p.id = m.pelada_id where p.name in ('QA Quinta','QA Resenha')) as partidas,
  (select count(*) from public.player_ratings pr join public.peladas p on p.id = pr.pelada_id where p.name = 'QA Quinta' and pr.eligible) as com_ovr;
