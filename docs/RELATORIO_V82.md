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
- Visual: web em 390×844 (mesma proporção da referência). Conferido a olho contra a referência: título, slogan, jogador, 91, campos, botões, divisor, Google e termos visíveis sem corte.
- **Não executado:** login/cadastro/recuperação/Google contra o Supabase, aparelho iOS/Android reais, teclado nativo, outras resoluções, sobreposição pixel a pixel.

## Diferenças remanescentes
- Fonte Inter (a do app) no lugar da fonte da referência; título um pouco maior que 55–60% da largura.
- Formulário começa um pouco mais acima que na referência (~52% × 54%) para caber o texto legal sem rolagem em 844 px.
- Sem hint de erro por campo; a mensagem aparece acima do botão Entrar.

## Matriz
| Requisito | Situação |
|---|---|
| Fundo original, jogador e 91 preservados | feito |
| Nome, slogan, campos, botões, divisor, Google, termos | feito (visual conferido na web) |
| Fluxos de autenticação | preservados no código; **não testados em execução** |
| Teclado / múltiplos aparelhos | **pendente** |
