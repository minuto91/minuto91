# Minuto 91 — V4.2, Fase 0: diagnóstico da V4.1 (22/10/2026)

Base: commit `6783044` (V4.1 + contexto), árvore limpa. Nada foi alterado antes deste diagnóstico.

## 1. Verificações de base (executadas)

| Verificação | Resultado |
|---|---|
| Banco local (PGlite): 37 migrações em ordem (inclui `008b` e `020b`, que o `sort()` coloca depois de `008_`/`020_`) | Aplicam sem erro |
| `tests_editor/001..029` no banco local | **29 de 29 PASS** (023 e 024 já estavam corretos; não foram tocados) |

**Fonte da auditoria:** o documento da auditoria independente da V3 (A01–A27) **não está no repositório nem em
Downloads**. Usei a descrição e os arquivos citados no prompt da V4.2 para cada achado e confirmei cada um no
código. Onde o prompt não dá detalhe, a interpretação está escrita na coluna "Evidência".

## 2. Inventário (resumo)

- **App** (`app/src`): 30 telas Expo Router, 23 módulos em `lib/`. Leituras diretas por RLS e escritas só por RPC.
- **Banco**: 37 migrações (001–035 + 008b + 020b). Cadeia pós-finalização `after_match_finalized` →
  014 (stats/Cards) → 015 (destaques/meses) → 016 (Seleção) → 018 (figurinhas).
- **Funções**: `revenuecat-webhook`, `push-sender`, `storage-cleanup` (Edge Functions, Deno).
- **Testes**: 29 arquivos SQL (`tests_editor`), 8 testes da lógica do push, carga (`load.mjs`).
- **Posições oficiais** (Doc 03): `goalkeeper`, `defender`, `midfielder`, `attacker`. Não existe "Lateral" no
  cadastro (o exemplo 11.5 do prompt usa Lateral) — o sorteio trabalha com as posições que existem.
  `pelada_memberships.preferred_position` é obrigatória, então membro sem posição não existe hoje; o
  algoritmo trata o caso mesmo assim (grupo "Posição não informada").

## 3. Matriz A01–A27

Legenda de situação real na V4.1: **Confirmado** (defeito presente), **Corrigido** (já resolvido), **Parcial**.

