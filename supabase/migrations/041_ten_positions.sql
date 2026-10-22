-- Minuto 91 / 041: V4.3 phase 2, the ten official positions.
--
--   Goleiro: GOL · Defesa: ZAG, LD, LE · Meio-campo: VOL, MEI · Ataque: CA, PD, PE, ATA
--
-- Model (nothing historical is rewritten, formulas untouched):
-- - pelada_memberships.preferred_position stays the SECTOR (goalkeeper/defender/midfielder/attacker). It is
--   what every official formula, Card weight, rating base and Seleção da Rodada slot already uses, so the
--   formulas keep working by sector (compatibility mapping of the prompt, 6.6).
-- - pelada_memberships.position_code is the specific position (one of the ten). Its sector must match
--   preferred_position. NULL = legacy record (Defensor / Meio-campista / Atacante not yet refined).
-- - Migration: Goleiro -> GOL automatically. Defensor, Meio-campista and Atacante are NOT guessed: they stay
--   legacy until the player chooses (ZAG/LD/LE, VOL/MEI, CA/PD/PE/ATA); the app shows a discreet notice.
-- - Every function that receives a position (create_pelada, join_pelada, set_my_position, the match sheet)
--   accepts the ten codes and, for old app versions, the four legacy sectors. A trigger normalizes: a code
--   fills position_code and the sector; a legacy sector keeps the code when the sector is the same.
-- - match_participants.position_code: snapshot of the specific position when the player enters a sheet
--   (members: their code at that time; guests: the code chosen). Old sheets keep NULL (sector only):
--   positions of finished matches are never changed.
-- - Draws and lineups count each specific position separately; legacy members form their own group per
--   sector ('defender', 'midfielder', 'attacker'), never assumed to be any specific position (8.5).
-- - Permissions are unchanged: each player changes only their own position (set_my_position), which now
--   records the previous and the new value in the audit.

create function private.position_codes() returns text[]
language sql immutable set search_path = '' as $$
 select array['GOL','ZAG','LD','LE','VOL','MEI','CA','PD','PE','ATA'];
$$;

alter table public.pelada_memberships add column position_code text
 check (position_code is null or position_code in ('GOL','ZAG','LD','LE','VOL','MEI','CA','PD','PE','ATA'));
update public.pelada_memberships set position_code='GOL' where preferred_position='goalkeeper';
alter table public.pelada_memberships add constraint memberships_position_code_sector
 check (position_code is null or private.position_sector(position_code) = preferred_position);

alter table public.match_participants add column position_code text
 check (position_code is null or position_code in ('GOL','ZAG','LD','LE','VOL','MEI','CA','PD','PE','ATA'));
alter table public.match_participants add constraint participants_position_code_sector
 check (position_code is null or private.position_sector(position_code) = primary_position);

-- Accepts the ten codes and the four legacy sectors (old app versions).
create or replace function private.valid_position(p text) returns boolean language sql immutable
set search_path = '' as $$
 select coalesce(p in ('goalkeeper','defender','midfielder','attacker','GOL','ZAG','LD','LE','VOL','MEI','CA','PD','PE','ATA'), false)
$$;

create function private.memberships_position_normalize() returns trigger
language plpgsql set search_path = '' as $$
begin
 if new.preferred_position = any(private.position_codes()) then
  new.position_code := new.preferred_position;
  new.preferred_position := private.position_sector(new.position_code);
 elsif new.position_code is not null and private.position_sector(new.position_code) is distinct from new.preferred_position then
  new.position_code := null; -- other sector chosen without a specific position
 end if;
 if new.preferred_position = 'goalkeeper' then new.position_code := 'GOL'; end if;
 return new;
end $$;
create trigger memberships_position_normalize before insert or update of preferred_position, position_code
 on public.pelada_memberships for each row execute function private.memberships_position_normalize();

create function private.participants_position_normalize() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.primary_position = any(private.position_codes()) then
  new.position_code := new.primary_position;
  new.primary_position := private.position_sector(new.position_code);
 elsif tg_op = 'INSERT' and new.position_code is null and new.membership_id is not null then
  -- Snapshot of the member's specific position when entering the sheet.
  select m.position_code into new.position_code from public.pelada_memberships m
  where m.id = new.membership_id and m.preferred_position = new.primary_position;
 elsif new.position_code is not null and private.position_sector(new.position_code) is distinct from new.primary_position then
  new.position_code := null;
 end if;
 if new.primary_position = 'goalkeeper' and new.position_code is null and tg_op = 'INSERT' then new.position_code := 'GOL'; end if;
 return new;
end $$;
create trigger participants_position_normalize before insert or update of primary_position, position_code
 on public.match_participants for each row execute function private.participants_position_normalize();

-- Draw/lineup key: the specific position, or the legacy sector while it is not refined.
create or replace function private.member_position_key(p_membership uuid) returns text
language sql stable security definer set search_path = '' as $$
 select coalesce(position_code, preferred_position) from public.pelada_memberships where id=p_membership;
