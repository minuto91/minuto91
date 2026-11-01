-- Minuto 91 / 069: preparação do beta — liga RLS (sem policies) nas 12 tabelas do schema private que ainda não tinham.
-- Defesa em profundidade: o schema private não é exposto pela API e nenhuma destas tabelas tem grant para anon/authenticated/PUBLIC.
-- Pré-condição verificada no dev (diagnóstico da Fase 1): TODAS as funções que acessam estas tabelas são SECURITY DEFINER
-- (nenhuma SECURITY INVOKER), então o dono da função continua acessando normalmente. Sem policies = ninguém mais acessa.
-- Não altera dados, funções, motor V7.7 nem migrações anteriores.
-- Rollback: alter table private.<tabela> disable row level security; (uma por tabela).

alter table private.match_schedule_events enable row level security;
alter table private.match_secondary_confirmations enable row level security;
alter table private.pelada_create_requests enable row level security;
alter table private.season_lifecycle_events enable row level security;
alter table private.v85_operations enable row level security;
alter table private.team_composition_ops enable row level security;
alter table private.v86_activation enable row level security;
alter table private.v86_events enable row level security;
alter table private.monthly_goalkeeper_results enable row level security;
alter table private.season_craque_polls enable row level security;
alter table private.season_craque_electors enable row level security;
alter table private.season_craque_ballots enable row level security;
