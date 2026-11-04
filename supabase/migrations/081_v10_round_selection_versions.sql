-- Minuto 91 / 081 (V10.0, REV-101/104/105/106/110/112): versões da Seleção da Rodada.
-- Antes, recalcular a Seleção APAGAVA a anterior (unique por partida). Agora cada recálculo que muda os 11 (ou a
-- vaga de alguém) cria uma NOVA versão vigente e guarda a anterior como "superseded" (Substituída); quando a Seleção
-- deixa de ser válida, a vigente vira "invalidated" (Invalidada) — a anulação da partida continua usando "revoked".
-- Só 'published' conta para troféus, figurinhas e carreira (todas essas leituras já filtram status='published'),
-- então versões antigas nunca são contabilizadas de novo. Recalcular com o mesmo resultado não cria versão (idempotente).
-- O ALGORITMO não muda (mesmas vagas 1-4-3-3 por posição principal, mesma otimização e mesmos desempates da 075);
-- só o destino do resultado (versionar em vez de apagar). Não destrutiva: nenhuma Seleção existente é alterada.
-- Rollback: reaplicar a compute_round_selection da 075 e recriar o unique (match_id) depois de limpar versões antigas.

alter table public.round_selections
 add column version integer not null default 1,
 add column superseded_at timestamptz;
alter table public.round_selections drop constraint round_selections_match_id_key;
alter table public.round_selections add constraint round_selections_match_version_key unique (match_id, version);
alter table public.round_selections drop constraint round_selections_status_check;
alter table public.round_selections add constraint round_selections_status_check
 check (status in ('published','revoked','superseded','invalidated'));
-- No máximo UMA versão vigente por partida.
create unique index round_selections_one_published on public.round_selections(match_id) where status = 'published';

create or replace function private.compute_round_selection(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c_min_eligible constant integer := 11; v_pelada uuid; v_sel uuid;
 v_ids uuid[]; v_pri text[]; v_rat numeric[]; v_n int; i int; st int; g int; d int; m int; a int;
 v_fill int[]; v_sum numeric[]; v_choice int[]; nf int; bf int; bs numeric; bc int; opt int; slot text;
 v_states int := 160; v_slot text; v_rank int := 0;
 v_pick jsonb := '[]'::jsonb; v_sig text; v_cur public.round_selections; v_cur_sig text; v_ver int;
begin
 select pelada_id into v_pelada from public.matches where id=p_match and status='finalized';
 if v_pelada is null then
  -- Partida anulada/não finalizada: a vigente fica oculta ("revoked"), como na anulação (054).
  update public.round_selections set status='revoked' where match_id=p_match and status='published';
  return;
 end if;
 select array_agg(r.membership_id order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id),
  array_agg(r.position_snapshot order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id),
  array_agg(r.final_rating order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id)
 into v_ids, v_pri, v_rat
 from public.match_player_results r
 where r.match_id=p_match and r.has_valid_rating and r.final_rating is not null;
 v_n := coalesce(cardinality(v_ids), 0);

 if v_n >= c_min_eligible and coalesce('goalkeeper' = any(v_pri), false) then
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
  st := 0;
  for i in 1..v_n loop
   opt := v_choice[(i-1)*v_states + st + 1];
   if opt = 0 then continue; end if;
   v_slot := v_pri[i];
   g := st / 80; d := (st / 16) % 5; m := (st / 4) % 4; a := st % 4;
   st := case v_slot when 'goalkeeper' then (g+1)*80 + d*16 + m*4 + a when 'defender' then g*80 + (d+1)*16 + m*4 + a
    when 'midfielder' then g*80 + d*16 + (m+1)*4 + a else g*80 + d*16 + m*4 + a + 1 end;
   v_rank := v_rank + 1;
   v_pick := v_pick || jsonb_build_object('m', v_ids[i], 'pos', v_pri[i], 'slot', v_slot, 'rating', v_rat[i], 'rank', v_rank);
  end loop;
 end if;

 select * into v_cur from public.round_selections where match_id=p_match and status='published';

 if jsonb_array_length(v_pick) = 0 then
  -- Não há mais Seleção válida (menos de 11 notas ou sem goleiro): a vigente é invalidada, nunca apagada.
  if found then
   update public.round_selections set status='invalidated', superseded_at=now() where id=v_cur.id;
   insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
   values(v_pelada,auth.uid(),'round_selection_invalidated',jsonb_build_object('match_id',p_match,'selection_id',v_cur.id,'version',v_cur.version));
  end if;
  return;
 end if;

 select string_agg(x->>'m' || ':' || (x->>'slot'), ',' order by x->>'m') into v_sig from jsonb_array_elements(v_pick) x;
 if v_cur.id is not null then
  select string_agg(p.membership_id::text || ':' || p.slot_position, ',' order by p.membership_id::text) into v_cur_sig
  from public.round_selection_players p where p.selection_id = v_cur.id;
  if v_cur_sig is not distinct from v_sig then return; end if; -- mesmos 11 nas mesmas vagas: nada a versionar
  update public.round_selections set status='superseded', superseded_at=now() where id=v_cur.id;
 end if;

 select coalesce(max(version),0)+1 into v_ver from public.round_selections where match_id=p_match;
 insert into public.round_selections(pelada_id,match_id,algorithm_version,version) values(v_pelada,p_match,2,v_ver) returning id into v_sel;
 insert into public.round_selection_players(selection_id,membership_id,official_position,slot_position,final_rating,rank_order)
 select v_sel, (x->>'m')::uuid, x->>'pos', x->>'slot', (x->>'rating')::numeric, (x->>'rank')::int from jsonb_array_elements(v_pick) x;
 if v_cur.id is not null then
  insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
  values(v_pelada,auth.uid(),'round_selection_replaced',jsonb_build_object('match_id',p_match,'old_selection_id',v_cur.id,'new_version',v_ver));
 end if;
end $$;
