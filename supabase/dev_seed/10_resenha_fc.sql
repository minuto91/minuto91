-- SÓ NO SUPABASE DEV. Vitrine da V5 na Pelada Teste (55a69aba-...):
--  1. Renomeia para "Resenha FC" (o escudo oval é colocado pelo app: Configurações da pelada > Escudo,
--     com o arquivo supabase/dev_seed/resenha_fc_escudo.png).
--  2. Tira os Bot 1..5 antigos e cria 21 jogadores de linha de teste (sem senha: ninguém entra com eles),
--     que com o Rafa (admin) fecham 22.
--  3. Cria uma partida já jogada (ontem, 20h): Rafa e 10 no Time A, 11 no Time B, placar 2 x 1, com gols e assistências,
--     publicada pelo fluxo normal (súmula -> oficial).
--  4. OVR DE DEMONSTRAÇÃO de 55 a 92 para os 22. ATENÇÃO: estes valores são escritos à mão só para ver a carta no iPhone;
--     o motor de verdade daria "Em avaliação" (todos têm 1 partida). O próximo recálculo da pelada (nova partida, publicação
--     de notas, troca de posição, cartões ou defesas) substitui tudo pelo cálculo oficial.
-- Pode rodar mais de uma vez: não duplica jogadores nem a partida.
do $$
declare
  v_pid constant uuid := '55a69aba-465e-4241-8638-19cfb7675d16';
  v_admin uuid; v_admin_mem uuid; v_tok text; v_uid uuid; v_m uuid; v_parts jsonb; v_season uuid;
  v_played timestamptz := make_timestamptz(extract(year from now())::int, extract(month from now())::int,
    extract(day from now())::int, 20, 0, 0, 'America/Sao_Paulo') - interval '1 day';
  names text[] := array['Digão','Tiago Bala','Caio','Léo Bento','Gui','Paulinho','Joaquim','Bruno Henrique','Tião','Rafinha Lima',
    'Marquinhos','Dudu','Pedrão','Neto','Biel','Alemão','Juninho','Vitinho','Careca','Fabinho','Matheus'];
  pos text[] := array['ZAG','ZAG','LD','LE','VOL','VOL','MEI','MEI','CA','PD',
    'PE','ATA','ZAG','LD','LE','VOL','MEI','MEI','CA','PE','ATA'];
  v_new boolean; v_join boolean; mems uuid[]; i int; r record; v_t numeric; v_atu numeric; v_est numeric; v_peq numeric; v_res numeric; v_dis numeric;
