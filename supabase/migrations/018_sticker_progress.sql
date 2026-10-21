-- Minuto 91 / 018: sticker progress and unlocks (Doc 03 sec. 22.4-22.10, Doc 04 sec. 26.3-27).
-- reconcile_sticker_unlocks(membership) recomputes the career metrics of a member in
-- the pelada, updates progress for every active sticker, unlocks reached thresholds and
-- revokes stickers whose requirement is no longer met (e.g. after an annulment).
-- Idempotent: repeating it never unlocks twice or logs duplicates.
-- Runs for every member of the pelada after each finalized match (the hook chain also
-- covers monthly titles). Technical history goes to private.sticker_events (never shown
-- as the album). Notifications: 022.

create table public.player_sticker_progress (
 pelada_id uuid not null,
 membership_id uuid not null,
 sticker_definition_id uuid not null references public.sticker_definitions(id),
 current_value integer not null check (current_value >= 0),
 target_value integer not null,
 is_unlocked boolean not null,
 updated_at timestamptz not null default now(),
 primary key (membership_id, sticker_definition_id),
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id)
);

create table public.player_sticker_unlocks (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 membership_id uuid not null,
 sticker_definition_id uuid not null references public.sticker_definitions(id),
 unlocked_at timestamptz not null default now(),
 status text not null default 'active' check (status in ('active','revoked')),
 revoked_at timestamptz,
 constraint unlock_revocation check ((status='revoked') = (revoked_at is not null)),
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id)
);
create unique index one_active_unlock on public.player_sticker_unlocks(membership_id, sticker_definition_id)
 where status='active';

create table private.sticker_events (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 membership_id uuid not null,
 sticker_definition_id uuid not null,
 event_type text not null check (event_type in ('unlocked','revoked','reactivated')),
 metric_value integer not null,
 created_at timestamptz not null default now()
);
revoke all on private.sticker_events from public,anon,authenticated;

alter table public.player_sticker_progress enable row level security;
alter table public.player_sticker_unlocks enable row level security;
revoke all on public.player_sticker_progress, public.player_sticker_unlocks from anon,authenticated;
grant select on public.player_sticker_progress, public.player_sticker_unlocks to authenticated;
create policy sticker_progress_read on public.player_sticker_progress for select to authenticated
 using ((select private.is_active_member(pelada_id)));
create policy sticker_unlocks_read on public.player_sticker_unlocks for select to authenticated
 using ((select private.is_active_member(pelada_id)));
-- No client writes.

-- Career metrics of a member in the pelada (official data only).
create function private.sticker_metrics(p_membership uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object(
  'mvp_count', coalesce(c.craque_awards,0),
  'goals', coalesce(c.goals,0),
  'assists', coalesce(c.assists,0),
  'matches_played', coalesce(c.matches_played,0),
  'best_win_streak', coalesce(c.best_win_streak,0),
  'best_unbeaten_streak', coalesce(c.best_unbeaten_streak,0),
  'high_ratings', coalesce(c.high_ratings,0),
  'monthly_king_count', (select count(*) from public.awards a where a.membership_id=p_membership
    and a.award_type='monthly_king' and a.status='active'),
  'selection_count', (select count(*) from public.round_selection_players sp
    join public.round_selections s on s.id=sp.selection_id join public.matches m on m.id=s.match_id
    where sp.membership_id=p_membership and s.status='published' and m.status='finalized'))
 from (select 1) one left join public.player_career_stats c on c.membership_id=p_membership;
$$;

create function private.reconcile_sticker_unlocks(p_membership uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_metrics jsonb; d record; v_value integer; v_active uuid; v_had_revoked boolean;
begin
 select pelada_id into v_pelada from public.pelada_memberships where id=p_membership;
 if not found then raise exception 'INVALID_MEMBER'; end if;
 v_metrics := private.sticker_metrics(p_membership);

 for d in select * from public.sticker_definitions where is_active loop
  v_value := (v_metrics->>d.metric_code)::integer;
  insert into public.player_sticker_progress(pelada_id,membership_id,sticker_definition_id,current_value,target_value,is_unlocked)
  values(v_pelada,p_membership,d.id,v_value,d.threshold,v_value>=d.threshold)
  on conflict (membership_id, sticker_definition_id) do update set current_value=excluded.current_value,
   target_value=excluded.target_value, is_unlocked=excluded.is_unlocked, updated_at=now()
  where (public.player_sticker_progress.current_value, public.player_sticker_progress.target_value,
   public.player_sticker_progress.is_unlocked) is distinct from (excluded.current_value, excluded.target_value, excluded.is_unlocked);

  select id into v_active from public.player_sticker_unlocks
  where membership_id=p_membership and sticker_definition_id=d.id and status='active';
  if v_value >= d.threshold and v_active is null then
   v_had_revoked := exists(select 1 from public.player_sticker_unlocks
    where membership_id=p_membership and sticker_definition_id=d.id and status='revoked');
   insert into public.player_sticker_unlocks(pelada_id,membership_id,sticker_definition_id)
   values(v_pelada,p_membership,d.id);
   insert into private.sticker_events(pelada_id,membership_id,sticker_definition_id,event_type,metric_value)
   values(v_pelada,p_membership,d.id,case when v_had_revoked then 'reactivated' else 'unlocked' end,v_value);
  elsif v_value < d.threshold and v_active is not null then
   update public.player_sticker_unlocks set status='revoked', revoked_at=now() where id=v_active;
   insert into private.sticker_events(pelada_id,membership_id,sticker_definition_id,event_type,metric_value)
   values(v_pelada,p_membership,d.id,'revoked',v_value);
  end if;
 end loop;
end $$;

-- Replaces the 016 hook: reconciles every member of the pelada with official data or stickers.
create or replace function private.after_selection_updated(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_mem uuid;
begin
 select pelada_id into v_pelada from public.matches where id=p_match;
 for v_mem in select membership_id from public.player_career_stats where pelada_id=v_pelada
   union select membership_id from public.player_sticker_progress where pelada_id=v_pelada loop
  perform private.reconcile_sticker_unlocks(v_mem);
 end loop;
end $$;

revoke all on function private.sticker_metrics(uuid), private.reconcile_sticker_unlocks(uuid) from public,anon,authenticated;
