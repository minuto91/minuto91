-- Minuto 91 / 065: V8.5 — Central do Jogador (Etapas 27/28) e avisos por relevância (Etapa 29).
--
--  * Próxima Rodada: além das escalações antigas (planned_lineups), entram as rodadas pré-cadastradas da V8.5 em
--    que o jogador está na escalação PREVISTA (rascunho, data de hoje em diante), com data, horário, local, status e
--    time previsto. Previsto ≠ participação; não cria check-in. Canceladas não aparecem como próxima rodada.
--  * Avisos (sem spam): mudança de data/horário e cancelamento de rodada pré-cadastrada → só para quem está na
--    escalação prevista; escalação confirmada → só para quem está nela; ajuste manual → só para quem teve o time
--    mudado, entrou ou saiu. Uma notificação por pessoa e por versão (dedupe).
--  * Etapa 36 A: o aviso não compara versões publicamente; o destino mostra só a composição vigente.

alter function public.get_player_central() rename to get_player_central_v84;
alter function public.get_player_central_v84() set schema private;
revoke all on function private.get_player_central_v84() from public, anon, authenticated;

create function public.get_player_central() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := private.get_player_central_v84(); v_rounds jsonb;
begin
 select coalesce(jsonb_agg(r order by (r->>'scheduled_at')::timestamptz, r->>'match_id'), '[]'::jsonb) into v_rounds from (
  select jsonb_build_object('lineup_id', null, 'match_id', m.id, 'composition_id', m.composition_id, 'pelada_id', m.pelada_id,
   'pelada_name', p.name, 'label', coalesce(c.label, 'Rodada'), 'my_team', pp.team,
   'team_name', case pp.team when 'A' then m.team_a_name else m.team_b_name end,
   'opponent_name', case pp.team when 'A' then m.team_b_name else m.team_a_name end,
   'scheduled_at', m.played_at, 'location', p.location, 'status', m.status,
   'rescheduled', m.originally_scheduled_at is not null, 'planned_status', m.planned_status,
   'created_at', m.created_at) r
  from public.match_planned_players pp
  join public.pelada_memberships pm on pm.id = pp.membership_id and pm.user_id = auth.uid() and pm.status = 'active'
  join public.matches m on m.id = pp.match_id and m.status = 'draft' and m.composition_id is not null
   and private.pelada_local_date(m.pelada_id, m.played_at) >= private.pelada_today(m.pelada_id)
  join public.peladas p on p.id = m.pelada_id
  left join public.team_compositions c on c.id = m.composition_id) q;
 return v || jsonb_build_object('next_rounds', v_rounds || coalesce(v->'next_rounds', '[]'::jsonb));
end $$;
revoke all on function public.get_player_central() from public, anon;
grant execute on function public.get_player_central() to authenticated;

---------------------------------------------------------------------------------------------------
-- Avisos
---------------------------------------------------------------------------------------------------
create function private.notify_v85_from_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_match uuid := private.try_uuid(new.metadata->>'match_id'); v_comp uuid := private.try_uuid(new.metadata->>'composition_id');
 v_ver integer := (new.metadata->>'version')::integer; u uuid; v_payload jsonb;
begin
 if new.event_type in ('match_rescheduled','match_cancelled') and v_match is not null
   and exists(select 1 from public.matches where id=v_match and composition_id is not null) then
  v_payload := jsonb_build_object('pelada_id', new.pelada_id, 'match_id', v_match);
  for u in select distinct pm.user_id from public.match_planned_players pp join public.pelada_memberships pm on pm.id=pp.membership_id
    where pp.match_id=v_match and pm.user_id is not null and pm.status='active' and pm.user_id is distinct from new.actor_user_id loop
   perform private.notify(u, new.pelada_id, case new.event_type when 'match_rescheduled' then 'round_rescheduled' else 'round_cancelled' end,
    'essential', new.event_type||':'||new.id||':'||u, v_payload);
  end loop;
 elsif new.event_type = 'draw_confirmed' then
  for u in select distinct pm.user_id from public.team_composition_members cm
    join public.pelada_memberships pm on pm.id=cm.membership_id
    where cm.composition_id = any(array(select private.try_uuid(x) from jsonb_array_elements_text(new.metadata->'compositions') x))
     and cm.version_to is null and pm.user_id is not null and pm.status='active' and pm.user_id is distinct from new.actor_user_id loop
   perform private.notify(u, new.pelada_id, 'lineup_published', 'essential', 'lineup_published:'||new.id||':'||u,
    jsonb_build_object('pelada_id', new.pelada_id));
  end loop;
 elsif new.event_type = 'composition_changed' and v_comp is not null and v_ver is not null then
  -- Só quem mudou de time, entrou ou saiu nesta versão.
  for u in select distinct pm.user_id from public.team_composition_members cm join public.pelada_memberships pm on pm.id=cm.membership_id
    where cm.composition_id=v_comp and (cm.version_from=v_ver or cm.version_to=v_ver)
     and pm.user_id is not null and pm.status='active' and pm.user_id is distinct from new.actor_user_id
     and not exists(select 1 from public.team_composition_members a join public.team_composition_members b
       on b.composition_id=a.composition_id and b.pid=a.pid
       where a.composition_id=v_comp and a.pid=cm.pid and a.version_to=v_ver and b.version_from=v_ver and a.team=b.team) loop
   perform private.notify(u, new.pelada_id, 'lineup_changed', 'essential', 'lineup_changed:'||v_comp||':'||v_ver||':'||u,
    jsonb_build_object('pelada_id', new.pelada_id));
  end loop;
 end if;
 return new;
end $$;
revoke all on function private.notify_v85_from_audit() from public, anon, authenticated;
create trigger audit_notifications_v85 after insert on private.audit_events
 for each row execute function private.notify_v85_from_audit();
