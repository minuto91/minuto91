-- Minuto 91 / 056: V7.7, bloco B e itens de prêmios.
--
-- Seleção da Rodada (algorithm_version 2):
-- - 4-3-3 (1 goleiro, 4 defensores, 3 meias, 3 atacantes). Publica só com pelo menos 11 jogadores com nota
--   oficial válida, entre eles quem possa ocupar o gol (posição principal ou secundária confirmada).
-- - Posição secundária CONFIRMADA vale tanto quanto a principal. Fora delas não há adaptação (vaga sem
--   candidato fica vazia, decisão anterior mantida).
-- - Escolha GLOBAL: a combinação de jogadores e vagas que preenche mais vagas e, entre essas, tem a maior soma de
--   notas oficiais internas (sem arredondar), sem repetir jogador. Empates exatos: prevalece a ordem
--   determinística nota, quantidade de notas válidas, nota dos votos, id (a mesma de 016). A administração não
--   escolhe manualmente.
-- Posição secundária: o jogador indica (fica pendente) e a administração confirma ou recusa; a administração
-- também pode definir direto. Entra na súmula como retrato da partida (match_participants.secondary_position),
-- só se confirmada. Não altera o motor de OVR (que usa só a principal).
-- Prêmios:
-- - Garçom da Partida (match_garcom, V4.6) excluído por completo: não é mais concedido e os troféus históricos
--   ficam revogados (a linha fica para auditoria, mas não aparece nem conta em lugar nenhum).
-- - Prêmios do mês recalculados (correções, anulação, restauração): o mesmo vencedor reaproveita o registro
--   (revogado e reativado na mesma transação), sem duplicar e sem novo aviso; quem perde fica revogado
--   (histórico preservado). Empates continuam compartilhados.
-- Rollback: recriar compute_round_selection (016), grant_month_award (015), after_cards_updated e
-- grant_match_garcom (049); reativar os match_garcom revogados por esta migração (audit 'garcom_match_removed').

---------------------------------------------------------------------------------------------------
-- Posição secundária
---------------------------------------------------------------------------------------------------
alter table public.pelada_memberships
 add column secondary_position text check (secondary_position is null or secondary_position in ('goalkeeper','defender','midfielder','attacker')),
 add column secondary_status text check (secondary_status is null or secondary_status in ('pending','confirmed')),
 add column secondary_decided_by uuid,
 add column secondary_decided_at timestamptz,
 add constraint memberships_secondary_differs check (secondary_position is null or secondary_position <> preferred_position),
 add constraint memberships_secondary_status check ((secondary_position is null) = (secondary_status is null));

alter table public.match_participants
 add column secondary_position text check (secondary_position is null or secondary_position in ('goalkeeper','defender','midfielder','attacker'));

create function private.snapshot_secondary_position() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.membership_id is not null and (tg_op='INSERT' or new.membership_id is distinct from old.membership_id) then
  select case when m.secondary_status='confirmed' then m.secondary_position end into new.secondary_position
  from public.pelada_memberships m where m.id=new.membership_id;
 end if;
 if new.secondary_position = new.primary_position then new.secondary_position := null; end if;
 return new;
end $$;
create trigger participants_secondary_snapshot before insert or update of membership_id, primary_position
 on public.match_participants for each row execute function private.snapshot_secondary_position();

-- Jogador: indica (ou limpa) a secundária; fica pendente até a administração confirmar.
create function public.request_secondary_position(p_pelada uuid, p_position text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.pelada_memberships;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.pelada_memberships where pelada_id=p_pelada and user_id=auth.uid() and status='active' for update;
 if not found then raise exception 'ACTIVE_MEMBERSHIP_REQUIRED'; end if;
 if p_position is not null and p_position not in ('goalkeeper','defender','midfielder','attacker') then
  raise exception 'INVALID_POSITION'; end if;
 if p_position = v_m.preferred_position then raise exception 'SECONDARY_EQUALS_PRIMARY'; end if;
 if p_position is not distinct from v_m.secondary_position then return; end if;
 update public.pelada_memberships set secondary_position=p_position,
  secondary_status=case when p_position is null then null else 'pending' end,
  secondary_decided_by=null, secondary_decided_at=null where id=v_m.id;
 if p_position is not null then
  perform private.notify(a.user_id, p_pelada, 'position_change_requested', 'essential', 'secreq:'||v_m.id||':'||p_position||':'||a.user_id,
   jsonb_build_object('pelada_id',p_pelada,'membership_id',v_m.id,'secondary',true))
  from public.pelada_memberships a where a.pelada_id=p_pelada and a.status='active' and a.role='admin' and a.user_id is not null;
 end if;
end $$;

-- Administração: confirma/recusa o pedido ou define direto (p_position nulo limpa).
create function public.decide_secondary_position(p_membership uuid, p_position text, p_confirm boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.pelada_memberships;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.pelada_memberships where id=p_membership for update;
 if not found or not private.is_active_admin(v_m.pelada_id) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if p_position is not null and p_position not in ('goalkeeper','defender','midfielder','attacker') then
  raise exception 'INVALID_POSITION'; end if;
 if p_position = v_m.preferred_position then raise exception 'SECONDARY_EQUALS_PRIMARY'; end if;
 if p_confirm and p_position is not null then
  update public.pelada_memberships set secondary_position=p_position, secondary_status='confirmed',
   secondary_decided_by=auth.uid(), secondary_decided_at=now() where id=v_m.id;
 else
  update public.pelada_memberships set secondary_position=null, secondary_status=null,
   secondary_decided_by=auth.uid(), secondary_decided_at=now() where id=v_m.id;
 end if;
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),v_m.id,'secondary_position_decided',jsonb_build_object('position',
  case when p_confirm then p_position end,'requested',v_m.secondary_position));
