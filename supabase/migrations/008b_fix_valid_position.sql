-- Minuto 91 / 008b: valid_position(NULL) returned NULL, so "not valid_position(x)"
-- let an empty position through to a NOT NULL error instead of INVALID_POSITION
-- (create_pelada, set_my_position, save_match_sheet guests). Now NULL is invalid.
-- join_pelada is unaffected: it checks "p_position is not null" first.
create or replace function private.valid_position(p text) returns boolean language sql immutable
set search_path = '' as $$ select coalesce(p in ('goalkeeper','defender','midfielder','attacker'), false) $$;
