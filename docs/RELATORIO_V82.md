# V8.2 — Tela de login (28/10/2026)

**Escopo:** só a tela de autenticação. Sucede a V8.1 apenas aqui; branding global (branco/azul/dourado) inalterado.
**Exceção visual V8.2:** a tela de entrada é escura, cinematográfica, azul-marinho e dourada.

## Referências
- Layout aprovado (com textos): `docs/login_v82_referencia.jpg` (709×1536).
- Fundo oficial (foto limpa, sem edição): `app/assets/login/fundo-login.jpg`.

## Arquivos
- `app/src/lib/loginui.tsx` (novo): fundo + gradiente sobreposto (react-native-svg), título, campos, botões, divisor, logo do Google colorida.
- `app/src/app/login.tsx`: só o visual foi trocado; Supabase `signInWithPassword`, `signUp`, `resetPasswordForEmail`, Google (OAuth + `setSession`), Apple, redirecionamentos e links `/termos` e `/privacidade` mantidos.
- `app/assets/login/fundo-login.jpg`, `docs/login_v82_referencia.jpg`.

## Alterações
- Fundo `cover`, ancorado ao topo, com gradiente: topo azul-marinho, centro (jogador) quase limpo, parte inferior até `#020813`.
- Entrar dourado (gradiente `#FFE184→#F4C85B→#D79A32`) com seta; Criar conta contorno dourado; Google escuro com logo colorida; campos translúcidos com borda que fica dourada no foco; mostrar/ocultar senha funcional.
- Validação no cliente (e-mail inválido, senha < 6) antes de chamar o servidor; botões desativados enquanto outra ação roda (evita envio duplicado).
- Safe areas, rolagem e `automaticallyAdjustKeyboardInsets` para o teclado.

## Preservado
Provedor, sessão, regras de acesso, cadastro, recuperação, Google, termos, banco e demais módulos: nenhuma linha fora da tela de login alterada.

## Testes
- `tsc --noEmit` 0 erros; `npm test` 29/29; lint: só o erro antigo de `lib/push.tsx:47`.
- **Executados na web (Metro, Supabase dev), 28/10/2026:**
  - Campos vazios → "Digite um e-mail válido."; senha de 3 caracteres → "A senha precisa ter 6 ou mais caracteres."
  - E-mail inexistente + senha de 6 caracteres → chamada real ao Supabase → "E-mail ou senha incorretos."
  - Mostrar/ocultar senha (input password ↔ text); modo "Esqueci minha senha" abre com "Enviar link"/"Voltar para entrar"; "Termos de Uso" navega para `/termos`.
  - Viewports 390×844, 375×667, 320×568, 412×915: sem sobreposição nem corte; em 667 e 568 de altura o formulário cobre parte do número 91 (a tela rola quando precisa).
- **Bug encontrado e corrigido nos testes:** a validação de e-mail que acrescentei perdeu as barras invertidas da regex e rejeitava qualquer e-mail (bloquearia todo login e cadastro). Corrigido. Também corrigidos: ícone do cadeado encolhido e olho da senha empurrado para fora em 320 px.
- **NÃO executados (sem evidência):** login com conta válida; cadastro (criaria conta real); envio do link de recuperação (dispararia e-mail real); Google OAuth e Apple; aparelho iOS/Android real; comportamento do teclado nativo; sobreposição pixel a pixel com a referência; redirecionamento pós-login.

## Matriz
| Requisito | Situação |
|---|---|
| Fundo original, jogador e 91 preservados | feito |
| Nome, slogan, campos, botões, divisor, Google, termos | feito (visual conferido na web) |
| Validação, erro de credencial, olho da senha, recuperação (abertura), Termos | testados na web |
| Login válido, cadastro, link de recuperação, Google, pós-login | **não testados** — exigem conta/serviços reais |
| Teclado nativo e aparelhos reais | **pendente** (só web emulada em 4 tamanhos) |

## Encerramento (28/10/2026)
V8.2 **encerrada por decisão do fundador, com pendências registradas**: login válido e pós-login, cadastro, link de recuperação, Google/Apple, aparelho real, teclado nativo e sobreposição pixel a pixel com a referência. Devem ser conferidos no iPhone; desvios achados lá viram ajuste de visual, sem mudar os fluxos.
