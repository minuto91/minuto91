# Matriz de rastreabilidade V7.7

"Pronto" só quando há código **e** teste executado nesta entrega. Testes SQL em `supabase/tests_editor/`
(rodados no Postgres local PGlite com `cd supabase/local_db; node run.mjs`); testes de lógica com `node --test`.

| Requisito | SQL / backend | Frontend | Teste | Status |
|---|---|---|---|---|
| Voto editado e versionado | `053`: `rating_vote_versions`, `cast_rating_vote`, trigger `protect_vote_history` | `votar.tsx` (sem mudança de fluxo) | `044` §1 | Pronto |
| Histórico do próprio eleitor | `053`: `get_my_rating_vote_history` | `partida/[id]/meus-votos.tsx` | `044` §1, §6 | Pronto |
| Voto invalidado / revalidado | `054`: `rating_vote_sync_eligibility`, `correct_match_sheet` | — | `044` §4 | Pronto |
| Votação com poucos votos | `053`: `publish_rating_vote_core` (q nulo) | `partida/[id]/index.tsx` ("Avaliação insuficiente") | `044` §6, `042` | Pronto |
| Empate em prêmio / em branco / ≥3 | `053`: `set_rating_vote_awards`, núcleo de publicação | — | `044` §3, §6 | Pronto |
| Sigilo administrativo | `053`: `get_rating_vote_admin` só progresso | `lib/ratingvote.tsx` | `044` §2, `042`, `020_security_invariants` | Pronto |
| Publicação automática idempotente | `053`: `rating_vote_tick`, `run_job` | `lib/ratingvote.tsx` ("publicado automaticamente") | `044` §6, `042` | Pronto |
| Prorrogação única | `053`: `extend_rating_vote` | `lib/ratingvote.tsx` | `044` §5 | Pronto |
| Seleção 4-3-3 global + secundária | `056`: `compute_round_selection` v2, `request/decide_secondary_position` | `lib/secondary.tsx`, `jogador/[id]`, `pelada/[id]` | `044` §13 | Pronto |
| Garçom da Partida excluído | `056` | `trophies.tsx`, `arts.tsx`, `career.ts`, `careerv2.ts`, `push-sender/logic.ts` | `041`, `push_logic.test.mjs` | Pronto |
| Anulação sem prazo, prévia com token, idempotente | `054`: `annul_match`, `preview_match_annulment` | `lib/annul.tsx` | `013`, `044` §7 | Pronto |
| Restauração / repetição | `054`: `restore_match`, `match_status_events` | `lib/annul.tsx` (`RestoreMatch`) | `044` §8–9 | Pronto |
| Dados de anulada ocultos (banco) | `054`: colunas `public_team_*_score`, privilégios de coluna, 9 políticas RESTRICTIVE, `get_match_lineup`, `get_my_home`, `get_rating_vote` | `match.ts`/`matchview.ts`, `partidas.tsx`, `partida/[id]`, `pelada/[id]`, `central.tsx`, `pending.tsx` | `044` §7, `app/tests/v77.test.ts` | Pronto |
| Linha do tempo pública x admin | `054`: `get_match_status_history(_admin)`; RLS de `match_annulments` fechada | `MatchStatusTimeline` | `013`, `044` §10 | Pronto |
| Notificação por operação + dedupe | `054`: `notify_from_audit`, `quiet_effects` | `push-sender/logic.ts` (`match_restored`) | `044` §7–9 | Pronto |
| Restauração da publicação original | `054`: suspensões, `rating_vote_sheet_compatible` | `lib/ratingvote.tsx` | `044` §8 | Pronto |
| Correção excepcional pós-publicação | `054`: `correct_match_sheet` | — | `042` | Pronto |
| Votação interrompida / reabertura 1–24 h / 1 por ciclo | `054`: `reactivate_rating_vote`, `rating_vote_reopenings` | `lib/ratingvote.tsx` | `044` §11 | Pronto |
| Ex-integrante eleitor | `053`: `rating_voters`, `rating_vote_my_voter`, tick, push | `lib/ratingvote.tsx` | `044` §12 | Pronto |
| Reserva de vaga / 100 participantes | `055`: `pelada_seat_count`, `join_pelada`, `cancel_account_deletion` | `conta.tsx` | `044` §14 | Pronto |
| Exclusão com retry e checkpoints | `055`: `purge_account`, `finish_account_purge`, `complete_account_purge_auth`, `run_scheduled_tasks` | `conta.tsx` | `044` §14 | Pronto (SQL); Edge Function `account-purge` **sem execução** (depende do projeto Supabase) |
| Minutas legais alinhadas | `057` | `legalText.ts` | `031` | Pronto — revisão jurídica pendente |
| Motor V7.7 congelado (regressão) | sem alteração | — | `rating_engine.test.mjs`, `rating_sql.test.mjs`, `simulate.mjs` | Pronto (regressão) |
| Atributos DEF/LET/APR/REF | — | — | — | **Pendente de evidência** (artefatos V7.5/V7.7 ausentes) |
| "Alternativa A" da configuração por rodada | — | — | — | **Pendente de evidência** |
| E2E em aparelho/navegador com login | — | — | — | **Não executado** (exige Supabase dev e conta; ver relatório §6) |
