# Especificação V8.0 — REV-001 a REV-050

> **AVISO DE FONTE (leia primeiro).** O texto **original** das 50 revisões (prompt/especificação da V8.0) **não está no
> repositório nem foi fornecido nesta entrega**. O que consta abaixo é a **matriz de implementação** copiada, sem alteração,
> de `docs/rev80/RELATORIO_REV80.md` (§1, §2, §3, §5): ela descreve o que foi feito por revisão, **não é a especificação
> original** e não a substitui. Pendência: enviar o original da V8.0 para ser arquivado aqui integralmente
> (DECISOES_MESTRE DOC-02). Nada foi reconstruído ou inventado.
> Estado de entrega da V8.0: `main` em `8f7f8cc`, migração `058_rev80.sql`; REV-024/025 bloqueadas (Resenha só no motor futuro).

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
| 004 Menos textos | IMPLEMENTADA | Telas tocadas + varredura das antigas: 20 legendas longas encurtadas (carreira, perfil, convite, partida, votação, escalações, Financeiro, Premium, temporadas, sorteio, avisos, secundária, troféus); títulos sem exclamação. Mantidos os textos de segurança, privacidade, legais e de ações irreversíveis (exclusão/transferência de conta, anulação, compartilhamento) | — | lint/tsc |
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
| 027 Estados vazios | IMPLEMENTADA | `EmptyState` com ícone simples em todas as listas de página (elenco, escalações, cobranças, lançamentos, mensalistas, perfil, conquistas, álbum, histórico, lote, extrato); CTA só onde a pessoa pode agir (Premium só para quem administra o plano) | — | lint/tsc |
| 028 Pendências admin na Central | IMPLEMENTADA | Central: uma linha por pelada administrada, só com pendência real | `get_my_admin_pending` | `045` §7b |
| 029 Salvamento confiável | JÁ EXISTIA CORRETAMENTE | V6.1 (voto só avança após o servidor); fluxos novos seguem o padrão (bloqueio de duplo envio, sucesso só após o servidor, campos preservados no erro) | — | — |
| 030 Nome único | JÁ EXISTIA CORRETAMENTE | `update_my_profile` (027) propaga o nome; carta ajusta fonte sem abreviar | — | — |
| 031 Configurações em seções | IMPLEMENTADA | `configuracoes.tsx`: Identidade, Times, Agenda, Votação, Registro de cartões, Financeiro, Plano | `update_pelada_identity` | tsc |
| 032 Reprocessamento coordenado | IMPLEMENTADA | — | cadeia existente (014→015→016→018) + álbum global por trigger + nova versão da retrospectiva por impressão digital | `045` §5/§6 |
| 033 Compartilhar carta e conquistas | IMPLEMENTADA | carta/figurinha já existiam; troféus próprios agora compartilháveis | — | tsc |
| 034 Premium contextual | IMPLEMENTADA | bloqueios só onde há recurso Premium; sem pop-ups | servidor | — |
| 035 Navegação contextual | IMPLEMENTADA | `lib/sticky.ts`: aba/filtro lembrados na sessão (rankings, elenco, cobranças, Minha Carreira); a pilha do Expo Router mantém a tela de origem e a rolagem; rascunhos guardam dados não enviados; pelada escolhida já persistia | — | lint/tsc |
| 036 Skeletons | IMPLEMENTADA | `LoadingBlock` neutro, sem animação, no lugar de "Carregando..." em 24 telas; distinto de vazio, erro (tentar de novo) e bloqueio | — | lint/tsc |
| 037 Confirmações proporcionais | JÁ EXISTIA CORRETAMENTE | `dialog.confirm`; novos: cancelar partida, lote, prorrogação | — | — |
| 038 Fotos e avatares | JÁ EXISTIA CORRETAMENTE | `Avatar` e carta com iniciais | — | — |
| 039 Hierarquia de botões | JÁ EXISTIA CORRETAMENTE | `Button` primary/secondary/ghost/danger | — | — |
| 040 Notificações inteligentes | IMPLEMENTADA | Minha conta > Notificações em Urgentes / Administrativas / Informativas | dedupe por operação (054) e limite semanal existentes | tsc |
| 041 Revisão da súmula | IMPLEMENTADA | `lib/sheetreview.tsx`: placar, participantes, estatísticas, problemas; diferenças na correção | validações oficiais intactas | tsc |
| 042 Detalhes da partida | IMPLEMENTADA | placar + gols no topo; Avaliações, Escalação, Estatísticas recolhíveis | — | tsc |
| 043 Usabilidade mobile | IMPLEMENTADA | `Screen`/`ListScreen`: teclado não cobre campos (`automaticallyAdjustKeyboardInsets`, recolhe ao rolar); toques pequenos levados a 44 pt (Central, Conta, Jogadores, Denunciar); componentes novos com 44–52 pt e linhas inteiras tocáveis | — | bundle web ok. **Não testado em aparelho** |
| 044 Rascunhos | IMPLEMENTADA | `lib/drafts.ts` (por usuário + pelada + formulário, 7 dias, só no aparelho): criação de pelada e súmula; Continuar/Descartar | nunca publica/vota/paga sozinho | — |
| 045 Busca | IMPLEMENTADA | Jogadores e Lote (≥12), sem acento/maiúscula, seleção preservada | — | `rev80.test.ts` |
| 046 Homônimos | IMPLEMENTADA | identificador curto só para admin e só se foto+posição não bastam | relações já por id | `rev80.test.ts` |
| 047 Saída preserva carreira | IMPLEMENTADA | "(encerrada)" na Minha Carreira; histórico marca participação encerrada | períodos; `left` já incluído na carreira (030) | `045` §2 |
| 048 Retorno reativa vínculo | IMPLEMENTADA | — | mesmo vínculo; períodos com datas; sem admin; classificação pendente | `045` §2 |
| 049 Financeiro após retorno | IMPLEMENTADA | `financeiro/extrato.tsx` (aberto por Mensalistas > Extrato): total em aberto, períodos, "Antes da saída" x "Depois do retorno", cada cobrança pela competência; pagar pelo lote | saída encerra a mensalidade; ausência sem cobrança; mesma competência não duplica; `get_member_finance_statement` | `045` §2, `036` atualizado |
| 050 Partidas canceladas | IMPLEMENTADA | `lib/cancelmatch.tsx` (cancelar/remarcar, dados do cancelamento) | status `cancelled`, `cancel_match`, `reschedule_match` (mesma linha), histórico; publicada não cancela | `045` §1 |

## 3. Testes alterados de propósito (regra nova)

- `036_v43_finance.sql`: a saída agora encerra a mensalidade sozinha (REV-049); reativar continua proibido.
- `038_v44_central_career.sql`: Artilheiro do Mês passou a ser troféu (REV-001).
- `044_v77_integrity.sql`: a secundária só vale com confirmação da partida (REV-011).

## 5. Bloqueios e lacunas (decisão sua)

1. **REV-024/025 — Resenha.** Decisão do fundador (28/10/2026): a escolha vai alimentar o RES do OVR, com a fórmula de
   um **novo motor matemático futuro**. Como o motor V7.7 está congelado, a Resenha fica para ser implementada junto
   com esse motor (coleta da escolha + RES novo + regressão), e não nesta entrega.
2. Auditoria visual em aparelho (iPhone/Android) e das artes da retrospectiva: não feita nesta entrega.
3. A retrospectiva por pelada exige vínculo ativo: quem saiu não abre a da pelada antiga (decisão pendente).
5. Herdado da V7.7: especificação V7.5/V7.7 do motor (DEF/LET/APR, 3,22) ausente do repositório.

