-- Minuto 91 / 084 (V10.0, REV-118): Seleção da Rodada em 4-3-3 OU 4-4-2, com posições específicas. Regras do fundador (04/11/2026):
--  * Vagas: GOL só GOL; lateral direita só LD; lateral esquerda só LE; zaga: 2 ZAG (qualquer um); meio: 4-3-3 = 1 VOL + 2 MEI,
--    4-4-2 = 2 VOL + 2 MEI (sigla exata); ataque: 3 (4-3-3) ou 2 (4-4-2) entre ATA, CA, PD e PE, em qualquer combinação.
--  * Formação: vale a que preenche mais vagas; depois a de maior soma de notas (equivale a comparar o 3º atacante com o 2º volante);
--    persistindo empate, a de mais gols na partida (dos jogadores escolhidos); persistindo, o 4-3-3.
--  * Quem tem só o setor (cadastro antigo, sem sigla) fica de fora, exceto goleiro (goleiro é sempre GOL).
--  * PD à direita, CA ao centro e PE à esquerda é só DESENHO no app; nunca critério de escolha.
-- Mínimo para existir Seleção (inalterado): 11 notas válidas e um GOL. Versionamento da 081 mantido (recálculo igual não cria versão).
-- Seleções já publicadas NÃO são recalculadas (decisão do fundador: "pode deixar como está").
-- Rollback: reaplicar compute_round_selection da 081 (colunas novas ficam sem uso).

alter table public.round_selection_players
 add column position_code text,
 add column slot_class text check (slot_class is null or slot_class in ('GOL','LD','LE','ZAG','VOL','MEI','ATT'));
grant select (position_code, slot_class) on public.round_selection_players to authenticated;
alter table public.round_selections add constraint round_selections_formation_check check (formation in ('4-3-3','4-4-2'));

-- Os escolhidos de uma formação (melhores de cada classe de vaga; ordem: nota, nº de votos, nota dos pares, id).
create function private.selection_pick(p_match uuid, p_formation text)
returns table(membership_id uuid, position_code text, official_position text, slot_class text, final_rating numeric, goals integer, votes integer, peer numeric)
language sql stable security definer set search_path = '' as $$
 with cand as (
  select r.membership_id, coalesce(p.position_code, case when r.position_snapshot = 'goalkeeper' then 'GOL' end) as code,
   r.final_rating, coalesce(r.goals, 0) as goals, r.numeric_rating_count as nc, r.peer_rating as peer
  from public.match_player_results r
  left join public.match_participants p on p.match_id = r.match_id and p.membership_id = r.membership_id
  where r.match_id = p_match and r.has_valid_rating and r.final_rating is not null),
 cls as (
  select *, case when code in ('PD','PE','ATA','CA') then 'ATT' when code in ('GOL','LD','LE','ZAG','VOL','MEI') then code end as k from cand),
 ranked as (
  select *, row_number() over (partition by k order by final_rating desc, nc desc, peer desc nulls last, membership_id) as rn from cls where k is not null),
 cap(k, c433, c442) as (values ('GOL',1,1),('LD',1,1),('LE',1,1),('ZAG',2,2),('VOL',1,2),('MEI',2,2),('ATT',3,2))
 select r.membership_id, r.code, case r.k when 'GOL' then 'goalkeeper' when 'ATT' then 'attacker' when 'VOL' then 'midfielder'
   when 'MEI' then 'midfielder' else 'defender' end, r.k, r.final_rating, r.goals, r.nc, r.peer
 from ranked r join cap c on c.k = r.k
 where r.rn <= case p_formation when '4-3-3' then c.c433 else c.c442 end
$$;
revoke all on function private.selection_pick(uuid, text) from public, anon, authenticated;

create or replace function private.compute_round_selection(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_sel uuid; v_cur public.round_selections; v_valid int; v_gk boolean; v_f text;
 n3 int; s3 numeric; g3 int; n4 int; s4 numeric; g4 int; v_sig text; v_cur_sig text; v_ver int;
begin
 select pelada_id into v_pelada from public.matches where id=p_match and status='finalized';
 if v_pelada is null then
  update public.round_selections set status='revoked' where match_id=p_match and status='published';
  return;
 end if;
 select count(*) into v_valid from public.match_player_results where match_id=p_match and has_valid_rating and final_rating is not null;
 select count(*), coalesce(sum(final_rating),0), coalesce(sum(goals),0), coalesce(bool_or(slot_class='GOL'),false)
  into n3, s3, g3, v_gk from private.selection_pick(p_match, '4-3-3');
 select count(*), coalesce(sum(final_rating),0), coalesce(sum(goals),0) into n4, s4, g4 from private.selection_pick(p_match, '4-4-2');

 select * into v_cur from public.round_selections where match_id=p_match and status='published';

 if v_valid < 11 or not v_gk then
  if found then
   update public.round_selections set status='invalidated', superseded_at=now() where id=v_cur.id;
   insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
   values(v_pelada,auth.uid(),'round_selection_invalidated',jsonb_build_object('match_id',p_match,'selection_id',v_cur.id,'version',v_cur.version));
  end if;
  return;
 end if;

 v_f := case when n3 > n4 then '4-3-3' when n4 > n3 then '4-4-2' when s3 > s4 then '4-3-3' when s4 > s3 then '4-4-2'
             when g4 > g3 then '4-4-2' else '4-3-3' end;

 select v_f || '|' || string_agg(x.membership_id::text || ':' || x.slot_class, ',' order by x.membership_id::text) into v_sig
 from private.selection_pick(p_match, v_f) x;
 if v_cur.id is not null then
  select v_cur.formation || '|' || string_agg(p.membership_id::text || ':' || coalesce(p.slot_class, p.slot_position), ',' order by p.membership_id::text) into v_cur_sig
  from public.round_selection_players p where p.selection_id = v_cur.id;
  if v_cur_sig is not distinct from v_sig then return; end if;
  update public.round_selections set status='superseded', superseded_at=now() where id=v_cur.id;
 end if;

 select coalesce(max(version),0)+1 into v_ver from public.round_selections where match_id=p_match;
 insert into public.round_selections(pelada_id,match_id,algorithm_version,version,formation) values(v_pelada,p_match,3,v_ver,v_f) returning id into v_sel;
 insert into public.round_selection_players(selection_id,membership_id,official_position,slot_position,final_rating,rank_order,position_code,slot_class)
 select v_sel, x.membership_id, x.official_position, x.official_position, x.final_rating,
  row_number() over (order by x.final_rating desc, x.votes desc, x.peer desc nulls last, x.membership_id)::int, x.position_code, x.slot_class
 from private.selection_pick(p_match, v_f) x;
 if v_cur.id is not null then
  insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
  values(v_pelada,auth.uid(),'round_selection_replaced',jsonb_build_object('match_id',p_match,'old_selection_id',v_cur.id,'new_version',v_ver));
 end if;
end $$;
