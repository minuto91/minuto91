-- Minuto 91 / 037: V4.2 audit items A06-A09, A12, A18, A20 and the snapshot policy after annulment
-- (V4.2 sec. 8.3). Formulas untouched (formula_version 1).
--
-- A06 Full history is a Pelada Premium benefit, now enforced by RLS too: Cards, season statistics,
--  Card history and awards of seasons older than the previous one are readable only with Premium
--  (same rule as rankings/records, RN-083). Match list and results stay readable (basic sporting record).
-- A07 A Card depends on the previous season (provisional base). Recomputing a season now also
--  recomputes the Cards of the later seasons of the pelada, oldest first.
-- A08 Monthly awards (Rei do Mês etc.) reconcile the member's stickers in the same transaction (at
--  commit), also when the month is closed by the scheduler.
-- A09 Onboarding keeps the current name when the field is empty and the nickname reaches the
--  memberships (it used to be the e-mail prefix in the app and stayed only in the profile).
-- A12 get_my_home: last match and drafts per pelada (no global limit) and the pending votes.
-- A18 Versioned acceptance of the Terms and the Privacy Policy (document, version, moment).
-- A20 get_season_retrospective: the season's story aggregated in the database (no 1,000-row cut),
--  with every player tied at the last position shown (sec. 8.4).
-- 8.3 Card history after an annulment: three states are kept apart.
--  * published: card_snapshots, written when each match was finalized, never rewritten;
--  * corrected: card_corrections, the Card of every player of the affected seasons right after an
--    annulment (written at commit time, after the recomputation);
--  * current: player_cards.
--  get_player_evolution returns the three; the chart shows the published line, then the correction.

---------------------------------------------------------------------------------------------------
-- A06
---------------------------------------------------------------------------------------------------

-- Readable season for the caller: active member, and Premium for seasons older than the previous one.
create function private.season_readable(p_season uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.seasons s where s.id=p_season and private.is_active_member(s.pelada_id)
  and (private.pelada_has_premium(s.pelada_id) or s.id in (
   select x.id from public.seasons x where x.pelada_id=s.pelada_id and x.starts_on <= private.pelada_today(s.pelada_id)
   order by x.starts_on desc limit 2)));
$$;
revoke all on function private.season_readable(uuid) from public,anon;
grant execute on function private.season_readable(uuid) to authenticated;

drop policy cards_read on public.player_cards;
create policy cards_read on public.player_cards for select to authenticated
 using ((select private.is_active_member(pelada_id)) and private.season_readable(season_id)
  and exists(select 1 from public.pelada_memberships m where m.id=membership_id and m.status<>'retired'));
drop policy season_stats_read on public.player_season_stats;
create policy season_stats_read on public.player_season_stats for select to authenticated
 using ((select private.is_active_member(pelada_id)) and private.season_readable(season_id));
drop policy awards_read_members on public.awards;
create policy awards_read_members on public.awards for select to authenticated
 using ((select private.is_active_member(pelada_id)) and private.season_readable(season_id));
