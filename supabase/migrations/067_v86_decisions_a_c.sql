-- Minuto 91 / 067: V8.6, decisões do produto sobre as pendências A e C (docs/V8.6_IMPLEMENTACAO.md §4).
--  A (G03): empate completo na formação de candidatos desempata por MAIS PARTIDAS na temporada e, persistindo,
--     por ENTRADA MAIS ANTIGA na pelada. Só se ainda empatar (mesma data de entrada) o fluxo continua bloqueado.
--  C (G10): retificação pós-publicação feita pelo admin: refaz a apuração com os votos já dados (último turno com votos),
--     contando só candidatos que continuam válidos; se o vencedor mudar, o troféu antigo é revogado e o novo concedido,
--     com trilha. Nada é alterado sem a ação do admin.
--  B (F04, ordem dos atributos e passo do admin): adiado para a próxima Rev; continua bloqueado (tie_blocked).
-- Rollback: restaurar private.craque_top_group da 063 e dropar public.rectify_season_craque.

create or replace function private.craque_top_group(p_season uuid, p_mode text, p_excl uuid[]) returns uuid[]
language sql stable security definer set search_path = '' as $$
 with tot as (select count(*)::int n from public.matches where season_id = p_season and status = 'finalized'),
 b as (
  select c.membership_id, c.overall ovr, pm.joined_at jn,
   (select count(*) from public.match_participants x join public.matches m on m.id = x.match_id
    where m.season_id = p_season and m.status = 'finalized' and x.membership_id = c.membership_id)::int played,
   coalesce((select sum(r.goals) from public.match_player_results r join public.matches m on m.id = r.match_id
    where m.season_id = p_season and m.status = 'finalized' and r.membership_id = c.membership_id), 0)::int goals,
   (select count(*) from public.awards a where a.season_id = p_season and a.membership_id = c.membership_id
    and a.award_type = 'match_craque' and a.status = 'active')::int craques
  from public.player_cards c join public.pelada_memberships pm on pm.id = c.membership_id
  where c.season_id = p_season and not c.is_provisional),
 f as (
  select b.membership_id, b.ovr, b.played, b.jn,
   case p_mode when 'goals' then b.goals when 'craque' then b.craques else 0 end k1
  from b cross join tot
  where not (b.membership_id = any(p_excl))
   and case p_mode when 'goals' then b.goals >= 1 when 'craque' then b.craques >= 1
        else tot.n > 0 and b.played * 2 >= tot.n end)
 select (select array_agg(f.membership_id order by f.membership_id) from f
  where (f.k1, f.ovr, f.played, f.jn) = (select f2.k1, f2.ovr, f2.played, f2.jn from f f2
   order by f2.k1 desc, f2.ovr desc, f2.played desc, f2.jn asc limit 1));
$$;
revoke all on function private.craque_top_group(uuid,text,uuid[]) from public, anon, authenticated;

create function public.rectify_season_craque(p_season uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.seasons; p private.season_craque_polls; v_set jsonb; v_round integer; v_pool uuid[]; v_tally jsonb;
 v_leaders uuid[]; v_tb jsonb; v_new uuid; v_cur uuid[];
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
 select * into s from public.seasons where id = p_season;
 if not found or not private.is_active_member(s.pelada_id) then raise exception 'SEASON_NOT_FOUND'; end if;
 if not private.is_active_admin(s.pelada_id) then raise exception 'ADMIN_REQUIRED' using errcode = '42501'; end if;
 perform private.craque_sync(p_season);
 select * into p from private.season_craque_polls where season_id = p_season and status <> 'cancelled' for update;
 if not found or p.status <> 'published' or not p.rectification_pending then raise exception 'NOTHING_TO_RECTIFY'; end if;
 v_set := private.craque_candidate_set(p_season);
 if v_set->>'blocked' is not null then raise exception 'CANDIDATE_TIE_UNRESOLVED'; end if;
 select coalesce(array_agg((e->>'membership_id')::uuid), '{}') into v_cur from jsonb_array_elements(v_set->'candidates') e;
 v_round := case when exists(select 1 from private.season_craque_ballots where poll_id = p.id and round = 2) then 2 else 1 end;
 v_pool := case when v_round = 2 then array(select u from unnest(p.r2_finalists) u where u = any(v_cur)) else v_cur end;
 if cardinality(v_pool) = 0 then raise exception 'NOTHING_TO_RECTIFY'; end if;
 select jsonb_object_agg(u.id::text, (select count(*) from private.season_craque_ballots b
   where b.poll_id = p.id and b.round = v_round and b.candidate_membership_id = u.id)) into v_tally from unnest(v_pool) u(id);
 select array_agg(u.id order by u.id) into v_leaders from unnest(v_pool) u(id)
 where (v_tally->>(u.id::text))::int = (select max(x::int) from jsonb_each_text(v_tally) t(k, x));
 if cardinality(v_leaders) = 1 then v_new := v_leaders[1];
 else
  v_tb := private.craque_tiebreak(p_season, v_leaders);
  if (v_tb->>'blocked')::boolean then raise exception 'TIE_UNRESOLVED'; end if; -- F04 adiado (B): nada muda
  v_new := (v_tb->>'winner')::uuid;
 end if;
 if v_new is distinct from p.winner_membership_id then
  update public.awards set status = 'revoked', revoked_at = now()
  where season_id = p_season and award_type = 'season_craque' and status = 'active';
  insert into public.awards(pelada_id, season_id, membership_id, award_type, is_shared)
  values(s.pelada_id, p_season, v_new, 'season_craque', false);
 end if;
 update private.season_craque_polls set winner_membership_id = v_new, candidates = v_set->'candidates',
  rectification_pending = false where id = p.id;
 perform private.craque_log(s.pelada_id, p.id, 'rectified',
  jsonb_build_object('from', p.winner_membership_id, 'to', v_new, 'round', v_round), auth.uid());
 insert into private.audit_events(pelada_id, actor_user_id, event_type, metadata)
 values(s.pelada_id, auth.uid(), 'season_craque_rectified', jsonb_build_object('season_id', p_season, 'poll_id', p.id));
 return jsonb_build_object('winner_membership_id', v_new, 'changed', v_new is distinct from p.winner_membership_id);
end $$;
revoke all on function public.rectify_season_craque(uuid) from public, anon;
grant execute on function public.rectify_season_craque(uuid) to authenticated;
