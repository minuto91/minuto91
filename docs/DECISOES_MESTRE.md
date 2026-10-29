# Registro mestre de decisões — Minuto 91

Status: **proposta · aprovada · implementada · pendente · superada · adiada**. "Aprovada" não é "implementada".
Nada aqui é apagado; substituição vira "superada" com o ID de quem substituiu.
Decisões V7.7 completas (A1–G4): `docs/v77/DECISOES_CONSOLIDADAS.md` (continuam vigentes, não repetidas aqui).
Decisões V8.0 (REV-001–050): `docs/ESPECIFICACAO_V8.0.md`.

## 1. Governança (fonte: Registro de 26/10/2026, §2)

| ID | Versão | Decisão | Status | Precedência / observação |
|---|---|---|---|---|
| GOV-01 | V8.1 | Toda decisão aprovada é requisito persistente, com ID, status, origem, versão e impacto | implementada (este arquivo) | — |
| GOV-02 | V8.1 | Consultar o registro mestre antes de perguntar; não reabrir decisão encerrada | aprovada | — |
| GOV-03 | V8.1 | Decisão que substitui outra: manter a antiga como superada | aprovada | — |
| GOV-04 | V8.1 | Todo prompt traz: implementar, preservar, não implementar + matriz | aprovada | — |
| GOV-05 | V8.1 | Conflito/lacuna: informar, nunca suposição; pequenas escolhas técnicas são delegadas | aprovada | — |
| GOV-06 | V8.1 | Atualizar registro mestre + changelog junto com o código | aprovada | Cumprido a partir desta entrega |
| GOV-07 | V8.1 | Não declarar implementação/recuperação sem evidência | aprovada | — |

## 2. Restrições absolutas V8.1 (fonte: prompt mestre V8.1 §1)

| ID | Decisão | Status | Observação |
|---|---|---|---|
| RST-01 | Motor V7.7 congelado; sem LET V7.9; sem cálculo de nota no app | aprovada, **preservada** | `git diff` de `050–052` e `supabase/local_db/rating/` vazio nesta entrega |
| RST-02 | Nada de Etapa 46 (anulação excepcional de partida oficializada) | adiada/não aprovada | Fora do escopo |
| RST-03 | Maior Evolução adiada | adiada | — |
| RST-04 | Luva de goleiro (exploração visual) não é categoria | aprovada | — |
| RST-05 | Garçom da Partida e Garçom da Rodada não são troféus históricos (Garçom da Rodada fica como destaque temporário) | aprovada | Garçom da Partida já excluído na V7.7 (A3) |
| RST-06 | Sem novas categorias/premiações | aprovada | — |

## 3. Etapas 1–45 da Sala de Troféus

Registro individual de cada etapa: `MATRIZ_RASTREABILIDADE.md` §A (V8.1-001…045). Letras A/B/C: só histórico (GOV/RST: nunca especificação).
Etapas **8, 9, 16, 17, 18, 19**: texto original **não recuperado** → status **pendente**; nada implementado nem inferido.
Etapas 41–45 têm conteúdo funcional recuperado (resumo abaixo, texto na `ESPECIFICACAO_V8.1.md` §4).

| ID | Decisão | Status |
|---|---|---|
| V8.1-041 | Empate real divide a colocação (1º, 1º, 3º); sem desempate artificial | **implementada (herdada)** — `get_season_ranking` usa `rank()`; teste `010` linha 190 |
| V8.1-042 | Indicar subida/queda/estabilidade entre rankings oficiais consecutivos; sem gráficos | aprovada — **não implementada** (não há registro de rankings oficiais anteriores) |
| V8.1-043 | Temporada interrompida segue em disputa; separar suspensão formal de inatividade recente; nunca encerrar/premiar por inatividade | **implementada** (059, 28/10/2026) — `suspend_season`/`resume_season`, só admin, motivo obrigatório; suspensa não é encerrada pelo calendário nem consolidada; inatividade é só informação (`get_season_lifecycle`). Mecanismo e permissão: escolha técnica do fundador em 28/10/2026 |
| V8.1-044 | Temporada cancelada preserva partidas, estatísticas, troféus válidos; sem títulos sazonais pendentes | **implementada** (059) — `cancel_season`, só admin, motivo; nada é apagado; cancelada não consolida (sem título sazonal). Coluna `seasons.lifecycle`; `status` por data não mudou |
| V8.1-045 | Reativação excepcional e auditável de temporada cancelada, sem duplicar/reprocessar | **implementada** (059) — `reactivate_season`, só admin, motivo; mesmo id/nome/datas/partidas; não concede nada; eventos imutáveis em `private.season_lifecycle_events` + `audit_events` |
| V8.1-046 | Anulação excepcional de partida oficializada | **não aprovada** — não implementar |

