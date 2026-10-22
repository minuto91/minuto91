# Minuto 91 — V3, Fase 6: retrospectiva da temporada (22/10/2026)

## O que foi feito

Nova tela **Retrospectiva da temporada** (`pelada/[id]/retrospectiva`), aberta pelo botão na tela da pelada.

- **A temporada da pelada**:
  - Partidas finalizadas, gols, maior placar e jogo com mais gols.
  - Artilharia, Garçons, Craque da Partida (mais vezes) e Mais presentes (top 3 de cada).
  - Reis do Mês, mês a mês.
  - Bola Murcha aparece só na tela, em tom neutro, e nunca vai para as artes (não é conquista).
- **Sua temporada**: jogos, gols, assistências, vitórias, empates, derrotas, vezes Craque da Partida e Rei do Mês, e o Card da temporada.
- **Dados**: tudo vem dos dados oficiais (partidas finalizadas, estatísticas da temporada, prêmios ativos). Partida anulada e prêmio revogado não entram. Sem dado, o item não aparece.
- **Casos especiais**:
  - Temporada em andamento: aparece como "parcial".
  - Sem partidas finalizadas: mensagem própria.
  - Menos de 3 partidas: aviso de poucos dados.
  - Quem não jogou na temporada: aviso, sem números inventados.

## Artes (9:16 e 4:5)

| Arte | Quem | Plano |
|---|---|---|
| Retrospectiva da pelada: partidas, gols, gols por jogo, artilheiro, mais vezes Craque, Reis do Mês, maior placar | Todo membro | Grátis |
| Minha temporada: foto, jogos, gols, assistências, V/E/D, selos de Craque da Partida e Rei do Mês | Só a própria pessoa | Grátis |
| Rankings da temporada (top 3 de artilharia, garçons, Craque da Partida, presença) | Todo membro | **Premium da pelada** (a versão especial) |

- **Acesso às temporadas**: igual aos rankings (RN-083). No grátis, a temporada atual e a anterior; no Premium da pelada, todas.
- **Estatísticas básicas**: nunca são bloqueadas.
- **Versão especial individual**: não foi criada (é um possível benefício do futuro Min91 Pro). Nenhuma cobrança nova.

## Arquivos

- `app/src/lib/retro.ts`: cálculo da retrospectiva, com 5 consultas por temporada.
- `app/src/app/pelada/[id]/retrospectiva.tsx`: tela.
- `app/src/lib/arts.tsx`: `RetroPeladaArt`, `RetroRankingsArt`, `RetroPlayerArt`.
- `app/src/app/pelada/[id]/index.tsx`: botão.
- `app/src/app/_layout.tsx`: título da tela.
- `docs/evidencias_v3/retro_*.jpg`.

## Testes

| Teste | Resultado |
|---|---|
| tsc e lint | Limpos |
| Navegador, Pelada Teste (temporada 2026, 1 partida) | Os números batem com a partida real (4 gols, Bot 4 artilheiro, Rafa Craque, Bot 1 Bola Murcha só na tela). As três artes nos dois formatos cabem |
| Temporada com muitas partidas | **Não testado** (o dev só tem 1 partida finalizada). Por segurança, o 4:5 mostra no máximo 3 destaques |
| Temporada encerrada e temporadas antigas (Premium) | **Não testado** (o dev só tem 2026) |
| Celular | **Não testado** |

## Observações

- Empates no top 3 aparecem em ordem qualquer, sem marcar empate (ex.: três jogadores com 1 jogo). Dá para tratar se você quiser.
- Com poucos dados, a arte dos Stories fica com bastante espaço em branco embaixo.
