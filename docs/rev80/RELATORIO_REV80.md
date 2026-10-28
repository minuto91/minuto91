# Minuto 91 — REV 8.0: relatório de implementação (28/10/2026)

Base: V7.7 (`main` em `1618227`, migrações 001–057). Trabalho na branch `claude/minuto-91-rev-8-398cfe`.
Não havia ZIP anexado: a auditoria foi feita sobre o repositório (mesmo código da V7.7).

## 1. Regras inegociáveis — como foram respeitadas

- **Motor V7.7 congelado.** Nenhuma linha de `050`–`052` nem de `supabase/local_db/rating/*` foi alterada
  (`git diff 1618227 -- supabase/migrations/05[0-2]* supabase/local_db/rating` vazio). Testes do motor
  (`rating_engine.test.mjs`, `rating_sql.test.mjs`) rodados de novo: ver §4.
  - Defesas de **goleiro temporário** ficam só no registro da partida (`match_keeper_save_claims`); o motor continua lendo
    apenas `match_keeper_saves`, que só recebe goleiros de posição principal. Teste: `045_rev80` §4.
  - DIS 70 com cartões desligados: regra do motor intacta; só o controle mudou de lugar (REV-014).
  - Nenhuma fórmula de OVR no app (a variação de OVR só esconde o zero, REV-023).
- **Sem curva LET V7.9.** Observação herdada da V7.7: o repositório tem o motor v2 (ATU/EST/PEQ/RES/DIS); os artefatos
  "V7.5/V7.7 DEF/LET/APR, diferencial 3,22" não existem no repositório (ver `docs/v77/RELATORIO_AUDITORIA_IMPLEMENTACAO.md` §2).
  O motor existente foi tratado como o congelado.
- **Nenhuma migração antiga editada.** Tudo novo está em `058_rev80.sql`. Testes antigos alterados só onde a REV 8.0
  muda a regra de propósito (listados em §3).
- Premium R$ 29,90/mês por pelada; bloqueios Premium verificados no servidor (rankings, retrospectiva, Bola Murcha na criação).

## 2. Matriz das 50 revisões

Status: **IMPLEMENTADA**, **JÁ EXISTIA CORRETAMENTE**, **BLOQUEADA**, **PARCIAL** (feita em parte; o que falta está escrito).