## 4. Troféus, branding e documentação

| ID | Decisão | Status |
|---|---|---|
| TRO-01 | Sete troféus oficiais (Craque da Partida, Artilheiro da Temporada, Artilheiro do Mês, Rei do Mês, Garçom do Mês, Seleção da Rodada, Bola Murcha) com **arquivos de arte oficiais** (sem SVG/CSS/emoji/IA) | aprovada — **pendente de fonte**: arquivos não fornecidos. Hoje a Sala usa 5 desenhos SVG da V4.4/V8.0 (`lib/trophies.tsx`) |
| TRO-02 | Artilheiro do Mês: chuteira dourada **sem bola** | aprovada; V8.0 (REV-001) implementou "sem pedestal" |
| TRO-03 | Garçom do Mês: mão dourada **no centro da base**, bandeja e bola | aprovada; conferir arte final |
| TRO-04 | Pedestal do Artilheiro do Mês (V8.0: sem pedestal × arte nova: com base) | **pendente — conflito, aguarda decisão do fundador** |
| TRO-05 | Bola Murcha privada por padrão | aprovada; herdada (029/030) |
| BRD-01 | Logo oficial só pelo arquivo original (sem redesenho/CSS/SVG/IA/texto) | aprovada — **pendente de fonte** (arquivo não fornecido; `app/assets/images/icon.png` não foi verificado como a logo oficial) |
| BRD-02 | Identidade: branco predominante, azul institucional, dourado; evitar tema escuro/verde | aprovada; app já usa `colors` azul/dourado |
| BRD-03 | Central do Jogador única (Início, Peladas, Carreira, Perfil) | aprovada, herdada (A1) |
| DOC-01 | Pasta `docs` permanente com 7 arquivos | **implementada nesta entrega** |
| DOC-02 | ESPECIFICACAO_V8.0 deve conter as 50 revisões integralmente "da fonte fornecida" | **pendente de fonte**: o texto original não está no repositório; só o relatório `docs/rev80/RELATORIO_REV80.md` |

## 4b. Central do Jogador V8.4 (anexo E01–E16)

Registro completo, por ID, em `V8.4_DECISOES_E01_E16.md` (E15-01…40 e E16-01…50 individualmente). Resumo: **C-01** REV-028 (resumo administrativo na Central) × E07 → vale E07 no bloco Atenção; **L-01** data/horário/local de rodada inexistentes; **L-04** pilhas independentes por aba não feitas (aguardam aprovação). Nenhuma regra de OVR, votação, finanças, planos ou RLS foi alterada.

## 5. Conflitos e perguntas abertas

1. Pedestal do Artilheiro do Mês (TRO-04).
2. Arquivos finais das 7 esculturas e da logo (TRO-01, BRD-01).
3. Textos originais das etapas 8–9, 16–19 e condições das 20–40.
4. O que é um "ranking oficial" (042). (Suspensão/cancelamento/reativação resolvidos em 28/10/2026: só admin, com motivo.) Abertas por não estarem especificadas: partidas novas em temporada cancelada/suspensa não são bloqueadas; cancelamento de temporada já consolidada é permitido.
5. `docs/rev80` informa que os artefatos V7.5/V7.7 (DEF/LET/APR, 3,22) não existem no repositório: o motor v2 existente foi tratado como o congelado (herdado de `docs/v77`).
