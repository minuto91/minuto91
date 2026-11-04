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
| RST-04 | Luva de goleiro (exploração visual) não é categoria | aprovada — **superada parcialmente pela V8.7 (C01/A03)**: a Luva de Ouro passa a ser prêmio oficial de temporada; a arte continua sem arquivo oficial | — |
| RST-05 | Garçom da Partida e Garçom da Rodada não são troféus históricos (Garçom da Rodada fica como destaque temporário) | aprovada | Garçom da Partida já excluído na V7.7 (A3) |
| RST-06 | Sem novas categorias/premiações | aprovada — **superada somente neste ponto pela V8.7**, que cria expressamente Maestro da Temporada e Luva de Ouro (e o Artilheiro da Temporada, que não existia como prêmio) | — |

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

## 6. V8.7 — prêmios de temporada e Meus Prêmios (29/10/2026)

Registro completo por ID em `V8.7_MATRIZ_RASTREABILIDADE.md`; texto normativo em `V8.7_DECISOES_COMPLETAS.md`. Resumo:

| ID | Decisão | Status |
|---|---|---|
| A01–A05 | Artilheiro da Temporada (nome preservado; "Chuteira de Ouro" só arte), Maestro da Temporada, Luva de Ouro (REF no encerramento; 50% e mínimo 5; desempates) | **implementadas** (M068, T054) |
| B01–B10 | Encerramento antecipado, anuladas fora, correções recalculam, precisão interna, REF publicada com janela de 20, denominador, improvisados, posição no encerramento, exceção, publicação conjunta | **implementadas** |
| C01 | Três identidades visuais | **implementada com arte provisória** (arquivos oficiais ausentes) |
| C02–C04, C06, C08–C12 | Sala só com contadores, troféu integral nos empates, retrospectiva, álbum de 48, exceção controlada, limitação da REF explícita, histórico versionado, saída/retorno, auditoria e testes | **implementadas** |
| C05, C07 | Artes compartilháveis; avisos | **implementadas**; compartilhamento real e envio real de push não executados |
| F01–F04 | Exceção com piso de 3, Sala só com contadores, ex-integrante, REF corrigida no contexto do encerramento | **implementadas** |
| AD01 | Meus Prêmios em Minha Carreira | **implementada** (tela real não aberta com sessão real) |
| V87-DIV-1 | Artilheiro da Temporada não existia no repositório; criado uma vez | registrado |
| V87-DIV-2 | Retroatividade não definida: sem concessão a temporadas já encerradas | **pendente — decisão do produto** |
| V87-DIV-5 | Recorte do desempate = temporada; média sobre partidas com registro | **pendente — confirmar** |

## 7. V8.9 — motor V7.7 oficial e preparação do beta (01/11/2026)

Decisões do fundador em 01/11/2026 (conversa de avaliação do projeto). Detalhe: `V8.9_IMPLEMENTACAO.md` §8.

| ID | Decisão | Status |
|---|---|---|
| V89-01 | Motor oficial = V7.7 (DEF, LET/REF, APR, RES, DIS; formula_version 3), portado da branch `v7.7-motor` | **implementada** (M070–072, T055) — supera o motor V5 (ATU/EST/PEQ/RES/DIS) como fórmula ativa; o V5 fica só como rollback |
| V89-02 | Corte da V7.7 **desde o início**: todas as temporadas de todas as peladas recalculadas | **implementada** (M073, T056) — supera o corte "temporada atual em diante" da 053 da V7.7 / 070 |
| V89-03 | V7.5 × V7.7 (≈ 3,22): mantidos os parâmetros efetivos do SQL V7.7, sem recalibrar | **aprovada** |
| V89-04 | A branch `v7.7-motor` equivale aos pacotes ZIP V7.7 (não localizados) | **aprovada** (SQL idêntico à referência) |
| V89-05 | Evolução da carta: correções por anulação mostram o OVR exibido (nulo se provisória), nunca o interno | **implementada** (M074, T031 ajustado) — achado da V8.9; vazamento existia desde o motor V5 |
| V89-06 | REV-024/025 (Resenha) | **implementadas pela V8.9** (M071: pergunta da resenha na votação alimenta o RES) — o bloqueio da V8.0 deixa de valer |
| BETA-01 | RLS ligada nas 12 tabelas `private` que não tinham (defesa em profundidade) | **implementada** (M069, Fase 2 da preparação do beta) |
| OPS-01 | Numeração: V8.9 renumerada para 070–074 depois da 069 (RLS); próxima migração livre = **075** | registrado |


## V10.0 — decisões do fundador de 04/11/2026 (REV-051 a REV-148)

| ID | Decisão | Status | Observação |
|---|---|---|---|
| V10-01 | REV-147: remover a segunda posição e reajustar o cálculo da Seleção da Rodada (só posição principal) | implementada | Migração 075; colunas antigas preservadas, sem promoção automática |
| V10-02 | REV-148: "Ver meu histórico" sai da Votação e vai para Meu Perfil, sem perda de segurança | implementada | Migração 080; tela de histórico por partida inalterada |
| V10-03 | REV-134/135: código curto e link público de convite ficam para o futuro | adiada | `docs/PENDENCIAS_FUTURAS.md` |
| V10-04 | REV-140: sem "Confirmar +18" na súmula; a declaração do convidado fica nos Termos do admin | implementada | Termos 1.3, cláusula 4.7 (migração 077); validar com advogado |
| V10-05 | REV-051/124: Início sem pelada ativa; sem Card geral; Card = maior OVR; Carreira em página contínua | implementada | — |
| V10-06 | REV-053: sem foto de perfil no primeiro bloco do Início | implementada | Faltam 4 frases de saudação |
| V10-07 | REV-097 a 106: tela, mensagens exatas e versões da Seleção da Rodada | implementada (REV-118 bloqueada) | Migração 081 |
| V10-08 | REV-136: mínimo de 7 votos por jogador avaliado (era 3) | implementada | Migração 076; só votações publicadas daqui em diante |
| V10-09 | REV-138: servidor recusa publicar gol sem autor | implementada | Migração 083 |
| V10-10 | REV-142: selo PREMIUM em todas no beta; REV-141: 3 passos (2h/4h/6h); REV-126: títulos de temporada primeiro | implementada | — |