| ID | Status | Frontend | Backend / banco (058 salvo indicação) | Teste |
|---|---|---|---|---|
| 001 Artilheiro do Mês | IMPLEMENTADA | `lib/trophies.tsx` (chuteira dourada, travas azuis, sem pedestal) | Prêmio já concedido em `close_month` (049/056: mês da partida, ≥1 gol, empate compartilhado, sem duplicar). Novo: contagem em `get_player_career_summary` e histórico em `get_trophy_history('top_scorer')` | `045` §REV-001; `038` atualizado |
| 002 Álbum global | IMPLEMENTADA | `app/album.tsx`; Minha Carreira abre um só álbum | `player_global_sticker_unlocks`, `global_sticker_values` (soma; sequências = melhor marca), `reconcile_global_stickers` por trigger em `player_sticker_progress` (revoga com data se uma correção baixar o total) | `045` §5 |
| 003 Histórico completo | IMPLEMENTADA | `lib/history.tsx` (3 recentes + `app/historico.tsx` paginado; ícones bola azul, chuteira azul com travas, retângulos amarelo/vermelho) | `get_my_match_history` passa a devolver cartões e `pelada_active` | tsc/lint; SQL `038` |
| 004 Menos textos | PARCIAL | Textos cortados nas telas tocadas (criação, configurações, votação, convite, rankings, jogadores, notificações, perfil, carreira) | — | Falta varrer as telas não tocadas nesta entrega |
| 005 Seletor de posição | IMPLEMENTADA | `PositionPicker` em grade de 4 colunas, sem grupos; nome completo abaixo; `accessibilityRole=radio` | ids internos iguais | tsc |
| 006 Criação em 5 etapas | IMPLEMENTADA | `app/criar-pelada.tsx` + rascunho | `create_pelada_wizard` (idempotente por `request_id`; Premium ignorado sem plano), colunas `location`, times/cores padrão | `045` §7a |
| 007 Pagamentos em lote | IMPLEMENTADA | `financeiro/lote.tsx` (preenche saldo, edita, parcial/integral, confirmação) | `register_payments_batch`: um lançamento por cobrança, atômico, idempotente (lote e item), auditado | `045` §3 |
| 008 Será mensalista? | IMPLEMENTADA | `lib/billing.tsx` em Jogadores | `billing_class` pendente na entrada/retorno; `classify_member_billing`; `set_default_monthly_amount`; falha = continua pendente | `045` §2 |
| 009 Sem "VOCÊ" | IMPLEMENTADA | `MatchScore` sem o rótulo; negrito no time em que a pessoa jogou (partida passa o time real da súmula) | — | tsc |
| 010 Formação e goleiro temporário | IMPLEMENTADA | `lib/matchroles.tsx` | `match_participants.temp_goalkeeper`, `set_match_temp_goalkeeper` (só se o time não tem goleiro; posição/carta/OVR intactos). Formação até 11 já existia (`formation.ts`) | `045` §4 |
| 011 Secundária por partida | IMPLEMENTADA | `lib/matchroles.tsx` | `match_secondary_confirmations`; `snapshot_secondary_position` só retrata com confirmação da partida; `set_match_secondary_played` recalcula a Seleção | `045` §4; `044` atualizado |
| 012 Bloco de votação | IMPLEMENTADA | `lib/ratingvote.tsx`: status, prazo, 1/12, Avaliar; +30 min/+1 h/+2 h; "Detalhes da votação" recolhível | regras do servidor intactas (uma prorrogação) | tsc |
| 013 Defesas difíceis | IMPLEMENTADA | `lib/matchroles.tsx` (goleiro informa; admin confirma/corrige/recusa) | `match_keeper_save_claims`, `submit_keeper_saves_claim`, `review_keeper_saves_claim`, auditoria | `045` §4 |
| 014 Registro de cartões | IMPLEMENTADA | saiu da tela da pelada; Configurações > Registro de cartões | `set_cards_tracking` (existente) | tsc |
| 015 Votação simplificada | IMPLEMENTADA | Configurações > Votação: 2/4/6 h, Bola Murcha (Premium), Todos/Quantidade mínima com campo só no mínimo | `update_pelada_settings` (existente) | `018` |
| 016 Convite compacto | IMPLEMENTADA | código curto + ícone de copiar (copia o token inteiro); sem texto de 7 dias/100 | validade no servidor (existente) | tsc |
| 017 Nome na carta | JÁ EXISTIA CORRETAMENTE | revogada: nada foi criado | — | — |
| 018 Rankings Basic/Premium | IMPLEMENTADA | Rankings: Premium identificado; bloqueio com CTA | `get_season_ranking` recusa média/jogos/vitórias sem Premium | `045` §6 |
| 019 Retrospectiva (8 telas) | IMPLEMENTADA | `pelada/[id]/retrospectiva.tsx` | `get_season_retrospective_official`, `season_retrospectives` (versões) | `045` §6 |
| 020 Artes da retrospectiva | IMPLEMENTADA | `lib/retroarts.tsx`: P01–P06 e I01–I05, composição própria para Story 1080×1920 e Feed 1080×1350 (via `SharePanel`) | dados da versão oficial | tsc. **Não conferido visualmente no aparelho** |
| 021 Botão Minha Carreira | IMPLEMENTADA | `perfil.tsx` | — | — |
| 022 Cabeçalho do perfil | IMPLEMENTADA | posição sem "em <pelada>" (perfil e carreira) | — | — |
| 023 Variação nula do OVR | IMPLEMENTADA | `OvrDelta` não mostra 0 nem sem base | — | `central.test.ts` |
| 024 Limite da Resenha | **BLOQUEADA** | — | — | ver §5 |
| 025 Resenha entre os times | **BLOQUEADA** | — | — | ver §5 |
| 026 Encerramento x consolidação | IMPLEMENTADA | estados "em andamento"/"em consolidação" | `season_consolidation` (fim do calendário E sem partidas/votações pendentes); geração idempotente | `045` §6 |
| 027 Estados vazios | PARCIAL | `EmptyState` nas telas novas (álbum, histórico, lote, rankings, retrospectiva) | — | falta padronizar telas antigas |
| 028 Pendências admin na Central | IMPLEMENTADA | Central: uma linha por pelada administrada, só com pendência real | `get_my_admin_pending` | `045` §7b |
| 029 Salvamento confiável | JÁ EXISTIA CORRETAMENTE | V6.1 (voto só avança após o servidor); fluxos novos seguem o padrão (bloqueio de duplo envio, sucesso só após o servidor, campos preservados no erro) | — | — |
| 030 Nome único | JÁ EXISTIA CORRETAMENTE | `update_my_profile` (027) propaga o nome; carta ajusta fonte sem abreviar | — | — |
| 031 Configurações em seções | IMPLEMENTADA | `configuracoes.tsx`: Identidade, Times, Agenda, Votação, Registro de cartões, Financeiro, Plano | `update_pelada_identity` | tsc |
| 032 Reprocessamento coordenado | IMPLEMENTADA | — | cadeia existente (014→015→016→018) + álbum global por trigger + nova versão da retrospectiva por impressão digital | `045` §5/§6 |
| 033 Compartilhar carta e conquistas | IMPLEMENTADA | carta/figurinha já existiam; troféus próprios agora compartilháveis | — | tsc |
| 034 Premium contextual | IMPLEMENTADA | bloqueios só onde há recurso Premium; sem pop-ups | servidor | — |
| 035 Navegação contextual | PARCIAL | pilha do Expo Router e pelada escolhida já preservadas; rascunhos novos preservam dados | — | rolagem/filtros não auditados |
| 036 Skeletons | PARCIAL | skeleton nas telas novas | — | telas antigas |
| 037 Confirmações proporcionais | JÁ EXISTIA CORRETAMENTE | `dialog.confirm`; novos: cancelar partida, lote, prorrogação | — | — |
| 038 Fotos e avatares | JÁ EXISTIA CORRETAMENTE | `Avatar` e carta com iniciais | — | — |
| 039 Hierarquia de botões | JÁ EXISTIA CORRETAMENTE | `Button` primary/secondary/ghost/danger | — | — |
| 040 Notificações inteligentes | IMPLEMENTADA | Minha conta > Notificações em Urgentes / Administrativas / Informativas | dedupe por operação (054) e limite semanal existentes | tsc |
| 041 Revisão da súmula | IMPLEMENTADA | `lib/sheetreview.tsx`: placar, participantes, estatísticas, problemas; diferenças na correção | validações oficiais intactas | tsc |
| 042 Detalhes da partida | IMPLEMENTADA | placar + gols no topo; Avaliações, Escalação, Estatísticas recolhíveis | — | tsc |
| 043 Usabilidade mobile | PARCIAL | componentes novos com 44–52 pt e linhas inteiras tocáveis | — | sem teste em aparelho nesta entrega |
| 044 Rascunhos | IMPLEMENTADA | `lib/drafts.ts` (por usuário + pelada + formulário, 7 dias, só no aparelho): criação de pelada e súmula; Continuar/Descartar | nunca publica/vota/paga sozinho | — |
| 045 Busca | IMPLEMENTADA | Jogadores e Lote (≥12), sem acento/maiúscula, seleção preservada | — | `rev80.test.ts` |
| 046 Homônimos | IMPLEMENTADA | identificador curto só para admin e só se foto+posição não bastam | relações já por id | `rev80.test.ts` |
| 047 Saída preserva carreira | IMPLEMENTADA | "(encerrada)" na Minha Carreira; histórico marca participação encerrada | períodos; `left` já incluído na carreira (030) | `045` §2 |
| 048 Retorno reativa vínculo | IMPLEMENTADA | — | mesmo vínculo; períodos com datas; sem admin; classificação pendente | `045` §2 |
| 049 Financeiro após retorno | PARCIAL | lote mostra cada cobrança pela competência | saída encerra a mensalidade; ausência sem cobrança; mesma competência não duplica; `get_member_finance_statement` separa "antes da saída"/"atual" | `045` §2, `036` atualizado. **Falta a tela do extrato separado** |
| 050 Partidas canceladas | IMPLEMENTADA | `lib/cancelmatch.tsx` (cancelar/remarcar, dados do cancelamento) | status `cancelled`, `cancel_match`, `reschedule_match` (mesma linha), histórico; publicada não cancela | `045` §1 |

