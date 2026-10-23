# Minuto 91 — Design System (V4.6)

Base: Brand Book v2.1 (cores, Inter como fonte única, logo 91’) e protótipos aprovados em 23/10/2026.
Código: `app/src/lib/theme.ts` (tokens), `app/src/lib/text.tsx` (Inter), `app/src/lib/ui.tsx` (componentes),
`app/src/lib/brand.tsx` (assinatura 91’). Vitrine sem login: `/dev-v46` (dados simulados).

## 1. Cores

| Token | Valor | Uso |
|---|---|---|
| `white` | `#FFFFFF` | fundo das telas |
| `blue` | `#1255C6` | ação principal, links, ícones ativos |
| `deepBlue` | `#103675` | títulos, números de destaque |
| `gold` | `#D4A63D` | detalhe de conquista (nunca texto sobre branco) |
| `darkGold` | `#8A6414` | texto de conquista, selo Premium |
| `ink` | `#15243B` | texto principal |
| `muted` | `#5E6E86` | legendas e metadados |
| `line` | `#D9E0EC` | bordas sutis |
| `bg` | `#F4F7FC` | superfícies secundárias, estado pressionado |
| `danger` | `#B42318` | erro e ação destrutiva |

Verde só no campo (Seleção da Rodada): gramado `#2F8A41` / `#349547`, linhas brancas.
Cores dos times (049): azul, branco, preto, vermelho, amarelo, laranja, roxo, rosa (`lib/selection.tsx`).

## 2. Tipografia (Inter)

`lib/text.tsx` troca `fontWeight` pela família Inter do peso (o Android não escolhe o peso sozinho). Todo o app
importa `Text`/`TextInput` daí. Escala em `theme.type`:

| Token | Tamanho / altura | Peso | Uso |
|---|---|---|---|
| `title` | 26 / 32 | 700 | título da tela |
| `section` | 19 / 25 | 700 | título de seção |
| `cardTitle` | 17 / 23 | 600 | título de cartão |
| `body` | 16 / 23 | 400 | texto principal |
| `bodySm` | 15 / 21 | 400 | texto em listas |
| `caption` | 14 / 20 | 400 | legendas |
| `meta` | 13 / 18 | 500 | metadados |
| `number` | 32 / 38 | 800 | números destacados (tabulares) |

Sem textos inteiros em maiúsculas na interface (siglas como FIN, GOL e o selo do pedestal são exceção).

## 3. Forma e espaço

- Raios (`theme.radius`): 8 pequeno · 12 campos e botões · 14 cartões · 20 folhas · 22 chips.
- Espaçamento (`theme.space`): 4, 8, 12, 16, 20, 28.
- Sombra moderada (`theme.shadow.card`): opacidade 0,07, raio 10, elevação 2.
- Área de toque mínima: 44 px (chips, ícones); botões 48 px.

## 4. Componentes (`lib/ui.tsx`)

| Componente | Notas |
|---|---|
| `Button` | `primary` (azul cheio), `secondary` (contorno azul), `ghost` (discreto, só texto), `danger` (contorno vermelho); estado carregando e desabilitado lidos pelo leitor de tela |
| `Card` | branco, borda sutil, raio 14, sombra moderada |
| `Title`, `Section`, `Body`, `Sub` | escala acima; títulos com papel de cabeçalho |
| `Input` | 48 px, raio 12 |
| `Chips` | seletor/abas de escolha única, 44 px |
| `Stepper` | contador acessível (ajustável por gesto) |
| `EmptyState` | título, dica e próximo passo |
| `Loading` | indicador + texto, região viva |
| `ErrorText` | vermelho, papel de alerta |
| `dialog.ts` | confirmações (celular e web) |

Componentes esportivos: `PlayerCard` (Card bronze/prata/ouro, rodapé com o ano), `TrophyArt`/`TrophyRoom`
(cinco troféus), `StickerTile` (9 ilustrações × 6 acabamentos), `SelectionField` (campo verde, fotos e cores
dos times), `TeamColorPicker`, `BrandSymbol`/`BrandSignature` (91’ provisório).

## 5. Navegação

Quatro abas (`app/(tabs)`): Início (Central do Jogador), Peladas, Carreira, Perfil. Tudo o que é de dentro
(pelada, partida, Card, álbum, financeiro) abre por cima, na pilha principal. Página da pelada em três grupos:
Jogo, Desempenho, Gestão (só com permissão).
