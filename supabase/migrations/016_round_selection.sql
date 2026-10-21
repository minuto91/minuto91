-- Minuto 91 / 016: Seleção da Rodada (Doc 02 RN-075, Doc 03 sec. 21, Doc 04 sec. 25).
-- 4-3-3: 1 goalkeeper, 4 defenders, 3 midfielders, 3 attackers, by the position
-- snapshot of the match. Only players with a valid official final rating; published
-- only with at least 11 of them.
-- PRODUCT DECISION (overrides Doc 02 RN-075 / Doc 03 21.4 / Doc 04 25.1, which allowed
-- automatic adaptations): positions are never mixed; a slot without a candidate of
-- that position stays empty.
-- Order inside a position: final rating, number of valid ratings received, peer
-- rating V, membership id (stable). Deterministic; the admin cannot change it.

create table public.round_selections (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null,
 algorithm_version integer not null,
 formation text not null default '4-3-3',
 status text not null default 'published' check (status in ('published','revoked')),
 calculated_at timestamptz not null default now(),
 foreign key (match_id, pelada_id) references public.matches(id, pelada_id),
 unique (match_id)
);

create table public.round_selection_players (
 id uuid primary key default gen_random_uuid(),
 selection_id uuid not null references public.round_selections(id) on delete cascade,
 membership_id uuid not null references public.pelada_memberships(id),
 official_position text not null check (official_position in ('goalkeeper','defender','midfielder','attacker')),
 slot_position text not null check (slot_position in ('goalkeeper','defender','midfielder','attacker')),
 -- Not readable by clients: the detailed rating follows the voters-only rule (013).
 final_rating numeric(8,6) not null,
 rank_order integer not null,
 is_adapted boolean not null default false check (not is_adapted), -- never adapted (product decision)
 unique (selection_id, membership_id)
);

alter table public.round_selections enable row level security;
alter table public.round_selection_players enable row level security;
revoke all on public.round_selections, public.round_selection_players from anon,authenticated;
grant select on public.round_selections to authenticated;
grant select (id, selection_id, membership_id, official_position, slot_position, rank_order, is_adapted)
 on public.round_selection_players to authenticated;
create policy selections_read on public.round_selections for select to authenticated
 using ((select private.is_active_member(pelada_id)));
create policy selection_players_read on public.round_selection_players for select to authenticated
 using (exists(select 1 from public.round_selections s where s.id=selection_id));
-- No client writes.

-- (Re)computes the selection of a finalized match. Idempotent.
create function private.compute_round_selection(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c_min_eligible constant integer := 11; v_pelada uuid; v_sel uuid;
begin
 select pelada_id into v_pelada from public.matches where id=p_match and status='finalized';
 delete from public.round_selections where match_id=p_match;
 if v_pelada is null then return; end if;
 if (select count(*) from public.match_player_results where match_id=p_match and has_valid_rating) < c_min_eligible then
  return; end if;

 insert into public.round_selections(pelada_id,match_id,algorithm_version) values(v_pelada,p_match,1)
 returning id into v_sel;
 insert into public.round_selection_players(selection_id,membership_id,official_position,slot_position,final_rating,rank_order)
 select v_sel, membership_id, position_snapshot, position_snapshot, final_rating,
  row_number() over (order by final_rating desc, numeric_rating_count desc, peer_rating desc, membership_id)
 from (
  select r.*, row_number() over (partition by r.position_snapshot
   order by r.final_rating desc, r.numeric_rating_count desc, r.peer_rating desc, r.membership_id) k
  from public.match_player_results r where r.match_id=p_match and r.has_valid_rating) x
 where k <= case position_snapshot when 'goalkeeper' then 1 when 'defender' then 4 else 3 end;
end $$;

-- Hook for 018 (album). Replaced there.
create function private.after_selection_updated(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 null;
end $$;

-- Replaces the 015 hook.
create or replace function private.after_rankings_updated(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 perform private.compute_round_selection(p_match);
 perform private.after_selection_updated(p_match);
end $$;

revoke all on function private.compute_round_selection(uuid), private.after_selection_updated(uuid)
 from public,anon,authenticated;
