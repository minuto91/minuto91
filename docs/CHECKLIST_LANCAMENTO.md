# Checklist de lançamento — o que depende do fundador

Estado em 01/11/2026. Código e dev estão prontos para o **beta fechado**; abaixo está tudo que só você pode fazer (contas,
chaves, jurídico, arte), com o próximo passo concreto de cada item. Nada aqui foi aplicado em produção (não existe projeto de
produção ainda). Valores de preço e exigências das lojas mudam: **confira no site da loja antes de pagar ou submeter**.

Legenda: ☐ a fazer · ◐ em andamento · ✔ feito

## A. Contas

| # | Item | Estado | Próximo passo concreto |
|---|---|---|---|
| A1 | **Apple Developer Program** (US$ 99/ano; necessário para TestFlight e App Store) | ☐ | Entrar em developer.apple.com/programs/enroll com um Apple ID com verificação em duas etapas. Como pessoa física é mais rápido; como empresa exige número D-U-N-S. Anotar o **Team ID** (Membership). |
| A2 | **Google Play Console** (US$ 25, uma vez) | ☐ | Criar em play.google.com/console e concluir a verificação de identidade. |
| A3 | **Teste fechado do Google Play** | ☐ | Contas pessoais novas costumam precisar de um número mínimo de testadores por um período mínimo antes da produção (hoje: 12 testadores por 14 dias seguidos — **confirme a regra vigente na Play Console**). Montar a lista de e-mails dos testadores (precisam de conta Google) e criar a trilha "Teste fechado". Isso encaixa com o beta fechado. |
| A4 | Conta **Expo/EAS** | ✔ | Projeto `@rafaabreus-team/minuto91` criado (projectId no `app.json`). |
| A5 | **RevenueCat** | ☐ | Criar projeto em app.revenuecat.com; adicionar o app iOS (`com.minuto91.app`) e o Android (`com.minuto91.app`); anotar as duas **chaves públicas do SDK** (vão para o EAS, ver C2). |

## B. Assinatura (Fase 2 do PRD; no beta o Premium é liberado a todos, sem cobrança)

`private.app_config.premium_beta_open = true` mantém o Premium aberto. Estes itens só são necessários para o lançamento.

| # | Item | Estado | Próximo passo concreto |
|---|---|---|---|
| B1 | Produto de assinatura mensal no **App Store Connect** | ☐ | Depois de A1: App Store Connect → Assinaturas → criar grupo + produto mensal. Anotar o **ID do produto**. |
| B2 | Produto de assinatura no **Google Play** | ☐ | Depois de A2: Monetizar → Assinaturas → criar o produto/base plan mensal. O ID deve ser o mesmo da B1, se possível. |
| B3 | Produtos e *offering* no **RevenueCat** | ☐ | Cadastrar os dois produtos, criar o *entitlement* e a *offering*. |
| B4 | ID do produto no app e no banco | ☐ | Colocar o ID em `EXPO_PUBLIC_PREMIUM_PRODUCT_ID` (EAS) e em `private.app_config` `premium_product_ids` (o webhook confere os dois). |
| B5 | Webhook do RevenueCat | ☐ | No RevenueCat → Integrations → Webhooks: URL `https://<ref>.supabase.co/functions/v1/revenuecat-webhook`, cabeçalho `Authorization` = valor do segredo `REVENUECAT_WEBHOOK_AUTH`. Opcional: segredo `REVENUECAT_ENVIRONMENT` (`SANDBOX` no dev, `PRODUCTION` na produção). **Testar com um evento de sandbox** (hoje a função não foi testada de ponta a ponta). |

## C. Supabase e EAS

