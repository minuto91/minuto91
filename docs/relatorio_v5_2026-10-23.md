# Minuto 91 — V5: motor de OVR e votação pós-partida (Prompt Master v2.0)

23/10/2026. Diagnóstico e plano: `docs/v5_fase_a_b_diagnostico_2026-10-23.md` (C1–C5 e D1–D8 aprovados pelo fundador).
**Nada foi aplicado no Supabase dev nem em produção.** As migrações 050–052 rodaram só no banco local (PGlite e
PostgreSQL 17 embutido).

## 1. O que mudou para o jogador e o admin

- **Súmula publicada = partida oficial na hora.** A votação deixa de abrir sozinha.
- **Votação nova (admin abre, 6 h):** um jogador por vez, com foto, nome, posição, time, gols e assistências.
  O controle vai de 0 a 10, de meio em meio ponto, e começa em 7,0. O 7,0 só vale depois de confirmar.
  Há "Confirmar e próximo", "Pular jogador", progresso e tempo restante. O pulado volta uma vez; depois fica na revisão.
  Cada nota é salva na hora no servidor; sem confirmação, nada avança. Craque e Bola Murcha continuam opcionais no fim.
- **Admin:** abre, prorroga (+30 min, +1 h ou +2 h, antes do fim), acompanha só por números (quem votou, cobertura,
  válidos e insuficientes) e publica com confirmação. Ninguém vê quem deu qual nota.
- **Nota da partida** = 50% média dos companheiros + 50% média dos adversários. Precisa de pelo menos uma nota de cada grupo.
  Sem isso aparece "Avaliação insuficiente".
- **Carta:** OVR de 0 a 99 com ATU, EST, PEQ, RES e DIS. Faixas: bronze < 65 ≤ prata < 80 ≤ ouro.
  Com menos de 5 partidas oficiais, a carta mostra "Em avaliação", sem número.
- **Central:** a pendência mostra o progresso ("avaliou X de Y") e o tempo que falta, com o botão Avaliar ou Continuar.
- **Súmula:** ganhou amarelo e 2º amarelo. O 2º amarelo conta como uma única penalidade de vermelho.
  O admin liga ou desliga o "registro de cartões"; desligado, a Disciplina fica em 70 para todos.
  Na partida oficial, o admin lança as defesas difíceis do goleiro; sem registro, não vira zero.
- **Posição:** o jogador escolhe livremente até a 1ª partida oficial. Depois disso, ele pede e o admin aprova.
  Durante as 5 partidas seguintes à troca, o EST migra aos poucos para a posição nova.

## 2. Arquivos

Criados: `supabase/migrations/050_v5_rating_data.sql`, `051_v5_rating_engine.sql`, `052_v5_rating_votes.sql`,
`supabase/tests_editor/042_v5_rating_votes.sql`, `supabase/local_db/rating/engine.mjs` (motor de referência),
`rating/simulate.mjs`, `rating_engine.test.mjs`, `rating_sql.test.mjs`, `rating_concurrency.mjs`,
`app/src/lib/ratingvote.tsx`, `app/src/lib/ratingadmin.tsx`, `app/src/app/dev-v5.tsx`, `docs/v5_simulacao_resultados.json`,
`docs/evidencias_v5/*`.
Modificados (app): `partida/[id]/votar.tsx` (novo fluxo; o antigo virou `lib/legacyvote.tsx` para votações abertas
antes da V5), `partida/[id]/index.tsx`, `partida/[id]/sumula.tsx`, `(tabs)/index.tsx`, `(tabs)/carreira.tsx`,
`jogador/[id]/index.tsx`, `pelada/[id]/index.tsx`, `pelada/[id]/elenco.tsx`, `guia-cards.tsx`, `_layout.tsx`,
`lib/career.ts`, `lib/playercard.tsx`, `lib/evolution.tsx`, `lib/match.ts`, `lib/profile.tsx`, `lib/retro.ts`, `lib/dates.ts`,
`lib/errors.ts`.
Testes antigos 013 e 027 ajustados ao OVR v2 (sem número antes de 5 partidas). Testes antigos 006, 007, 008, 009, 010, 014, 015 e 030: religam o fluxo antigo só durante o teste (e o 010, a carta v1).
Assim continuam cobrindo a cédula antiga, que ainda vale para sessões abertas antes da 052.
`local_db/concurrency.mjs`: a disputa correção × último voto roda até a 051.

## 3. Motor (resumo técnico)

Funções puras em SQL (`private.rating_*`), com parâmetros em `private.rating_params` (versão 1, formula_version 2).
`private.rating_compute(membro)` usa as últimas 20 partidas oficiais disputadas na pelada (RES: últimas 20 rodadas
desde a entrada). O cálculo acontece no servidor a cada partida oficial, publicação, correção, anulação, troca de posição,
mudança de cartões e lançamento de defesas, para todos os membros da pelada (RES e referências mudam para todos).
`public.player_ratings` guarda o valor atual. `public.player_rating_history` guarda um registro por evento,
marcado como "original" ou "recalculated". Reprocessar não duplica.
Partidas antigas entram no ATU só pela parte dos votos (peer_rating), nunca pela nota mista antiga.

## 4. Testes executados (com saída em `docs/evidencias_v5/`)

