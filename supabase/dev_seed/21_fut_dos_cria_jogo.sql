-- SÓ NO SUPABASE DEV. Função temporária que joga UM domingo da Fut dos Cria pelo fluxo real do app:
-- presença -> escalação 11x11 + reservas -> súmula (gols, assistências, cartões) -> linha do tempo ->
-- oficial -> votação (notas, Craque e Bola Murcha de cada jogador) -> defesas dos goleiros -> publicação.
-- Uso: select private.seed_fdc_play('2026-06-28 08:00-03');   Apagar no fim: 29_fut_dos_cria_limpar.sql
create or replace function private.seed_fdc_play(p_at timestamptz) returns text
language plpgsql set search_path to '' as $f$
declare
  v_pid uuid; v_admin uuid; v_m uuid; v_s uuid; v_dv int; i int; t int; v_min int;
  v_parts jsonb := '[]'; v_events jsonb := '[]'; v_tl jsonb := '[]'; v_saves jsonb := '[]';
  v_goals int[]; v_diff numeric; v_scorer uuid; v_assist uuid; v_team text; r record; v_voter record; v_tgt record;
  v_note numeric; v_tm uuid[]; v_tn numeric[]; v_craque uuid; v_murcha uuid; v_res text;
begin
  select id, created_by into v_pid, v_admin from public.peladas where name='Fut dos Cria';
  if exists(select 1 from public.matches where pelada_id=v_pid and played_at=p_at and status<>'cancelled') then
    return 'já existe'; end if;

  -- Presença (goleiro sempre aparece 2) e grupos por posição.
  create temp table if not exists fdc_day(mem uuid primary key, uid uuid, grp text, skill numeric, team text,
    starter boolean default false, g int default 0, a int default 0, yc int default 0, rc int default 0, perf numeric) on commit drop;
  delete from fdc_day;
  insert into fdc_day(mem, uid, grp, skill)
  select mem, uid, case when pos in ('ATA','CA') then 'FW' else pos end, skill from private.seed_fdc s
  where random() < att;
  insert into fdc_day(mem, uid, grp, skill)
  select mem, uid, 'GOL', skill from private.seed_fdc s where pos='GOL' and mem not in (select mem from fdc_day)
  order by random() limit greatest(0, 2 - (select count(*) from fdc_day where grp='GOL'));

  -- Titulares: GOL 2, LD 2, LE 2, ZAG 4, VOL 2, MEI 4, PE 2, PD 2, FW 2 (falta de lateral/ponta é coberta pelo setor).
  update fdc_day d set starter=true from (
    select mem, row_number() over (partition by grp order by skill + random()*0.8 desc) rn, grp from fdc_day) x
  where x.mem=d.mem and x.rn <= case x.grp when 'ZAG' then 4 when 'MEI' then 4 else 2 end;
  -- completa as vagas que faltaram com quem sobrou (prioriza mesmo setor)
  for i in 1..greatest(0, 22 - (select count(*) from fdc_day where starter)) loop
    update fdc_day set starter=true where mem=(select mem from fdc_day where not starter and grp<>'GOL' order by random() limit 1);
  end loop;
  -- Reservas: até 3 por time; o resto foi embora cedo (fica fora da súmula).
  delete from fdc_day where not starter and mem not in (select mem from fdc_day where not starter order by random() limit 6);

  -- Times equilibrados: em cada grupo, em "cobrinha" pelo nível.
  update fdc_day d set team = case when x.rn % 4 in (1,0) then 'A' else 'B' end from (
    select mem, row_number() over (partition by grp, starter order by skill desc) + (case when grp in ('LE','PE','VOL') then 1 else 0 end) rn
    from fdc_day) x where x.mem=d.mem;

  select coalesce(avg(skill) filter (where team='A'),0) - coalesce(avg(skill) filter (where team='B'),0) into v_diff from fdc_day where starter;
  v_goals := array[greatest(0, least(6, floor(random()*3.6 + 0.9*v_diff + 0.3)))::int,
                   greatest(0, least(6, floor(random()*3.6 - 0.9*v_diff + 0.3)))::int];

  for t in 1..2 loop
    v_team := case t when 1 then 'A' else 'B' end;
    for i in 1..v_goals[t] loop
      v_min := 1 + floor(random()*90)::int;
      select mem into v_scorer from fdc_day where team=v_team and grp<>'GOL'
      order by random() * (case grp when 'FW' then 5 when 'PE' then 3.2 when 'PD' then 3.2 when 'MEI' then 2.3
        when 'VOL' then 1.0 when 'LD' then 0.8 when 'LE' then 0.8 else 0.5 end) * exp(0.6*skill) * (case when starter then 1 else 0.5 end) desc limit 1;
      update fdc_day set g=g+1 where mem=v_scorer;
      v_tl := v_tl || jsonb_build_object('type','goal','membership_id',v_scorer,'minute',v_min);
      if random() < 0.72 then
        select mem into v_assist from fdc_day where team=v_team and mem<>v_scorer
        order by random() * (case grp when 'MEI' then 4 when 'PE' then 3 when 'PD' then 3 when 'VOL' then 1.8
          when 'LD' then 2 when 'LE' then 2 when 'FW' then 2 when 'GOL' then 0.15 else 0.7 end) * exp(0.5*skill) desc limit 1;
        update fdc_day set a=a+1 where mem=v_assist;
        v_tl := v_tl || jsonb_build_object('type','assist','membership_id',v_assist,'minute',v_min);
      end if;
    end loop;
  end loop;

  -- Cartões: 0 a 3 amarelos, quase sempre de zagueiro/volante; vermelho raro.
  for i in 1..floor(random()*4)::int loop
    select mem into v_scorer from fdc_day where grp<>'GOL'
    order by random() * (case grp when 'ZAG' then 4 when 'VOL' then 4 when 'LD' then 2 when 'LE' then 2 else 1 end) desc limit 1;
    update fdc_day set yc=yc+1 where mem=v_scorer and yc=0;
    if found then v_tl := v_tl || jsonb_build_object('type','yellow_card','membership_id',v_scorer,'minute',10+floor(random()*80)::int); end if;
  end loop;
  if random() < 0.09 then
    select mem into v_scorer from fdc_day where grp in ('ZAG','VOL') and yc=0 order by random() limit 1;
    if v_scorer is not null then update fdc_day set rc=1 where mem=v_scorer;
      v_tl := v_tl || jsonb_build_object('type','red_card','membership_id',v_scorer,'minute',55+floor(random()*35)::int); end if;
  end if;

  select jsonb_agg(jsonb_build_object('membership_id', mem, 'team', team)) into v_parts from fdc_day;
  select coalesce(jsonb_agg(e), '[]') into v_events from (
    select jsonb_build_object('membership_id', mem, 'type', 'goal', 'quantity', g) e from fdc_day where g>0
    union all select jsonb_build_object('membership_id', mem, 'type', 'assist', 'quantity', a) from fdc_day where a>0
    union all select jsonb_build_object('membership_id', mem, 'type', 'yellow_card', 'quantity', 1) from fdc_day where yc>0
    union all select jsonb_build_object('membership_id', mem, 'type', 'red_card', 'quantity', 1) from fdc_day where rc>0) z;
  select coalesce(jsonb_agg(x order by (x->>'minute')::int), '[]') into v_tl from jsonb_array_elements(v_tl) x;

  -- Súmula como o admin.
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('role', 'authenticated', true);
  v_m := public.create_match(v_pid, p_at, 'Time Preto', 'Time Amarelo');
  perform public.save_match_sheet(v_m, v_parts, v_events);
  execute 'reset role';
  select draft_version into v_dv from public.matches where id=v_m;
  perform set_config('role', 'authenticated', true);
  begin perform public.set_match_timeline(v_m, v_dv, v_tl); exception when others then raise notice 'timeline: %', sqlerrm; end;
  perform public.publish_match(v_m);
  perform public.set_match_team_colors(v_m, 'preto', 'amarelo');
  begin perform public.set_match_discipline_status(v_m, 'confirmed'); exception when others then raise notice 'disciplina: %', sqlerrm; end;
  v_s := (public.open_rating_vote(v_m)->>'session_id')::uuid;
  execute 'reset role';

  -- Defesas difíceis dos goleiros.
  select coalesce(jsonb_agg(jsonb_build_object('participant_id', p.id, 'hard_saves', 1 + floor(random()*3 + d.skill + 1.2)::int)), '[]')
  into v_saves from public.match_participants p join fdc_day d on d.mem=p.membership_id
  where p.match_id=v_m and p.primary_position='goalkeeper';
  perform set_config('role', 'authenticated', true);
  begin perform public.set_match_hard_saves(v_m, v_saves); exception when others then raise notice 'defesas: %', sqlerrm; end;
  execute 'reset role';

  -- Desempenho real do dia (para notas, Craque e Bola Murcha).
  update fdc_day set perf = skill + 0.9*g + 0.45*a - 0.4*yc - 1.5*rc
    + case when (team='A' and v_goals[1]>v_goals[2]) or (team='B' and v_goals[2]>v_goals[1]) then 0.35
           when v_goals[1]=v_goals[2] then 0 else -0.25 end
    + case when grp='GOL' then 0.4 - 0.2*(case team when 'A' then v_goals[2] else v_goals[1] end) else 0 end
    + (random()+random()+random()-1.5)*0.9
    - case when not starter then 0.4 else 0 end;

  -- Votação: ~88% votam; cada um dá nota a 70%-100% dos colegas e escolhe Craque e Bola Murcha.
  for v_voter in select d.mem, d.uid from fdc_day d join public.rating_vote_participants vp on vp.membership_id=d.mem and vp.session_id=v_s
    where random() < 0.88 loop
    -- tudo calculado como postgres; só as chamadas do app rodam como o jogador
    select array_agg(d.mem), array_agg(least(10, greatest(2, round((6.3 + 1.05*d.perf + (random()+random()+random()-1.5)*1.1) * 2) / 2)))
    into v_tm, v_tn from fdc_day d join public.rating_vote_participants vp on vp.membership_id=d.mem and vp.session_id=v_s
    where d.mem<>v_voter.mem and random() < 0.7 + random()*0.3;
    select d.mem into v_craque from fdc_day d join public.rating_vote_participants vp on vp.membership_id=d.mem and vp.session_id=v_s
      where d.mem<>v_voter.mem order by d.perf + random()*0.9 desc limit 1;
    select d.mem into v_murcha from fdc_day d join public.rating_vote_participants vp on vp.membership_id=d.mem and vp.session_id=v_s
      where d.mem<>v_voter.mem and d.mem<>v_craque order by d.perf - random()*0.9 asc limit 1;
    perform set_config('request.jwt.claim.sub', v_voter.uid::text, true);
    perform set_config('role', 'authenticated', true);
    for i in 1..coalesce(cardinality(v_tm),0) loop
      perform public.cast_rating_vote(v_s, v_tm[i], v_tn[i]);
    end loop;
    begin perform public.set_rating_vote_awards(v_s, v_craque, v_murcha);
    exception when others then perform public.set_rating_vote_awards(v_s, v_craque, null); end;
    execute 'reset role';
  end loop;

  -- Prazo encerrado e publicação pelo admin.
  update public.rating_vote_sessions set closes_at = clock_timestamp() - interval '1 second' where id=v_s;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('role', 'authenticated', true);
  perform public.publish_rating_vote(v_s);
  execute 'reset role';

  update public.notification_events set status='suppressed' where pelada_id=v_pid and status='pending';
  select v_goals[1] || ' x ' || v_goals[2] || ' (' || count(*) || ' na súmula)' into v_res from fdc_day;
  return v_res;
end $f$;
