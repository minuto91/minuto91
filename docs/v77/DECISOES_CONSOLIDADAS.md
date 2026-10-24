# Minuto 91 — Decisões consolidadas V7.7 (24/10/2026)

Fonte: prompt mestre V7.7 de 24/10/2026 (decisões mais recentes) > documentos antigos > comportamento legado.
Base de código auditada: repositório `minuto91/minuto91`, branch `main` em `e3c3f7f` (V6.2, migrações 001–052).
Não havia ZIP anexado na sessão: o inventário foi feito sobre o repositório.

Status: **Implementado** = código + teste executado nesta entrega. **Herdado** = já existia antes (V4–V6) e não foi
alterado; evidência é o teste antigo indicado. **Pendente de evidência** = a regra exata não está no repositório; nada
foi inventado. **Fora do escopo** = adiado pelo prompt.

| ID | Decisão | Regra final | Arquivos | Implementação | Testes | Evidência / status |
|---|---|---|---|---|---|---|
| G1 | Motor de notas congelado | Fórmulas, pesos, benchmarks e calibração não mudam; sem curva LET V7.9 | `supabase/migrations/050–052`, `supabase/local_db/rating/*` | Nenhuma linha do motor alterada (`git diff main -- 051_* rating/` vazio) | `rating_engine.test.mjs`, `rating_sql.test.mjs`, `rating/simulate.mjs` | Implementado (regressão): simulação de 1.000 peladas idêntica à de referência, só o tempo mudou |
| G2 | Atributos DEF/LET/APR/RES/DIS (linha) e DEF/REF/APR/RES/DIS (goleiro), sem ATU | — | — | **Não aplicado**: o repositório tem o motor v2 (ATU/EST/PEQ/RES/DIS); não existem artefatos V7.5/V7.7 (fórmulas DEF/LET/APR, diferencial 3,22). Trocar atributos exigiria inventar fórmulas, o que a regra 2 proíbe | — | **Pendente de evidência / conflito material** (ver relatório §2) |
| A1 | Central do Jogador única, abas Início/Peladas/Carreira/Perfil | — | `app/src/app/(tabs)`, `lib/central.tsx` | Herdado (V6.x) | `app/tests/central.test.ts` | Herdado |
| A2 | Premium R$ 29,90/mês por pelada; Financeiro só Premium e somente leitura após expirar | — | `043_finance.sql`, `lib/purchases.ts`, `legalText.ts` 11.2 | Herdado | `036`–`040` SQL | Herdado (não alterado) |
| A3 | Troféus com desenho único; Garçom da Partida excluído por completo | Não é concedido; históricos revogados (linha fica para auditoria); some da Sala de Troféus, histórico, push, artes e textos | `056_v77_selection_awards.sql`, `lib/trophies.tsx`, `lib/arts.tsx`, `partida/[id]/index.tsx`, `push-sender/logic.ts` | `grant_match_garcom` vira no-op; revogação em massa com auditoria `garcom_match_removed`; `get_trophy_history('match_garcom')` → `INVALID_TROPHY` | `041_v46_garcom_awards.sql`, `push_logic.test.mjs` | Implementado |
| A4 | Artilheiro/Rei do Mês empatados = troféus compartilhados; recálculo sem duplicar | Mesmo vencedor reaproveita o registro; quem perde fica revogado; sem novo aviso | `056` (`grant_month_award`) | Reativação do prêmio revogado na mesma transação | `013`, `044` | Implementado |
| A5 | Convites por link e código; convidado sem conta não vota | — | `004`, `034` | Herdado | `028_invite_preview` | Herdado |
| A6 | Bloqueio entre contas, transferência de carreira, conflitos de contas | Regras existentes mantidas | `023`, `024`, `032` | Herdado | `016`, `017`, `025` | Herdado; regra de "conflito de contas" **pendente de evidência** |
| A7 | Configurações de votação por rodada — "alternativa A" | — | — | Não há registro da "alternativa A" no repositório | — | **Pendente de evidência** |
| A8 | Cartões: mudança no registro vale só para partidas futuras | — | `050_v5_rating_data.sql` | Herdado | `042` | Herdado |
| B1 | Seleção 4-3-3, mínimo 11 com nota válida incluindo goleiro | Sem goleiro possível (principal ou secundária confirmada) não publica | `056` (`compute_round_selection` v2) | Programação dinâmica global | `044` §13 (S3, S4) | Implementado |
| B2 | Secundária confirmada = principal; melhor combinação global | Maximiza vagas preenchidas e soma das notas internas sem arredondar; empate exato pela ordem nota, nº de notas, nota dos votos, id | `056`, `lib/secondary.tsx`, `jogador/[id]`, `pelada/[id]` | Pedido do jogador + confirmação do admin; retrato na súmula | `044` §13 (S1, S2) | Implementado |
| B3 | Craque/Bola Murcha: votação própria, ≥3 escolhas válidas por prêmio, empate compartilhado, em branco permitido | — | `053` (`publish_rating_vote_core`, `set_rating_vote_awards`) | Escolha em branco = versão com alvo nulo | `044` §3 e §6 | Implementado |
| B4 | Correção de troféus revoga, preserva histórico, recalcula sem duplicar | — | `054`, `056` | Reativação dos mesmos ids na restauração | `044` §8 | Implementado |
| C1 | Sem quórum de 50% | Nenhuma regra percentual nas votações atuais; texto legal e da tela atualizados | `053`, `legalText.ts` 6.8, `partida/[id]/index.tsx` | Texto da votação antiga neutro | `044` §6 | Implementado |
| C2 | Votos editáveis até o prazo, versões imutáveis | `private.rating_vote_versions` só INSERT; projeção nunca perde linha; DELETE/UPDATE de histórico bloqueados por trigger | `053` | `cast_rating_vote`, `set_rating_vote_awards` | `044` §1, §3 | Implementado |
| C3 | Eleitor consulta o próprio histórico; só leitura depois | `get_my_rating_vote_history` | `053`, `app/partida/[id]/meus-votos.tsx` | — | `044` §1, §6 | Implementado |
| C4 | Administração sem conteúdo de votos nem resultado provisório | Resumo só com progresso (concluiu / em andamento / não começou) | `053` (`get_rating_vote_admin`), `lib/ratingvote.tsx` | Removidos média, validade por jogador e cobertura | `044` §2, `042` | Implementado |
| C5 | Confirmação de nota só após o servidor; retry; dedupe | — | `votar.tsx` (V6.1), `053` | Retry com o mesmo valor não cria versão | `044` §1 | Implementado (servidor) / Herdado (tela) |
| C6 | Publicação automática no fechamento, idempotente, prazo original preservado | `rating_vote_tick` publica com `run_job`; falha registrada e repetida; alerta à gestão após 3 falhas | `053` | `publish_rating_vote_core` | `044` §6, `042` | Implementado |
| C7 | Votos insuficientes = "Avaliação insuficiente" | — | `053` | — | `044` §6 | Implementado |
| C8 | Uma prorrogação comum, 15 min–12 h, só gestão, avisa só pendentes | `EXTENSION_ALREADY_USED` | `053`, `lib/ratingvote.tsx` | Aviso `voting_extended` | `044` §5 | Implementado |
| C9 | Correção da súmula invalida/revalida votos sem apagar | `rating_vote_sync_eligibility` | `054` (`correct_match_sheet`) | Versões `invalidated`/`revalidated` | `044` §4 | Implementado |
| C10 | Exclusão de conta: resultado oficial fica, voto individual sai | Na exclusão definitiva e na publicação posterior | `053`, `055` | Remoção (não pseudonimização) das versões do eleitor excluído | `044` §14 | Implementado |
| D1 | Anulação a qualquer tempo, categoria, justificativa, prévia, confirmação | Sem limite de 7 dias; prévia com token (`PREVIEW_OUTDATED`); `request_id` idempotente | `054`, `lib/annul.tsx` | `annul_match(…, p_preview_token, p_request_id)` | `013`, `044` §7 | Implementado |
| D2 | Efeitos esportivos fora, inclusive meses/temporadas fechados; Financeiro intocado | — | `054` (`apply_match_status_effects`) | — | `013`, `044` §7 | Implementado |
| D3 | Restauração excepcional; anular/restaurar repetidamente | Eventos imutáveis em `private.match_status_events`, ciclos | `054` (`restore_match`) | — | `044` §8–9 | Implementado |
| D4 | Histórico visível sem descrição nem autor; detalhes só admin; RLS de `match_annulments` corrigida | Leitura direta revogada; `get_match_status_history` / `_admin` | `054` | Ex-integrante que jogou a partida também vê | `013`, `044` §10 | Implementado |
| D5 | Partida anulada sem placar, gols, cartões, notas, prêmios — também no banco | Colunas `public_team_*_score`; privilégio de coluna; políticas RESTRICTIVE; RPCs ajustadas | `054`, `lib/match.ts`, `matchview.ts`, telas | — | `044` §7, `app/tests/v77.test.ts` | Implementado |
| D6 | Uma notificação coletiva por operação, dedupe pelo id da operação; nada por efeito | `notify_from_audit`; efeitos em silêncio (`minuto91.quiet_effects`) | `054` | Outbox na mesma transação | `044` §7–9 | Implementado |
| E1 | Anulação preserva sessão, votos e estado anterior | `private.rating_vote_suspensions` | `054` | Trigger `rating_vote_on_annul` removido | `044` §7 | Implementado |
| E2 | Restauração recupera a publicação original sem segunda publicação | Verifica compatibilidade da súmula; divergente = suspensa até correção | `054` | — | `044` §8 | Implementado |
| E3 | Correção excepcional pós-publicação só sem mudar eleitorado/avaliados | `CORRECTION_CHANGES_ELECTORATE`; só admin | `054` | — | `042` | Implementado |
| E4 | Votação interrompida não reabre sozinha; retomar / publicar / reabrir 1–24 h; uma reabertura por ciclo | `reactivate_rating_vote`; `unique(cycle_id)`; prorrogação comum intacta | `054`, `lib/ratingvote.tsx` | — | `044` §11 | Implementado |
| E5 | Ex-integrante que jogou continua eleitor (acesso pontual) | `rating_voters`, `rating_vote_my_voter`; lembretes e push incluem | `053` | — | `044` §12 | Implementado |
| F1 | Vaga reservada 30 dias, conta no limite de 100 | `private.pelada_seat_count` em `join_pelada` | `055` | — | `044` §14 | Implementado |
| F2 | Cancelar no prazo recupera sem duplicar; legado cheio é informado | `not_restored` na resposta | `055`, `conta.tsx` | — | `044` §14 | Implementado |
| F3 | `completed` só com todas as etapas; retry com espera; alerta; sem PII no erro | Checkpoints `votes`/`personal`/`auth` | `055`, `functions/account-purge` | — | `044` §14 | Implementado (Edge Function não executada: precisa do projeto Supabase) |
| G3 | Documentação e minutas legais | Termos 1.2 e Política 1.3 (minutas) | `legalText.ts`, `057` | — | `031` | Implementado — **[VALIDAR COM ADVOGADO]** |
| G4 | Partida Rápida, Central de Compartilhamento, temas Premium | — | — | — | — | Fora do escopo |
