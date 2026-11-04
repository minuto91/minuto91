-- Minuto 91 / 076 (V10.0, REV-136): mínimo de sete votos recebidos por jogador avaliado (antes: bastava 1 colega + 1 adversário).
-- Um jogador só tem nota válida (q) se recebeu ≥ 7 votos no total, mantidos os demais critérios (≥ 1 colega e ≥ 1 adversário).
-- Seis votos = inválido. Não altera anonimato, janela de votação, extensão administrativa, Craque/Bola Murcha nem fórmulas.
-- Só vale para votações publicadas depois desta migração (resultados já publicados não são recalculados). Rollback: reaplicar 053/052.

create or replace function private.publish_rating_vote_core(p_session uuid, p_actor uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_s public.rating_vote_sessions; v_m public.matches; t text;
begin
 select * into v_s from public.rating_vote_sessions where id=p_session;
 if not found then raise exception 'SESSION_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_s.pelada_id for update;
 select * into v_s from public.rating_vote_sessions where id=p_session for update;
 if v_s.status = 'published' then return false; end if; -- idempotente
 if v_s.status = 'cancelled' then raise exception 'SESSION_CANCELLED'; end if;
 if clock_timestamp() < v_s.closes_at then raise exception 'VOTING_STILL_OPEN'; end if;
 select * into v_m from public.matches where id=v_s.match_id for update;
 if v_m.status <> 'finalized' then raise exception 'VOTING_SUSPENDED'; end if;

 -- Resultado da sessão: uma vez por sessão (retry não duplica; a restauração não passa por aqui).
 insert into private.rating_vote_results(session_id, membership_id, q, teammate_votes, opponent_votes)
 select p_session, t2.membership_id,
  case when count(r.*) >= 7 and count(r.*) filter (where vt.team=t2.team) > 0 and count(r.*) filter (where vt.team<>t2.team) > 0 then
   0.5*avg(r.rating) filter (where vt.team=t2.team) + 0.5*avg(r.rating) filter (where vt.team<>t2.team) end,
  count(r.*) filter (where vt.team=t2.team), count(r.*) filter (where vt.team<>t2.team)
 from public.rating_vote_participants t2
 left join private.rating_votes r on r.session_id=p_session and r.target_membership_id=t2.membership_id and r.invalidated_at is null
 left join public.rating_vote_participants vt on vt.session_id=p_session and vt.membership_id=r.voter_membership_id
 where t2.session_id=p_session
 group by t2.membership_id, t2.team
 on conflict (session_id, membership_id) do nothing;

 -- Craque / Bola Murcha: apuração independente, 3+ escolhas válidas por prêmio, empate = compartilhado.
 foreach t in array case when v_s.bola_murcha_enabled then array['craque','bola_murcha'] else array['craque'] end loop
  if (select count(*) from private.rating_vote_awards w join public.rating_vote_participants vt
      on vt.session_id=w.session_id and vt.membership_id=w.voter_membership_id
      where w.session_id=p_session and w.award_type=t and w.invalidated_at is null and w.target_membership_id is not null
       and exists(select 1 from public.rating_vote_participants x where x.session_id=p_session and x.membership_id=w.target_membership_id)) >= 3
     and not exists(select 1 from public.awards a where a.match_id=v_s.match_id and a.status='active'
      and a.award_type=case t when 'craque' then 'match_craque' else 'bola_murcha' end) then
   insert into public.awards(pelada_id,match_id,season_id,membership_id,award_type,votes_count,is_shared)
   with votes as (select w.target_membership_id m, count(*)::int c from private.rating_vote_awards w
     join public.rating_vote_participants vt on vt.session_id=w.session_id and vt.membership_id=w.voter_membership_id
     where w.session_id=p_session and w.award_type=t and w.invalidated_at is null and w.target_membership_id is not null
      and exists(select 1 from public.rating_vote_participants x where x.session_id=p_session and x.membership_id=w.target_membership_id)
     group by w.target_membership_id),
   top as (select * from votes where c=(select max(c) from votes))
   select v_s.pelada_id, v_s.match_id, v_m.season_id, top.m,
    case t when 'craque' then 'match_craque' else 'bola_murcha' end, top.c, (select count(*) from top) > 1
   from top on conflict do nothing;
  end if;
 end loop;

 update public.rating_vote_sessions set status='published', published_by=p_actor, published_at=now(),
  published_sheet_version=v_m.sheet_version where id=p_session;
 if to_regclass('private.rating_vote_reopenings') is not null then
  execute 'update private.rating_vote_reopenings set closed_at=now() where session_id=$1 and closed_at is null' using p_session;
 end if;
 perform private.compute_match_results(v_s.match_id, null);
 perform set_config('minuto91.rating_event', 'votes_published', true);
 perform private.after_match_finalized(v_s.match_id);
 perform set_config('minuto91.rating_event', '', true);
 perform private.notify(pm.user_id, v_s.pelada_id, 'result_published', 'essential', 'rvpub:'||p_session||':'||pm.user_id,
  jsonb_build_object('pelada_id',v_s.pelada_id,'match_id',v_s.match_id))
 from public.rating_vote_participants t2 join public.pelada_memberships pm on pm.id=t2.membership_id
 where t2.session_id=p_session and pm.user_id is not null and pm.status='active';
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_s.pelada_id,p_actor,'rating_vote_published',jsonb_build_object('session_id',p_session,'match_id',v_s.match_id,
  'automatic', p_actor is null,
  'valid_players',(select count(*) from private.rating_vote_results where session_id=p_session and q is not null),
  'insufficient_players',(select count(*) from private.rating_vote_results where session_id=p_session and q is null)));
 -- Contas já excluídas definitivamente: o voto individual não tem mais fundamento de retenção.
 perform set_config('minuto91.vote_purge','on',true);
 delete from private.rating_vote_versions v using public.pelada_memberships pm
  where v.session_id=p_session and pm.id=v.voter_membership_id and pm.user_id is null;
 delete from private.rating_votes v using public.pelada_memberships pm
  where v.session_id=p_session and pm.id=v.voter_membership_id and pm.user_id is null;
 delete from private.rating_vote_awards v using public.pelada_memberships pm
  where v.session_id=p_session and pm.id=v.voter_membership_id and pm.user_id is null;
 delete from private.rating_vote_progress v using public.pelada_memberships pm
  where v.session_id=p_session and pm.id=v.voter_membership_id and pm.user_id is null;
 perform set_config('minuto91.vote_purge','',true);
 return true;
end $$;
