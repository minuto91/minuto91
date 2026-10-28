# Matriz de rastreabilidade V8.1

Auditoria de 28/10/2026 sobre `main` (`8f7f8cc`, migrações 001–058). Status: **implementado · parcial · ausente · conflitante · pendente de fonte**.
"Implementado" só com código **e** teste. Sem texto original, o status é "pendente de fonte" — a letra A/B/C nunca basta.
Testes: SQL = `supabase/tests_editor/NNN_*.sql` (PGlite, `cd supabase/local_db; node run.mjs`); App = `cd app; npm test`.

## A. As 45 etapas

| ID | Letra | Conteúdo comprovado | Status | Fonte | Arquivos / teste | Resultado |
|---|---|---|---|---|---|---|
| V8.1-001…007 | C,B,B,B,B,B,B | Bloco "coleção e apresentação" (8 requisitos, tabela B1–B8) — associação exata por etapa não recuperada | parcial (ver B) | Registro §5.1 | ver §B | ver §B |
| V8.1-008 | B | — | **pendente de fonte** | — | — | nada feito |
| V8.1-009 | B | — | **pendente de fonte** | — | — | nada feito |
| V8.1-010…015 | B… | Bloco notificações/integridade (tabela C1–C6) | parcial (ver C) | Registro §5.1 | ver §C | ver §C |
| V8.1-016…019 | B… | — | **pendente de fonte** | — | — | comportamento atual preservado |
| V8.1-020…029 | C,B,B,B,B,C,C,B,C,B | Bloco privacidade/histórico/compartilhamento (tabela D1–D8) | parcial (ver D) | Registro §5.1 | ver §D | ver §D |
| V8.1-030…035 | A,A,A,B,B,B | Bloco apuração/encerramento (tabela E1–E6) | parcial (ver E) | Registro §5.1 | ver §E | ver §E |
| V8.1-036…040 | B,B,B,B,B | Bloco continuidade (tabela F1–F6) | parcial (ver F) | Registro §5.1 | ver §F | ver §F |
| **V8.1-041** | B | Empate compartilha colocação (1º, 1º, 3º) | **implementado (herdado)** | Registro §5.1 | `get_season_ranking` usa `rank()` (`015`, `051`, `058:584`); SQL `010` l.190 ("empate: 1º, 1º") | `010` PASSA no baseline |
| **V8.1-042** | B | Subida/queda/estabilidade entre rankings oficiais consecutivos, sem gráficos | **ausente** | Registro §5.1 | nenhum snapshot de ranking por rodada/mês existe; app não mostra variação de posição | não implementado — ver §G |
| **V8.1-043** | B | Temporada interrompida em disputa; suspensão formal ≠ inatividade; não encerrar por inatividade | **implementado** (059) | Registro §5.1 + decisão do fundador 28/10/2026 (só admin, motivo) | `059`: `suspend_season`, `resume_season`, `get_season_lifecycle`, `sync_season_status` ignora suspensas; teste `046` | `046` PASSA; suíte 46/46 |
| **V8.1-044** | B | Temporada cancelada preserva partidas/estatísticas/troféus válidos; sem títulos sazonais pendentes | **implementado** (059) | idem | `059`: `cancel_season`, `season_consolidation` (cancelada nunca pronta); teste `046` | `046` PASSA |
| **V8.1-045** | B | Reativação excepcional e auditável de temporada cancelada | **implementado** (059) | idem | `059`: `reactivate_season`; mesmo id/datas, 0 prêmios gerados, eventos imutáveis; teste `046` | `046` PASSA |
| V8.1-046 | — | Anulação excepcional de partida oficializada | **fora do escopo (não aprovada)** | Registro §5.1 | — | não implementar |

## B. Coleção e apresentação (etapas 1–7)

| ID | Requisito | Status | Evidência no código |
|---|---|---|---|
| B1 | Troféus premium com identidade própria | parcial | SVG próprio por troféu em `lib/trophies.tsx`; arquivos oficiais **pendentes de fonte** |
| B2 | Repetidas: contador e histórico | **implementado** | contagens em `get_player_career_summary`; `get_trophy_history` paginado (`058`); SQL `045` §REV-001, `038` |
| B3 | Sala global agregando peladas, identificação e **filtro por pelada** | parcial | global (`030`, `get_trophy_history`); cada item mostra `pelada_name`; **filtro por pelada não existe** em `TrophyRoom` |
| B4 | Bloqueados em escala de cinza | parcial | `dim` = opacidade 0,35, não cinza |
| B5 | Hierarquia visual por relevância esportiva | ausente | todos os cartões têm o mesmo tamanho/ordem fixa em `TROPHIES` |
| B6 | Catálogo controlado, sem categorias automáticas | parcial | 5 de 7 no catálogo: faltam **Artilheiro da Temporada** (sem tipo de prêmio) e **Seleção da Rodada** (existe fora de `awards`) |
| B7 | Seleção da Rodada integrada à coleção | ausente | `round_selections` não entra em `TROPHIES` |
| B8 | Sala independente do Álbum | **implementado** | `TrophyRoom` separado de `app/album.tsx` |

## C. Notificações e integridade (10–15)

