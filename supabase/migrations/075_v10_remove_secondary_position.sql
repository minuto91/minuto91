-- Minuto 91 / 075 (V10.0, REV-147): remoção definitiva da segunda posição.
-- Decisão do fundador (04/11/2026): cada jogador tem só a posição principal; o cálculo da Seleção da Rodada
-- deixa de considerar posição secundária. NÃO destrutiva: as colunas antigas (pelada_memberships.secondary_*,
-- match_participants.secondary_position) e private.match_secondary_confirmations ficam intocadas como
-- registro histórico, sem leitura nem escrita por funções e sem promoção a posição principal.
-- Seleções já publicadas NÃO são recalculadas (são histórico oficial); passam a valer a regra nova só nas
-- próximas publicações/recálculos. Rollback: reaplicar 056/058 (funções) — não há dado apagado.

-- 1) Fim dos pedidos/decisões/confirmações de secundária
drop function if exists public.request_secondary_position(uuid, text);
drop function if exists public.decide_secondary_position(uuid, text, boolean);
drop function if exists public.set_match_secondary_played(uuid, uuid, boolean);

drop trigger if exists memberships_clear_secondary on public.pelada_memberships;
drop function if exists private.clear_secondary_on_primary();
-- O gatilho de retrato da súmula vira inofensivo: nada mais preenche match_participants.secondary_position.
create or replace function private.snapshot_secondary_position() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 new.secondary_position := null;
 return new;
end $$;

-- 2) Seleção da Rodada: só a posição principal (o retrato da partida) ocupa as vagas 1-4-3-3.
--    Mesma otimização global da 056 (vagas preenchidas, depois soma das notas; empate pela ordem); a única
--    mudança é que a escolha "2 = secundária" deixou de existir.
create or replace function private.compute_round_selection(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c_min_eligible constant integer := 11; v_pelada uuid; v_sel uuid;
 v_ids uuid[]; v_pri text[]; v_rat numeric[]; v_n int; i int; st int; g int; d int; m int; a int;
 v_fill int[]; v_sum numeric[]; v_choice int[]; nf int; bf int; bs numeric; bc int; opt int; slot text;
 v_states int := 160; v_slot text; v_rank int := 0;
begin
 select pelada_id into v_pelada from public.matches where id=p_match and status='finalized';
 if v_pelada is null then
  delete from public.round_selections where match_id=p_match and status='published';
  return;
 end if;
 delete from public.round_selections where match_id=p_match;
 select array_agg(r.membership_id order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id),
  array_agg(r.position_snapshot order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id),
  array_agg(r.final_rating order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id)
 into v_ids, v_pri, v_rat
 from public.match_player_results r
 where r.match_id=p_match and r.has_valid_rating and r.final_rating is not null;
 v_n := coalesce(cardinality(v_ids), 0);
 if v_n < c_min_eligible then return; end if;
 if not coalesce('goalkeeper' = any(v_pri), false) then return; end if;

 v_fill := array_fill(0, array[(v_n+1)*v_states]);
 v_sum := array_fill(0::numeric, array[(v_n+1)*v_states]);
 v_choice := array_fill(0, array[(v_n+1)*v_states]);
 for i in reverse v_n..1 loop
  for st in 0..v_states-1 loop
   g := st / 80; d := (st / 16) % 5; m := (st / 4) % 4; a := st % 4;
   bf := v_fill[i*v_states + st + 1]; bs := v_sum[i*v_states + st + 1]; bc := 0;
   opt := 1;
   slot := v_pri[i];
   nf := -1;
   if slot='goalkeeper' and g < 1 then nf := (g+1)*80 + d*16 + m*4 + a;
   elsif slot='defender' and d < 4 then nf := g*80 + (d+1)*16 + m*4 + a;
   elsif slot='midfielder' and m < 3 then nf := g*80 + d*16 + (m+1)*4 + a;
   elsif slot='attacker' and a < 3 then nf := g*80 + d*16 + m*4 + a + 1;
   end if;
   if nf >= 0 and (v_fill[i*v_states + nf + 1] + 1 > bf or (v_fill[i*v_states + nf + 1] + 1 = bf and v_sum[i*v_states + nf + 1] + v_rat[i] >= bs)) then
    bf := v_fill[i*v_states + nf + 1] + 1; bs := v_sum[i*v_states + nf + 1] + v_rat[i]; bc := opt;
   end if;
   v_fill[(i-1)*v_states + st + 1] := bf; v_sum[(i-1)*v_states + st + 1] := bs; v_choice[(i-1)*v_states + st + 1] := bc;
  end loop;
 end loop;

 insert into public.round_selections(pelada_id,match_id,algorithm_version) values(v_pelada,p_match,2) returning id into v_sel;
 st := 0;
 for i in 1..v_n loop
  opt := v_choice[(i-1)*v_states + st + 1];
  if opt = 0 then continue; end if;
  v_slot := v_pri[i];
  g := st / 80; d := (st / 16) % 5; m := (st / 4) % 4; a := st % 4;
  st := case v_slot when 'goalkeeper' then (g+1)*80 + d*16 + m*4 + a when 'defender' then g*80 + (d+1)*16 + m*4 + a
   when 'midfielder' then g*80 + d*16 + (m+1)*4 + a else g*80 + d*16 + m*4 + a + 1 end;
  v_rank := v_rank + 1;
  insert into public.round_selection_players(selection_id,membership_id,official_position,slot_position,final_rating,rank_order)
  values(v_sel, v_ids[i], v_pri[i], v_slot, v_rat[i], v_rank);
 end loop;
end $$;

-- 3) Pendências administrativas sem "secondary_requests"
create or replace function public.get_my_admin_pending() returns jsonb
language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_agg(x order by x->>'pelada_name'), '[]'::jsonb) from (
  select jsonb_strip_nulls(jsonb_build_object('pelada_id',p.id,'pelada_name',p.name,
   'drafts', nullif((select count(*) from public.matches m where m.pelada_id=p.id and m.status='draft'
      and private.pelada_local_date(p.id, m.played_at) < private.pelada_today(p.id)),0),
   'keeper_claims', nullif((select count(*) from public.match_keeper_save_claims c where c.pelada_id=p.id and c.status='pending'),0),
   'position_requests', nullif((select count(*) from public.position_change_requests r where r.pelada_id=p.id and r.status='pending'),0),
   'billing_pending', case when pm.role='admin' then nullif((select count(*) from public.pelada_memberships x
      where x.pelada_id=p.id and x.status='active' and x.billing_class='pending'),0) end,
   'votes_suspended', nullif((select count(*) from private.rating_vote_suspensions s join public.rating_vote_sessions v on v.id=s.session_id
      where v.pelada_id=p.id and s.resolved_at is null),0))) x
  from public.pelada_memberships pm join public.peladas p on p.id=pm.pelada_id
  where pm.user_id=auth.uid() and pm.status='active' and pm.role in ('admin','assistant')) t(x)
 where (select count(*) from jsonb_object_keys(x)) > 2;
$$;
