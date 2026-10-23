-- SÓ NO SUPABASE DEV. Rode depois do 10_resenha_fc.sql. Cria 10 partidas oficiais anteriores na Resenha FC,
-- uma por semana antes da 2 x 1, para todos passarem de 5 jogos e o OVR aparecer pelo CÁLCULO OFICIAL
-- (os valores de demonstração do script 10 são substituídos).
-- Cada partida segue o fluxo real: súmula -> oficial -> votação aberta -> os 21 jogadores de teste votam
-- (cada um dá nota a parte dos colegas) -> prazo encerrado -> publicação pelo admin (Rafa).
-- O Rafa não vota (é conta real). Presença de ~85%, times equilibrados no sorteio, gols e assistências
-- conforme a posição e o nível de cada um, notas coerentes com o nível e com o jogo. Aleatório: cada execução
-- gera jogos diferentes; rodar de novo não duplica (as datas já usadas são puladas).
-- Os avisos (push) dessas partidas são silenciados no fim, para o seu iPhone não receber dezenas de notificações.
do $$
declare
  v_pid constant uuid := '55a69aba-465e-4241-8638-19cfb7675d16';
  v_admin uuid; v_admin_mem uuid; v_start timestamptz := now();
  v_last timestamptz; v_season record; v_at timestamptz; v_m uuid; v_s uuid; k int; t int; g int;
  v_parts jsonb; v_events jsonb; v_present uuid[]; v_a uuid[]; v_b uuid[]; v_team uuid[];
  v_goals int[]; v_scorer uuid; v_assist uuid; v_cnt jsonb; v_uid uuid; v_target record; v_note numeric;
  colors text[] := array['azul','branco','preto','vermelho','amarelo','laranja','roxo','rosa'];
