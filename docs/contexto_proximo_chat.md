# Minuto 91 — contexto para continuar em outro chat

Atualizado em 22/10/2026. Leia este arquivo inteiro antes de qualquer ação.

## 1. Como trabalhar comigo
- Responda sempre em português do Brasil, direto e curto. Sou fundador solo, não desenvolvedor.
- Uso Windows + PowerShell e iPhone. Todo comando para eu rodar deve começar com o `cd` completo
  (ex.: `cd $HOME\Documents\minuto91\app; ...`).
- Quando eu precisar fazer algo fora do computador (painel, conta, celular), dê passo a passo numerado e curto.
- Em conflito entre código e documentação, pergunte antes. Decisão de produto que não está nos docs:
  pergunte uma vez, com opções, e use o padrão mais simples.
- Não adicione funcionalidades fora do escopo. Faça commits pequenos e claros.
  **Peça minha confirmação antes de todo `git push`** (não usamos PR; commit direto na `main`).
- Não rode builds EAS nem nada que gaste dinheiro sem me avisar.

## 2. Produto (resumo)
App de "resenha pós-pelada" para futebol amador (iOS + Android). Jogadores registram a partida, votam notas
sigilosas, e o app gera cartas (overall, bronze/prata/ouro), rankings, prêmios, Seleção da Rodada e álbum de
48 figurinhas. Freemium: Premium R$ 29,90/mês por pelada; no beta o Premium é liberado para todos
(`private.app_config.premium_beta_open = true`).

Fonte de verdade: `docs/Minuto91_Documentacao_Completa.pdf` (PRD v2.5, Doc 02 Regras v3.1, Doc 03 Modelo de
Dados v2.1, Doc 04 Especificação Técnica v1.1, Brand Book v2.1), Termos v1.1 e Política v1.2 (minutas).
Para ler o PDF: `pdftotext -layout -enc UTF-8 <arquivo> <saida.txt>` (Python não está instalado).

## 3. Stack e repositório
- App: React Native + Expo SDK 57 (Expo Router, TypeScript, React Compiler) em `app/` (rotas em `app/src/app`,
  código de apoio em `app/src/lib`). Leia `app/AGENTS.md` (regras do Expo).
- Backend: Supabase projeto **minuto91-dev** (ref `lqirpgqrnbsycuowwoie`, São Paulo). RevenueCat (ainda não ligado).
- Monorepo: `app/`, `supabase/` (migrations, tests, tests_editor, dev_seed, functions), `docs/`.
- GitHub privado: github.com/minuto91/minuto91 (branch `main`).

## 4. Segurança (inegociável)
- Nunca usar chave service_role / sb_secret no app nem em commit. O app usa só a chave publicável em
  `app/.env` (no .gitignore). Nunca commitar `.env`.
- Schema `private` fechado. Todo write de negócio por RPC `security definer`; cliente sem INSERT/UPDATE direto.
- Nunca rodar testes ou migrações em produção. **Nunca editar migração já aplicada**: criar nova
  (para correção fora da numeração usamos sufixo, ex.: `008b_...`, `020b_...`).
- O assistente (Claude) não pode criar contas nem digitar senhas em serviços externos (Supabase):
  eu crio as contas; para testes de votação usamos os bots sem senha (seção 8).

## 5. Banco: o que está pronto (tudo aplicado no Supabase dev e testado)
Migrações em `supabase/migrations` (ordem do Doc 04 seção 36):
001 fundação · 002 perfis · 003 peladas/membros · 004 configurações/convites · 005 sucessão · 006 temporadas ·
007 partidas · 008 participantes/convidados/eventos · 008b correção valid_position · 009 versionamento da súmula ·
010 publicação/sessões/elegibilidade · 011 cédulas protegidas · 012 envio de votos · 013 finalização e notas ·
014 estatísticas e cartas · 015 rankings/prêmios do mês/destaques/recordes · 016 Seleção da Rodada ·
017 catálogo de figurinhas · 018 progresso/desbloqueio · 019 Premium/teste grátis/eventos da loja ·
020 anulação · 020b correção de permissão · 021 exclusão de conta · 022 notificações e agendador (pg_cron) ·
023 denúncia/bloqueio/índices · 024 transferência de conta por código · 025 configurações da pelada
(admin: prazo padrão, Bola Murcha só com Premium, mínimo de notas; fuso não editável) ·
026 Premium/loja (um pendente por comprador, atributo pelada_id, eventos fora de ordem, reembolso, TRANSFER) ·
027 foto em bucket privado `avatars`, pé dominante, perfil só por RPC (update_my_profile/set_my_avatar/clear_my_avatar) ·
028 escudo da pelada (bucket privado `crests`, só o admin; set_pelada_crest/clear_pelada_crest) ·
029 privacidade do perfil e da carreira (privado/minhas peladas/público; app lê de profiles só id, nome e foto; o resto por
get_my_profile/get_player_profile) · 030 carreira global (get_player_career, respeita o Premium de cada pelada) ·
031 proteção do teste grátis (segue a pessoa na transferência, trava por conta, private.premium_trial_grants e private.trial_review).