begin
  select user_id, id into v_admin, v_admin_mem from public.pelada_memberships
  where pelada_id=v_pid and role='admin' and status='active';
  if v_admin is null then raise exception 'Pelada Teste não encontrada ou sem administrador'; end if;

  update public.peladas set name='Resenha FC' where id=v_pid;
  update public.pelada_memberships set status='left', role='player', assistant_since=null
  where pelada_id=v_pid and user_id::text like 'b0750000-0000-4000-8000-%' and role<>'admin';

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('role', 'authenticated', true);
  v_tok := public.create_pelada_invite(v_pid, 24, 30);
  execute 'reset role';

  for i in 1..21 loop
    v_uid := ('b0760000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid;
    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
    values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'resenha' || i || '@minuto91.invalid', '', now(), now(), now())
    on conflict (id) do nothing;
    v_new := not exists (select 1 from public.profiles where id=v_uid and terms_accepted_at is not null);
    v_join := not exists (select 1 from public.pelada_memberships where pelada_id=v_pid and user_id=v_uid and status='active');
    perform set_config('request.jwt.claim.sub', v_uid::text, true);
    perform set_config('role', 'authenticated', true);
    if v_new then perform public.complete_onboarding(names[i], true, true); end if;
    if v_join then perform public.join_pelada(v_tok, pos[i]); end if;
    execute 'reset role';
  end loop;
  mems := array(select m.id from generate_series(1,21) g
    join public.pelada_memberships m on m.pelada_id=v_pid and m.status='active'
     and m.user_id=('b0760000-0000-4000-8000-' || lpad(g::text, 12, '0'))::uuid order by g);

  -- Partida 2 x 1 (uma vez só).
  if not exists (select 1 from public.matches where pelada_id=v_pid and played_at=v_played and status <> 'annulled') then
    v_parts := jsonb_build_array(jsonb_build_object('membership_id', v_admin_mem, 'team', 'A'))
      || (select jsonb_agg(jsonb_build_object('membership_id', mems[g], 'team', case when g <= 10 then 'A' else 'B' end)) from generate_series(1,21) g);
    perform set_config('request.jwt.claim.sub', v_admin::text, true);
    perform set_config('role', 'authenticated', true);
    v_m := public.create_match(v_pid, v_played);
    perform public.save_match_sheet(v_m, v_parts, jsonb_build_array(
      jsonb_build_object('membership_id', v_admin_mem, 'type', 'goal', 'quantity', 1),     -- Rafa
      jsonb_build_object('membership_id', mems[7], 'type', 'assist', 'quantity', 1),       -- Joaquim
      jsonb_build_object('membership_id', mems[9], 'type', 'goal', 'quantity', 1),         -- Tião
      jsonb_build_object('membership_id', v_admin_mem, 'type', 'assist', 'quantity', 1),   -- Rafa
      jsonb_build_object('membership_id', mems[19], 'type', 'goal', 'quantity', 1),        -- Careca
      jsonb_build_object('membership_id', mems[17], 'type', 'assist', 'quantity', 1)));    -- Juninho
    perform public.publish_match(v_m);
    perform public.set_match_team_colors(v_m, 'azul', 'branco');
    execute 'reset role';
  end if;

  -- OVR de demonstração: 55 a 92, espalhado; o Rafa fica com 86.
  select id into v_season from public.seasons where pelada_id=v_pid and starts_on <= current_date and ends_on >= current_date
  order by starts_on desc limit 1;
  i := 0;
  for r in select x.mem, x.n from (select v_admin_mem mem, 0 n union all select mems[g], g from generate_series(1,21) g) x order by x.n loop
    v_t := case when r.n = 0 then 86 else 55 + round((r.n - 1) * 37.0 / 20) end;
    v_atu := least(97, v_t + ((r.n % 5) - 2) * 1.5);
    v_peq := least(97, v_t - 3 + (r.n % 4) * 2);
    v_res := least(95, v_t + (r.n % 3) * 2);
    v_dis := 70;
    v_est := least(99, greatest(0, (v_t - 0.3325*v_atu - 0.19*v_peq - 0.095*v_res - 0.05*v_dis) / 0.3325));
    update public.player_ratings set atu=v_atu, est=v_est, peq=v_peq, res=v_res, dis=v_dis, ovr=v_t, ovr_display=v_t,
      tier=case when v_t < 65 then 'bronze' when v_t < 80 then 'prata' else 'ouro' end, eligible=true, updated_at=now()
    where membership_id=r.mem;
    update public.player_cards set overall=v_t, ovr_display=v_t, atu=v_atu, est=v_est, peq=v_peq, res=v_res, dis=v_dis,
      tier=case when v_t < 65 then 'bronze' when v_t < 80 then 'prata' else 'ouro' end, is_provisional=false,
      formula_version=2, updated_at=now()
    where membership_id=r.mem and season_id=v_season;
  end loop;
end $$;

-- Confere: 22 jogadores com OVR, e a partida 2 x 1.
select m.player_name, coalesce(m.position_code, m.preferred_position) pos, c.ovr_display ovr, c.tier
from public.pelada_memberships m
left join public.player_cards c on c.membership_id=m.id
 and c.season_id=(select id from public.seasons where pelada_id=m.pelada_id and starts_on<=current_date and ends_on>=current_date order by starts_on desc limit 1)
where m.pelada_id='55a69aba-465e-4241-8638-19cfb7675d16' and m.status='active'
order by c.ovr_display desc nulls last;
select team_a_name, team_a_score, team_b_score, team_b_name, status from public.matches
where pelada_id='55a69aba-465e-4241-8638-19cfb7675d16' order by played_at desc limit 1;
