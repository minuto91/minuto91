# Minuto 91 — contexto para continuar em outro chat

Atualizado em 21/10/2026. Leia este arquivo inteiro antes de qualquer ação.

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
- Monorepo: `app/`, `supabase/` (migrations, tests, tests_editor, dev_seed), `docs/`.
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
(admin: prazo padrão, Bola Murcha só com Premium, mínimo de notas; fuso não editável).

Testes: `supabase/tests_editor/001..018_*.sql` (rodar no SQL Editor; terminam com o erro proposital
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
- Votação inválida (<50% ou <3 votos): sem notas e sem prêmios (nem Craque).
- **Seleção da Rodada sem adaptação de posição**: vaga sem candidato fica vazia. Isso muda Doc 02 RN-075,
  Doc 03 21.4 e Doc 04 25.1 (atualizar os docs).
- Maior Evolução do mês: quem mudou de posição no mês não concorre.
- Teste grátis de 30 dias: começa por botão do admin (não automático); bloqueado durante o beta.
- Anulação: 4 categorias (erro na súmula, partida duplicada, partida não aconteceu, outro).
- Exclusão de conta: vira "Aposentado" na hora; 30 dias para recuperar (volta como jogador, sem admin);
  depois apaga perfil e login. Precisa constar na Política/Termos [VALIDAR COM ADVOGADO].
- Denúncia e bloqueio (RN-120/RF-014) implementados na 023.

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
impacto e motivo), configurações da pelada (admin). Também existe `premium.tsx` (teste RevenueCat).
Avisos e confirmações: `app/src/lib/dialog.ts` (funciona no celular e na web).

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
- pg_cron ativo (agendador a cada 5 min: fecha votações vencidas, fecha meses, apaga contas após 30 dias,
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
- Apagar node_modules no Windows: `cmd /c rmdir /s /q node_modules`.

## 11. Próximas etapas (em ordem sugerida)
1. **Testes que precisam de uma segunda conta real** (eu crio no navegador): bloquear jogador, excluir e
   recuperar conta, usar código de transferência numa conta nova.
2. **Passada no iPhone** (Expo Go com `--tunnel`): aparência, teclado, compartilhar convite.
3. **Documentos**: atualizar regra da Seleção (sem adaptação) nos Docs 02/03/04; levar ao advogado: 30 dias de
   recuperação, retenção do Aposentado e das cédulas, registro do teste grátis (PT-05).
4. **Lacunas de app ainda não feitas** (confirmar escopo comigo antes):
   - Tela de temporadas (personalizar/encerrar, Premium) — banco pronto (006).
   - Nomes personalizados dos times (Premium) — banco pronto (007).
   - Botão de denunciar convidado — banco pronto (023).
   - Foto de perfil, escudo/imagem da pelada (upload).
   - Arte de compartilhamento 9:16 do resultado (bloqueada para quem não votou, RN-098) e da figurinha.
   - Retrospectiva mensal/anual. Destaques (Craque/Garçom da rodada) na tela da pelada.
5. **Apple Developer (US$ 99/ano)** → `eas login`, `eas init` (commitar o projectId), `eas device:create`,
   development build iOS (pedir minha confirmação antes de rodar). Login com Apple é obrigatório na App Store
   (o app oferece Google). Configurar Apple no Supabase (Client ID `com.minuto91.app`).
6. **Edge Functions**: envio de push (Expo) lendo `claim_notifications` e webhook do RevenueCat chamando
   `apply_subscription_event` (service role só na Edge Function, nunca no app).
7. **Antes do lançamento**: projeto Supabase de produção, ligar confirmação de e-mail, `premium_beta_open=false`,
   produtos no RevenueCat/lojas, TestFlight.
