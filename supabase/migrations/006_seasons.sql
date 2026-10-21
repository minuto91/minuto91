-- Minuto 91 / 006: seasons (Doc 02 RN-005 / sec. 7, Doc 04 sec. 11).
-- Default: calendar year (Jan 1 - Dec 31 in the pelada's timezone), created
-- automatically and filling any gap between other seasons.
-- Premium: custom period. A season is always running, so the admin must choose
-- explicitly (and confirm) one of two modes in customize_season():
--  'close_and_start': the current season ends the day before the new one starts;
--  'keep_current'   : the current season and its matches stay; only its name and
--                     end date change.
-- Seasons never overlap inside a pelada. Closing a season never deletes data.
-- Status is derived from the dates (planned / active / closed) and refreshed on
-- every season write; TODO(022): daily job + end-of-season actions (RN-107).
create extension if not exists btree_gist with schema extensions;

create table public.seasons (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 name text not null check (length(btrim(name)) between 2 and 60),
 kind text not null default 'annual' check (kind in ('annual','custom')),
 starts_on date not null,
 ends_on date not null,
 status text not null default 'active',
 closed_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint season_dates_check check (ends_on >= starts_on),
 constraint season_status_check check (status in ('planned','active','closed')),
 unique (id, pelada_id),
 constraint seasons_no_overlap exclude using gist
  (pelada_id with =, (daterange(starts_on, ends_on, '[]')) with &&)
);
create trigger seasons_touch before update on public.seasons
for each row execute function private.touch_updated_at();

alter table public.seasons enable row level security;
revoke all on public.seasons from anon,authenticated;
grant select on public.seasons to authenticated;
create policy seasons_read_members on public.seasons for select to authenticated
 using ((select private.is_active_member(pelada_id)));
-- No client INSERT/UPDATE/DELETE: seasons change only through the functions below.

-- "Today" in the pelada's timezone (settings may not exist yet during creation).
create function private.pelada_today(p_pelada uuid) returns date
language sql stable security definer set search_path = '' as $$
 select (now() at time zone coalesce(
  (select timezone from public.pelada_settings where pelada_id=p_pelada),
  'America/Sao_Paulo'))::date;
$$;

create function private.sync_season_status(p_pelada uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_today date := private.pelada_today(p_pelada);
begin
 update public.seasons s set
  status = x.st,
  closed_at = case when x.st='closed' then coalesce(s.closed_at, now()) end
 from (select id, case when ends_on < v_today then 'closed'
                       when starts_on > v_today then 'planned' else 'active' end st
       from public.seasons where pelada_id=p_pelada) x
 where s.id=x.id and s.status is distinct from x.st;
end $$;

-- Season that contains p_date; creates the annual season (clipped to the gap
-- between neighbouring seasons) when none does. Used by matches (007).
create function private.season_for_date(p_pelada uuid, p_date date) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_year int := extract(year from p_date)::int; v_start date; v_end date;
begin
 perform 1 from public.peladas where id=p_pelada for update;
 if not found then raise exception 'PELADA_NOT_FOUND'; end if;
 select id into v_id from public.seasons
 where pelada_id=p_pelada and p_date between starts_on and ends_on;
 if found then return v_id; end if;
 v_start := greatest(make_date(v_year,1,1),
  (select max(ends_on)+1 from public.seasons where pelada_id=p_pelada and ends_on < p_date));
 v_end := least(make_date(v_year,12,31),
  (select min(starts_on)-1 from public.seasons where pelada_id=p_pelada and starts_on > p_date));
 insert into public.seasons(pelada_id,name,kind,starts_on,ends_on)
 values(p_pelada,'Temporada '||v_year,'annual',v_start,v_end) returning id into v_id;
 perform private.sync_season_status(p_pelada);
 return v_id;
end $$;

create function private.on_pelada_created() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 perform private.season_for_date(new.id, private.pelada_today(new.id));
 return new;
end $$;
create trigger pelada_default_season after insert on public.peladas
for each row execute function private.on_pelada_created();

-- Peladas created before this migration get their current annual season.
select private.season_for_date(id, private.pelada_today(id)) from public.peladas;

-- Premium, admin only. p_confirm must be true: the app shows the warning
-- (what each mode does to the running season) before calling.
-- keep_current ignores p_starts_on.
create function public.customize_season(p_pelada uuid, p_mode text, p_name text,
 p_starts_on date, p_ends_on date, p_confirm boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_today date; v_cur public.seasons%rowtype; v_name text := nullif(btrim(p_name),'');
 v_id uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if not private.pelada_has_premium(p_pelada) then raise exception 'PREMIUM_REQUIRED'; end if;
 if p_mode is null or p_mode not in ('close_and_start','keep_current') then raise exception 'INVALID_SEASON_MODE'; end if;
 if v_name is null or length(v_name) not between 2 and 60 then raise exception 'INVALID_NAME'; end if;
 if p_confirm is distinct from true then raise exception 'CONFIRMATION_REQUIRED'; end if;

 v_today := private.pelada_today(p_pelada);
 -- Locks the pelada and guarantees a current season exists.
 v_id := private.season_for_date(p_pelada, v_today);
 select * into v_cur from public.seasons where id=v_id;

 begin
  if p_mode='keep_current' then
   if p_ends_on is null or p_ends_on < v_today then raise exception 'INVALID_SEASON_DATES'; end if;
   -- TODO(007): reject when the current season has matches after p_ends_on.
   update public.seasons set name=v_name, kind='custom', ends_on=p_ends_on
   where id=v_cur.id returning id into v_id;
  else
   if p_starts_on is null or p_ends_on is null or p_starts_on < v_today or p_ends_on < p_starts_on then
    raise exception 'INVALID_SEASON_DATES'; end if;
   if v_cur.starts_on >= p_starts_on then
    -- The current season has not really begun: it becomes the custom one.
    -- TODO(007): reject when it has matches outside the new period.
    update public.seasons set name=v_name, kind='custom', starts_on=p_starts_on, ends_on=p_ends_on
    where id=v_cur.id returning id into v_id;
   else
    -- TODO(007): reject when the current season has matches on/after p_starts_on.
    update public.seasons set ends_on=least(ends_on, p_starts_on-1) where id=v_cur.id;
    insert into public.seasons(pelada_id,name,kind,starts_on,ends_on)
    values(p_pelada,v_name,'custom',p_starts_on,p_ends_on) returning id into v_id;
   end if;
  end if;
 exception when exclusion_violation then
  raise exception 'SEASON_OVERLAP';
 end;

 perform private.sync_season_status(p_pelada);
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'season_customized',jsonb_build_object(
  'mode',p_mode,'season_id',v_id,'previous_season_id',v_cur.id,
  'previous_period',jsonb_build_array(v_cur.starts_on,v_cur.ends_on),
  'new_period',jsonb_build_array(case when p_mode='keep_current' then v_cur.starts_on else p_starts_on end,p_ends_on)));
 return v_id;
end $$;

revoke all on function private.pelada_today(uuid), private.sync_season_status(uuid),
 private.season_for_date(uuid,date), private.on_pelada_created() from public,anon,authenticated;
revoke all on function public.customize_season(uuid,text,text,date,date,boolean) from public,anon;
grant execute on function public.customize_season(uuid,text,text,date,date,boolean) to authenticated;