-- card_snapshots follows player_cards (its policy reads through the cards' RLS).

-- Seasons the caller can open (for the season pickers).
create function public.get_readable_seasons(p_pelada uuid) returns table(id uuid, name text, starts_on date,
 ends_on date, status text, kind text)
language sql stable security definer set search_path = '' as $$
 select s.id, s.name, s.starts_on, s.ends_on, s.status, s.kind from public.seasons s
 where s.pelada_id=p_pelada and private.season_readable(s.id) order by s.starts_on desc;
$$;
revoke all on function public.get_readable_seasons(uuid) from public,anon;
grant execute on function public.get_readable_seasons(uuid) to authenticated;

---------------------------------------------------------------------------------------------------
-- A07 + 8.3
---------------------------------------------------------------------------------------------------

-- One season (body of 036 recompute_cards).
create function private.recompute_season_cards(p_season uuid, p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_mem uuid;
begin
 for v_mem in select membership_id from public.player_cards where season_id=p_season
   union select r.membership_id from public.match_player_results r join public.matches m on m.id=r.match_id
   where m.season_id=p_season and m.status='finalized' loop
  if private.retention_excluded(p_season, v_mem) then
   delete from public.player_cards where season_id=p_season and membership_id=v_mem;
   continue;
  end if;
  perform private.recompute_card(p_season, v_mem, p_match);
 end loop;
end $$;

-- The season and every later season with Cards, in chronological order (provisional base).
create or replace function private.recompute_cards(p_season uuid, p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_next uuid;
begin
 perform private.recompute_season_cards(p_season, p_match);
 for v_next in select s2.id from public.seasons s1 join public.seasons s2 on s2.pelada_id=s1.pelada_id
   and s2.starts_on > s1.starts_on where s1.id=p_season order by s2.starts_on loop
  if exists(select 1 from public.player_cards where season_id=v_next) then
   perform private.recompute_season_cards(v_next, null);
  end if;
 end loop;
end $$;

create table public.card_corrections (
 id uuid primary key default gen_random_uuid(),
 card_id uuid not null references public.player_cards(id) on delete cascade,
 annulled_match_id uuid not null references public.matches(id),
 snapshot_data jsonb not null,
 formula_version integer not null,
 created_at timestamptz not null default now(),
 unique (card_id, annulled_match_id)
);
alter table public.card_corrections enable row level security;
revoke all on public.card_corrections from anon,authenticated;
grant select on public.card_corrections to authenticated;
create policy card_corrections_read on public.card_corrections for select to authenticated
 using (exists(select 1 from public.player_cards c where c.id=card_id));

-- Runs at commit (deferred), after annul_match recomputed everything.
create function private.record_card_corrections() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 insert into public.card_corrections(card_id,annulled_match_id,snapshot_data,formula_version)
 select c.id, new.match_id, jsonb_build_object('position',c.position,'finishing',c.finishing,'assisting',c.assisting,
  'attendance',c.attendance,'winning',c.winning,'peer_rating',c.peer_rating,'overall',c.overall,'tier',c.tier,
  'is_provisional',c.is_provisional,'matches_played',c.matches_played), c.formula_version
 from public.player_cards c join public.seasons s on s.id=c.season_id
 where s.pelada_id=new.pelada_id and s.starts_on >= (select s0.starts_on from public.matches m
   join public.seasons s0 on s0.id=m.season_id where m.id=new.match_id)
 on conflict (card_id, annulled_match_id) do update set snapshot_data=excluded.snapshot_data, created_at=now();
 return null;
end $$;
create constraint trigger annulment_card_corrections after insert on public.match_annulments
deferrable initially deferred for each row execute function private.record_card_corrections();

create or replace function public.get_player_evolution(p_membership uuid, p_season uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_pelada uuid; v_points jsonb; v_current jsonb; v_kings jsonb; v_craque integer; v_corr jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 v_pelada := private.check_season_access(p_season);
 if not exists(select 1 from public.pelada_memberships where id=p_membership and pelada_id=v_pelada) then
  raise exception 'MEMBER_NOT_FOUND'; end if;

 select coalesce(jsonb_agg(jsonb_build_object(
   'match_id', m.id, 'played_at', m.played_at,
   'played', exists(select 1 from public.match_player_results r where r.match_id=m.id and r.membership_id=p_membership),
   'overall', (s.snapshot_data->>'overall')::numeric, 'finishing', (s.snapshot_data->>'finishing')::numeric,
   'assisting', (s.snapshot_data->>'assisting')::numeric, 'attendance', (s.snapshot_data->>'attendance')::numeric,
   'winning', (s.snapshot_data->>'winning')::numeric, 'peer_rating', (s.snapshot_data->>'peer_rating')::numeric,
   'tier', s.snapshot_data->>'tier', 'position', s.snapshot_data->>'position',
   'is_provisional', (s.snapshot_data->>'is_provisional')::boolean)
   order by m.played_at, m.id), '[]'::jsonb)
 into v_points
 from public.player_cards c
 join public.card_snapshots s on s.card_id=c.id
 join public.matches m on m.id=s.match_id and m.status='finalized'
 where c.membership_id=p_membership and c.season_id=p_season;

 select coalesce(jsonb_agg(jsonb_build_object('annulled_match_id', k.annulled_match_id, 'corrected_at', k.created_at,
   'overall', (k.snapshot_data->>'overall')::numeric, 'tier', k.snapshot_data->>'tier') order by k.created_at), '[]'::jsonb)
 into v_corr from public.card_corrections k join public.player_cards c on c.id=k.card_id
 where c.membership_id=p_membership and c.season_id=p_season;

 select jsonb_build_object('overall', c.overall, 'finishing', c.finishing, 'assisting', c.assisting,
   'attendance', c.attendance, 'winning', c.winning, 'peer_rating', c.peer_rating, 'tier', c.tier,
   'position', c.position, 'is_provisional', c.is_provisional, 'updated_at', c.updated_at)
 into v_current from public.player_cards c where c.membership_id=p_membership and c.season_id=p_season;

 select coalesce(jsonb_agg(a.period_month order by a.period_month), '[]'::jsonb) into v_kings
 from public.awards a where a.membership_id=p_membership and a.season_id=p_season
  and a.award_type='monthly_king' and a.status='active';
 select count(*) into v_craque from public.awards a where a.membership_id=p_membership and a.season_id=p_season
  and a.award_type='match_craque' and a.status='active';

 return jsonb_build_object('points', v_points, 'corrections', v_corr, 'current', v_current,
  'monthly_king', v_kings, 'craque', v_craque);
end $$;

---------------------------------------------------------------------------------------------------
-- A08
---------------------------------------------------------------------------------------------------

create function private.on_period_award_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 perform private.reconcile_sticker_unlocks(new.membership_id);
 return null;
end $$;
-- Deferred to the commit: a month being recomputed revokes and re-grants its awards in the same
-- transaction, and the sticker must only see the final state (no revoked/reactivated noise).
create constraint trigger awards_period_stickers after insert or update of status on public.awards
deferrable initially deferred for each row when (new.match_id is null)
execute function private.on_period_award_changed();

---------------------------------------------------------------------------------------------------
-- A09 + A18
---------------------------------------------------------------------------------------------------

create or replace function public.complete_onboarding(p_display_name text, p_adult boolean, p_terms boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_name text := nullif(btrim(p_display_name),'');
begin
 if v_user is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_adult is distinct from true then raise exception 'ADULT_DECLARATION_REQUIRED'; end if;
 if p_terms is distinct from true then raise exception 'TERMS_ACCEPTANCE_REQUIRED'; end if;
 if v_name is not null and length(v_name) > 80 then raise exception 'INVALID_NAME'; end if;
 update public.profiles set
  display_name = coalesce(v_name, display_name),
  adult_declared_at = coalesce(adult_declared_at, now()),
  terms_accepted_at = coalesce(terms_accepted_at, now())
 where id = v_user;
 if not found then raise exception 'PROFILE_REQUIRED'; end if;
 if v_name is not null then
  update public.pelada_memberships set player_name = v_name
  where user_id = v_user and status = 'active' and player_name is distinct from v_name;
 end if;
end $$;

-- Official versions in force (docs/Minuto91_Termos_de_Uso_v1.1.pdf, Minuto91_Politica_de_Privacidade_v1.2.pdf).
insert into private.app_config(key,value) values ('legal_versions','{"terms":"1.1","privacy":"1.2"}'::jsonb)
on conflict (key) do nothing;

create table public.legal_acceptances (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 document text not null check (document in ('terms','privacy')),
 version text not null check (length(version) between 1 and 20),
 accepted_at timestamptz not null default now(),
 unique (user_id, document, version)
);
alter table public.legal_acceptances enable row level security;
revoke all on public.legal_acceptances from anon,authenticated;
grant select on public.legal_acceptances to authenticated;
create policy legal_read_own on public.legal_acceptances for select to authenticated using (user_id=(select auth.uid()));

-- Versions in force and whether the caller accepted both.
create function public.get_legal_status() returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('terms_version', v->>'terms', 'privacy_version', v->>'privacy',
  'accepted', exists(select 1 from public.legal_acceptances a where a.user_id=(select auth.uid()) and a.document='terms' and a.version=v->>'terms')
   and exists(select 1 from public.legal_acceptances a where a.user_id=(select auth.uid()) and a.document='privacy' and a.version=v->>'privacy'),
  'accepted_at', (select max(accepted_at) from public.legal_acceptances a where a.user_id=(select auth.uid())))
 from (select value v from private.app_config where key='legal_versions') c;
$$;

-- The app sends the versions it showed; an outdated screen is refused.
create function public.accept_legal_documents(p_terms_version text, p_privacy_version text) returns void
language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select value into v from private.app_config where key='legal_versions';
 if p_terms_version is distinct from v->>'terms' or p_privacy_version is distinct from v->>'privacy' then
  raise exception 'LEGAL_VERSION_OUTDATED'; end if;
 insert into public.legal_acceptances(user_id,document,version) values
  (auth.uid(),'terms',v->>'terms'), (auth.uid(),'privacy',v->>'privacy')
 on conflict (user_id, document, version) do nothing;
 update public.profiles set terms_accepted_at=coalesce(terms_accepted_at, now()) where id=auth.uid() and adult_declared_at is not null;
end $$;

revoke all on function public.get_legal_status(), public.accept_legal_documents(text,text) from public,anon;
grant execute on function public.get_legal_status(), public.accept_legal_documents(text,text) to authenticated;

---------------------------------------------------------------------------------------------------
-- A12
---------------------------------------------------------------------------------------------------

create function public.get_my_home() returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object(
  'peladas', coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'role',pm.role,
     'last',(select jsonb_build_object('id',m.id,'played_at',m.played_at,'status',m.status,'team_a_name',m.team_a_name,
        'team_b_name',m.team_b_name,'team_a_score',m.team_a_score,'team_b_score',m.team_b_score)
       from public.matches m where m.pelada_id=p.id and m.status<>'draft' order by m.played_at desc, m.id desc limit 1),
     'drafts',case when pm.role in ('admin','assistant')
       then (select count(*) from public.matches m where m.pelada_id=p.id and m.status='draft') else 0 end)
    order by p.name)
   from public.pelada_memberships pm join public.peladas p on p.id=pm.pelada_id
   where pm.user_id=(select auth.uid()) and pm.status='active'), '[]'::jsonb),
  'pending', coalesce((select jsonb_agg(jsonb_build_object('match_id',s.match_id,'pelada_id',s.pelada_id,
     'pelada_name',p.name,'closes_at',s.closes_at,'team_a_name',m.team_a_name,'team_b_name',m.team_b_name,
     'team_a_score',m.team_a_score,'team_b_score',m.team_b_score) order by s.closes_at)
   from public.voting_sessions s join public.voting_eligible_members e on e.session_id=s.id
   join public.pelada_memberships pm on pm.id=e.membership_id and pm.user_id=(select auth.uid()) and pm.status='active'
   join public.peladas p on p.id=s.pelada_id join public.matches m on m.id=s.match_id
   where s.status='open' and s.closes_at > now()
    and not exists(select 1 from public.vote_receipts r where r.session_id=s.id and r.membership_id=e.membership_id)), '[]'::jsonb),
  'server_time', now());
$$;
revoke all on function public.get_my_home() from public,anon;
grant execute on function public.get_my_home() to authenticated;

---------------------------------------------------------------------------------------------------
-- A20
---------------------------------------------------------------------------------------------------

-- Top of a ranking with competition positions; keeps every player tied at the last position shown.
create function private.retro_top(p_rows jsonb, p_limit integer default 3) returns jsonb
language sql immutable set search_path = '' as $$
 with r as (select (x->>'membership_id')::uuid membership_id, x->>'name' name, (x->>'value')::numeric value
            from jsonb_array_elements(p_rows) x where (x->>'value')::numeric > 0),
 k as (select r.*, rank() over (order by value desc) rk from r)
 select coalesce(jsonb_agg(jsonb_build_object('membership_id',membership_id,'name',name,'value',value,'rank',rk)
   order by rk, name collate "C"), '[]'::jsonb)
 from k where rk <= p_limit;
$$;

create function public.get_season_retrospective(p_season uuid, p_membership uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_pelada uuid; v jsonb; v_me jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 v_pelada := private.check_season_access(p_season);
 with ms as (select id, played_at, team_a_name, team_b_name, team_a_score, team_b_score,
   abs(team_a_score-team_b_score) d, team_a_score+team_b_score t
   from public.matches where season_id=p_season and status='finalized'),
 st as (select s.*, pm.player_name name from public.player_season_stats s
   join public.pelada_memberships pm on pm.id=s.membership_id where s.season_id=p_season),
 aw as (select a.*, pm.player_name name from public.awards a join public.pelada_memberships pm on pm.id=a.membership_id
   where a.season_id=p_season and a.status='active')
 select jsonb_build_object(
  'matches', (select count(*) from ms),
  'goals', (select coalesce(sum(t),0) from ms),
  'biggest_win', (select to_jsonb(x) - 'd' - 't' from ms x where d > 0 order by d desc, t desc, played_at, id limit 1),
  'most_goals', (select to_jsonb(x) - 'd' - 't' from ms x where t > 0 order by t desc, played_at, id limit 1),
  'scorers', private.retro_top((select coalesce(jsonb_agg(jsonb_build_object('membership_id',membership_id,'name',name,'value',goals)),'[]') from st)),
  'assisters', private.retro_top((select coalesce(jsonb_agg(jsonb_build_object('membership_id',membership_id,'name',name,'value',assists)),'[]') from st)),
  'presence', private.retro_top((select coalesce(jsonb_agg(jsonb_build_object('membership_id',membership_id,'name',name,'value',matches_played)),'[]') from st)),
  'craques', private.retro_top((select coalesce(jsonb_agg(jsonb_build_object('membership_id',membership_id,'name',name,'value',c)),'[]')
     from (select membership_id, min(name) name, count(*) c from aw where award_type='match_craque' group by membership_id) x)),
  'bola_murcha', private.retro_top((select coalesce(jsonb_agg(jsonb_build_object('membership_id',membership_id,'name',name,'value',c)),'[]')
     from (select membership_id, min(name) name, count(*) c from aw where award_type='bola_murcha' group by membership_id) x)),
  'kings', (select coalesce(jsonb_agg(jsonb_build_object('month',period_month,'names',names) order by period_month),'[]')
     from (select period_month, jsonb_agg(name order by name) names from aw where award_type='monthly_king' group by period_month) x))
 into v;

 if p_membership is not null and exists(select 1 from public.pelada_memberships where id=p_membership and pelada_id=v_pelada) then
  select jsonb_build_object('matches',s.matches_played,'wins',s.wins,'draws',s.draws,'losses',s.losses,'goals',s.goals,
   'assists',s.assists,'craque',s.craque_awards,
   'kings',(select count(*) from public.awards a where a.membership_id=p_membership and a.season_id=p_season
     and a.award_type='monthly_king' and a.status='active'))
  into v_me from public.player_season_stats s where s.season_id=p_season and s.membership_id=p_membership and s.matches_played > 0;
 end if;
 return v || jsonb_build_object('me', v_me);
end $$;

revoke all on function private.retro_top(jsonb,integer) from public,anon,authenticated;
revoke all on function public.get_season_retrospective(uuid,uuid) from public,anon;
grant execute on function public.get_season_retrospective(uuid,uuid) to authenticated;

revoke all on function private.recompute_season_cards(uuid,uuid), private.record_card_corrections(),
 private.on_period_award_changed() from public,anon,authenticated;
