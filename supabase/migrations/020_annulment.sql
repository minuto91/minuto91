-- Minuto 91 / 020: match annulment (Doc 02 RN-117, Doc 03 sec. 23 / DT-09, sec. 33).
-- Only the admin, up to 7 days after finalization, with reason category, description
-- and explicit confirmation (the app shows preview_match_annulment first).
-- The match is not deleted: it becomes 'annulled' and stops counting. Everything that
-- depends on it is recomputed in the same transaction (nobody sees partial rankings):
-- awards of the match revoked, Seleção revoked, highlights moved back to the latest
-- finalized match, season/career stats and cards (no new snapshot), monthly awards of
-- its month (if that month is over) and stickers of every member.
-- Votes are not reopened or reused; there is no restoration (register the match again).
-- Idempotent: annulling an annulled match returns the stored annulment.
-- Notice to every player of the pelada: 022 (notification_events), from the audit event.

create table public.match_annulments (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null unique,
 reason_category text not null check (reason_category in
  ('sheet_error','duplicate_match','match_not_played','other')),
 description text not null check (length(btrim(description)) between 10 and 1000),
 annulled_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 foreign key (match_id, pelada_id) references public.matches(id, pelada_id)
);
alter table public.match_annulments enable row level security;
revoke all on public.match_annulments from anon,authenticated;
grant select on public.match_annulments to authenticated;
create policy annulments_read on public.match_annulments for select to authenticated
 using ((select private.is_active_member(pelada_id)));
-- No client writes.

-- Locks the pelada and validates that the caller may annul the match now.
create function private.lock_annullable_match(p_match uuid) returns public.matches
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_m public.matches;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_pelada for update;
 if not private.is_active_admin(v_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match for update;
 return v_m;
end $$;

-- Main effects, for the confirmation screen.
create function public.preview_match_annulment(p_match uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches;
begin
 v_m := private.lock_annullable_match(p_match);
 return jsonb_build_object(
  'status', v_m.status,
  'can_annul', v_m.status='finalized' and now() <= v_m.finalized_at + interval '7 days',
  'deadline', v_m.finalized_at + interval '7 days',
  'players_affected', (select count(*) from public.match_player_results where match_id=p_match),
  'goals', (select coalesce(sum(goals),0) from public.match_player_results where match_id=p_match),
  'awards_revoked', (select coalesce(jsonb_agg(jsonb_build_object('award_type',award_type,'membership_id',membership_id)),'[]'::jsonb)
    from public.awards where match_id=p_match and status='active'),
  'has_round_selection', exists(select 1 from public.round_selections where match_id=p_match and status='published'),
  'month_awards_recomputed', exists(select 1 from public.monthly_closures where pelada_id=v_m.pelada_id
    and period_month=date_trunc('month', private.pelada_local_date(v_m.pelada_id, v_m.played_at))::date));
end $$;

-- p_reason_category: sheet_error | duplicate_match | match_not_played | other.
create function public.annul_match(p_match uuid, p_reason_category text, p_description text,
 p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_a public.match_annulments; v_desc text := nullif(btrim(p_description),'');
 v_latest uuid; v_mem uuid;
begin
 v_m := private.lock_annullable_match(p_match);
 if v_m.status='annulled' then
  select * into v_a from public.match_annulments where match_id=p_match;
  return jsonb_build_object('annulled',true,'already_annulled',true,'annulment_id',v_a.id);
 end if;
 if v_m.status <> 'finalized' then raise exception 'MATCH_NOT_FINALIZED'; end if;
 if now() > v_m.finalized_at + interval '7 days' then raise exception 'ANNULMENT_WINDOW_EXPIRED'; end if;
 if p_reason_category is null or p_reason_category not in ('sheet_error','duplicate_match','match_not_played','other') then
  raise exception 'INVALID_REASON_CATEGORY'; end if;
 if v_desc is null or length(v_desc) not between 10 and 1000 then raise exception 'DESCRIPTION_REQUIRED'; end if;
 if p_confirm is distinct from true then raise exception 'CONFIRMATION_REQUIRED'; end if;

 update public.matches set status='annulled' where id=p_match;
 insert into public.match_annulments(pelada_id,match_id,reason_category,description,annulled_by)
 values(v_m.pelada_id,p_match,p_reason_category,v_desc,auth.uid()) returning * into v_a;

 update public.awards set status='revoked', revoked_at=now() where match_id=p_match and status='active';
 update public.round_selections set status='revoked' where match_id=p_match;
 -- The current highlights are those of the latest finalized match.
 update public.highlights set expires_at=now() where match_id=p_match and expires_at is null;
 select id into v_latest from public.matches where pelada_id=v_m.pelada_id and status='finalized'
 order by finalized_at desc, id desc limit 1;
 if v_latest is not null and not exists(select 1 from public.highlights
   where pelada_id=v_m.pelada_id and expires_at is null) then
  perform private.refresh_highlights(v_latest);
 end if;

 perform private.recompute_stats(v_m.pelada_id, v_m.season_id);
 perform private.recompute_cards(v_m.season_id, null);
 perform private.close_month(v_m.pelada_id, private.pelada_local_date(v_m.pelada_id, v_m.played_at));
 for v_mem in select membership_id from public.player_career_stats where pelada_id=v_m.pelada_id
   union select membership_id from public.player_sticker_progress where pelada_id=v_m.pelada_id loop
  perform private.reconcile_sticker_unlocks(v_mem);
 end loop;

 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),'match_annulled',jsonb_build_object('match_id',p_match,
  'annulment_id',v_a.id,'reason_category',p_reason_category));
 return jsonb_build_object('annulled',true,'already_annulled',false,'annulment_id',v_a.id);
end $$;

revoke all on function private.lock_annullable_match(uuid) from public,anon,authenticated;
revoke all on function public.preview_match_annulment(uuid), public.annul_match(uuid,text,text,boolean) from public,anon;
grant execute on function public.preview_match_annulment(uuid), public.annul_match(uuid,text,text,boolean) to authenticated;
