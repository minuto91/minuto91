# Minuto 91 — Relatório de auditoria e implementação V7.7 (24/10/2026)

Branch `v7.7-consolidacao`, a partir de `main` (`e3c3f7f`, V6.2). Migrações novas: `053`–`057`. Nenhuma migração
antiga foi editada. Nenhuma fórmula, peso, benchmark ou calibração do motor de notas foi alterada.

## 1. Inventário (o que existe no repositório)

- **Banco**: 54 migrações (001–052, com `008b` e `020b`), PGlite local com `shim.sql` (auth/storage simulados).
  Votação v2 em `052` (`rating_vote_*`), motor v2 em `050`/`051` (ATU/EST/PEQ/RES/DIS), anulação em `020`,
  exclusão de conta em `021`/`036`, notificações e agendador em `022`/`035`/`036`, Garçom da Partida em `049`.
- **App**: Expo SDK 57 / React Native 0.86, rotas em `app/src/app`, lógica de apoio em `app/src/lib` (65 módulos).
- **Edge Functions**: `push-sender`, `revenuecat-webhook`, `storage-cleanup` (+ `account-purge`, nova).
- **Testes**: 43 testes SQL (`tests_editor`), 6 arquivos de lógica em `local_db/*.test.mjs`, 2 no app (`app/tests`).
  Linha de base antes de qualquer mudança: **43/43 SQL passando**.
- **Ausente**: o ZIP citado no prompt, transcrição integral das decisões, artefatos V7.5/V7.7 do motor.

## 2. Conflito material sinalizado (não resolvido por decisão própria)

O prompt fixa atributos DEF/LET/APR/RES/DIS (linha) e DEF/REF/APR/RES/DIS (goleiro), sem ATU, e o "motor V7.7"
com diferencial médio 3,22. O repositório contém o **motor v2** (Prompt Master v2.0): `OVR = 0,3325 ATU + 0,3325 EST
+ 0,19 PEQ + 0,095 RES + 0,05 DIS`, com REF dentro do EST do goleiro. Não há no projeto nenhuma definição das fórmulas
DEF/LET/APR, nem da calibração V7.5, nem do valor 3,22. A regra 2 proíbe alterar o motor e a regra de escopo proíbe
inventar regras: **o motor existente foi mantido e tratado como o congelado**, e a troca de atributos ficou como
*pendente de evidência*. Para fechar: anexar a especificação V7.7 (fórmulas e tabela de pesos) e rodar a regressão
`rating/simulate.mjs` contra os resultados de referência dessa versão.

Também pendente de evidência: "alternativa A" da configuração de votação por rodada; regra exata de "conflitos de
contas". Contradição antiga nos Termos (7.3: faixas 60/80) x código e teste `042` (faixas 65/80) — não alterada
porque envolve o motor congelado; precisa de decisão documental.

## 3. Falhas reais encontradas e corrigidas

| # | Crit. | Falha | Correção |
|---|---|---|---|
| 1 | P0 | `match_annulments` legível por qualquer membro ativo com `description` e `annulled_by` (política `annulments_read`) | Leitura direta revogada; `get_match_status_history` (sem descrição/autor, inclui ex-integrante que jogou) e `get_match_status_history_admin` (054) |
| 2 | P0 | Placar, gols, cartões, notas e prêmios de partida anulada entregues pelo banco e exibidos (`partidas.tsx`, `partida/[id]`, `pelada/[id]`, `get_my_home`, `get_match_lineup`, `get_rating_vote`) | Colunas geradas `public_team_*_score` + privilégio de coluna; 9 políticas RESTRICTIVE; RPCs ajustadas; telas usam `scoreLine` e selo "Anulada" |
| 3 | P0 | `get_rating_vote_admin` mostrava, durante a votação, média das notas e validade por jogador (resultado provisório) | Só progresso operacional por eleitor e contagens (053) |
| 4 | P0 | `cast_rating_vote` sobrescrevia por UPSERT sem trilha; `set_rating_vote_awards` apagava e reinseria; `correct_match_sheet` apagava votos | Versões imutáveis, projeção sem DELETE, invalidação lógica e revalidação (053/054) |
| 5 | P0 | `purge_account` capturava `AUTH_DELETE_FAILED` e marcava `completed` | Etapas com checkpoint; `completed` só depois do login apagado; espera crescente e alerta; legado reaberto (055) |
| 6 | P1 | Exclusão pendente liberava a vaga (contagem só `status='active'`): a pelada podia lotar e a recuperação falhava em silêncio | `pelada_seat_count` com vagas reservadas; recuperação devolve `not_restored` (055) |
| 7 | P1 | `rating_vote_on_annul` cancelava a sessão sem guardar o estado; restauração inexistente; limite de 7 dias | Suspensões por ciclo, restauração da publicação original sem nova apuração, decisão da administração para votação interrompida (054) |
| 8 | P1 | Dedupe de `match_annulled` por tipo+partida+usuário: segunda anulação não notificava | Chave pelo id da operação; `match_restored`; efeitos retroativos sem avisos (054) |
| 9 | P1 | Publicação dependia de ação manual do admin | Publicação automática pelo agendador, idempotente, com novas tentativas (053) |
| 10 | P1 | Prorrogações ilimitadas e sem aviso | Uma por votação; aviso só a pendentes (053) |
| 11 | P1 | `my_membership`/`rating_vote_lock_voter`/tick exigiam filiação ativa: quem jogou e saiu perdia o voto | Eleitorado por participação (ativos e quem saiu, sem exclusão pendente); acesso só à votação (053) |
| 12 | P2 | `close_month` recriava prêmios do mês a cada recálculo (novas linhas e novos avisos) | Reaproveita o registro do mesmo vencedor (056) |
| 13 | P2 | Seleção sem posição secundária e por setor isolado | Otimização global com secundária confirmada (056) |
| 14 | P2 | Textos falsos em `annul.tsx` ("não dá para desfazer", "até 7 dias", "todos serão avisados") e texto de quórum 50% | Reescritos conforme o processamento real; erro `ANNULMENT_WINDOW_EXPIRED` removido |

