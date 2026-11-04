-- Minuto 91 / 077 (V10.0, REV-140): Termos de Uso 1.3 — nova cláusula 4.7 (o administrador/assistente declara que
-- os convidados que incluir têm 18 anos ou mais). Substitui o controle "Declaro que o convidado tem 18 anos"
-- da súmula e do sorteio. Quem já aceitou a 1.2 é convidado a aceitar de novo no próximo acesso.
-- [VALIDAR COM ADVOGADO] antes de aplicar em produção. A declaração por convidado continua registrada em
-- public.guests.adult_declared_at (a RPC segue exigindo p_adult_declared = true; o app envia true por força do aceite).
-- Rollback: update private.app_config set value='{"terms":"1.2","privacy":"1.3"}' where key='legal_versions'.
update private.app_config set value='{"terms":"1.3","privacy":"1.3"}'::jsonb where key='legal_versions';