Testes: `supabase/tests_editor/001..024_*.sql` (020 = invariantes de segurança do banco inteiro; 022 escudo, 023 privacidade e carreira, 024 teste grátis) (rodar no SQL Editor; terminam com o erro proposital
"PASS: ..." = ok e nada gravado). Versões psql em `supabase/tests/`. Cadeia pós-finalização:
`after_match_finalized` → stats/cartas (014) → `after_cards_updated` → destaques/meses (015) →
`after_rankings_updated` → Seleção (016) → `after_selection_updated` → figurinhas (018).
Fórmulas de nota e carta validadas em `docs/simulacao_formulas.xlsx` (aprovada).

## 6. Decisões de produto já tomadas (fora ou além dos docs)
- Temporada personalizada (Premium): com temporada em andamento o admin escolhe "encerrar e iniciar" ou
  "manter a atual" (muda nome/fim); exige confirmação explícita.
- Partida: data só até hoje; rascunho pode ser excluído; para publicar precisa de jogadores nos dois times.
- Correção durante a votação: garante pelo menos 1h de prazo; se mudar o conjunto de eleitores, reinicia a votação.
- Horário fixo de encerramento (Premium): entre 1h e 24h após abrir.
- Jogador sem celular (sem conta): não recebe nota nem prêmio (só estatística objetiva). Conflita com RN-004
  ("pode ter carta"): a carta dele fica sem Resenha (valor neutro 50).
- Votação inválida (<50% ou <3 votos): sem notas e sem prêmios da votação (nem Craque). O Garçom da Partida (V4.6)
  é estatística objetiva e vale mesmo assim (decisão de 23/10).
- **Seleção da Rodada sem adaptação de posição**: vaga sem candidato fica vazia. Isso muda Doc 02 RN-075,
  Doc 03 21.4 e Doc 04 25.1 (atualizar os docs).
- Maior Evolução do mês: quem mudou de posição no mês não concorre.
- Teste grátis de 30 dias: começa por botão do admin (não automático); bloqueado durante o beta.
- Anulação: 4 categorias (erro na súmula, partida duplicada, partida não aconteceu, outro).
- Exclusão de conta: vira "Aposentado" na hora; 30 dias para recuperar (volta como jogador, sem admin);
  depois apaga perfil e login. Precisa constar na Política/Termos [VALIDAR COM ADVOGADO].
- Denúncia e bloqueio (RN-120/RF-014) implementados na 023.
- Evolução V2 (22/10): carreira global respeita o plano de cada pelada (grátis = temporada atual e anterior); "Privado" esconde
  só a área global (dentro da pelada nome, foto e carta seguem visíveis); padrão "minhas peladas"; bloqueio esconde perfil e
  carreira nos dois sentidos; Bola Murcha não é conquista; teste grátis com registro e alerta para revisão manual, sem bloqueio.
  Relatório: `docs/relatorio_evolucao_v2_2026-10-22.md`.

