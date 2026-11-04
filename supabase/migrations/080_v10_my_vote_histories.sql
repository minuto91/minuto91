-- Minuto 91 / 080 (V10.0, REV-148): "Ver meu histórico" sai da seção Votação da partida e passa para Meu Perfil.
-- Esta função só LISTA as partidas em que a própria pessoa registrou votos (nunca de outra pessoa, nunca aos
-- administradores); o conteúdo de cada partida continua vindo de get_my_rating_vote_history (053), sem alteração.
-- Não lê nem mostra notas: só partida, pelada e data. Rollback: drop function public.get_my_vote_histories().
create function public.get_my_vote_histories() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 return coalesce((
  select jsonb_agg(jsonb_build_object('match_id', x.match_id, 'played_at', x.played_at, 'pelada_id', x.pelada_id,
    'pelada_name', x.pelada_name, 'team_a_name', x.team_a_name, 'team_b_name', x.team_b_name) order by x.played_at desc)
  from (
   select distinct on (s.match_id) s.match_id, m.played_at, m.pelada_id, p.name pelada_name, m.team_a_name, m.team_b_name
   from private.rating_vote_versions v
   join public.pelada_memberships pm on pm.id = v.voter_membership_id and pm.user_id = auth.uid()
   join public.rating_vote_sessions s on s.id = v.session_id
   join public.matches m on m.id = s.match_id
   join public.peladas p on p.id = m.pelada_id
   order by s.match_id
  ) x), '[]'::jsonb);
end $$;
revoke all on function public.get_my_vote_histories() from public, anon;
grant execute on function public.get_my_vote_histories() to authenticated;
