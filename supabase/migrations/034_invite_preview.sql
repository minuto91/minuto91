-- Minuto 91 / 034: invite preview (V4.1, invitations).
-- Before joining, the invited person sees which pelada the invite is for. Returns only what the
-- holder of a valid token is meant to know: the pelada name and whether the caller is already an active
-- member (then the app opens the pelada instead of asking for a position). No members, no crest, no
-- statistics. Invalid, expired, revoked or used-up tokens all answer {"valid": false} (same as
-- join_pelada, 004, which stays the only way in and keeps every check: expiry, revocation, use limit,
-- pelada status, capacity, returning member, onboarding).
-- Requires a signed-in user (the link opened without login shows only a generic screen).

create function public.get_invite_preview(p_token text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_inv private.pelada_invites%rowtype; v_name text; v_member uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return jsonb_build_object('valid', false); end if;
 select * into v_inv from private.pelada_invites where token_hash=encode(extensions.digest(p_token,'sha256'),'hex');
 if not found or v_inv.revoked_at is not null or v_inv.expires_at <= now() or v_inv.uses >= v_inv.max_uses then
  return jsonb_build_object('valid', false); end if;
 select name into v_name from public.peladas where id=v_inv.pelada_id and status='active';
 if v_name is null then return jsonb_build_object('valid', false); end if;
 select id into v_member from public.pelada_memberships
 where pelada_id=v_inv.pelada_id and user_id=auth.uid() and status='active';
 return jsonb_build_object('valid', true, 'pelada_name', v_name, 'already_member', v_member is not null,
  'pelada_id', case when v_member is not null then v_inv.pelada_id end);
end $$;

revoke all on function public.get_invite_preview(text) from public, anon;
grant execute on function public.get_invite_preview(text) to authenticated;