## 4. Migrações (todas incrementais, com rollback descrito no cabeçalho)

- `053_v77_vote_integrity.sql` — versões de votos, sigilo da gestão, publicação automática, prorrogação única,
  eleitorado por participação. Backfill: uma versão `backfill_053` por nota/escolha existente; `published_sheet_version`.
- `054_v77_annulment_restoration.sql` — eventos de status, ciclos, suspensões, reaberturas, ocultação no banco,
  notificações, `correct_match_sheet`. Backfill: anulações antigas viram eventos; sessões canceladas por anulação ganham
  o estado anterior recuperável.
- `055_v77_account_deletion.sql` — reserva de vaga, recuperação, exclusão em etapas. Backfill: solicitações marcadas
  `completed` com `AUTH_DELETE_FAILED` cujo login ainda existe voltam a `pending`.
- `056_v77_selection_awards.sql` — posição secundária, Seleção v2, fim do Garçom da Partida, prêmios do mês sem duplicar.
- `057_v77_legal_versions.sql` — Termos 1.2 / Política 1.3 (minutas).

## 5. Evidências de teste (comandos reais nesta máquina)

| Comando | Resultado |
|---|---|
| `cd supabase/local_db; node run.mjs` (PGlite, 59 migrações) | ver §5.1 |
| `node run.mjs 044` (teste novo, 14 blocos) | PASS |
| `cd supabase/local_db; node --test` (push, dinheiro, paginação, storage, motor JS×SQL) | 43/43 + push atualizado |
| `node rating/simulate.mjs` (1.000 peladas × 30 rodadas) | Resultado idêntico ao de referência (`docs/v5_simulacao_resultados.json`), só o tempo mudou |
| `cd app; npm run lint; npx tsc --noEmit; npm test` | 0 erros, 0 avisos; 26/26 |

### 5.1 Bateria completa (saída em `RESULTADO_TESTES.txt`)
- `node run.mjs`: **44/44 PASS** (43 antigos, 7 deles ajustados à regra nova, + `044_v77_integrity`).
- `node --test` (local_db): **43/43**.
- `rating_concurrency.mjs 10` em **PostgreSQL 17.10 real** com as 59 migrações: **10/10 sem problemas**.
- Testes antigos ajustados (a regra mudou, não o teste foi afrouxado): `006` (formato de retorno mantido), `013` (sem 7 dias,
  prévia com token, retry idempotente, linha do tempo sem descrição), `023`/`027`/`030`/`031` (nova assinatura de
  `annul_match`; `031` versões legais), `041` (Garçom da Partida excluído), `042` (publicação automática, resumo sem média,
  correção excepcional pós-publicação).

Observação honesta: numa execução intermediária o teste antigo `034_v43_positions_formations` falhou uma vez com
`ADMIN_TRANSITION_REQUIRES_RPC`; não reproduziu em 6 execuções isoladas nem na bateria final. Fica registrado como
possível teste instável (o 034 usa sorteio aleatório).

## 6. O que não foi executado (exige infraestrutura externa)

- Aplicar as migrações no Supabase dev (`lqirpgqrnbsycuowwoie`) e rodar `tests_editor/044_v77_integrity.sql` no SQL
  Editor. **Passo externo**: `supabase db push` (ou colar 053–057 em ordem) e depois o 044.
- Agendar `private.rating_vote_tick()` já existe (`052`, a cada 5 min via pg_cron); conferir no painel que o job está ativo.
- Publicar a Edge Function `account-purge` e criar o secret `ACCOUNT_PURGE_AUTH`; agendar a chamada (ex.: de hora em hora).
- Teste E2E com login (web/iPhone) e capturas de tela; build EAS.
- Revisão jurídica dos Termos 1.2 e da Política 1.3 antes de aplicar `057` em produção.
- `concurrency.mjs` (Financeiro) e `perf.mjs` não foram rodados (não tocam no que mudou; `perf.mjs` leva ~15 min).
  Para rodar como root neste tipo de contêiner, a pasta temporária do embedded-postgres precisa pertencer ao usuário
  `postgres` (wrapper usado nesta entrega; no Windows do fundador não é necessário).

## 7. Riscos e lacunas

- Colunas `team_a_score`/`team_b_score` deixaram de ser legíveis pelo app: versões antigas do app que leiam essas colunas
  recebem erro de permissão. Publicar o app novo junto com a migração 054.
- `annul_match` mudou de assinatura (6 parâmetros); o app antigo recebe "função não existe" ao anular.
- A Seleção v2 vale para partidas recalculadas a partir de agora; seleções antigas publicadas não são reprocessadas
  automaticamente (não é retroativo por decisão de não reescrever histórico sem motivo).
- A posição secundária não altera o motor de OVR (usa só a principal), por causa do congelamento.
- Destaque "Garçom da rodada" (highlight, não troféu) foi mantido; se também deve sair, é uma decisão de produto.