## 7. App: o que está pronto (tsc, lint e bundle iOS limpos)
Telas: login (e-mail, Google; Apple só aparece se disponível), onboarding (18+ e termos), início (peladas,
aviso de conta em exclusão), criar pelada, entrar com convite, convite por link, pelada (membros, convidar,
assistente, sucessor, sair, partidas, rankings, minha carta, Premium, denunciar), súmula (rascunho e correção,
convidados, gols/assistências/vermelhos, gol sem autor/gol contra, publicar 2/4/6h, excluir), partida (placar,
súmula, quem falta votar, votar/editar, corrigir, encerrar após prazo, resultado com Craque/Bola Murcha/notas,
bloqueio para quem não votou), votação (conferir súmula, notas 0–10 em 0,5, "não vi jogar", Craque, Bola
Murcha, rascunho, envio), carta (overall, categoria, provisória, 5 atributos, temporada, prêmios, denunciar,
bloquear), rankings (overall/gols/assistências/média/jogos/vitórias, prêmios do mês, recordes), álbum
(9 coleções, 48 figurinhas, progresso), Premium da pelada (estado + teste grátis), Minha conta (código de
transferência gerar/usar, bloqueados, excluir/recuperar), anulação de partida (admin, até 7 dias, prévia do
impacto e motivo), configurações da pelada (admin), Seleção da Rodada na partida, destaques da última rodada
na pelada, denunciar convidado (na partida). Artes 9:16 em `lib/arts.tsx` (+ `lib/share.ts`, react-native-view-shot
e expo-sharing): resultado/Craque e Seleção (só para quem vê as notas), carta e figurinha (só as próprias).
A arte da Seleção foi vista só com dados simulados (o dev não tem 11 jogadores com nota). Missão de auditoria (21-22/10): ver `docs/relatorio_final_2026-10-22.md` (checklist de lançamento, deploy) e
`docs/auditoria_inicial_2026-10-21.md`. Novo: Meu perfil (foto, nome, pé), posição por pelada na carta (RN-068),
carta `PlayerCard` com foto e moldura bronze/prata/ouro, início com "Falta o seu voto", Minha conta em seções,
fundo branco, assinatura só na tela Premium da pelada (`lib/purchases.ts`). Tela Premium geral e template do Expo removidos.
Avisos e confirmações: `app/src/lib/dialog.ts` (funciona no celular e na web).
Evolução V2: cartas com fundo e moldura da categoria e escudo (`lib/arts.tsx`, `lib/crest.tsx`); Meu Perfil em seções
(visão geral, carreira, peladas, conquistas, cartas, privacidade; `lib/profile.tsx`); perfil de outro jogador (`atleta/[id]`);
Elenco da pelada (`pelada/[id]/elenco`); escudo nas configurações da pelada.

## 8. Como testar
- **Web (mais rápido)**: `cd $HOME\Documents\minuto91\app; npx expo start --go --tunnel -c`, depois tecla `w`
  ou abrir http://localhost:8081 no Chrome. O Claude também consegue testar pelo navegador embutido
  (eu faço o login; ele faz o resto).
- **iPhone (Expo Go)**: o mesmo comando, ler o QR code. `--tunnel` é obrigatório para o login com Google.
- Roteiro completo: `docs/roteiro_teste_iphone.md` (seções 0 a 13).
- Bots (6 eleitores sem 6 contas): no SQL Editor do dev, `supabase/dev_seed/01_criar_bots.sql` (cria Bot 1..5
  na Pelada Teste `55a69aba-465e-4241-8638-19cfb7675d16`), `02_bots_votam.sql` (os bots votam na votação aberta),
  `99_apagar_bots.sql` (remove).
- Já testado pela web (21/10): súmula, publicação, votação completa com 6 votos, correção com reconferência,
  resultado, carta (conferida com a fórmula), rankings com empate, álbum, Premium, código de transferência,
  denúncia, travas do excluir conta.

## 9. Configurações externas já feitas
- Supabase Auth: confirmação de e-mail DESLIGADA (só dev). Google ativo (OAuth do Google Cloud, app em modo
  teste com meu Gmail como usuário de teste). Redirect URLs: `exp://**`, `minuto91://**`, `http://localhost:8081/**`.
- pg_cron e pg_net ativos desde 22/10 (antes o pg_cron estava desligado). Agendador a cada 5 min: fecha votações vencidas, fecha meses, apaga contas após 30 dias,
  limpa fim de temporada).
- Apple Developer: **ainda não pago** (login com Apple, push e RevenueCat dependem do development build).

## 10. Armadilhas já encontradas
- Supabase recusa redirect `exp://` com IP numérico → no Expo Go use `--tunnel` (`@expo/ngrok` é devDependency).
- Expo Go não tem login com Apple, RevenueCat nem push → development build (EAS).
- Web: `app.json` usa `web.output: "single"` (a pré-renderização quebrava o Supabase). Alert do RN não aparece
  na web → usar `lib/dialog.ts`.