| # | Item | Estado | Próximo passo concreto |
|---|---|---|---|
| C1 | **Projeto Supabase de produção** | ☐ | Criar um projeto novo (nome sugerido: `minuto91-prod`). Aplicar as migrações **001 a 074 em ordem** (a 075 é a próxima livre) (no dev, 001–057 foram aplicadas fora do histórico; para produção use o histórico completo, p. ex. `supabase db push`). Rodar `tests_editor` no SQL Editor depois. Publicar as 4 Edge Functions de `supabase/functions` com JWT desligado. |
| C2 | **Variáveis por perfil no EAS** | ☐ | `eas env:create --environment preview --name EXPO_PUBLIC_SUPABASE_URL --visibility plaintext` (e o mesmo para `..._ANON_KEY`, `EXPO_PUBLIC_REVENUECAT_IOS_KEY`, `EXPO_PUBLIC_REVENUECAT_ANDROID_KEY`, `EXPO_PUBLIC_PREMIUM_PRODUCT_ID`). `preview` aponta para o dev; `production` só depois de C1. Nunca colocar a chave secreta (`service_role`) no EAS. |
| C3 | **SMTP próprio** (o padrão do Supabase tem limite baixo de envio; PRD RF-001) | ☐ | Escolher um provedor de e-mail transacional (Resend, Amazon SES, Postmark ou similar); verificar o domínio (SPF e DKIM); em Supabase → Authentication → SMTP Settings preencher host, porta, usuário e senha; testar o código de 6 dígitos do login por e-mail. |
| C4 | Segredos das Edge Functions | ☐ | Em Edge Functions → Secrets, no dev e na produção: `ACCOUNT_PURGE_AUTH`, `PUSH_SENDER_SECRET`, `STORAGE_CLEANUP_AUTH`, `REVENUECAT_WEBHOOK_AUTH` (strings aleatórias longas, uma por função); `EXPO_ACCESS_TOKEN` só se o "push security" estiver ligado na conta Expo. **No dev, `ACCOUNT_PURGE_AUTH` ainda tem um valor de teste que apareceu no chat: troque.** |
| C5 | Agendamentos (cron) | ☐ | `push-sender`: rodar uma vez `supabase/deploy/push_sender_cron.sql` (precisa de pg_cron, pg_net e o segredo). `account-purge` e `storage-cleanup`: agendar chamada a cada hora com o cabeçalho `Authorization` igual ao segredo respectivo (mesmo modelo do script do push). Não existe script pronto para esses dois. |
| C6 | Proteção contra senhas vazadas | ☐ | Supabase → Authentication → (Passwords/Providers) → ativar "Prevent use of leaked passwords". Pode exigir plano pago. É o alerta `auth_leaked_password_protection` do advisor. |
| C7 | Login com Apple | ☐ | Depois de A1: criar o App ID `com.minuto91.app` com "Sign in with Apple" (o EAS pode fazer isso no primeiro build iOS). No Supabase → Authentication → Providers → Apple: ativar e colocar `com.minuto91.app` em **Client IDs**. Basta para o fluxo nativo; Service ID, Key ID, chave `.p8` e redirect só se um dia houver login com Apple na web ou no Android. |
| C8 | Login com Google | ◐ | Conferir se o provedor Google está ativo com Client ID e Secret do Google Cloud, e se `minuto91://auth-callback` está em Authentication → URL Configuration → Redirect URLs. Não verifiquei isso no dev. |
| C9 | Teste de push no aparelho | ☐ | `eas build --profile development` → instalar → Minha conta → Notificações → Ativar → conferir `select * from public.push_devices` → com `PUSH_SENDER_SECRET` e cron (C5) enviar um aviso real. No iOS é preciso a credencial de push da Apple (o EAS oferece criar). |
| C10 | Teste do app com o escopo do beta | ☐ | `eas build --profile preview` (já tem `EXPO_PUBLIC_BETA_SCOPE=core`) → conferir que Financeiro, Sorteio, Escalações, Craque/Prêmios da temporada, Personalizar Central e o guia de Cards não aparecem, e que nenhuma rota `dev-*` abre. |
| C11 | Limpeza do dev | ☐ | Apagar: usuário `zz-teste-purga-b@example.invalid`, pelada `ZZ-TESTE-PURGA`, 2 solicitações de exclusão de teste e a Edge Function `seed-upload-tmp` (painel → Edge Functions → Delete). |

## D. Marca e loja

