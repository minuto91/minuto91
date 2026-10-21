-- Minuto 91 / 003: peladas and memberships (v1.1).
create table public.peladas (
 id uuid primary key default gen_random_uuid(),
 name text not null check (length(btrim(name)) between 2 and 100),
 description text check (description is null or length(description)<=1000),
 crest_path text,
 image_path text,
 recurring_weekday smallint check (recurring_weekday is null or recurring_weekday between 0 and 6),
 recurring_time time,
 -- Admin-designated successor (optional). Composite FK added below.
 successor_membership_id uuid,
 created_by uuid references auth.users(id) on delete set null,
 status text not null default 'active' check(status in ('active','restricted','archived')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create trigger peladas_touch before update on public.peladas
for each row execute function private.touch_updated_at();

create table public.pelada_memberships (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id) on delete restrict,
 user_id uuid references auth.users(id) on delete set null,
 player_name text not null check(length(btrim(player_name)) between 1 and 80),
 role text not null default 'player' check(role in ('admin','assistant','player')),
 status text not null default 'active' check(status in ('active','left','retired','suspended')),
 -- The ONLY position that defines formula and card weights (profile position).
 preferred_position text not null check(preferred_position in ('goalkeeper','defender','midfielder','attacker')),
 joined_at timestamptz not null default now(),
 -- Seniority among assistants for succession (set when designated).
 assistant_since timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(id,pelada_id),
 constraint memberships_assistant_since_consistent check ((role='assistant') = (assistant_since is not null))
);
alter table public.peladas add constraint peladas_successor_fk
 foreign key (successor_membership_id, id) references public.pelada_memberships(id, pelada_id);
create trigger memberships_touch before update on public.pelada_memberships
for each row execute function private.touch_updated_at();
-- One sporting identity per authenticated user in a pelada, including rejoining.
create unique index memberships_one_user_per_pelada on public.pelada_memberships(pelada_id,user_id) where user_id is not null;
create unique index memberships_one_active_admin on public.pelada_memberships(pelada_id) where role='admin' and status='active';
create index memberships_by_pelada on public.pelada_memberships(pelada_id,status,joined_at,id);
create index memberships_by_user on public.pelada_memberships(user_id,pelada_id);

create table private.pelada_invites (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id) on delete cascade,
 token_hash text not null unique,
 created_by uuid references auth.users(id) on delete set null,
 expires_at timestamptz not null,
 max_uses integer not null check(max_uses between 1 and 1000),
 uses integer not null default 0 check(uses>=0),
 revoked_at timestamptz,
 created_at timestamptz not null default now(),
 check (uses <= max_uses)
);
revoke all on private.pelada_invites from public,anon,authenticated;

-- RLS helpers are SECURITY DEFINER to avoid recursion in the memberships policy.
create function private.is_active_member(p_pelada uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.pelada_memberships m
 where m.pelada_id=p_pelada and m.user_id=(select auth.uid()) and m.status='active');
$$;
create function private.is_active_admin(p_pelada uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.pelada_memberships m
 where m.pelada_id=p_pelada and m.user_id=(select auth.uid())
 and m.status='active' and m.role='admin');
$$;
create function private.shares_pelada(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.pelada_memberships me
 join public.pelada_memberships other on other.pelada_id=me.pelada_id
 where me.user_id=(select auth.uid()) and me.status='active'
 and other.user_id=p_user and other.status='active');
$$;
revoke all on function private.is_active_member(uuid) from public,anon;
revoke all on function private.is_active_admin(uuid) from public,anon;
revoke all on function private.shares_pelada(uuid) from public,anon;
grant execute on function private.is_active_member(uuid),private.is_active_admin(uuid),private.shares_pelada(uuid) to authenticated;

alter table public.peladas enable row level security;
alter table public.pelada_memberships enable row level security;
revoke all on public.peladas,public.pelada_memberships from anon,authenticated;
grant select on public.peladas,public.pelada_memberships to authenticated;
create policy peladas_read_members on public.peladas for select to authenticated
 using ((select private.is_active_member(id)));
create policy memberships_read_peers on public.pelada_memberships for select to authenticated
 using ((select private.is_active_member(pelada_id)));
create policy profiles_read_peers on public.profiles for select to authenticated
 using ((select private.shares_pelada(id)));
-- No client INSERT/UPDATE/DELETE grants for peladas or memberships.
