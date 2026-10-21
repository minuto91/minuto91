-- Minuto 91 / 023: report and block (PRD RF-014 / Doc 02 RN-120, required by the
-- stores at launch), audit access and index optimizations (Doc 04 sec. 33.4, 34).
-- Reports: any member reports user-generated content of a pelada he belongs to
-- (nickname, photo, crest/image, pelada name, guest name). Support (service role)
-- reads them and can hide the content, which replaces it by a neutral value.
-- Blocks: a user blocks another; the blocked user's profile (name and photo) is no
-- longer readable by the blocker. The member nickname inside the pelada stays, since
-- statistics and sheets need it (it can be reported).

create table public.content_reports (
 id uuid primary key default gen_random_uuid(),
 reporter_user_id uuid references auth.users(id) on delete set null,
 pelada_id uuid not null references public.peladas(id),
 target_type text not null check (target_type in ('profile','member_name','pelada','guest')),
 target_id uuid not null,
 reason text not null check (reason in ('offensive','inappropriate_image','spam','impersonation','other')),
 details text check (details is null or length(details) <= 1000),
 status text not null default 'open' check (status in ('open','hidden','dismissed')),
 created_at timestamptz not null default now(),
 resolved_at timestamptz
);
create index content_reports_open on public.content_reports(created_at) where status='open';
create unique index one_open_report_per_reporter on public.content_reports(reporter_user_id, target_type, target_id)
 where status='open';

create table public.user_blocks (
 blocker_user_id uuid not null references auth.users(id) on delete cascade,
 blocked_user_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key (blocker_user_id, blocked_user_id),
 check (blocker_user_id <> blocked_user_id)
);

alter table public.content_reports enable row level security;
alter table public.user_blocks enable row level security;
revoke all on public.content_reports, public.user_blocks from anon,authenticated;
grant select on public.content_reports, public.user_blocks to authenticated;
create policy reports_read_own on public.content_reports for select to authenticated
 using (reporter_user_id = (select auth.uid()));
create policy blocks_read_own on public.user_blocks for select to authenticated
 using (blocker_user_id = (select auth.uid()));

-- A blocked user's profile is hidden from the blocker.
drop policy profiles_read_peers on public.profiles;
create policy profiles_read_peers on public.profiles for select to authenticated
 using ((select private.shares_pelada(id)) and not exists(select 1 from public.user_blocks b
  where b.blocker_user_id=(select auth.uid()) and b.blocked_user_id=profiles.id));

-- target_id: profile = user id; member_name = membership id; pelada = pelada id; guest = guest id.
create function public.report_content(p_pelada uuid, p_target_type text, p_target_id uuid, p_reason text,
 p_details text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_details text := nullif(btrim(p_details),'');
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.is_active_member(p_pelada) then raise exception 'PELADA_NOT_FOUND'; end if;
 if p_reason is null or p_reason not in ('offensive','inappropriate_image','spam','impersonation','other') then
  raise exception 'INVALID_REASON'; end if;
 if v_details is not null and length(v_details) > 1000 then raise exception 'INVALID_DETAILS'; end if;
 if not case p_target_type
   when 'profile' then exists(select 1 from public.pelada_memberships where pelada_id=p_pelada and user_id=p_target_id)
   when 'member_name' then exists(select 1 from public.pelada_memberships where pelada_id=p_pelada and id=p_target_id)
   when 'pelada' then p_target_id=p_pelada
   when 'guest' then exists(select 1 from public.guests where pelada_id=p_pelada and id=p_target_id)
   else false end then
  raise exception 'INVALID_REPORT_TARGET'; end if;
 select id into v_id from public.content_reports where reporter_user_id=auth.uid() and target_type=p_target_type
  and target_id=p_target_id and status='open';
 if found then return v_id; end if;
 insert into public.content_reports(reporter_user_id,pelada_id,target_type,target_id,reason,details)
 values(auth.uid(),p_pelada,p_target_type,p_target_id,p_reason,v_details) returning id into v_id;
 return v_id;
end $$;

create function public.block_user(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_user is null or p_user=auth.uid() or not exists(select 1 from auth.users where id=p_user) then
  raise exception 'INVALID_USER'; end if;
 insert into public.user_blocks(blocker_user_id,blocked_user_id) values(auth.uid(),p_user) on conflict do nothing;
end $$;

create function public.unblock_user(p_user uuid) returns void
language sql security definer set search_path = '' as $$
 delete from public.user_blocks where blocker_user_id=(select auth.uid()) and blocked_user_id=p_user;
$$;

-- Support (service role): hide (replace by a neutral value) or dismiss a report.
create function public.resolve_content_report(p_report uuid, p_hide boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.content_reports;
begin
 select * into r from public.content_reports where id=p_report for update;
 if not found then raise exception 'REPORT_NOT_FOUND'; end if;
 if p_hide then
  if r.target_type='profile' then
   update public.profiles set display_name='Jogador', avatar_path=null where id=r.target_id;
  elsif r.target_type='member_name' then
   update public.pelada_memberships set player_name='Jogador' where id=r.target_id;
  elsif r.target_type='pelada' then
   update public.peladas set name='Pelada', crest_path=null, image_path=null where id=r.target_id;
  elsif r.target_type='guest' then
   update public.guests set display_name='Convidado' where id=r.target_id;
  end if;
 end if;
 update public.content_reports set status=case when p_hide then 'hidden' else 'dismissed' end, resolved_at=now()
 where target_type=r.target_type and target_id=r.target_id and status='open';
 insert into private.audit_events(pelada_id,event_type,metadata)
 values(r.pelada_id,'content_report_resolved',jsonb_build_object('report_id',p_report,'hidden',p_hide,
  'target_type',r.target_type));
end $$;

revoke all on function public.report_content(uuid,text,uuid,text,text), public.block_user(uuid),
 public.unblock_user(uuid), public.resolve_content_report(uuid,boolean) from public,anon,authenticated;
grant execute on function public.report_content(uuid,text,uuid,text,text), public.block_user(uuid),
 public.unblock_user(uuid) to authenticated;
grant execute on function public.resolve_content_report(uuid,boolean) to service_role;

-- ===== Indexes for foreign keys and frequent lookups =====
create index if not exists audit_events_by_pelada on private.audit_events(pelada_id, occurred_at desc);
create index if not exists audit_events_by_type on private.audit_events(event_type, occurred_at desc);
create index if not exists vote_receipts_by_membership on public.vote_receipts(membership_id);
create index if not exists eligible_by_membership on public.voting_eligible_members(membership_id);
create index if not exists awards_by_membership on public.awards(membership_id, award_type) where status='active';
create index if not exists card_snapshots_by_match on public.card_snapshots(match_id);
create index if not exists highlights_by_membership on public.highlights(membership_id);
create index if not exists match_events_by_participant on public.match_events(participant_id) where participant_id is not null;
create index if not exists selection_players_by_membership on public.round_selection_players(membership_id);
create index if not exists sticker_unlocks_by_membership on public.player_sticker_unlocks(membership_id, status);
create index if not exists sticker_progress_by_pelada on public.player_sticker_progress(pelada_id);
create index if not exists season_stats_by_membership on public.player_season_stats(membership_id);
create index if not exists cards_by_membership on public.player_cards(membership_id);
create index if not exists results_by_match_valid on public.match_player_results(match_id) where has_valid_rating;
create index if not exists matches_by_status on public.matches(pelada_id, status);
create index if not exists sessions_open_deadline on public.voting_sessions(closes_at) where status='open';
create index if not exists deletion_pending_by_date on private.account_deletion_requests(purge_after) where status='pending';
