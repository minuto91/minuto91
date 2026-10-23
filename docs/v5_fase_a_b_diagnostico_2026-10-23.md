# Minuto 91 — Prompt Master v2.0 (motor de OVR + votação) — Fases A, B e C

23/10/2026. Nada foi implementado ainda. Este documento é o diagnóstico, o plano e os pontos que precisam
da aprovação do fundador antes do motor definitivo.

## 1. Fase A — o que já existe (verificado no código)

| Item | Onde | Situação |
|---|---|---|
| Stack | `app/` Expo SDK 57 + TypeScript; Supabase (Postgres, RLS, RPC `security definer`, pg_cron a cada 5 min) | reaproveitar |
| Partidas | `public.matches` (draft → voting_open → finalizing → finalized / annulled), uma por registro, sem conceito de "rodada" | reaproveitar; rodada = partida oficial |
| Participantes | `match_participants` (time A/B, posição da época, membro **ou** convidado). Só entra na súmula quem jogou: não há "reserva que não entrou" | reaproveitar |
| Eventos | `match_events`: goal, assist, own_goal, red_card, unattributed_goal | **faltam** amarelo, defesas difíceis, "registro disciplinar confirmado" |
| Posições | 10 códigos (GOL, ZAG, LD, LE, VOL, MEI, CA, PD, PE, ATA) + setor; o **próprio jogador** muda a posição (`set_my_position`) | precisa mapear para as 6/7 do v2.0 e exigir admin |
| Votação | `voting_sessions` abre **automaticamente** ao publicar (2/4/6 h), cédula inteira enviada de uma vez (`secret_ballots`), encerra sozinha, válida se ≥50% e ≥3 votos, nota = mediana / média aparada, mistura nota objetiva (gols etc.), prêmios Craque e Bola Murcha | **conflita** em quase tudo com as Etapas 10–15 |
| Sigilo | cédulas no schema `private`, vínculo eleitor–cédula apagado na finalização, admin não lê autoria | bom; o v2.0 exige manter o vínculo até a publicação (correções), também no `private` |
| Cartas | `player_cards` **por temporada**, 0–100, atributos Finalização/Garçom/Presença/Pé Quente/Resenha, provisória < 5 jogos, faixas bronze < 60 ≤ prata < 80 ≤ ouro, `card_snapshots` por partida, `formula_version` | será substituído pelo OVR do v2.0 (ver decisão D1) |
| Cadeia pós-partida | `after_match_finalized` → stats/cartas → rankings/prêmios → Seleção → figurinhas | tudo que usa `final_rating` e `overall` é afetado |
| Notificações | `022` fila + push (`035`) + agendador | reaproveitar para abertura e lembretes |
| Fuso | `pelada_local_date`, servidor é a fonte do prazo | ok |
| Testes | `supabase/tests_editor` (SQL, "PASS" por erro proposital) | seguir o mesmo padrão |

Riscos: (1) trocar a nota da partida muda rankings, Seleção, recordes, sequências ≥ 8,0 e prêmios já
existentes; (2) cartas históricas não podem ser reescritas — o OVR novo começa como `formula_version 2`
e as cartas antigas ficam como estão; (3) migrações aplicadas não podem ser editadas: tudo entra em
050+; (4) Python não está instalado — a simulação de 1.000 peladas será feita em Node (TypeScript),
com o motor em funções puras idênticas às do SQL e testes cruzando os dois.

## 2. Fase B — plano

- **Motor puro** `app/src/lib/rating/` (TS) + mesmo motor em SQL (`private.rating_*`), parâmetros numa
  tabela versionada `private.rating_params(version, json)`; OVR calculado só no servidor.
- **Migração 050** dados novos: `yellow_card`, `second_yellow` (= um vermelho) e `hard_saves` em
  `match_events`; `pelada_settings.cards_tracking` (liga/desliga); `matches.discipline_confirmed`.
- **Migração 051** votação v2: estados `unavailable / ready / open / awaiting_publication / published`;
  `vote_sessions_v2`, `private.votes` (um voto ativo por partida+eleitor+avaliado, `unique`),
  `private.vote_sequences` (ordem fixa por eleitor), `vote_progress`, `vote_extensions`; RPCs
  `open_voting`, `cast_vote` (checa prazo e elegibilidade na mesma transação, `for update` na sessão),
  `skip_vote`, `extend_voting`, `get_voting_summary_admin` (só agregados), `publish_voting` (idempotente).