| ID | Descrição | Sev. | Situação na V4.1 | Evidência de código | Risco | Solução proposta | Arquivos | Teste de regressão |
|---|---|---|---|---|---|---|---|---|
| A01 | Votos de versão antiga da súmula contam na apuração | P1 | **Confirmado** | `010:on_sheet_corrected` só zera `confirmed_sheet_version` quando os eleitores não mudam; cédulas `submitted` (com `sheet_version` antigo) e `vote_receipts` ficam. `013:finalize_session` conta recibos e `compute_match_results`/`grant_vote_awards` leem `status='submitted'` sem olhar a versão. Se todos já tinham votado, o próximo reenvio finaliza com votos da súmula velha | Notas e Craque calculados sobre uma súmula que não existe mais | Correção invalida (volta a rascunho) as cédulas enviadas e apaga os recibos; apuração só usa cédulas da versão atual; `finalize_session` trava pelada → partida → sessão (mesma ordem da correção) | nova 036 | SQL 030 + concorrência real |
| A02 | Nome de ex-integrante fica salvo após exclusão | P1 | **Confirmado** | `021:request_account_deletion` só troca o nome das associações `active`; `left` mantém `player_name`. `purge_account` só zera `user_id`. Também ficam: `memberships_snapshot` (limpo), denúncias com o nome, `audit_events.metadata` sem nome (ok) | Dado pessoal retido sem base | Anonimizar todas as associações da conta (active/left/suspended) na solicitação e de novo no expurgo; recuperação devolve só as que estavam ativas (snapshot) | 036 | SQL 031 |
| A03 | Renovação vai para a pelada errada pelo atributo `pelada_id` | P1 | **Confirmado** | `026:apply_subscription_event` procura primeiro por comprador + atributo `pelada_id` (mutável) e só depois por `original_transaction_id` | Pelada paga perde Premium; outra ganha | Vínculo imutável `store_account_ref` (transação original) tem precedência; atributo só vale para a 1ª compra de uma intenção pendente; transação já ligada nunca muda de pelada; produto e ambiente conferidos no banco | 036 + webhook | SQL 032 |
| A04 | Dados de aposentado reaparecem após recomputação | P1 | **Confirmado** | `022:cleanup_season` apaga stats/Cards de `retired`, mas `014:recompute_stats/recompute_cards` reconstroem a partir de `match_player_results` (anulação em até 7 dias, correção) | Retenção violada | Regra permanente: temporada limpa + membro aposentado = não reconstruir (stats, Cards, snapshots) | 036 | SQL 033 |
| A05 | Evento recuperável tratado como duplicado definitivo | P1 | **Confirmado (parcial)** | `026`: só `unmatched` é reprocessável; `conflict` vira definitivo; sem estados, sem tentativas, sem alerta | Assinatura paga sem Premium, sem ninguém saber | Estados `received/validated/applied/pending_reconciliation/rejected`, contador de tentativas, `reconcile_store_events` no agendador, alerta em `private.store_event_alerts` | 036 + webhook | SQL 032 |
| A06 | Histórico Premium acessível direto | P2 | **Confirmado** | RLS de `player_cards`, `player_season_stats`, `card_snapshots`, `awards` só exige ser membro; tela do Card lista todas as temporadas | Benefício pago livre | `private.season_readable()` nas políticas; telas mostram só as temporadas liberadas | 037 + telas | SQL 034 |
| A07 | Card errado após mudança histórica | P2 | **Confirmado** | Card provisório usa o overall da temporada anterior (`014:recompute_card`); anular partida de temporada antiga só recalcula aquela temporada | Card das temporadas seguintes com base velha | Recomputar em ordem cronológica a temporada afetada e as seguintes | 037 | SQL 034 |
| A08 | Rei do Mês sem atualizar figurinha | P2 | **Confirmado** | Fechamento de mês pelo agendador (`close_pending_months(p, null)`) não passa pela cadeia que reconcilia figurinhas | Figurinha só aparece na próxima partida | Gatilho em `awards` (prêmios do mês) reconcilia o membro | 037 | SQL 034 |
| A09 | Nome do onboarding inconsistente | P3 | **Confirmado** | App manda o prefixo do e-mail se o campo ficar vazio (sobrescreve o nome do Google/Apple e expõe parte do e-mail); `complete_onboarding` não sincroniza `player_name` | Nome diferente entre perfil e pelada; vazamento parcial de e-mail | Campo pré-preenchido; vazio mantém o nome atual; servidor sincroniza as associações ativas | 037 + onboarding | SQL 035 |
| A10 | Reenvio do último voto falha | P2 | **Confirmado** | Último voto finaliza; reenvio com a mesma chave cai em `lock_voter` → `VOTING_NOT_OPEN` | App mostra erro após voto aceito | Antes da trava, mesma chave já registrada = `repeated` | 036 | SQL 030 |
| A11 | Histórico de partidas limitado | P3 | **Corrigido** | `pelada/[id]/partidas.tsx`: 30 por página com `range` | — | Manter | — | Conferido no código |
| A12 | Limite global de 100 partidas | P2 | **Confirmado** | `app/index.tsx` busca 100 partidas de todas as peladas juntas | Pelada sem "última partida" e rascunhos errados | RPC `get_my_home` com consulta por pelada | 037 + início | SQL 035 |
| A13 | Pendências desatualizadas | P2 | **Confirmado** | Início e Central só recarregam no foco; votação vencida segue em "Falta o seu voto" | Usuário tenta votar fora do prazo | Filtrar por prazo, recarregar ao voltar ao app e no vencimento | início, Central | Web |
| A14 | Retrospectiva mistura temporadas | P2 | **Confirmado** | `retrospectiva.tsx` mantém o `retro` da temporada anterior enquanto a nova carrega; a arte pode sair com nome de uma e números de outra | Arte errada compartilhada | Resultado com a chave da temporada; tela e arte só com o par certo | retrospectiva | Web |
| A15 | UTC muda a temporada | P2 | **Confirmado** | `toISOString().slice(0,10)` em `career.ts`, `retrospectiva.tsx` (depois das 21h no Brasil já é "amanhã") | Temporada errada perto da virada | Data de hoje no fuso da pelada (`lib/dates.ts`) | app | Unitário (node) |
| A16 | URLs de imagem expiram | P3 | **Confirmado** | `useSignedUrl`: link de 15 min sem renovação enquanto a tela fica aberta | Foto/escudo quebrados | Renovação antes de vencer e ao falhar | `avatar.tsx` | Web |
| A17 | Sem recuperação de senha | P2 | **Confirmado** | `login.tsx` não tem "Esqueci minha senha" | Conta perdida | Fluxo completo com `resetPasswordForEmail` + tela de nova senha | login, `redefinir-senha` | Web (envio real depende do Supabase) |
| A18 | Termos e Privacidade sem acesso / aceite sem versão | P2 | **Confirmado** | Onboarding só tem o texto "Li e aceito"; sem link; banco grava só a data | Aceite sem prova da versão | Links para os documentos oficiais, tabela `terms_acceptances` (versão + momento) | 037 + onboarding/conta | SQL 035 |
| A19 | Benefícios Premium sem interface | P2 | **Confirmado (parcial)** | Banco pronto: temporadas (006), nomes dos times (007), horário fixo (010). App: só Bola Murcha e assistentes | Pago sem uso | Telas Temporadas, nomes dos times na súmula, horário fixo ao publicar | app | Web |
| A20 | Retrospectiva truncada | P2 | **Confirmado** | `retro.ts` lê partidas e prêmios direto (limite de 1.000 linhas do PostgREST) | Números errados em temporadas grandes | RPC `get_season_retrospective` agregada no banco | 037 | SQL 035 |
| A21 | Erro de consulta tratado como vazio | P2 | **Confirmado** | Ex.: `index.tsx` ignora o erro do 2º lote; várias telas usam `data ?? []` | "Nenhuma partida" quando a rede falhou | Estado de erro + "Tentar de novo" nas telas principais | app | Web |
| A22 | Testes SQL 023/024 | P3 | **Corrigido** | Expectativas corrigidas na V4.1; 29/29 PASS hoje | — | Não tocar | — | Suíte |
| A23 | Produto de assinatura incorreto | P2 | **Confirmado** | `loadPremiumPackage` cai em `pkgs[0]` se não houver mensal; tela fixa "por mês" | Cobrança de produto errado | Só o produto mensal configurado; preço e período da loja | `purchases.ts`, premium | Revisão (loja real pendente) |
| A24 | Limpeza do Storage incompleta | P3 | **Confirmado** | `storage-cleanup`: arquivos de cada pasta lidos só até 1.000 | Arquivos órfãos ficam | Paginação integral | função | `node --test` da paginação |
| A25 | Arte gerada antes das imagens carregarem | P3 | **Confirmado** | `SharePanel` captura na hora | Arte sem foto/escudo | Espera as imagens (até 5 s) e usa iniciais se falhar | `arts.tsx`, `artload.tsx` | Web |
| A26 | Controles de avaliação pouco acessíveis | P3 | **Confirmado** | Botões ± de 32 px, sem `accessibilityLabel`; "Não vi jogar" é só texto | Difícil votar | Alvos de 44 px, rótulos, `adjustable` | `ui.tsx`, votar | Web |
| A27 | Texto errado sobre quórum | P3 | **Confirmado** | Tela diz "menos da metade votou"; servidor exige metade **e** pelo menos 3 votos | Explicação errada | Texto alinhado à regra | partida | Revisão |

## 4. Outros pontos da Fase 0

- **Deadlock (8.1)**: `correct_match_sheet` trava pelada → partida → sessão; `submit_ballot` (último voto) e o
  agendador travam sessão → partida. Ordem inversa: risco real. Corrigido na 036 (todos: pelada → partida → sessão).
- **Snapshots após anulação (8.3)**: a anulação recalcula sem snapshot; política definida na 037.
- **Retrospectiva com empates (8.4)**: corrigida na V4.1 na tela; a RPC nova mantém todos os empatados na última posição.
- **`premium_beta_open`**: `true` no dev. Precisa ser `false` em produção (checklist).