| Bateria | Resultado |
|---|---|
| `node run.mjs` — 42 testes SQL (41 antigos + 042 da V5) | 42 de 42 passaram |
| `node --test` — motor (13), SQL × JS em 300 casos aleatórios, push/financeiro/paginação antigos | 43 de 43 passaram |
| `node rating_concurrency.mjs 8` — Postgres 17 real | 8/8 sem problemas: envio duplo, notas simultâneas, voto × prorrogação, rajada no prazo (nenhum voto gravado depois do prazo), publicação dupla, reprocessamento |
| `npx tsc --noEmit` e `npx expo lint` | sem erros |
| Vitrine `/dev-v5` no navegador | cartas nas 3 faixas, "em avaliação" e controle de nota (clique 2,5, arrastar 10,0, + passo 0,5), também em 375 px |

O teste 042 cobre os itens 1–34 da lista 23.4 que dependem do banco. Ficam de fora a falha de rede, simulada só no app
(o servidor é idempotente), e a regressão visual completa das telas com dados reais, que depende do dev.

## 5. Simulação (DADOS SINTÉTICOS, `node rating/simulate.mjs 1000 30`)

1.000 peladas, 32.314 jogadores, 29.990 partidas, 32.275 com OVR. Tudo em `docs/v5_simulacao_resultados.json`.

- **OVR mediano por posição:** GOL 68, ZAG 69, LAT 69, VOL 69, MEI 68, ATA 68, PON 67. P5–P95 fica em 58–81 em todas.
  Nada foi ajustado para igualar as posições.
- **Frequência:** acima de 80, 5%; acima de 85, 1%; acima de 90, menos de 0,5%; acima de 95, nenhum.
- **Componentes (mediana):** ATU 66, EST 70, PEQ 68,5, RES 70, DIS 70.
- **Cartões** (peladas com registro ligado): DIS mediano 88,9 sem cartão, 83,2 com 1 e 72,9 com 2 ou mais.
  Peso máximo no OVR: 2,45 pontos.
- **Ausências:** presença abaixo de 60% leva a RES 53 e OVR 67; presença de 90–100% leva a RES 91 e OVR 71.
- **Histórico curto:** a diferença entre o OVR na 5ª partida e no fim tem mediana −0,2, com P5 de −5,8 e P95 de +6,2.
- **Votação:** 99% de jogador-partida com nota válida (participação simulada de 60% dos eleitores).
  O erro médio da nota cai de 0,55 (1 voto no menor grupo) para 0,27 (8 ou mais).
- **Sensibilidade:** variar alfa, estabilização do REF, μC e referências ±20% move as medianas no máximo ±1 ponto.

**Distorções encontradas (investigadas, não corrigidas):**
1. Goleiros excepcionais (top 2%) ficam em 79, contra 82–84 nas outras posições. A causa é o REF: com 2–3 defesas
   difíceis por jogo, ele fica perto de 72–75, e a curva só passa de 80 com mais de 5 defesas por partida.
   O resultado depende de quantas defesas o admin lança na prática.
2. Em peladas com registro de cartões, quem não leva cartão chega a DIS 85–90, contra 70 fixo nas sem registro:
   até cerca de 1 ponto de OVR de diferença entre peladas. É o efeito da regra aprovada (9.2).
3. PEQ: empate rende 1/3 dos pontos, então só empates puxam o PEQ abaixo de 70 (fórmula aprovada).

## 6. Decisões técnicas tomadas sozinho

- Com o registro de cartões ligado, a súmula publicada confirma a disciplina. O admin pode marcar a partida como pendente.
- O 2º amarelo é lançado sozinho (sem os amarelos) e vale um vermelho. Amarelo: no máximo 1 por jogo.
- Correção da súmula depois de oficial: só com a votação v2 aberta ou aguardando publicação.
  Antes de abrir, o admin abre e corrige.
- O Craque e a Bola Murcha da votação nova exigem 3 ou mais escolhas, herdando o mínimo da regra antiga.
- A prorrogação aceita de 15 min a 12 h. O app oferece +30 min, +1 h e +2 h.
- A ordem por eleitor é um hash fixo da sessão, do eleitor e do avaliado.
  Ela mistura companheiros e adversários e é diferente para cada eleitor.
- O OVR calculado interno (antes de 5 partidas) existe em `player_cards.overall` para o sorteio equilibrar os times.
  O app não exibe; a coluna `ovr` de `player_ratings` não é legível pelo app.

## 7. Pendências e limitações

- **Aplicar 050–052 no Supabase dev e rodar o teste 042 no SQL Editor** (precisa da sua confirmação).
  Também é preciso ligar o agendador: `select cron.schedule('minuto91-rating-votes','*/5 * * * *','select private.rating_vote_tick()')`,
  que a migração faz sozinha quando o pg_cron está ativo.
- Testar no iPhone o fluxo completo com contas reais: abrir, votar, pular, revisar, publicar.
- Os parâmetros C2–C4 continuam experimentais. Validar com dados reais depois de algumas semanas (a versão 2 dos parâmetros
  entra em `private.rating_params` sem mexer no histórico).
- Docs do PRD (Doc 02/03/04) ainda descrevem a carta e a votação antigas: atualizar.
- O ranking "overall" de temporadas antigas continua com a carta v1. Cartas e históricos antigos não foram recalculados.
