# Central do Jogador 2.0 — relatório (24/10/2026)

## 1. Diagnóstico inicial
- Tela: `app/src/app/(tabs)/index.tsx` (aba Início). Quatro abas já existiam (`(tabs)/_layout.tsx`).
- Dados: `get_player_central` (peladas, votações antigas, posições, próxima rodada, último jogo **de todas as peladas**, horário do servidor), `get_my_pending_rating_votes` (votações V5 com progresso), `get_player_career_summary` (cartas e números por temporada).
- OVR V5: `get_player_rating` (OVR exibido, elegível, partidas) e `player_rating_history` (histórico oficial, mesma regra de acesso das cartas).
- Nota da partida: `match_player_results` (só existe com votação publicada; `has_valid_rating=false` = insuficiente).
- Problemas da tela antiga: não havia contexto de pelada (último jogo e carta podiam ser de peladas diferentes), sem variação do OVR, sem urgência de votação, blocos com o mesmo peso visual.
- **Limitação do produto:** o app não tem data, horário, local nem confirmação de presença de rodada. A "Próxima rodada" usa a escalação planejada existente (rótulo, times, seu time) com a ação "Ver rodada". Não inventei confirmação de presença.

## 2. O que mudou
- Cabeçalho próprio: foto/iniciais, saudação, "Central do Jogador", sino (abre Minha conta, onde ficam os avisos). Cabeçalho das abas oculto só no Início, com área segura.
- Seletor de pelada (chips; com uma pelada vira só o rótulo). Última escolha guardada no aparelho por conta. Tudo abaixo filtra pela pelada escolhida.
- Votação urgente (≤ 1 h pelo relógio do servidor) acima da carta, com tempo, progresso e "Continuar votação". Reavalia ao entrar na última hora e no fim do prazo (e recarrega, pegando prorrogações).
- Card compacto: carta oficial em miniatura (nova opção `mini` no `PlayerCard`, só oculta a linha de atributos; moldura e categorias intactas), OVR, variação (▲/▼/= + sinal, não só cor), jogos, gols, assistências, Minha Carreira. Menos de 5 partidas: "Avaliação em andamento", barra X de 5, sem número.
- Pendências compactas (votações não urgentes, convite, votação em outra pelada → troca a pelada, rascunhos para admin, posição, foto), "Ver todas" acima de 3.
- Último jogo da pelada: placar, resultado, gols, assistências, nota publicada / "Aguardando publicação" / "Avaliação insuficiente" / "Você não jogou esta partida".
- Resumo da carreira na pelada (jogos, % vitórias, gols e assistências, prêmios sem Bola Murcha) com link ao histórico.
- Carregamento com placeholders por bloco; erro de um bloco não derruba a tela.

Fórmulas, votação, critérios de cartas e banco: **sem alteração** (nenhuma migração nova).

## 3. Arquivos
- Novo: `app/src/lib/central.tsx` (componentes e leituras por pelada), `app/src/lib/centrallogic.ts` (regras puras), `app/tests/central.test.ts`, `app/src/app/dev-central.tsx` (vitrine com dados simulados), `docs/evidencias_central2/`.
- Alterados: `app/src/app/(tabs)/index.tsx`, `app/src/app/(tabs)/_layout.tsx`, `app/src/lib/playercard.tsx` (prop `mini`), `app/src/app/_layout.tsx` (libera `/dev-central` só em desenvolvimento), `app/tsconfig.json` (exclui `tests/` do tsc do app).

## 4. Testes (executados)
- `npx tsc --noEmit`: OK. `npx expo lint`: OK.
- `node --experimental-strip-types --test tests/central.test.ts`: 18 de 18 passaram (urgente/não urgente, prorrogação, encerrada, relógio do servidor, variação +/−/0/sem histórico, nota publicada/pendente/insuficiente/não jogou, seleção e isolamento por pelada).
- Visual (web, Chromium, 390 e 320 px, dados simulados): 14 capturas em `docs/evidencias_central2/`, sem rolagem horizontal.

**Não validado em ambiente real:** a tela com dados do Supabase dev, iPhone/Android, leitor de tela e navegação entre as quatro abas no aparelho. Não tive acesso ao banco nem a um login.

## 5. Como conferir
`cd $HOME\Documents\minuto91\app; npx expo start --go --tunnel -c` → Início (com login). Vitrine: `http://localhost:8081/dev-central?s=urgente` (estados: ovr-up, ovr-down, ovr-neutro, avaliacao, sem-carta, urgente, insuficiente, nao-jogou, uma-pelada, sem-pelada).

## 6. Pendências técnicas
- Data/horário/local e confirmação de presença não existem no produto (decisão de produto necessária para a "Próxima rodada" completa).
- O último jogo é lido com 3 etapas de consultas (partida → participação/nota → eventos); dá para virar uma RPC no servidor depois.
- A variação compara com o fim da partida anterior; recálculos sem partida não contam como "publicação".
- Pelada principal (servidor) continua sendo a padrão; a escolha na Central fica só no aparelho.
