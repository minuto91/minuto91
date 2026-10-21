# Roteiro de teste no iPhone (development build)

Marque cada item. Se algo falhar, anote o passo e a mensagem exata da tela.

## 0. Antes de começar
- [ ] Supabase > Authentication > URL Configuration > Redirect URLs contém `minuto91://**` e `exp://**`.
- [ ] Supabase > Authentication > Providers: Google ativo (Client ID/Secret do Google Cloud).
- [ ] Supabase > Authentication > Providers: Apple ativo, com `com.minuto91.app` em "Client IDs".
- [ ] No PC: `cd $HOME\Documents\minuto91\app; npx expo start --dev-client -c` e abra o app Minuto 91 no iPhone (mesmo Wi-Fi).
- [ ] Tenha 3 e-mails de teste (ex.: voce+a@gmail.com, voce+b@gmail.com, voce+c@gmail.com). Chamaremos de A, B e C.

## 1. Cadastro e login
- [ ] E-mail: "Criar conta" com A + senha de 6+ caracteres → vai direto para "Seu cadastro".
- [ ] Senha errada em "Entrar" → mostra "E-mail ou senha incorretos."
- [ ] Google: "Continuar com Google" → abre o navegador → escolhe a conta → volta ao app logado.
- [ ] Apple: "Continuar com Apple" → Face ID → volta ao app logado.
- [ ] Cada método cria uma conta separada (esperado). Saia da conta entre um teste e outro.

## 2. Onboarding
- [ ] "Continuar" fica desabilitado até ligar as duas chaves (18+ e Termos).
- [ ] Preencha o apelido e continue → cai em "Minhas peladas" (vazia).
- [ ] Feche e reabra o app → continua logado, não pede onboarding de novo.
- [ ] Conta sem apelido: usa a parte do e-mail antes do @.

## 3. Criar pelada (conta A)
- [ ] "Criar pelada" com nome de 1 letra → botão desabilitado.
- [ ] Sem posição → "Escolha sua posição."
- [ ] Nome válido + posição → abre a pelada, A aparece como "Administrador · posição (você)".
- [ ] Voltar → a pelada aparece na lista como "Administrador".

## 4. Convite por link
- [ ] Na pelada, "Convidar" → abre o compartilhar do iOS com link e código. Mande para você mesmo (WhatsApp/Notas).
- [ ] Saia da conta A. Toque no link no iPhone → abre o app na tela "Você foi convidado".
- [ ] "Entrar ou criar conta" → crie a conta B → onboarding → o app volta sozinho para o convite.
- [ ] Escolha posição → "Entrar na pelada" → a pelada aparece na lista de B como "Jogador".
- [ ] Código: com a conta C, "Entrar com convite" → cole só o código → entra também.
- [ ] Código inventado → "Convite inválido."

## 5. Assistente e sucessor (conta A)
- [ ] A vê B e C com botões; B e C NÃO veem botões de admin.
- [ ] "Tornar assistente" em B → B aparece como "Assistente".
- [ ] "Indicar como sucessor" em C → aparece "· sucessor indicado".
- [ ] "Remover sucessor" e indicar de novo → funciona nos dois sentidos.

## 6. Admin sai com sucessão
- [ ] A: "Sair da pelada" → alerta explica a sucessão → "Sair" → volta para a lista, pelada sumiu.
- [ ] Entre como C → C é "Administrador" (sucessor indicado tem prioridade sobre o assistente B).
- [ ] C sai sem indicar sucessor → entre como B → B é "Administrador" (assistente mais antigo).
- [ ] B gera novo convite; A entra por ele → reaparece na mesma pelada (mesmo registro), como "Jogador".
- [ ] A (jogador) toca "Sair da pelada" → alerta diz que o histórico fica guardado → sai.

## 7. Premium
- [ ] "Premium" abre a tela com o texto do preço e do beta gratuito.
- [ ] Sem chave do RevenueCat no .env: aparece "Chave do RevenueCat ainda não configurada" (esperado por enquanto).
- [ ] Nenhum travamento ao abrir/fechar a tela.

## 8. Geral
- [ ] "Sair da conta" leva para o login.
- [ ] Nenhuma tela em modo escuro; cores azul/fundo claro conforme a marca.
