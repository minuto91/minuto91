-- Minuto 91 / 020b: the 019 policy career_stats_read calls private.pelada_has_premium,
-- but 005 revoked that function from authenticated, and RLS expressions run with the
-- reader's privileges ("permission denied for function pelada_has_premium").
-- Granting EXECUTE only exposes a yes/no Premium flag, and the private schema is not
-- reachable through the API.
grant execute on function private.pelada_has_premium(uuid) to authenticated;
