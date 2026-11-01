# Arquivos de arte para o app (logo) — onde colocar e quais tamanhos

Hoje os arquivos abaixo são os do **template do Expo** (não são a logo do Minuto 91). Para trocar, **substitua o arquivo
mantendo o mesmo nome e caminho**; o `app.json` já aponta para eles. Cores já configuradas: splash `#FFFFFF`, fundo do
ícone adaptativo do Android `#1255C6` (Brand Book v2.1).

| Arquivo (em `app/assets/images/`) | Tamanho exato | Formato | Regras |
|---|---|---|---|
| `icon.png` | **1024 × 1024 px** | PNG, **sem transparência**, sem cantos arredondados | Ícone do iOS e da loja. A Apple/Google arredondam sozinhas. Sem texto pequeno. |
| `android-icon-foreground.png` | **1024 × 1024 px** | PNG com transparência | Só a logo (monograma "91"), **centralizada dentro de um círculo de ~680 px** (zona segura de 66%); o resto é cortado em alguns aparelhos. O fundo azul `#1255C6` vem do app.json. |
| `android-icon-monochrome.png` | **1024 × 1024 px** | PNG transparente, **uma cor só** (silhueta) | Ícone temático do Android 13+. Mesma zona segura. |
| `splash-icon.png` | **1024 × 1024 px** | PNG com transparência | Logo centralizada ocupando ~60% da tela do arquivo. Aparece com 200 pt de largura sobre fundo branco. |
| `favicon.png` | **48 × 48 px** | PNG | Só usado na versão web (não faz parte do beta). |

Opcional (recomendado), ainda **não** configurado porque o arquivo não existe:
- `notification-icon.png` — **96 × 96 px**, PNG transparente, **silhueta toda branca**. Ícone da barra de status do
  Android nas notificações. Para ativar: adicionar `"icon": "./assets/images/notification-icon.png"` ao plugin
  `expo-notifications` no `app.json`. Sem ele o Android usa o ícone do app, que pode aparecer como um quadrado cinza.

iOS: foi removido o `ios.icon` (pacote `expo.icon`, que também era do template). O iOS passa a usar `icon.png`. Se quiser o
visual "Liquid Glass" do iOS 26, é preciso montar um `.icon` no Icon Composer (Xcode) e reapontar `ios.icon`.

Lojas (não vão no app): ícone da loja 1024 × 1024 (Apple e Google), gráfico de recursos do Google Play 1024 × 500 px,
capturas de tela (ver `docs/CHECKLIST_LANCAMENTO.md`).