| ID | Requisito | Status | Evidência |
|---|---|---|---|
| C1 | Notificações pertinentes, sem excesso | implementado (herdado) | REV-040; dedupe por operação (`054`); `044` §7 |
| C2 | Histórico detalhado conforme plano | parcial | `partial` em `TrophyRoom` ("Temporadas disponíveis no seu plano"); regra exata de limite não recuperada |
| C3 | Troféus compartilhados com mesma identidade visual | parcial | `SharePanel` reutiliza `TrophyArt`; depende dos arquivos oficiais |
| C4 | Anonimização na exclusão definitiva | implementado (herdado) | `055`, `044` §14 |
| C5 | Reconfirmações em reabertura/correção | implementado (herdado) | `054` (`rating_vote_sync_eligibility`, `reactivate_rating_vote`); `044` §4, §11 |
| C6 | Competência mensal pela data efetiva da partida | implementado (herdado) | `close_month`/`grant_month_award` (049/056); `045` §REV-001 |

## D. Privacidade, histórico, compartilhamento (20–29)

| ID | Requisito | Status | Evidência |
|---|---|---|---|
| D1 | Visibilidade por perfil/vínculo | implementado (herdado) | `029`, `can_view_global`; `023` |
| D2 | Bola Murcha privada por padrão | **parcial** | `030:85` exclui `bola_murcha` da agregação vista por terceiros; teste dedicado à privacidade da Bola Murcha **não localizado** |
| D3 | Histórico de peladas encerradas preservado | implementado (herdado) | REV-047, `045` §2 |
| D4 | Correções oficiais auditáveis | implementado (herdado) | `054`; `013`, `044` |
| D5 | Conquista identificada pela pelada de origem | implementado | `get_trophy_history` devolve `pelada_name`/`season_name` |
| D6 | Elegibilidade histórica de ex-integrantes | implementado (herdado) | `left` incluído na carreira (`030`); `044` §12 |
| D7 | Celebrações individuais e acumuladas | **pendente de fonte** | regra exata não recuperada |
| D8 | Compartilhamento 1:1 e 9:16 respeitando privacidade | parcial | `SharePanel` (Story 1080×1920 / Feed 1080×1350, REV-020/033); verificação visual em aparelho **não feita** |

## E. Apuração e encerramento (30–35)

| ID | Requisito | Status | Evidência |
|---|---|---|---|
| E1 | Pendências de premiação no encerramento | parcial | `season_consolidation` (REV-026) cobre partidas/votações pendentes, não prêmios pendentes |
| E2 | Alterar datas só se compatível com a integridade | **pendente de fonte** | `customize_season` (`006`) existe; regra de compatibilidade não recuperada |
| E3 | Todos os artilheiros empatados reconhecidos; sem gols = sem vencedor | implementado | `grant_month_award` (empate compartilhado, ≥1 gol); `045` §REV-001 |
| E4 | Sem Garçom da Partida histórico | implementado | `056`; `041` |
| E5 | Prêmio mensal só após consolidação oficial | **a verificar** | `close_month` existe; vínculo com consolidação não comprovado por teste nesta entrega |
| E6 | Regras anteriores de correção/encerramento preservadas | implementado (herdado) | `054`, `056` |

## F. Continuidade (36–40)

| ID | Requisito | Status | Evidência |
|---|---|---|---|
| F1 | Conquistas preservadas após mudança de configuração | parcial | `awards` não é recalculada por `update_pelada_settings` (leitura de código); sem teste dedicado |
| F2 | Disputas/premiações pendentes respeitadas | pendente de fonte | condições exatas não recuperadas |
| F3 | Elegibilidade por vínculo e período | implementado (herdado) | REV-047/048; `045` §2 |
| F4 | Saída não elimina histórico | implementado (herdado) | REV-047 |
| F5 | Avisos de pendência sem antecipar resultado | pendente de fonte | — |
| F6 | Nada encerra/premia por inatividade | **a verificar** | `sync_season_status` encerra por **data**, não por inatividade; exceções originais não recuperadas |

## G. O que a V8.1 ainda exige e não foi implementado (e por quê)

| Item | Bloqueio |
|---|---|
| Sete troféus com arquivos oficiais; logo original | **arquivos não fornecidos** — substituir os SVG por outra coisa inventada violaria a regra |
| Artilheiro da Temporada (tipo de prêmio + tela) | falta a regra de concessão (quando, empate, quem fecha); só existe o desenho descrito |
| Seleção da Rodada na Sala | é coleção de outra tabela; falta decidir contagem (por rodada? por jogador na seleção?) |
| 042 movimentação | não existe "ranking oficial" persistido para comparar; precisa decidir o que é um ranking oficial |
| 043–045 (resolvido na 059) — riscos abertos | partidas novas em temporada cancelada/suspensa não são bloqueadas; tela em `lib/seasonlifecycle.tsx` + `temporadas.tsx` (typecheck/testes ok, **não vista rodando**); sem notificação |
| Pedestal do Artilheiro do Mês | conflito V8.0 × arte nova — aguarda o fundador |

## H. Regressão obrigatória (preservado)

| Item | Evidência |
|---|---|
| Motor V7.7 (050–052, `local_db/rating/*`) | nenhuma linha alterada nesta entrega; `git diff` vazio; testes do motor em `CHANGELOG.md` |
| Decisões V7.7 / REV V8.0 | nenhum arquivo SQL/TS alterado nesta entrega; suite completa de base em `CHANGELOG.md` |
| Documentos antigos | `docs/v77`, `docs/rev80`, `relatorio_*` intactos |
