# Minuto 91 — Design System V6.0

Evolução do Design System V4.6 (`docs/v46_design_system.md`), sem mudar a identidade: branco predominante,
azul principal, dourado de destaque, cinza claro de superfície e grafite no texto. Inter continua a fonte única.

## 1. Tokens (`app/src/lib/theme.ts`)

| Grupo | Novo na V6.0 | Uso |
|---|---|---|
| Cores | `divider #EEF2F8` | separador interno de listas (antes literal em várias telas) |
| | `blueSoft #EAF1FD` | fundo de destaque informativo (ex.: "Falta o seu voto") |
| | `goldSoft #FBF4E2` | fundo de conquista (1º do ranking) |
| | `success/successSoft`, `warning/warningSoft`, `dangerSoft` | selos e avisos |
| Tipografia | `display` 40/46 800 tabular | placar grande da partida e da pelada |
| | `numberSm` 20/24 800 tabular | números esportivos em linha |
| | `label` 12/16 600 | rótulo curto abaixo de números |
| Espaço | `space.xxxl = 40` | respiro no fim das telas roláveis |
| Toque | `touch.min = 44`, `touch.button = 48` | áreas mínimas |

## 2. Componentes novos (`app/src/lib/ui.tsx`)

| Componente | Substitui | Observação |
|---|---|---|
| `Badge` | textos coloridos soltos | sempre com texto e ponto: nunca só cor |
| `MatchStatusBadge` | `STATUS_LABEL` colorido à mão | só apresentação |
| `SectionHeader` | títulos + "Ver todas" avulsos | ação à direita com 44 px |
| `ListItem` / `ListGroup` | `Group`/`Row` locais da pelada, grade de atalhos do Financeiro, botões empilhados do Perfil | uma moldura por grupo, divisores finos, sem cartão dentro de cartão |
| `Scoreboard` | placar local da pelada e placares em texto corrido | vencedor em negrito, cor do time opcional |
| `StatItem` / `StatRow` | `Stat` duplicados | disponível para as próximas telas |
| `Notice` | avisos em texto solto | sucesso só após resposta do servidor |
| `ErrorState` | `ErrorText` + botão solto | erro de rede nunca vira "sem dados" |
| `NoPermission`, `Skeleton`, `Divider` | — | estados padronizados |

`Screen` ajusta a área rolável ao teclado (iOS) e tem respiro inferior.

## 3. Estados de partida (apresentação)

| Status do servidor | Selo | Tom |
|---|---|---|
| `draft` | Em preparação | neutro |
| `voting_open` | Votação aberta | azul |
| `finalizing` | Aguardando publicação | alerta |
| `finalized` | Resultado publicado | sucesso |
| `annulled` | Anulada | erro |

As transições continuam exclusivamente no servidor.