end $$;

-- A posição principal mudou para o mesmo setor da secundária: a secundária deixa de existir.
create function private.clear_secondary_on_primary() returns trigger
language plpgsql set search_path = '' as $$
begin
 if new.secondary_position is not null and new.secondary_position = new.preferred_position then
  new.secondary_position := null; new.secondary_status := null;
 end if;
 return new;
end $$;
create trigger memberships_clear_secondary before update of preferred_position on public.pelada_memberships
 for each row execute function private.clear_secondary_on_primary();

---------------------------------------------------------------------------------------------------
-- Seleção da Rodada v2: otimização global
---------------------------------------------------------------------------------------------------
create or replace function private.compute_round_selection(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c_min_eligible constant integer := 11; v_pelada uuid; v_sel uuid;
 v_ids uuid[]; v_pri text[]; v_sec text[]; v_rat numeric[]; v_n int; i int; st int; g int; d int; m int; a int;
 v_fill int[]; v_sum numeric[]; v_choice int[]; nf int; ns numeric; bf int; bs numeric; bc int; opt int; slot text;
 v_cap int[] := array[1,4,3,3]; v_states int := 160; v_slot text; v_rank int := 0;
 v_secs text[] := array['goalkeeper','defender','midfielder','attacker'];
begin
 select pelada_id into v_pelada from public.matches where id=p_match and status='finalized';
 if v_pelada is null then
  delete from public.round_selections where match_id=p_match and status='published';
  return;
 end if;
 delete from public.round_selections where match_id=p_match;
 select array_agg(r.membership_id order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id),
  array_agg(r.position_snapshot order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id),
  array_agg(p.secondary_position order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id),
  array_agg(r.final_rating order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc nulls last, r.membership_id)
 into v_ids, v_pri, v_sec, v_rat
 from public.match_player_results r
 left join public.match_participants p on p.match_id=r.match_id and p.membership_id=r.membership_id
 where r.match_id=p_match and r.has_valid_rating and r.final_rating is not null;
 v_n := coalesce(cardinality(v_ids), 0);
 if v_n < c_min_eligible then return; end if;
 if not coalesce('goalkeeper' = any(v_pri) or 'goalkeeper' = any(v_sec), false) then return; end if;

 -- Programação dinâmica de trás para frente: estado = vagas usadas (g,d,m,a) = g*80 + d*16 + m*4 + a.
 -- dp[i][estado] = melhor (vagas preenchidas, soma) usando os jogadores i..n. Escolha: 0 fora, 1 principal,
 -- 2 secundária. Em empate exato vale a ordem: principal, secundária, fora (o jogador mais bem colocado entra).
 v_fill := array_fill(0, array[(v_n+1)*v_states]);
 v_sum := array_fill(0::numeric, array[(v_n+1)*v_states]);
 v_choice := array_fill(0, array[(v_n+1)*v_states]);
 for i in reverse v_n..1 loop
  for st in 0..v_states-1 loop
   g := st / 80; d := (st / 16) % 5; m := (st / 4) % 4; a := st % 4;
   bf := v_fill[i*v_states + st + 1]; bs := v_sum[i*v_states + st + 1]; bc := 0;
   for opt in reverse 2..1 loop
    slot := case opt when 1 then v_pri[i] else v_sec[i] end;
    if slot is null then continue; end if;
    nf := -1;
    if slot='goalkeeper' and g < 1 then nf := (g+1)*80 + d*16 + m*4 + a;
    elsif slot='defender' and d < 4 then nf := g*80 + (d+1)*16 + m*4 + a;
    elsif slot='midfielder' and m < 3 then nf := g*80 + d*16 + (m+1)*4 + a;
    elsif slot='attacker' and a < 3 then nf := g*80 + d*16 + m*4 + a + 1;
    end if;
    if nf < 0 then continue; end if;
    if v_fill[i*v_states + nf + 1] + 1 > bf or (v_fill[i*v_states + nf + 1] + 1 = bf and v_sum[i*v_states + nf + 1] + v_rat[i] >= bs) then
     bf := v_fill[i*v_states + nf + 1] + 1; bs := v_sum[i*v_states + nf + 1] + v_rat[i]; bc := opt;
    end if;
   end loop;
   v_fill[(i-1)*v_states + st + 1] := bf; v_sum[(i-1)*v_states + st + 1] := bs; v_choice[(i-1)*v_states + st + 1] := bc;
  end loop;
 end loop;

 insert into public.round_selections(pelada_id,match_id,algorithm_version) values(v_pelada,p_match,2) returning id into v_sel;
 st := 0;
 for i in 1..v_n loop
  opt := v_choice[(i-1)*v_states + st + 1];
  if opt = 0 then continue; end if;
  v_slot := case opt when 1 then v_pri[i] else v_sec[i] end;
  g := st / 80; d := (st / 16) % 5; m := (st / 4) % 4; a := st % 4;
  st := case v_slot when 'goalkeeper' then (g+1)*80 + d*16 + m*4 + a when 'defender' then g*80 + (d+1)*16 + m*4 + a
   when 'midfielder' then g*80 + d*16 + (m+1)*4 + a else g*80 + d*16 + m*4 + a + 1 end;
  v_rank := v_rank + 1;
  insert into public.round_selection_players(selection_id,membership_id,official_position,slot_position,final_rating,rank_order)
  values(v_sel, v_ids[i], v_pri[i], v_slot, v_rat[i], v_rank);
 end loop;
end $$;

---------------------------------------------------------------------------------------------------
-- Garçom da Partida: fora
---------------------------------------------------------------------------------------------------
create or replace function private.grant_match_garcom(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 null; -- V7.7: prêmio excluído
end $$;

create or replace function private.after_cards_updated(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid;
begin
 select pelada_id into v_pelada from public.matches where id=p_match;
 perform private.refresh_highlights(p_match);
 perform private.close_pending_months(v_pelada, p_match);
 perform private.after_rankings_updated(p_match);
end $$;

with g as (
 update public.awards set status='revoked', revoked_at=now() where award_type='match_garcom' and status='active' returning id)
insert into private.audit_events(event_type,metadata)
select 'garcom_match_removed', jsonb_build_object('awards', count(*)) from g;

---------------------------------------------------------------------------------------------------
-- Prêmios do mês sem duplicar nem reavisar
---------------------------------------------------------------------------------------------------
create or replace function private.grant_month_award(p_pelada uuid, p_season uuid, p_month date, p_type text,
 p_winners uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare w uuid; v_w uuid[];
begin
 -- RN-106 (021): aposentado não recebe prêmio novo.
 select coalesce(array_agg(m.id),'{}') into v_w from public.pelada_memberships m where m.id = any(p_winners) and m.status<>'retired';
 foreach w in array v_w loop
  update public.awards set status='active', revoked_at=null, is_shared=cardinality(v_w) > 1, season_id=p_season
  where id = (select id from public.awards where pelada_id=p_pelada and award_type=p_type and membership_id=w
   and period_month=p_month and status='revoked' and revoked_at=now() order by created_at desc limit 1);
  if not found and not exists(select 1 from public.awards where pelada_id=p_pelada and award_type=p_type
    and membership_id=w and period_month=p_month and status='active') then
   insert into public.awards(pelada_id,season_id,membership_id,award_type,period_month,is_shared)
   values(p_pelada, p_season, w, p_type, p_month, cardinality(v_w) > 1);
  end if;
 end loop;
end $$;

revoke all on function private.snapshot_secondary_position(), private.clear_secondary_on_primary() from public, anon, authenticated;
revoke all on function public.request_secondary_position(uuid,text), public.decide_secondary_position(uuid,text,boolean) from public, anon;
grant execute on function public.request_secondary_position(uuid,text), public.decide_secondary_position(uuid,text,boolean) to authenticated;

-- Sala de Troféus sem Garçom da Partida (os demais troféus e regras de 049 ficam iguais).
alter function public.get_player_career_summary(uuid) rename to get_player_career_summary_v46;
alter function public.get_player_career_summary_v46(uuid) set schema private;
create function public.get_player_career_summary(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := private.get_player_career_summary_v46(p_user);
begin
 if not coalesce((v->>'visible')::boolean, false) then return v; end if;
 return v || jsonb_build_object('trophies', (v->'trophies') - 'match_garcom',
  'peladas', coalesce((select jsonb_agg(e || jsonb_build_object('trophies', (e->'trophies') - 'match_garcom') order by o)
   from jsonb_array_elements(v->'peladas') with ordinality q(e, o)), '[]'::jsonb));
end $$;

alter function public.get_trophy_history(uuid,text,jsonb,integer) rename to get_trophy_history_v46;
alter function public.get_trophy_history_v46(uuid,text,jsonb,integer) set schema private;
create function public.get_trophy_history(p_user uuid, p_type text, p_after jsonb default null, p_limit integer default 20)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 if p_type = 'match_garcom' then raise exception 'INVALID_TROPHY'; end if;
 return private.get_trophy_history_v46(p_user, p_type, p_after, p_limit);
end $$;

revoke all on function private.get_player_career_summary_v46(uuid), private.get_trophy_history_v46(uuid,text,jsonb,integer)
 from public, anon, authenticated;
revoke all on function public.get_player_career_summary(uuid), public.get_trophy_history(uuid,text,jsonb,integer) from public, anon;
grant execute on function public.get_player_career_summary(uuid), public.get_trophy_history(uuid,text,jsonb,integer) to authenticated;