begin
  select user_id, id into v_admin, v_admin_mem from public.pelada_memberships
  where pelada_id=v_pid and role='admin' and status='active';
  if v_admin is null then raise exception 'Pelada não encontrada'; end if;
  select min(played_at) into v_last from public.matches where pelada_id=v_pid and status='finalized';
  v_last := coalesce(v_last, now());
  select * into v_season from public.seasons where pelada_id=v_pid and starts_on <= current_date and ends_on >= current_date
  order by starts_on desc limit 1;

  -- Nível escondido de cada jogador (só para gerar os jogos): Rafa bom; os de teste em ordem crescente.
  create temp table if not exists rf_skill(mem uuid primary key, skill numeric, att numeric) on commit drop;
  delete from rf_skill;
  insert into rf_skill
  select m.id, case when m.id=v_admin_mem then 1.0
   else -1.4 + 3.0 * (right(pr.id::text, 2)::int - 1) / 20.0 end,
   case when m.id=v_admin_mem then 1 else 0.75 + random()*0.2 end
  from public.pelada_memberships m join public.profiles pr on pr.id=m.user_id
  where m.pelada_id=v_pid and m.status='active';

  for k in 1..10 loop
    v_at := v_last - make_interval(days => 7*k);
    if private.pelada_local_date(v_pid, v_at) < v_season.starts_on then
      raise notice 'Partida % fora da temporada atual: pulada', k; continue; end if;
    if exists(select 1 from public.matches where pelada_id=v_pid and played_at=v_at) then continue; end if;

    -- Presença e sorteio equilibrado (alterna os mais fortes entre os times).
    v_present := array(select mem from rf_skill where mem=v_admin_mem or random() < att order by skill desc);
    v_a := '{}'; v_b := '{}';
    for g in 1..cardinality(v_present) loop
      if (g % 4) in (1, 0) then v_a := v_a || v_present[g]; else v_b := v_b || v_present[g]; end if;
    end loop;
    v_parts := (select jsonb_agg(jsonb_build_object('membership_id', x, 'team', 'A')) from unnest(v_a) x)
            || (select jsonb_agg(jsonb_build_object('membership_id', x, 'team', 'B')) from unnest(v_b) x);

    -- Gols por time (0 a 5), puxados pela força do time; autor e garçom pela posição e nível.
    v_goals := array[
      least(5, floor(random()*3.2 + 0.6*((select avg(skill) from rf_skill where mem=any(v_a)) - (select avg(skill) from rf_skill where mem=any(v_b))) + 0.6))::int,
      least(5, floor(random()*3.2 + 0.6*((select avg(skill) from rf_skill where mem=any(v_b)) - (select avg(skill) from rf_skill where mem=any(v_a))) + 0.6))::int];
    v_cnt := '{}';
    for t in 1..2 loop
      v_team := case t when 1 then v_a else v_b end;
      for g in 1..greatest(0, v_goals[t]) loop
        select s.mem into v_scorer from rf_skill s join public.pelada_memberships m on m.id=s.mem
        where s.mem=any(v_team)
        order by random() * (case coalesce(m.position_code,'MEI') when 'ATA' then 5 when 'CA' then 5 when 'PE' then 3.5 when 'PD' then 3.5
          when 'MEI' then 2.5 when 'VOL' then 1.2 when 'LD' then 1 when 'LE' then 1 else 0.6 end) * exp(0.5*s.skill) desc limit 1;
        v_cnt := v_cnt || jsonb_build_object(v_scorer::text, coalesce(v_cnt->v_scorer::text, '{}') || jsonb_build_object('g', coalesce((v_cnt->v_scorer::text->>'g')::int,0)+1));
        if random() < 0.75 then
          select s.mem into v_assist from rf_skill s join public.pelada_memberships m on m.id=s.mem
          where s.mem=any(v_team) and s.mem<>v_scorer
          order by random() * (case coalesce(m.position_code,'MEI') when 'MEI' then 4 when 'PE' then 3 when 'PD' then 3
            when 'VOL' then 2 when 'LD' then 2 when 'LE' then 2 when 'ATA' then 2 when 'CA' then 2 else 0.8 end) * exp(0.5*s.skill) desc limit 1;
          v_cnt := v_cnt || jsonb_build_object(v_assist::text, coalesce(v_cnt->v_assist::text, '{}') || jsonb_build_object('a', coalesce((v_cnt->v_assist::text->>'a')::int,0)+1));
        end if;
      end loop;
    end loop;
    select coalesce(jsonb_agg(e), '[]') into v_events from (
      select jsonb_build_object('membership_id', key, 'type', 'goal', 'quantity', (value->>'g')::int) e from jsonb_each(v_cnt) where value ? 'g'
      union all
      select jsonb_build_object('membership_id', key, 'type', 'assist', 'quantity', (value->>'a')::int) from jsonb_each(v_cnt) where value ? 'a') z;

    -- Súmula, oficial, cores e votação (como o admin).
    perform set_config('request.jwt.claim.sub', v_admin::text, true);
    perform set_config('role', 'authenticated', true);
    v_m := public.create_match(v_pid, v_at);
    perform public.save_match_sheet(v_m, v_parts, v_events);
    perform public.publish_match(v_m);
    perform public.set_match_team_colors(v_m, colors[1 + (k % 4) * 2], colors[2 + (k % 4) * 2]);
    v_s := (public.open_rating_vote(v_m)->>'session_id')::uuid;
    execute 'reset role';

    -- Os jogadores de teste votam: ~70% votam; cada um avalia 50% a 100% dos outros.
    for v_uid in select pm.user_id from public.rating_vote_participants vp join public.pelada_memberships pm on pm.id=vp.membership_id
      where vp.session_id=v_s and pm.id<>v_admin_mem and random() < 0.7 loop
      for v_target in select vp.membership_id mem, s.skill,
          coalesce((v_cnt->vp.membership_id::text->>'g')::int,0) g, coalesce((v_cnt->vp.membership_id::text->>'a')::int,0) a
        from public.rating_vote_participants vp join rf_skill s on s.mem=vp.membership_id
        where vp.session_id=v_s and vp.membership_id <> (select id from public.pelada_memberships where pelada_id=v_pid and user_id=v_uid)
      loop
        continue when random() > 0.5 + random()*0.5;
        v_note := least(10, greatest(0, round((6.4 + 1.1*v_target.skill + 0.5*v_target.g + 0.3*v_target.a + (random()+random()+random()-1.5)*1.2) * 2) / 2));
        perform set_config('request.jwt.claim.sub', v_uid::text, true);
        perform set_config('role', 'authenticated', true);
        perform public.cast_rating_vote(v_s, v_target.mem, v_note);
        execute 'reset role';
      end loop;
    end loop;

    -- Prazo encerrado e publicação pelo admin.
    update public.rating_vote_sessions set closes_at = clock_timestamp() - interval '1 second' where id=v_s;
    perform set_config('request.jwt.claim.sub', v_admin::text, true);
    perform set_config('role', 'authenticated', true);
    perform public.publish_rating_vote(v_s);
    execute 'reset role';
  end loop;

  -- Sem push atrasado no iPhone por causa da carga.
  update public.notification_events set status='suppressed'
  where pelada_id=v_pid and created_at >= v_start and status='pending';
end $$;

-- Confere: partidas por jogador e OVR oficial (5+ partidas = OVR exibido).
select m.player_name, coalesce(m.position_code, m.preferred_position) pos, r.matches_played jogos, r.ovr_display ovr, r.tier,
 round(r.atu) atu, round(r.est) est, round(r.peq) peq, round(r.res) res, round(r.dis) dis
from public.pelada_memberships m join public.player_ratings r on r.membership_id=m.id
where m.pelada_id='55a69aba-465e-4241-8638-19cfb7675d16' and m.status='active'
order by r.ovr_display desc nulls last;
select played_at::date dia, team_a_score || ' x ' || team_b_score placar from public.matches
where pelada_id='55a69aba-465e-4241-8638-19cfb7675d16' and status='finalized' order by played_at;
