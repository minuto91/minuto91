# Minuto 91 — V3, Fase 5: artes para compartilhar (22/10/2026)

## O que foi feito

- **Dois formatos em todas as artes**: Stories 9:16 (1080 × 1920) e post 4:5 (1080 × 1350). A pessoa escolhe no painel, antes de compartilhar. Cada arte se ajusta ao 4:5 (escudo menor, foto ao lado do nome, menos linhas).
- **Arte da partida** (`ResultArt`):
  - Antes só existia para quem via as notas. Agora todo membro pode gerar, desde que a partida esteja **finalizada** (nada provisório).
  - Mostra: escudo, nome da pelada, data, placar, times, quantos jogaram, total de gols, Craque da Partida (só quando apurado oficialmente), autores dos gols e Garçom.
  - As notas aparecem só para quem pode vê-las (o banco não as entrega a quem não votou): top 3 nos Stories, e nenhuma no 4:5.
- **Arte pós-jogo individual** (`PostGameArt`), diferente do Card:
  - Mostra o desempenho naquela partida: foto, nome, pelada, data, resultado do ponto de vista do jogador (vitória, empate ou derrota), placar, gols, assistências e nota oficial (só se existir e for visível para ele). Selo "Craque da Partida" quando for o caso.
  - Zero gols ou zero assistências aparecem como 0, o número oficial.
  - Só a própria pessoa gera a sua, e só se jogou a partida.
- **Aviso de privacidade** no painel: ao compartilhar, a imagem sai do app e pode continuar acessível fora dele.
- **Nada é publicado sozinho**: o app só abre o compartilhamento do sistema quando a pessoa toca.

## Arquivos

- `app/src/lib/arts.tsx`: formatos, contexto `useArtFormat`, arte da partida, pós-jogo, ajustes do 4:5 na Seleção, no Card e na figurinha.
- `app/src/lib/share.ts`: tamanho da imagem por formato.
- `app/src/app/partida/[id]/index.tsx`: monta as duas artes; busca a própria foto.
- `docs/evidencias_v3/`: `pos_jogo_stories_9x16.jpg`, `pos_jogo_post_4x5.png`, `partida_stories_9x16.jpg`, `partida_post_4x5.png`.

## Testes

| Teste | Resultado |
|---|---|
| tsc e lint | Limpos |
| Navegador, partida real da Pelada Teste (2 × 2, Craque Rafa) | Pós-jogo e arte da partida conferidos nos dois formatos. Corrigido: o 4:5 do pós-jogo e os Stories da partida passavam do limite (logo cortado) |
| Exportação da imagem em 1080 × 1350 | **Não testada de ponta a ponta**: na web o botão baixaria um arquivo. A captura usa o mesmo caminho já testado em 1080 × 1920 |
| Seleção da Rodada no 4:5 | **Não vista**: a partida de teste não tem Seleção (poucos jogadores) |
| Celular (Expo Go) | **Não testado** |

## Pendências

- Testar no iPhone: compartilhar no WhatsApp e no Instagram (Stories e post).
- Seleção da Rodada no 4:5, quando houver uma partida com Seleção.
