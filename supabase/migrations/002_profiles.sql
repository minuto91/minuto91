-- Minuto 91 / 002: profiles (v1.1: adulthood declaration + terms acceptance).
create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 display_name text not null check (length(btrim(display_name)) between 1 and 80),
 avatar_path text,
 -- Set once by complete_onboarding(); NULL until the user finishes onboarding.
 -- Date of birth is deliberately NOT stored.
 adult_declared_at timestamptz,
 terms_accepted_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint profiles_onboarding_consistent
  check ((adult_declared_at is null) = (terms_accepted_at is null))
);
create function private.touch_updated_at() returns trigger language plpgsql
set search_path = '' as $$ begin new.updated_at := now(); return new; end $$;
create trigger profiles_touch before update on public.profiles
for each row execute function private.touch_updated_at();

-- Works for e-mail sign-up (options.data.display_name) and for Apple/Google
-- sign-in (full_name / name). The adulthood/terms declaration cannot be passed
-- at OAuth sign-up, so it is recorded afterwards by complete_onboarding().
create function private.on_auth_user_created() returns trigger language plpgsql
security definer set search_path = '' as $$
begin
 insert into public.profiles(id, display_name)
 values(new.id, left(coalesce(
   nullif(btrim(new.raw_user_meta_data->>'display_name'),''),
   nullif(btrim(new.raw_user_meta_data->>'full_name'),''),
   nullif(btrim(new.raw_user_meta_data->>'name'),''),
   'Jogador'),80))
 on conflict (id) do nothing;
 return new;
end $$;
create trigger auth_user_profile after insert on auth.users
for each row execute function private.on_auth_user_created();

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
-- The client can edit only these columns; consent timestamps are server-set.
grant update (display_name, avatar_path) on public.profiles to authenticated;
create policy profiles_select_self on public.profiles for select to authenticated
using (id = (select auth.uid()));
create policy profiles_update_self on public.profiles for update to authenticated
using (id = (select auth.uid())) with check (id = (select auth.uid()));
revoke all on function private.on_auth_user_created() from public, anon, authenticated;
revoke all on function private.touch_updated_at() from public, anon, authenticated;

-- Onboarding: the user declares being 18+ and accepts the terms. Both flags
-- must be true; timestamps are written once and never overwritten.
create function public.complete_onboarding(p_display_name text, p_adult boolean, p_terms boolean)
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
end $$;
revoke all on function public.complete_onboarding(text,boolean,boolean) from public, anon;
grant execute on function public.complete_onboarding(text,boolean,boolean) to authenticated;

-- Used by the other RPCs: no sporting action before onboarding is complete.
create function private.require_onboarded() returns void language plpgsql
security definer set search_path = '' as $$
begin
 if not exists(select 1 from public.profiles
   where id=(select auth.uid()) and adult_declared_at is not null and terms_accepted_at is not null) then
  raise exception 'ONBOARDING_REQUIRED' using errcode='42501';
 end if;
end $$;
revoke all on function private.require_onboarded() from public, anon;
grant execute on function private.require_onboarded() to authenticated;