- Rotas tipadas: ao criar rota nova, o servidor do Expo precisa regenerar `.expo/types/router.d.ts` antes do tsc.
- Lint (React Compiler) proíbe chamar função que faz setState direto no `useEffect`: buscar dados dentro do
  efeito com flag `alive` e usar contador `reload` para recarregar.
- PL/pgSQL: `if ... case ... then ... end then` quebra (o IF para no primeiro THEN) → calcular antes.
- Funções usadas em políticas RLS precisam de `grant execute ... to authenticated`.
- SQL Editor: "Too small: expected string" = query vazia (colar o conteúdo).
- `select` com embed `peladas(...)` em `pelada_memberships` dá erro (duas FKs): evitar embed.
- Pacote instalado incompleto (ex.: html2canvas sem `dist`): apagar a pasta dele, `npm install` e reiniciar o
  Expo com `-c`.
- Apagar node_modules no Windows: `cmd /c rmdir /s /q node_modules`.

## 10b. V4.1 (22/10)
- Relatório: `docs/relatorio_v41_2026-10-22.md` (diagnóstico em `docs/v41_fase0_diagnostico_2026-10-22.md`).
- Migrações 033 (evolução do Card), 034 (prévia do convite) e 035 (envio de push) **aplicadas no dev em 22/10**;
  testes 020, 027, 028 e 029 com PASS no dev. Edge Function `push-sender` e `supabase/deploy/push_sender_cron.sql`
  ainda não publicadas (esperam o development build).
- 22/10: o pg_cron **não estava ligado** no dev (o agendador da 022 nunca rodou). Ligados pg_cron e pg_net e criado
  o job `minuto91-tasks` (a cada 5 min). pg_net fica pronto para o push.
- Banco local de testes: `cd $HOME\Documents\minuto91\supabase\local_db; npm install; node run.mjs` (PGlite;
  roda todas as migrações e `tests_editor`; `node load.mjs` = carga; `node --test` = lógica do push).
- App: Central da Rodada na página da pelada; telas Partidas, Jogadores e Convidar; Rankings em abas; números e
  gráfico de evolução no Card; avisos em Minha conta (`lib/push.tsx`).

## 10c. V4.2 (22/10)
- Relatório: `docs/relatorio_v42_2026-10-22.md` (matriz A01–A27, testes, implantação, checklist). Diagnóstico:
  `docs/v42_fase0_diagnostico_2026-10-22.md`. Evidências: `docs/evidencias_v42/` (Duelo/sorteio com dados simulados).
- Migrações **036–039 aplicadas no dev em 22/10** e testes `030`, `031`, `032` e `020` com PASS no dev.
  036 = correções P1 (votos de súmula antiga, exclusão, assinatura, retenção, eventos da loja) e ordem de travas;
  037 = histórico Premium por RLS, Card cronológico, figurinha do mês, onboarding, `get_my_home`, aceite versionado,
  retrospectiva no servidor; 038 = estatísticas incrementais; 039 = Duelo, escalações, sorteio por posição.
- Nome comercial: **Pelada Premium** (nunca "Premium da pelada"). Posições do cadastro: Goleiro, Defensor,
  Meio-campista, Atacante (não existe "Lateral").
- Sorteio: regra no servidor (diferença ≤ 1 por posição e no total; overall só por troca na mesma posição);
  modos "único" (N rodadas) e "um por rodada"; confirmado nunca muda; escalação vira só rascunho de súmula.
- Novos testes locais: `node concurrency.mjs` (Postgres 17 real, duas conexões); `node --test` inclui o Storage.
- Pendências externas: Redirect URL `…/redefinir-senha` no Auth, republicar `revenuecat-webhook` e
  `storage-cleanup`, `premium_product_ids`/`store_environment`/`premium_beta_open=false` em produção,
  `EXPO_PUBLIC_PREMIUM_PRODUCT_ID` no app. Termos/Política no app: `app/src/lib/legalText.ts` (trocar junto com
  `private.app_config.legal_versions`).
- V4.3 feita (ver 10d).

## 10d. V4.3 (22/10)
- Relatório: `docs/relatorio_v43_2026-10-22.md` (diagnóstico, matriz da auditoria, posições, formações, sorteio,
  Financeiro, permissões, testes, checklist, riscos). Evidências (dados simulados): `docs/evidencias_v43/`; vitrine `/dev-v43`.
