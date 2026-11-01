-- Minuto 91 / 054: V7.7, pergunta "Quem ficou para a resenha depois do jogo?" na votação pós-partida (052).
--
-- - Cada eleitor da sessão responde uma vez (pode mudar até o fim do prazo): marca, numa lista, quem ficou para a
--   resenha. Seleção múltipla; marcar a si mesmo é proibido; só participantes da sessão podem ser marcados.
--   Responder com a lista vazia = "ninguém ficou" (resposta válida). Não responder = sem informação.
-- - Apuração por jogador, na publicação (private.v77_resenha): eleitores válidos = quem respondeu, menos o próprio;
--   sim exige pelo menos 2 confirmações e maioria estrita; com 2 eleitores os dois precisam confirmar; com 1 só
--   eleitor (ou nenhum) o resultado é indeterminado (null) e não mexe no RES.
-- - Sigilo igual ao das notas: respostas no schema private, sem SELECT para ninguém; o admin vê só quantos
--   responderam. Prazo, elegibilidade e encerramento continuam os da 052 (private.rating_vote_lock_voter).
-- - Correção da súmula durante a votação: quem sai da súmula deixa de contar como eleitor e como marcado (a apuração
--   só considera participantes atuais da sessão).
-- Rollback: recriar get_rating_vote (052) a partir de private.get_rating_vote_v2 e compute_match_results a partir de
-- private.compute_match_results_v2; dropar private.rating_vote_resenha e public.set_rating_vote_resenha.

create table private.rating_vote_resenha (
 session_id uuid not null references public.rating_vote_sessions(id) on delete cascade,
 voter_membership_id uuid not null,
 present uuid[] not null,
 answered_at timestamptz not null default now(),
 primary key (session_id, voter_membership_id),
 check (not (voter_membership_id = any(present)))
);
revoke all on private.rating_vote_resenha from public, anon, authenticated;

alter table private.rating_vote_results add column resenha boolean, add column resenha_yes integer, add column resenha_voters integer;

-- p_present: membros que ficaram para a resenha (null apaga a resposta: volta a "não respondeu").
create function public.set_rating_vote_resenha(p_session uuid, p_present uuid[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_me uuid; v_match uuid; v_list uuid[];
begin
 v_me := private.rating_vote_lock_voter(p_session);
 if p_present is null then
  delete from private.rating_vote_resenha where session_id=p_session and voter_membership_id=v_me;
 else
  v_list := array(select distinct x from unnest(p_present) x where x is not null order by x);
  if v_me = any(v_list) then raise exception 'SELF_VOTE_NOT_ALLOWED'; end if;
  if exists(select 1 from unnest(v_list) x where not exists(select 1 from public.rating_vote_participants t
    where t.session_id=p_session and t.membership_id=x)) then raise exception 'TARGET_NOT_ELIGIBLE'; end if;
  insert into private.rating_vote_resenha(session_id, voter_membership_id, present)
  values(p_session, v_me, v_list)
  on conflict (session_id, voter_membership_id) do update set present=excluded.present, answered_at=now();
 end if;
 select match_id into v_match from public.rating_vote_sessions where id=p_session;
 return public.get_rating_vote(v_match);
end $$;

-- Estado da votação: o mesmo da 052 + a resposta do próprio eleitor e, para a gestão, quantos responderam.
alter function public.get_rating_vote(uuid) rename to get_rating_vote_v2;
alter function public.get_rating_vote_v2(uuid) set schema private;
create function public.get_rating_vote(p_match uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb; v_pelada uuid; v_me uuid; v_session uuid; v_mine uuid[]; v_answered boolean;
begin
 r := private.get_rating_vote_v2(p_match);
 v_session := (r->>'session_id')::uuid;
 if v_session is null then return r || jsonb_build_object('resenha_enabled', true); end if;
 select pelada_id into v_pelada from public.matches where id=p_match;
 v_me := private.my_membership(v_pelada);
 select present, true into v_mine, v_answered from private.rating_vote_resenha where session_id=v_session and voter_membership_id=v_me;
 return r || jsonb_build_object('resenha_enabled', true,
  'my_resenha', case when coalesce(v_answered,false) then to_jsonb(v_mine) end,
  'resenha_answers', case when (r->>'can_manage')::boolean then
   (select count(*) from private.rating_vote_resenha a join public.rating_vote_participants t
     on t.session_id=a.session_id and t.membership_id=a.voter_membership_id where a.session_id=v_session) end);
end $$;

-- Apuração da resenha da sessão publicada da partida (idempotente; só participantes atuais contam).
create function private.tally_rating_vote_resenha(p_session uuid) returns void
language sql security definer set search_path = '' as $$
 update private.rating_vote_results r set resenha_voters=x.voters, resenha_yes=x.yes,
  resenha=private.v77_resenha(x.yes, x.voters)
 from (
  select t.membership_id,
   count(a.*) filter (where a.voter_membership_id <> t.membership_id)::int voters,
   count(a.*) filter (where a.voter_membership_id <> t.membership_id and t.membership_id = any(a.present))::int yes
  from public.rating_vote_participants t
  left join (select a.* from private.rating_vote_resenha a join public.rating_vote_participants v
    on v.session_id=a.session_id and v.membership_id=a.voter_membership_id where a.session_id=p_session) a on true
  where t.session_id=p_session
  group by t.membership_id) x
 where r.session_id=p_session and r.membership_id=x.membership_id;
$$;

alter function private.compute_match_results(uuid,uuid) rename to compute_match_results_v2;
create function private.compute_match_results(p_match uuid, p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_s uuid;
begin
 perform private.compute_match_results_v2(p_match, p_session);
 if p_session is not null then return; end if; -- sessão antiga (013): sem pergunta de resenha
 select id into v_s from public.rating_vote_sessions where match_id=p_match and status='published';
 if v_s is null then return; end if;
 perform private.tally_rating_vote_resenha(v_s);
 update public.match_player_results m set resenha=r.resenha
 from private.rating_vote_results r where r.session_id=v_s and r.membership_id=m.membership_id and m.match_id=p_match;
end $$;

revoke all on function private.get_rating_vote_v2(uuid), private.tally_rating_vote_resenha(uuid),
 private.compute_match_results(uuid,uuid), private.compute_match_results_v2(uuid,uuid) from public, anon, authenticated;
revoke all on function public.set_rating_vote_resenha(uuid,uuid[]), public.get_rating_vote(uuid) from public, anon;
grant execute on function public.set_rating_vote_resenha(uuid,uuid[]), public.get_rating_vote(uuid) to authenticated;
