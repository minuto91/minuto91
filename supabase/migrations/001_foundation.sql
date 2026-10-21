-- Minuto 91 / 001: foundation. Apply in numerical order.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create table private.audit_events (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid, actor_user_id uuid, subject_membership_id uuid,
 event_type text not null, metadata jsonb not null default '{}'::jsonb,
 occurred_at timestamptz not null default now()
);
revoke all on private.audit_events from public, anon, authenticated;

-- Only privileged functions should mutate application-owned records.
-- private is deliberately NOT an exposed Supabase API schema.