- Migrações **040–043 aplicadas no dev em 22/10**; testes 020 e 030–036 com PASS no dev.
  040 = correções da auditoria V4.2 (nomes fora dos sorteios, escalação revalidada no servidor, Duelo só ativos, semente
  do servidor, rodadas independentes sem repetição); 041 = dez posições; 042 = formações 4-3-3/4-4-2; 043 = Financeiro.
- **Posições**: `preferred_position` continua sendo o SETOR (fórmulas inalteradas); a sigla (GOL, ZAG, LD, LE, VOL, MEI,
  CA, PD, PE, ATA) fica em `position_code`. Goleiro virou GOL; Defensor/Meio-campista/Atacante ficam pendentes até o
  jogador escolher (aviso discreto). As funções aceitam siglas e setores (gatilho normaliza).
- **Sorteio**: o app não manda semente (`create_team_draw(p_pelada, p_members, p_mode, p_rounds)`); semente fixa só em
  `private.create_team_draw_core` (testes). Algoritmo 2.
- **Financeiro**: só admin e assistentes autorizados (`set_finance_access`), com Pelada Premium; valores em centavos;
  nada é apagado (cancelamento/estorno com motivo); o app não movimenta dinheiro.

## 10e. V4.4 (22/10)
- Relatório: `docs/relatorio_v44_2026-10-22.md` (diagnóstico, matriz, desempenho medido, limites por plano, checklist).
  Evidências: `docs/evidencias_v44/` (planos EXPLAIN, `perf_resultados.json`, vitrine `/dev-v44` com dados simulados).
- Migrações **044 e 045 NÃO aplicadas no dev ainda** (aplicar no SQL Editor, nessa ordem; depois rodar `tests_editor/020`,
  `028`, `036`, `037`, `038`). 044 = Financeiro (relatórios por agregação SQL, páginas com cursor para cobranças, livro-caixa
  e auditoria, exportação completa); 045 = Central do Jogador, Minha Carreira, Sala de Troféus, convites com motivo,
  notificações por categoria, guia inicial (`user_app_state`).
- Tela inicial = **Central do Jogador** (igual para todos; admin também é jogador). Minha Carreira em `/carreira`;
  guia de Cards em `/guia-cards`. Sala de Troféus: só Craque da Partida, Rei do Mês e Bola Murcha, contados da tabela
  `awards` (a mesma das estatísticas e do álbum). Bola Murcha continua fora das "conquistas" antigas e do push.
- Listas longas: `ListScreen` (FlatList) + `usePaged` (`lib/paging.ts`). CSV vira arquivo (`expo-file-system`) e protege
  contra fórmula. Fotos de listas assinadas em lote (`prefetchAvatars`).
- Carga com Postgres 17 real: `cd supabase/local_db; node perf.mjs` (~15 min).
- Tag local `v4.3` marca a V4.3 intacta (não enviada).

## 10f. V4.5 (22/10) — auditoria corretiva
- Relatório: `docs/relatorio_v45_2026-10-22.md` (matriz E1/G1–G6/S1/L1–L4/U1–U5/I1, regressão, desempenho V4.4 × V4.5,
  visual, checklist). LGPD: `docs/v45_lgpd_retencao_e_minuta_politica.md` (proposta de retenção + minuta da Política v1.3,
  tudo [VALIDAR COM ADVOGADO]). Evidências: `docs/evidencias_v45/`.
- Migrações **044–047 aplicadas no dev em 23/10** (044–046 já estavam; 047 aplicada nesse dia) e testes 020, 023, 026, 028,
  031, 036, 037, 038 e 039 com PASS no dev. Migração **047**: `get_finance_export` (exportação do mês numa chamada
  STABLE = um instantâneo; o app confere linhas × totais antes de gerar o CSV) e gatilho que apaga a permissão financeira
  quando a pessoa deixa de ser assistente ativa (com auditoria). Teste SQL `039_v45_finance_export`.
- App: paginação em `lib/pager.ts` (sem React, testada no Node) e `usePaged(fetch, keyOf)`; uma página a mais por vez,
  respostas antigas descartadas, filtro novo limpa a lista. Filtros (`Chips`) com 44 px. Vitrine `/dev-v45` (simulada).
