-- SÓ NO SUPABASE DEV. Vitrine "Fut dos Cria" (Reels do Instagram).
-- 1. Cria a pelada como o Rafael (rafael98abreu@hotmail.com, admin, não joga).
-- 2. Cria 45 contas simuladas (sem senha) que entram pelo convite com posição detalhada.
-- 3. Guarda o nível escondido de cada um em private.seed_fdc (só para gerar os jogos; apagado no fim).
-- Pode rodar de novo: não duplica.
do $$
declare
  v_admin uuid := (select id from auth.users where email='rafael98abreu@hotmail.com');
  v_pid uuid; v_tok text; v_uid uuid; i int; v_new boolean; v_join boolean;
  names text[] := array[
   'Fernando Muralha','Diego Paredão','Wesley','Jorge Luiz',                 -- GOL
   'Renan','Carlos Eduardo','Tuca',                                          -- LD
   'Murilo','João Victor','Lelê',                                            -- LE
   'Paulo Henrique','Xerife','Anderson','Marcão','Beto','Gustavo Henrique',  -- ZAG
   'Luiz Felipe','Cabeça','Igor','Pitbull','Sandro',                         -- VOL
   'Thiago Ramos','Pedro Henrique','Maestro','Felipe','Arthur Gabriel','Nandinho','Bruninho','Zé Ricardo', -- MEI
   'Vinícius','Ligeirinho','Matheus Felipe','Danilo',                        -- PE
   'Jean Carlos','Fumaça','Kauã','Leandro',                                  -- PD
   'Matador','Lucas Gabriel','Tanque','Rafinha','Edson',                     -- ATA
   'Henrique','Pezão','Marcelinho'];                                         -- CA
  pos text[] := array['GOL','GOL','GOL','GOL','LD','LD','LD','LE','LE','LE',
   'ZAG','ZAG','ZAG','ZAG','ZAG','ZAG','VOL','VOL','VOL','VOL','VOL',
   'MEI','MEI','MEI','MEI','MEI','MEI','MEI','MEI','PE','PE','PE','PE','PD','PD','PD','PD',
   'ATA','ATA','ATA','ATA','ATA','CA','CA','CA'];
  -- nível escondido: ouro ~1.3-1.9, prata ~-0.2-0.9, bronze ~-1.6--0.7
  sk numeric[] := array[1.5,0.6,0.2,-1.0, 0.5,0.1,-1.2, 1.4,0.4,-0.9,
   1.5,0.8,0.3,0.0,-0.8,-1.3, 1.4,0.7,0.4,0.1,-1.1,
   1.6,1.5,0.9,0.5,0.3,0.1,-0.1,-1.4, 1.5,0.7,0.2,-1.0, 0.6,0.3,-0.2,-0.9,
   1.9,1.4,0.8,0.4,-1.5, 1.7,0.6,0.0];
  att numeric[] := array[0.85,0.8,0.65,0.6, 0.8,0.75,0.6, 0.85,0.7,0.6,
   0.9,0.85,0.7,0.75,0.6,0.55, 0.9,0.8,0.7,0.75,0.6,
   0.95,0.85,0.8,0.7,0.65,0.7,0.6,0.55, 0.9,0.75,0.7,0.6, 0.8,0.75,0.65,0.6,
   0.95,0.85,0.75,0.7,0.55, 0.9,0.7,0.6];
begin
  if v_admin is null then raise exception 'Conta do Rafael não encontrada'; end if;
  select id into v_pid from public.peladas where name='Fut dos Cria' and created_by=v_admin;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('role', 'authenticated', true);
  if v_pid is null then
    v_pid := public.create_pelada('Fut dos Cria', 'MEI',
      'Todo domingo, 8h, na Arena Mangueira. Time Preto x Time Amarelo. Quem chega atrasado vai pro gol.');
  end if;
  perform public.update_pelada_identity(v_pid, jsonb_build_object('location','Arena Mangueira',
    'team_a_name','Time Preto','team_b_name','Time Amarelo','team_a_color','preto','team_b_color','amarelo',
    'weekday','0','time','08:00'));
  perform public.set_cards_tracking(v_pid, true);
  perform public.update_pelada_settings(v_pid, 360, true, null);
  v_tok := public.create_pelada_invite(v_pid, 24, 60);
  execute 'reset role';
  update public.peladas set created_at = '2026-06-20 10:00-03' where id=v_pid;
  update public.pelada_settings set team_names_customized=true where pelada_id=v_pid;

  create table if not exists private.seed_fdc(n int primary key, mem uuid, uid uuid, pos text, skill numeric, att numeric, name text);

  for i in 1..45 loop
    v_uid := ('f0dc0000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid;
    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
    values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'futdoscria' || i || '@minuto91.invalid', '', now(), now(), now())
    on conflict (id) do nothing;
    v_new := not exists (select 1 from public.profiles where id=v_uid and terms_accepted_at is not null);
    v_join := not exists (select 1 from public.pelada_memberships where pelada_id=v_pid and user_id=v_uid and status='active');
    perform set_config('request.jwt.claim.sub', v_uid::text, true);
    perform set_config('role', 'authenticated', true);
    if v_new then
      perform public.complete_onboarding(names[i], true, true);
      perform public.update_my_profile(names[i], case when pos[i] in ('LE','PE') then 'left' when i % 9 = 0 then 'both' else 'right' end);
    end if;
    if v_join then perform public.join_pelada(v_tok, pos[i]); end if;
    execute 'reset role';
    insert into private.seed_fdc(n, mem, uid, pos, skill, att, name)
    select i, m.id, v_uid, pos[i], sk[i], att[i], names[i] from public.pelada_memberships m
    where m.pelada_id=v_pid and m.user_id=v_uid and m.status='active'
    on conflict (n) do update set mem=excluded.mem, skill=excluded.skill, att=excluded.att;
  end loop;
  update public.pelada_memberships set joined_at = '2026-06-20 12:00-03' where pelada_id=v_pid;
  update public.membership_periods set started_at = '2026-06-20 12:00-03' where pelada_id=v_pid and ended_at is null;
end $$;

select m.player_name, m.role, m.position_code, m.preferred_position from public.pelada_memberships m
join public.peladas p on p.id=m.pelada_id where p.name='Fut dos Cria' order by m.position_code, m.player_name;
