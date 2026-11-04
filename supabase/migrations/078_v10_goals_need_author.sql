-- Minuto 91 / 078 (V10.0, REV-138): todo gol precisa de autor identificado antes de publicar.
-- Gol sem autor e gol contra sem o jogador adversário passam de aviso a BLOQUEIO na revisão da súmula (só rascunho;
-- súmulas já publicadas e suas correções não mudam). A tela já cria um registro por gol do placar (autor ou gol contra).
-- Rollback: reaplicar get_match_sheet_review da 063.
create or replace function public.get_match_sheet_review(p_match uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v public.matches; v_err jsonb := '[]'::jsonb; v_warn jsonb := '[]'::jsonb; v_un integer; v_na integer; v_nb integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v from public.matches where id=p_match;
 if not found or not private.is_active_staff(v.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select count(*) filter (where team='A'), count(*) filter (where team='B') into v_na, v_nb from public.match_participants where match_id=p_match;
 if v.status <> 'draft' then v_err := v_err || '"MATCH_NOT_DRAFT"'::jsonb; end if;
 if v_na = 0 or v_nb = 0 then v_err := v_err || '"TEAMS_INCOMPLETE"'::jsonb; end if;
 if private.pelada_local_date(v.pelada_id, v.played_at) > private.pelada_today(v.pelada_id) then v_err := v_err || '"MATCH_IN_FUTURE"'::jsonb; end if;
 if exists(select 1 from public.match_planned_players where match_id=p_match) and v.participation_confirmed_at is null then
  v_err := v_err || '"PARTICIPATION_NOT_CONFIRMED"'::jsonb; end if;
 if exists(select 1 from public.match_participants p where p.match_id=p_match and p.membership_id is not null
   and not exists(select 1 from public.pelada_memberships m where m.id=p.membership_id and m.status='active')) then
  v_err := v_err || '"PARTICIPANT_INELIGIBLE"'::jsonb; end if;
 select coalesce(sum(quantity),0) into v_un from public.match_events where match_id=p_match and event_type='unattributed_goal';
 if v_un > 0 then v_err := v_err || '"UNATTRIBUTED_GOALS"'::jsonb; end if;
 if exists(select 1 from public.match_events where match_id=p_match and event_type='own_goal' and participant_id is null) then
  v_err := v_err || '"OWN_GOAL_WITHOUT_PLAYER"'::jsonb; end if;
 if v.team_a_score + v.team_b_score > 0 and not exists(select 1 from public.match_events where match_id=p_match and event_type='assist') then
  v_warn := v_warn || '{"code":"NO_ASSISTS"}'::jsonb; end if;
 if abs(v_na - v_nb) > 1 then v_warn := v_warn || jsonb_build_object('code','TEAM_SIZES_DIFFER','a',v_na,'b',v_nb); end if; -- informativo
 return jsonb_build_object('match_id', p_match, 'draft_version', v.draft_version, 'team_a_score', v.team_a_score,
  'team_b_score', v.team_b_score, 'participants_a', v_na, 'participants_b', v_nb,
  'blocking', v_err, 'warnings', v_warn, 'can_publish', jsonb_array_length(v_err) = 0);
end $$;
