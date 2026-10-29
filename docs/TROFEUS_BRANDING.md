# Troféus e branding oficiais

Fonte: prompt V8.1 §4–5 e Registro de 26/10/2026 §3–4. Estado real do código: auditoria de 28/10/2026.
**Nenhum arquivo oficial de arte (sete esculturas, logo) foi fornecido até agora.** Por regra, não foram substituídos
nem gerados: nada de emoji, CSS, SVG novo ou IA no lugar deles.

## 1. Sete categorias

| Troféu | Representação obrigatória | Tipo de prêmio no banco | Na Sala hoje (`app/src/lib/trophies.tsx`) | Arquivo oficial |
|---|---|---|---|---|
| Craque da Partida | Jogador dourado em ação, estrela, detalhes azuis/dourados, base da coleção | `match_craque` | Sim — desenho SVG da V4.4 (bola dourada), **não** o jogador | pendente |
| Artilheiro da Temporada | Chuteira dourada **com bola**, composição mais imponente | `season_top_scorer` (V8.7, 068) | Contador na Sala, desenho SVG **provisório** (chuteira dourada + bola dourada sobre o pedestal, selo TEMP) | pendente |
| Artilheiro do Mês | Chuteira dourada **sem bola** | `top_scorer` | Sim — SVG, sem pedestal (REV-001) | pendente |
| Rei do Mês | Coroa dourada com pedras azuis | `monthly_king` | Sim — SVG | pendente |
| Garçom do Mês | Mão dourada saindo **do centro da base**, bandeja e bola; sem deslocamento lateral | `monthly_garcom` | Sim — SVG (mão com bandeja e bola) | pendente |
| Seleção da Rodada | Escudo azul/dourado, jogadores, louros | `round_selections` (não é `awards`) | **Não aparece na Sala** | pendente |
| Bola Murcha | Bola desinflada, discreta e bem-humorada; **privada por padrão** | `bola_murcha` | Sim — SVG; privacidade herdada (029/030) | pendente |

## 2. Fora do catálogo

Maior Evolução (adiado; o tipo `most_improved` ainda existe na restrição do banco desde a 049 e **não foi tocado**),
Garçom da Partida (excluído na V7.7 — `docs/v77/DECISOES_CONSOLIDADAS.md` A3), Garçom da Rodada como troféu histórico
(continua só como destaque temporário), luva de goleiro (arte de exploração, **não aprovada**), Etapa 46.

## 3. Conflito aberto

Pedestal do **Artilheiro do Mês**: V8.0 (REV-001) = "sem pedestal"; arte posterior da conversa de 26/10 = chuteira sem bola
**sobre base**. A retirada da bola está aprovada; o pedestal depende de conferir a referência final. Não alterado.

## 4. Logo e paleta

- Logo: ícone quadrado de cantos arredondados, azul degradê, monograma branco "91", faixa diagonal dourada, apóstrofo dourado.
  **Só o arquivo original**. Não redesenhar, aproximar, recriar por CSS/SVG/IA, trocar por texto nem distorcer.
- Estado: arquivo original **não fornecido**. `app/assets/images/icon.png` (ícone atual do app) **não foi validado** como a logo oficial.
- Paleta/tokens do app: `app/src/lib/theme.ts` (`colors.blue`, `deepBlue`, `gold`, `darkGold`). Dourados internos de `trophies.tsx`: `#F3D98B`, `#A97C1F`.
- Direção: branco predominante; azul institucional; dourado de prestígio. Evitar tema escuro como identidade, verde institucional, degradês/sombras excessivos.
- Aplicar logo em: Sala de Troféus, Minha Carreira, conquistas, rankings, compartilhamentos, bloqueado/desbloqueado, navegação relacionada — **após** receber o arquivo.

## 5. Critérios de validação de assets (quando chegarem)

PNG/WebP com transparência real (sem fundo preto), sem cortes, proporção única entre as sete, resolução ≥ 3× do tamanho exibido (a Sala usa 72 pt; compartilhamento 150 pt; Story 1080×1920 / Feed 1080×1350), peso por arquivo baixo, versão bloqueada em escala de cinza (hoje é só opacidade 0,35), conferência em tela pequena e em Story/Feed 1:1 e 9:16.

## 6. V8.7: três identidades de temporada (C01) — arte provisória

| Prêmio | Representação (C01) | Tipo no banco | No app hoje (`trophies.tsx`) | Arquivo oficial |
|---|---|---|---|---|
| Artilheiro da Temporada | Chuteira dourada com a bola previamente aprovada | `season_top_scorer` | `SeasonBoot` (kind scorer): reaproveita `GoldenBoot` e a bola dourada, pedestal azul/dourado, selo TEMP | pendente |
| Maestro da Temporada | Chuteira com efeito de passe | `season_maestro` | `SeasonBoot` (kind maestro): arco tracejado até a bola | pendente |
| Luva de Ouro | Luvas douradas | `season_golden_glove` | `GoldenGloves`: luvas douradas com punho azul | pendente |

Nenhum arquivo oficial existe no repositório; os desenhos acima são provisórios e **não** foram apresentados como oficiais. Substituir pelos arquivos quando chegarem, validados pelos critérios do §5. A V8.7 supera a restrição RST-04 (luva "não é categoria") apenas neste ponto. "Chuteira de Ouro" é só a referência da arte do Artilheiro da Temporada, nunca nome de prêmio.