- Testes locais: suíte SQL 39/39, `node --test` 29/29, `concurrency.mjs` com exportação concorrente, `PERF_COMPARE=v45 node perf.mjs`.
- **Não está pronta para lançamento**: falta login real, aparelhos, push/RevenueCat e advogado.

## 10g. V4.6 (23/10) — visual, Garçons e homologação local
- Relatório: `docs/relatorio_v46_2026-10-23.md`; diagnóstico `docs/v46_fase0_diagnostico_2026-10-23.md`; Design System
  `docs/v46_design_system.md`; evidências `docs/evidencias_v46/`; vitrine sem login `/dev-v46` (simulada).
- Migrações **048 e 049 NÃO aplicadas no dev** (aplicar nessa ordem; depois testes 009, 010, 020, 037, 040, 041).
  048 = ordem estável dos pagamentos da cobrança (o teste 037 era intermitente). 049 = Garçom da Partida (`match_garcom`,
  mín. 1, empate premia todos; estatística objetiva: vale também com votação inválida — decisão do fundador em 23/10) e Garçom do Mês
  (`monthly_garcom`, mín. 2, desempate total → média exata → partidas com assistência → todos; substitui `top_assist`,
  meses fechados recalculados sem aviso); cor dos times (`matches.team_a_color/team_b_color`, paleta fixa,
  `set_match_team_colors` só admin/assistente).
- App: Inter em todo o app (`lib/text.tsx`: todo Text/TextInput vem daí), tokens em `theme.ts` (`type`, `radius`, `space`,
  `shadow`, `HOME`), quatro abas em `app/(tabs)` (Início, Peladas, Carreira, Perfil), pelada em Jogo/Desempenho/Gestão,
  Card com o ano no rodapé, cinco troféus, álbum com 9 ilustrações (`lib/stickers.tsx`), Seleção no campo verde
  (`lib/selection.tsx`), assinatura 91’ provisória (`lib/brand.tsx`) até a arte final do fundador.
- Rotas tipadas: o índice dentro de `(tabs)` não aparece como "/" nos tipos; use `HOME` de `lib/theme`.

## 11. Próximas etapas (em ordem sugerida)
0. **Push** dos commits da Evolução V2 (aguarda confirmação) e rodar `tests_editor/001..019` de novo no dev.
   Pendências V2: escudo nas artes de resultado e Seleção; publicar `storage-cleanup` (fotos e escudos).
1. **Testes que precisam de uma segunda conta real** (eu crio no navegador): bloquear jogador, excluir e
   recuperar conta, usar código de transferência numa conta nova.
2. **Passada no iPhone** (Expo Go com `--tunnel`): aparência, teclado, compartilhar convite.
3. **Documentos**: atualizar regra da Seleção (sem adaptação) nos Docs 02/03/04; levar ao advogado: 30 dias de
   recuperação, retenção do Aposentado e das cédulas, registro do teste grátis (PT-05).
4. **Lacunas de app ainda não feitas** (confirmar escopo comigo antes):
   - Tela de temporadas (personalizar/encerrar, Premium) — banco pronto (006).
   - Nomes personalizados dos times (Premium) — banco pronto (007).
   - Imagem de capa da pelada (upload; o escudo já existe).
   - Retrospectiva mensal/anual.
5. **Apple Developer (US$ 99/ano)** → `eas login`, `eas init` (commitar o projectId), `eas device:create`,
   development build iOS (pedir minha confirmação antes de rodar). Login com Apple é obrigatório na App Store
   (o app oferece Google). Configurar Apple no Supabase (Client ID `com.minuto91.app`).
6. **Edge Functions**: envio de push (Expo) lendo `claim_notifications` (falta). Webhook do RevenueCat FEITO em
   `supabase/functions/revenuecat-webhook` (deploy pelo painel, JWT desligado, secrets REVENUECAT_WEBHOOK_AUTH e,
   em produção, REVENUECAT_ENVIRONMENT=PRODUCTION). O banco ainda ignora SUBSCRIPTION_EXTENDED, REFUND_REVERSED e
   NON_RENEWING_PURCHASE (avaliar antes do lançamento).
7. **Antes do lançamento**: projeto Supabase de produção, ligar confirmação de e-mail, `premium_beta_open=false`,
   produtos no RevenueCat/lojas, TestFlight.
