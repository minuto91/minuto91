-- Minuto 91 / 024: account transfer by code (Doc 04 sec. 29.3, Terms of Use clause 22,
-- PRD RF-001). Replaces automatic e-mail linking (does not work with Apple's hidden e-mail).
-- create_transfer_code(): signed-in, onboarded user; random code of 16 characters
-- (shown once, as XXXX-XXXX-XXXX-XXXX), valid 30 days, single use; a new code revokes
-- the previous one. Only the SHA-256 of the code is stored; it is never logged.
-- redeem_transfer_code(code): the destination account (onboarded, no active pelada)
-- receives every membership of the source account - history, cards, stickers, roles
-- (admin included) and open-voting receipts follow, because they belong to the
-- membership. Ballots are not identity-linked and are not touched. Premium stays with
-- the pelada and the store account that paid. The source account is deactivated and
-- receives an essential notification. At most 5 attempts per hour per destination.
-- Atomic and locked per pelada, like succession.

create table private.account_transfer_codes (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null,
 code_hash text not null unique,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null,
 redeemed_at timestamptz,
 redeemed_by uuid,
 revoked_at timestamptz
);
create unique index one_active_transfer_code on private.account_transfer_codes(user_id)
 where redeemed_at is null and revoked_at is null;

create table private.account_transfer_attempts (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null,
 succeeded boolean not null,
 created_at timestamptz not null default now()
);
create index transfer_attempts_recent on private.account_transfer_attempts(user_id, created_at desc);
revoke all on private.account_transfer_codes, private.account_transfer_attempts from public,anon,authenticated;

-- Deactivated (transferred) accounts cannot create or join peladas.
alter table public.profiles add column deactivated_at timestamptz;

create or replace function private.require_onboarded() returns void language plpgsql
security definer set search_path = '' as $$
begin
 if not exists(select 1 from public.profiles
   where id=(select auth.uid()) and adult_declared_at is not null and terms_accepted_at is not null) then
  raise exception 'ONBOARDING_REQUIRED' using errcode='42501';
 end if;
 if exists(select 1 from public.profiles where id=(select auth.uid()) and deactivated_at is not null) then
  raise exception 'ACCOUNT_DEACTIVATED' using errcode='42501';
 end if;
 if exists(select 1 from private.account_deletion_requests where user_id=(select auth.uid()) and status='pending') then
  raise exception 'ACCOUNT_DELETION_PENDING' using errcode='42501';
 end if;
end $$;

-- Normalized form hashed with SHA-256 (upper case, no separators).
create function private.transfer_code_hash(p_code text) returns text
language sql immutable set search_path = '' as $$
 select encode(extensions.digest(upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g')), 'sha256'), 'hex');
$$;

create function public.create_transfer_code() returns text
language plpgsql security definer set search_path = '' as $$
declare c_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- no 0/O, 1/I
 v_bytes bytea := extensions.gen_random_bytes(16); v_code text := ''; i integer;
begin
 perform private.require_onboarded();
 for i in 0..15 loop
  v_code := v_code || substr(c_alphabet, (get_byte(v_bytes, i) % 32) + 1, 1);
 end loop;
 update private.account_transfer_codes set revoked_at=now()
 where user_id=auth.uid() and redeemed_at is null and revoked_at is null;
 insert into private.account_transfer_codes(user_id,code_hash,expires_at)
 values(auth.uid(), private.transfer_code_hash(v_code), now() + interval '30 days');
 insert into private.audit_events(actor_user_id,event_type) values(auth.uid(),'transfer_code_created');
 return substr(v_code,1,4)||'-'||substr(v_code,5,4)||'-'||substr(v_code,9,4)||'-'||substr(v_code,13,4);
end $$;

create function public.revoke_transfer_code() returns void
language sql security definer set search_path = '' as $$
 update private.account_transfer_codes set revoked_at=now()
 where user_id=(select auth.uid()) and redeemed_at is null and revoked_at is null;
$$;

-- Returns {"peladas": n}. An invalid, used, expired or revoked code returns
-- {"error": "INVALID_TRANSFER_CODE"} instead of raising, so the failed attempt is kept
-- for the rate limit. Raises TOO_MANY_ATTEMPTS, DESTINATION_HAS_PELADA, DESTINATION_CONFLICT.
create function public.redeem_transfer_code(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c_max_attempts constant integer := 5; v_dest uuid := auth.uid(); v_code private.account_transfer_codes;
 v_pelada uuid; v_count integer;
begin
 perform private.require_onboarded();
 if (select count(*) from private.account_transfer_attempts where user_id=v_dest
   and created_at > now() - interval '1 hour') >= c_max_attempts then
  raise exception 'TOO_MANY_ATTEMPTS'; end if;
 if exists(select 1 from public.pelada_memberships where user_id=v_dest and status='active') then
  raise exception 'DESTINATION_HAS_PELADA'; end if;

 select * into v_code from private.account_transfer_codes where code_hash=private.transfer_code_hash(p_code)
 for update;
 if not found or v_code.redeemed_at is not null or v_code.revoked_at is not null or v_code.expires_at <= now()
   or v_code.user_id=v_dest or exists(select 1 from private.account_deletion_requests
    where user_id=v_code.user_id and status='pending')
   or not exists(select 1 from public.profiles where id=v_code.user_id and deactivated_at is null) then
  insert into private.account_transfer_attempts(user_id,succeeded) values(v_dest,false);
  return jsonb_build_object('error','INVALID_TRANSFER_CODE');
 end if;
 -- The destination may have left a pelada of the source: one record per user and pelada.
 if exists(select 1 from public.pelada_memberships d join public.pelada_memberships s on s.pelada_id=d.pelada_id
   where d.user_id=v_dest and s.user_id=v_code.user_id) then
  raise exception 'DESTINATION_CONFLICT'; end if;

 for v_pelada in select distinct pelada_id from public.pelada_memberships where user_id=v_code.user_id order by 1 loop
  perform 1 from public.peladas where id=v_pelada for update;
 end loop;
 update public.pelada_memberships set user_id=v_dest where user_id=v_code.user_id;
 get diagnostics v_count = row_count;
 update private.account_transfer_codes set redeemed_at=now(), redeemed_by=v_dest where id=v_code.id;
 update public.profiles set deactivated_at=now() where id=v_code.user_id;
 insert into private.account_transfer_attempts(user_id,succeeded) values(v_dest,true);
 insert into private.audit_events(actor_user_id,event_type,metadata)
 values(v_dest,'account_transferred',jsonb_build_object('source_user_id',v_code.user_id,'memberships',v_count));
 perform private.notify(v_code.user_id, null, 'account_transferred', 'essential', 'transfer:'||v_code.id,
  jsonb_build_object('memberships',v_count));
 return jsonb_build_object('peladas',v_count);
end $$;

revoke all on function private.transfer_code_hash(text) from public,anon,authenticated;
revoke all on function public.create_transfer_code(), public.revoke_transfer_code(), public.redeem_transfer_code(text)
 from public,anon;
grant execute on function public.create_transfer_code(), public.revoke_transfer_code(), public.redeem_transfer_code(text)
 to authenticated;