| # | Item | Estado | Próximo passo concreto |
|---|---|---|---|
| D1 | **Arquivos da logo** | ☐ | Substituir os arquivos de `app/assets/images/` pelos tamanhos de `app/assets/branding/LEIA-ME.md` (`icon.png` 1024², `android-icon-foreground.png` 1024², `android-icon-monochrome.png` 1024², `splash-icon.png` 1024², opcional `notification-icon.png` 96²). Depois refazer o build. |
| D2 | **Screenshots** | ☐ | Tirar capturas do app real (build `preview`): Central, Pelada, Votação, Resultado/Card, Rankings. Tamanhos mudam por loja: Apple pede o conjunto do iPhone de tela maior (hoje 6,9"); Google pede no mínimo 2 capturas de celular e um gráfico de recursos de **1024 × 500**. **Confira os tamanhos vigentes** em App Store Connect e Play Console. |
| D3 | Ficha da loja | ☐ | Nome, subtítulo, descrição, palavras-chave, categoria (Esportes), contato de suporte (e-mail) e classificação etária (o app tem conteúdo gerado por usuários: apelidos, fotos e escudos, com denúncia e bloqueio implementados). |

## E. Jurídico e privacidade

| # | Item | Estado | Próximo passo concreto |
|---|---|---|---|
| E1 | **Domínio com Termos e Política hospedados** | ☐ | Registrar um domínio; publicar numa página pública os textos de `docs/Minuto91_Termos_de_Uso_v1.1.pdf` e `docs/Minuto91_Politica_de_Privacidade_v1.2.pdf` (também estão dentro do app em `termos` e `privacidade`). A **URL da política de privacidade é obrigatória** nas duas lojas. Depois dá para usar o domínio nos links de convite (`EXPO_PUBLIC_INVITE_BASE_URL`) e, se quiser, Universal Links. |
| E2 | **App Privacy (Apple)** e **Data Safety (Google)** | ☐ | Rascunho a partir do que o código usa — **confirme contra a Política**: e-mail, nome/apelido, foto (opcional), ID do usuário, token de notificação (push), histórico de compras (RevenueCat, no lançamento), estatísticas de jogo e conteúdo gerado pelo usuário. Não há SDK de analytics nem de relatório de falhas no `package.json`. Sem rastreamento entre apps. Marcar que a conta pode ser excluída no app (RF-013). |
| E3 | **Validação jurídica da PT-05** (retenção na exclusão de conta) | ☐ | Enviar a um advogado de LGPD: PRD RF-013 e RN-101 a RN-110, `docs/v45_lgpd_retencao_e_minuta_politica.md`, os Termos e a Política. Perguntas: o histórico esportivo como "Aposentado" até o fim da temporada, sem nome, foto ou perfil, atende à LGPD? E o tratamento de menores (RF-001: declaração de 18+, LGPD art. 14)? As lojas exigem o fluxo de exclusão antes da submissão. |
| E4 | Declaração de criptografia (App Store Connect) | ☐ | O app usa só HTTPS padrão; a resposta usual é "isenta" (`ITSAppUsesNonExemptEncryption`). Quem declara é você, ao enviar o build. |

## F. Distribuição do beta

| # | Item | Estado | Próximo passo concreto |
|---|---|---|---|
| F1 | iPhone: TestFlight | ☐ | Depois de A1, C2, C7, D1: `eas build --profile preview --platform ios` → `eas submit` (ou TestFlight direto). Testadores internos entram na hora; externos exigem revisão da Apple ("Beta App Review"). |
| F2 | Android: teste fechado | ☐ | Depois de A2, A3, D1: `eas build --profile production --platform android` (gera `.aab`), enviar na trilha de teste fechado e convidar os testadores. Para o `production` valer, C1 precisa estar pronto. |
| F3 | Indicadores do beta | ☐ | Definir com os administradores do beta as metas da seção 11 do PRD e a pergunta sobre rodízio (PRD 10.4). |

## Ordem sugerida

1. D1 (logo) e A1/A2 (contas) — têm prazo de aprovação.
2. C1 + C3 + C4 + C5 (produção, SMTP, segredos, cron).
3. C2 + C7 + C8, depois os testes C9 e C10 com build `preview` no dev.
4. E1 + E2 + E3 em paralelo, desde já.
5. F1 e F2. As assinaturas (B) ficam para o lançamento.
