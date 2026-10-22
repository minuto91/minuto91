-- Simula o mínimo do Supabase que as migrações usam (papéis, auth, storage, extensions).
-- Só para o banco local descartável; nunca rodar no Supabase.
do $$ begin
 if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
 if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
 if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists extensions;
create schema if not exists auth;
create schema if not exists storage;
grant usage on schema extensions, auth, storage to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
create table auth.users (
 id uuid primary key, instance_id uuid, aud text, role text, email text, encrypted_password text,
 email_confirmed_at timestamptz, raw_user_meta_data jsonb default '{}'::jsonb, raw_app_meta_data jsonb default '{}'::jsonb,
 created_at timestamptz default now(), updated_at timestamptz default now(), deleted_at timestamptz);
create function auth.uid() returns uuid language sql stable as
 $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create function auth.role() returns text language sql stable as
 $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), current_user::text) $$;
grant execute on function auth.uid(), auth.role() to anon, authenticated, service_role;
create table storage.buckets (id text primary key, name text, public boolean default false,
 file_size_limit bigint, allowed_mime_types text[], created_at timestamptz default now());
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id),
 name text, owner uuid, metadata jsonb, created_at timestamptz default now(), updated_at timestamptz default now());
alter table storage.objects enable row level security;
grant select, insert, update, delete on storage.objects to authenticated;
create function storage.foldername(name text) returns text[] language sql immutable as
 $$ select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $$;
grant execute on function storage.foldername(text) to anon, authenticated, service_role;