$$;

-- Own position only (unchanged permission). Takes effect from the next sheet; the audit keeps from/to.
create or replace function public.set_my_position(p_pelada uuid, p_position text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.pelada_memberships; v_new public.pelada_memberships;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.valid_position(p_position) then raise exception 'INVALID_POSITION'; end if;
 select * into v_m from public.pelada_memberships
 where pelada_id=p_pelada and user_id=auth.uid() and status='active' for update;
 if not found then raise exception 'ACTIVE_MEMBERSHIP_REQUIRED'; end if;
 update public.pelada_memberships set preferred_position=p_position where id=v_m.id returning * into v_new;
 if v_new.preferred_position is distinct from v_m.preferred_position or v_new.position_code is distinct from v_m.position_code then
  insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
  values(p_pelada,auth.uid(),v_m.id,'position_changed',jsonb_build_object('position',v_new.preferred_position,
   'position_code',v_new.position_code,'from_position',v_m.preferred_position,'from_position_code',v_m.position_code));
 end if;
end $$;

-- Duel: the specific position when it belongs to the Card's sector (the Card keeps its own sector).
create or replace function private.duel_side(p_membership uuid, p_season uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object(
  'membership_id', m.id, 'name', m.player_name,
  'position', case when c.position is null or private.position_sector(coalesce(m.position_code, m.preferred_position)) = c.position
    then coalesce(m.position_code, m.preferred_position) else c.position end,
  'avatar_path', case when m.user_id is not null and not private.blocked_either_way(m.user_id)
    then (select p.avatar_path from public.profiles p where p.id=m.user_id) end,
  'card', case when c.id is not null then jsonb_build_object('tier',c.tier,'overall',c.overall,'finishing',c.finishing,
    'assisting',c.assisting,'attendance',c.attendance,'winning',c.winning,'peer_rating',c.peer_rating,
    'is_provisional',c.is_provisional,'matches_played',c.matches_played) end,
  'stats', jsonb_build_object('matches', coalesce(s.matches_played,0), 'goals', coalesce(s.goals,0),
    'assists', coalesce(s.assists,0), 'wins', coalesce(s.wins,0), 'avg_rating', s.avg_final_rating,
    'valid_ratings', coalesce(s.valid_ratings,0),
    'craque', (select count(*) from public.awards a where a.membership_id=m.id and a.season_id=p_season
      and a.award_type='match_craque' and a.status='active')))
 from public.pelada_memberships m
 left join public.player_cards c on c.membership_id=m.id and c.season_id=p_season
 left join public.player_season_stats s on s.membership_id=m.id and s.season_id=p_season
 where m.id=p_membership;
$$;

-- Profile: the specific position of each pelada (legacy sector while not refined).
create or replace function public.get_player_profile(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p public.profiles;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into p from public.profiles where id = p_user;
 if not found or not private.can_view_global(p_user, p.profile_visibility) then
  return jsonb_build_object('visible', false);
 end if;
 return jsonb_build_object('visible', true, 'id', p.id, 'display_name', p.display_name,
  'avatar_path', p.avatar_path, 'dominant_foot', p.dominant_foot, 'is_me', p.id = auth.uid(),
  'career_visible', private.can_view_global(p_user, p.career_visibility),
  'peladas', coalesce((select jsonb_agg(jsonb_build_object('pelada_id', x.id, 'name', x.name,
     'crest_path', x.crest_path, 'membership_id', m.id, 'position', coalesce(m.position_code, m.preferred_position),
     'position_needs_update', m.status='active' and m.position_code is null,
     'role', m.role, 'status', m.status, 'joined_at', m.joined_at) order by m.status, m.joined_at)
   from public.pelada_memberships m join public.peladas x on x.id = m.pelada_id
   where m.user_id = p_user and m.status in ('active','left')), '[]'::jsonb));
end $$;

-- How many active members still have a legacy position (for the staff notice and the draw hint).
create function public.get_position_migration_status(p_pelada uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.is_active_member(p_pelada) then raise exception 'PELADA_NOT_FOUND'; end if;
 return jsonb_build_object(
  'mine_needs_update', exists(select 1 from public.pelada_memberships where pelada_id=p_pelada and user_id=auth.uid()
    and status='active' and position_code is null),
  'legacy_members', (select count(*) from public.pelada_memberships where pelada_id=p_pelada and status='active'
    and position_code is null),
  'active_members', (select count(*) from public.pelada_memberships where pelada_id=p_pelada and status='active'));
end $$;

create index memberships_legacy_position on public.pelada_memberships(pelada_id) where status='active' and position_code is null;

revoke all on function private.position_codes(), private.memberships_position_normalize(),
 private.participants_position_normalize() from public, anon, authenticated;
-- position_sector is used by the check constraints of tables the app can read.
grant execute on function private.position_sector(text) to authenticated;
revoke all on function public.get_position_migration_status(uuid) from public, anon;
grant execute on function public.get_position_migration_status(uuid) to authenticated;
