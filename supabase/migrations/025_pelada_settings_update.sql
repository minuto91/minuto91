-- Minuto 91 / 025: admin changes the pelada settings (Doc 02 RN-028, RN-030, RN-049..052; Doc 03 12.5).
-- Only the admin. Changes apply to FUTURE voting sessions only: an open session keeps the
-- configuration frozen when it was opened (010 copies it into voting_sessions).
-- Bola Murcha is a Premium feature: switching it requires Premium (active, trial or beta).
-- minimum_numeric_ratings null = rate every colleague (except "Não vi jogar"), the default.
-- The timezone is intentionally not editable here (it moves month/season boundaries).

create function public.update_pelada_settings(p_pelada uuid, p_voting_duration_minutes integer,
 p_bola_murcha_enabled boolean, p_minimum_numeric_ratings integer default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_s public.pelada_settings;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform 1 from public.peladas where id=p_pelada for update;
 if not found then raise exception 'PELADA_NOT_FOUND'; end if;
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if p_voting_duration_minutes is null or p_voting_duration_minutes not in (120,240,360) then
  raise exception 'INVALID_VOTING_DURATION'; end if;
 if p_bola_murcha_enabled is null then raise exception 'INVALID_SETTINGS'; end if;
 if p_minimum_numeric_ratings is not null and p_minimum_numeric_ratings not between 1 and 99 then
  raise exception 'INVALID_MINIMUM_RATINGS'; end if;
 select * into v_s from public.pelada_settings where pelada_id=p_pelada for update;
 if not found then raise exception 'PELADA_NOT_FOUND'; end if;
 if p_bola_murcha_enabled is distinct from v_s.bola_murcha_enabled
    and not private.pelada_has_premium(p_pelada) then
  raise exception 'PREMIUM_REQUIRED'; end if;

 update public.pelada_settings set voting_duration_minutes=p_voting_duration_minutes,
  bola_murcha_enabled=p_bola_murcha_enabled, minimum_numeric_ratings=p_minimum_numeric_ratings
 where pelada_id=p_pelada;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'settings_updated',jsonb_build_object(
  'before',jsonb_build_object('voting_duration_minutes',v_s.voting_duration_minutes,
   'bola_murcha_enabled',v_s.bola_murcha_enabled,'minimum_numeric_ratings',v_s.minimum_numeric_ratings),
  'after',jsonb_build_object('voting_duration_minutes',p_voting_duration_minutes,
   'bola_murcha_enabled',p_bola_murcha_enabled,'minimum_numeric_ratings',p_minimum_numeric_ratings)));
end $$;

revoke all on function public.update_pelada_settings(uuid,integer,boolean,integer) from public,anon;
grant execute on function public.update_pelada_settings(uuid,integer,boolean,integer) to authenticated;