## 3. Testes alterados de propósito (regra nova)

- `036_v43_finance.sql`: a saída agora encerra a mensalidade sozinha (REV-049); reativar continua proibido.
- `038_v44_central_career.sql`: Artilheiro do Mês passou a ser troféu (REV-001).
- `044_v77_integrity.sql`: a secundária só vale com confirmação da partida (REV-011).

## 4. Resultados executados

Ver `docs/rev80/RESULTADO_TESTES.txt` (gerado nesta entrega):
- SQL (PGlite, 60 migrações, 45 testes incl. `045_rev80`): resultado no arquivo.
- Motor/lógica (`node --test` em `supabase/local_db`): resultado no arquivo.
- App: `npm run lint` (0 problemas), `npm run typecheck` (0 erros), `npm test` (29/29).

Não executado: testes no Supabase dev real (SQL Editor), Edge Functions, iPhone/Android, verificação visual das artes.

## 5. Bloqueios e lacunas (decisão sua)

1. **REV-024/025 — Resenha.** Decisão do fundador (28/10/2026): a escolha vai alimentar o RES do OVR, com a fórmula de
   um **novo motor matemático futuro**. Como o motor V7.7 está congelado, a Resenha fica para ser implementada junto
   com esse motor (coleta da escolha + RES novo + regressão), e não nesta entrega.
2. **REV-049 tela** do extrato separado (backend pronto).
3. **REV-004/027/035/036/043**: varredura completa das telas antigas e auditoria visual em aparelho (Fase 5).
4. Ex-integrante não abre a retrospectiva da pelada antiga (o acesso por temporada exige vínculo ativo, regra existente).
5. Herdado da V7.7: especificação V7.5/V7.7 do motor (DEF/LET/APR, 3,22) ausente do repositório.

## 6. Implantação

1. Supabase **dev**: rodar `supabase/migrations/058_rev80.sql` no SQL Editor; depois `supabase/tests_editor/045_rev80.sql`
   (termina com o erro proposital "PASS: 045_rev80").
2. App: `cd app; npm install; npm run check`.
3. Rollback: descrito no cabeçalho da `058`.
