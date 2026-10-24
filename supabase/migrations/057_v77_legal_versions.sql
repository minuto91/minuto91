-- Minuto 91 / 057: V7.7 - versões das minutas legais alinhadas às regras novas (Termos 1.2, Política 1.3; texto em
-- app/src/lib/legalText.ts). Quem já aceitou a versão anterior é convidado a aceitar de novo no próximo acesso.
-- [VALIDAR COM ADVOGADO] antes de aplicar em produção.
-- Rollback: update private.app_config set value='{"terms":"1.1","privacy":"1.2"}' where key='legal_versions'.
update private.app_config set value='{"terms":"1.2","privacy":"1.3"}'::jsonb where key='legal_versions';
