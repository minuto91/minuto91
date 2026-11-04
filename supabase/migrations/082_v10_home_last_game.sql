-- Minuto 91 / 082 (V10.0, REV-057/063-074): o Último Jogo da tela Início olha TODAS as peladas do jogador.
-- get_my_home_last_game() devolve a partida oficial concluída (finalizada) mais recente entre as peladas em que a
-- pessoa é membro ativo — canceladas, anuladas, rascunhos e futuras ficam de fora. Se a pessoa não entrou em campo,
-- a partida aparece mesmo assim com participation = 'listed' (estava na escalação prevista, sem entrada confirmada)
-- ou 'none'; nesses casos não há time, estatística nem nota (nunca se presume participação). A nota só vai quando a
-- votação foi publicada (o app decide pelo estado da sessão, como já fazia). Só leitura; não altera regras nem dados.
-- Rollback: drop function public.get_my_home_last_game().
create function public.get_my_home_last_game() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_m public.matches; v_mem public.pelada_memberships; v_part public.match_participants; v_r public.match_player_results;
 v_sess text; v_legacy boolean; v_saves integer; v_pel text; v_how text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select m.* into v_m from public.matches m
 where m.status = 'finalized' and exists(select 1 from public.pelada_memberships x
   where x.pelada_id = m.pelada_id and x.user_id = auth.uid() and x.status = 'active')
 order by m.played_at desc, m.id desc limit 1;
 if not found then return jsonb_build_object('game', null); end if;
 select * into v_mem from public.pelada_memberships where pelada_id = v_m.pelada_id and user_id = auth.uid() and status = 'active';
 select name into v_pel from public.peladas where id = v_m.pelada_id;
 select * into v_part from public.match_participants where match_id = v_m.id and membership_id = v_mem.id;
 if found then
  v_how := 'played';
  select * into v_r from public.match_player_results where match_id = v_m.id and membership_id = v_mem.id;
  select hard_saves into v_saves from public.match_keeper_saves where match_id = v_m.id and participant_id = v_part.id;
 elsif exists(select 1 from public.match_planned_players pp where pp.match_id = v_m.id and pp.membership_id = v_mem.id) then
  v_how := 'listed';
 else
  v_how := 'none';
 end if;
 select status into v_sess from public.rating_vote_sessions where match_id = v_m.id;
 v_legacy := exists(select 1 from public.voting_sessions where match_id = v_m.id and status = 'finalized');
 return jsonb_build_object('game', jsonb_build_object(
  'match_id', v_m.id, 'played_at', v_m.played_at, 'pelada_id', v_m.pelada_id, 'pelada_name', v_pel,
  'team_a_name', v_m.team_a_name, 'team_b_name', v_m.team_b_name, 'team_a_color', v_m.team_a_color, 'team_b_color', v_m.team_b_color,
  'team_a_score', v_m.team_a_score, 'team_b_score', v_m.team_b_score,
  'participation', v_how,
  'my_team', case when v_how = 'played' then v_part.team end,
  'position', case when v_how = 'played' then v_part.primary_position end,
  'goals', v_r.goals, 'assists', v_r.assists, 'red_cards', v_r.red_cards, 'hard_saves', v_saves,
  'final_rating', v_r.final_rating, 'has_valid_rating', coalesce(v_r.has_valid_rating, false),
  'rating_session_status', v_sess, 'legacy_finalized', v_legacy));
end $$;
revoke all on function public.get_my_home_last_game() from public, anon;
grant execute on function public.get_my_home_last_game() to authenticated;