- **Migração 052** OVR: `player_ratings` (atual, por membro e pelada) e `player_rating_history`
  (ATU…DIS, OVR calculado e exibido, posição, versões, evento, original × recalculado).
- **App**: tela `partida/[id]/votar` refeita (um jogador por vez, controle 0–10 de 0,5, Confirmar e
  próximo, Pular, revisão), pendência na Central, painel do admin na Gestão da pelada, card novo.
- **Rollback**: cada migração com bloco `down` comentado; a v1 (cartas por temporada) fica intacta até
  o corte.
- **Testes**: unitários do motor (Node), SQL em `tests_editor/042+`, simulação em `docs/`.

## 3. Fase C — pontos bloqueantes (propostas para aprovar)

### C1. DEF
`DEF = 70 + 29·tanh(1,2·max(0, ln(μC/rC))) − 20·tanh(1,2·max(0, ln(rC/μC)))`.
rC = μC → 70; rC → 0 → tende a 99; rC muito alto → tende a 50. Sempre finita (rC > 0 porque μC > 0).
Monótona decrescente em rC. Com μC = 3,0: rC 1,5 → 89,8 · 2,5 → 76,2 · 3,5 → 66,3 · 6,0 → 56,4.

### C2. Referências iniciais (por partida)
| | ZAG | LAT | VOL | MEI | ATA/PON | GOL |
|---|---|---|---|---|---|---|
| μG gols | 0,10 | 0,15 | 0,20 | 0,40 | 0,70 | — |
| μA assist. | 0,10 | 0,20 | 0,25 | 0,40 | 0,30 | — |
| μC gols sofridos pelo time | 3,0 (todas) | | | | | |

Base: placares típicos de pelada 11×11 (~6 gols por jogo, ~3 por time). Pisos de 0,05 em μG/μA.

### C3. Confiança das referências locais
μ̂ = média aparada 10% por partida, **excluindo o próprio jogador**, nas últimas 40 partidas da pelada;
α = n / (n + 150), limitada a 0,5, onde n = jogador‑partidas daquela posição na janela. Referência
recalculada só ao publicar cada partida e gravada com a versão; cartas já publicadas não mudam.

### C4. Estabilização de REF
REF_médio = média ponderada (pesos 11…30) das partidas com registro;
`REF = 65 + (n/(n+3))·(REF_médio − 65)`, n = partidas com registro. 1 partida com 5 defesas → 68,75;
5 partidas → 74,4; 20 partidas → 78,0.

### C5. Transição de posição (5 partidas)
Só o EST muda: `EST = (k/5)·EST_nova + (1 − k/5)·EST_antiga`, k = partidas disputadas desde a troca
(0…5), ambas calculadas com a mesma janela de dados. ATU, PEQ, RES e DIS não mudam.

## 4. Decisões de produto que o v2.0 força (precisam de resposta)

- **D1 Cartas antigas**: o OVR novo (por pelada, 0–99, últimos 20 jogos, sem temporada) substitui a carta
  por temporada? Proposta: sim, a partir da versão 2; cartas de temporadas passadas ficam congeladas.
- **D2 Faixas**: com 70 neutro, todo mundo nasce "prata" nas faixas atuais. Proposta: bronze < 65,
  prata 65–79, ouro ≥ 80 (validar na simulação).
- **D3 Nota da partida**: hoje mistura votos + gols e vale para rankings/Seleção/prêmios. O v2.0 usa só
  votos (50/50). Proposta: a nota publicada passa a ser q (só votos) em tudo.
- **D4 Craque e Bola Murcha**: o fluxo novo não tem esses votos. Manter (tela extra no fim) ou remover?
- **D5 Validade**: hoje ≥ 50% e ≥ 3 votantes; o v2.0 pede ≥ 1 companheiro e ≥ 1 adversário por
  jogador. Proposta: seguir o v2.0 (a regra dos 6 eleitores mínimos também cai).
- **D6 Abertura**: hoje automática ao publicar a súmula; o v2.0 manda abrir manualmente (6 h). E a
  regra "correção reinicia a votação" deixa de existir (vira notificação aos afetados). Ok?
- **D7 Posição**: o jogador hoje troca sozinho; o v2.0 exige admin. Mapeamento proposto: LD/LE → LAT,
  CA → ATA, PD/PE → PON; setores antigos sem código: defender → ZAG, midfielder → MEI, attacker → ATA.
- **D8 Convidados e jogadores sem conta**: continuam sem votar e sem receber nota (sem conta não há
  eleitor). Ok?
