-- Minuto 91 / 007: matches (Doc 02 RN-014/RN-018, Doc 03 sec. 8, Doc 04 sec. 12).
-- Match header only: date, season, team names and state. Participants, events
-- and the score (which must agree with the events) arrive in 008; voting in 010+.
-- Admin or assistant creates, edits and discards drafts. Drafts are hidden from
-- players. A match may be dated any day up to today (pelada timezone); its season
-- is the one containing that day. Custom team names are Premium.
-- Also closes the 006 TODOs: a season can no longer leave matches outside its dates.

create function private.is_active_staff(p_pelada uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.pelada_memberships m
 where m.pelada_id=p_pelada and m.user_id=(select auth.uid())
 and m.status='active' and m.role in ('admin','assistant'));
$$;
revoke all on function private.is_active_staff(uuid) from public,anon;
grant execute on function private.is_active_staff(uuid) to authenticated;

create function private.pelada_local_date(p_pelada uuid, p_at timestamptz) returns date
language sql stable security definer set search_path = '' as $$
 select (p_at at time zone coalesce(
  (select timezone from public.pelada_settings where pelada_id=p_pelada),
  'America/Sao_Paulo'))::date;
$$;

create table public.matches (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 season_id uuid not null,
 played_at timestamptz not null,
 status text not null default 'draft',
 team_a_name text not null default 'Time A' check (length(btrim(team_a_name)) between 1 and 40),
 team_b_name text not null default 'Time B' check (length(btrim(team_b_name)) between 1 and 40),
 team_a_score integer not null default 0,
 team_b_score integer not null default 0,
 sheet_version integer not null default 1,
 formula_version integer not null default 1,
 created_by uuid references public.profiles(id) on delete set null,
 finalized_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint match_status_check check (status in ('draft','voting_open','finalizing','finalized','annulled')),
 constraint match_scores_check check (team_a_score >= 0 and team_b_score >= 0),
 foreign key (season_id, pelada_id) references public.seasons(id, pelada_id),
 unique (id, pelada_id)
);
create index idx_matches_pelada_date on public.matches(pelada_id, played_at desc);
create index idx_matches_season on public.matches(season_id);
create trigger matches_touch before update on public.matches
for each row execute function private.touch_updated_at();

-- A match's day must fall inside its season.
create function private.check_match_in_season() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if not exists(select 1 from public.seasons s where s.id=new.season_id
   and private.pelada_local_date(new.pelada_id,new.played_at) between s.starts_on and s.ends_on) then
  raise exception 'MATCH_OUTSIDE_SEASON';
 end if;
 return new;
end $$;
create trigger matches_in_season before insert or update of played_at, season_id on public.matches
for each row execute function private.check_match_in_season();

-- A season's dates cannot change so that any of its matches falls outside.
create function private.check_season_keeps_matches() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if exists(select 1 from public.matches m where m.season_id=new.id
   and private.pelada_local_date(m.pelada_id,m.played_at) not between new.starts_on and new.ends_on) then
  raise exception 'SEASON_HAS_MATCHES_OUTSIDE';
 end if;
 return new;
end $$;
create trigger seasons_keep_matches before update of starts_on, ends_on on public.seasons
for each row execute function private.check_season_keeps_matches();

alter table public.matches enable row level security;
revoke all on public.matches from anon,authenticated;
grant select on public.matches to authenticated;
create policy matches_read_members on public.matches for select to authenticated
 using ((select private.is_active_member(pelada_id))
  and (status <> 'draft' or (select private.is_active_staff(pelada_id))));
-- No client INSERT/UPDATE/DELETE: matches change only through the RPCs below.

-- Validates date and team names; returns the season for the match day.
create function private.prepare_match(p_pelada uuid, p_played_at timestamptz,
 inout p_team_a text, inout p_team_b text, out p_season uuid)
language plpgsql security definer set search_path = '' as $$
begin
 if p_played_at is null
  or private.pelada_local_date(p_pelada,p_played_at) > private.pelada_today(p_pelada) then
  raise exception 'INVALID_MATCH_DATE'; end if;
 p_team_a := coalesce(nullif(btrim(p_team_a),''),'Time A');
 p_team_b := coalesce(nullif(btrim(p_team_b),''),'Time B');
 if length(p_team_a) > 40 or length(p_team_b) > 40 then raise exception 'INVALID_TEAM_NAME'; end if;
 if (p_team_a,p_team_b) is distinct from ('Time A','Time B') and not private.pelada_has_premium(p_pelada) then
  raise exception 'TEAM_NAMES_PREMIUM'; end if;
 p_season := private.season_for_date(p_pelada, private.pelada_local_date(p_pelada,p_played_at));
end $$;

-- Locks the pelada of a match and checks that the caller may edit its draft.
create function private.lock_match_draft(p_match uuid) returns public.matches
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_m public.matches;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_pelada for update;
 if not private.is_active_staff(v_pelada) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match for update;
 if v_m.status <> 'draft' then raise exception 'MATCH_NOT_DRAFT'; end if;
 return v_m;
end $$;

create function public.create_match(p_pelada uuid, p_played_at timestamptz,
 p_team_a_name text default null, p_team_b_name text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_a text := p_team_a_name; v_b text := p_team_b_name; v_season uuid; v_id uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 perform 1 from public.peladas where id=p_pelada for update;
 if not private.is_active_staff(p_pelada) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 if not exists(select 1 from public.peladas where id=p_pelada and status='active') then
  raise exception 'PELADA_NOT_ACTIVE'; end if;
 select * into v_a, v_b, v_season from private.prepare_match(p_pelada, p_played_at, v_a, v_b);
 insert into public.matches(pelada_id,season_id,played_at,team_a_name,team_b_name,created_by)
 values(p_pelada,v_season,p_played_at,v_a,v_b,auth.uid()) returning id into v_id;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'match_created',jsonb_build_object('match_id',v_id));
 return v_id;
end $$;

-- Draft only. Null team names mean the defaults (Time A / Time B).
create function public.update_match_draft(p_match uuid, p_played_at timestamptz,
 p_team_a_name text default null, p_team_b_name text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_a text := p_team_a_name; v_b text := p_team_b_name; v_season uuid;
begin
 v_m := private.lock_match_draft(p_match);
 select * into v_a, v_b, v_season from private.prepare_match(v_m.pelada_id, p_played_at, v_a, v_b);
 update public.matches set played_at=p_played_at, season_id=v_season, team_a_name=v_a, team_b_name=v_b
 where id=p_match;
end $$;

-- Draft only (never shown to players). Published matches are only annulled (020).
create function public.discard_match_draft(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches;
begin
 v_m := private.lock_match_draft(p_match);
 -- TODO(008): participants and events of the draft must go with it (on delete cascade).
 delete from public.matches where id=p_match;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),'match_draft_discarded',jsonb_build_object(
  'match_id',p_match,'played_at',v_m.played_at,'created_by',v_m.created_by));
end $$;

revoke all on function private.pelada_local_date(uuid,timestamptz), private.check_match_in_season(),
 private.check_season_keeps_matches(), private.prepare_match(uuid,timestamptz,text,text),
 private.lock_match_draft(uuid) from public,anon,authenticated;
revoke all on function public.create_match(uuid,timestamptz,text,text),
 public.update_match_draft(uuid,timestamptz,text,text), public.discard_match_draft(uuid) from public,anon;
grant execute on function public.create_match(uuid,timestamptz,text,text),
 public.update_match_draft(uuid,timestamptz,text,text), public.discard_match_draft(uuid) to authenticated;
