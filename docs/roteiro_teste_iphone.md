# Roteiro de teste no iPhone

Marque cada item. Se algo falhar, anote o passo e a mensagem exata da tela.
Sem conta Apple paga, use o Expo Go e pule Apple e Premium (precisam do development build).

## 0. Antes de começar
- [ ] Supabase > Authentication > URL Configuration > Redirect URLs contém `minuto91://**` e `exp://**`.
- [ ] Supabase > Authentication > Providers: Google ativo (Client ID/Secret do Google Cloud).
- [ ] Supabase > Authentication > Providers: Apple ativo, com `com.minuto91.app` em "Client IDs" (só no development build).
- [ ] No PC, com Expo Go: `cd $HOME\Documents\minuto91\app; npx expo start --go --tunnel -c` e leia o QR code com a câmera do iPhone.
      O `--tunnel` é obrigatório para o login com Google no Expo Go: sem ele o endereço de retorno usa o IP do PC
      (exp://192.168.x.x), que o Supabase recusa e manda para "localhost". Sem testar Google, `--go -c` basta.
- [ ] Com development build: `cd $HOME\Documents\minuto91\app; npx expo start --dev-client -c` e abra o app Minuto 91.
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

## 9. Partida e súmula (admin A)
Para votar de verdade são precisos **6 jogadores com conta** na pelada. Atalho no banco dev:
`supabase/dev_seed/01_criar_bots.sql` cria 5 jogadores de teste sem senha na Pelada Teste, e
`02_bots_votam.sql` faz os 5 votarem na votação aberta (`99_apagar_bots.sql` remove).
Ou crie contas de e-mail (teste1@..., teste2@...) e entre na pelada com cada uma pelo convite.
- [ ] Na pelada, "Lançar partida" → abre a súmula em rascunho.
- [ ] "Ontem" muda a data; a data aparece no topo.
- [ ] Adicione jogadores com "+ A" e "+ B"; troque um de time pelos botões Time A / Time B; "Tirar" remove.
- [ ] Gols, assistências e vermelho com − e +; o placar do topo acompanha.
- [ ] "Gol sem autor" e "Gol contra a favor" somam no placar do time.
- [ ] Mais assistências que gols num time → erro "Um time tem mais assistências do que gols."
- [ ] Novo convidado: nome + chave 18+ → entra no Time A com a posição escolhida.
- [ ] "Salvar rascunho" → "Súmula salva". Saia e volte: tudo continua lá.
- [ ] Entre como jogador comum (B): o rascunho NÃO aparece na lista de partidas.
- [ ] "Excluir rascunho" (em outra partida de teste) → some da lista.

## 10. Publicar e votar
- [ ] Com menos de 6 contas na súmula: "Publicar" → aviso "finalizada sem votação"; a partida mostra só os gols.
- [ ] Com 6 ou mais: escolha o prazo (2h/4h/6h) e "Publicar e abrir votação" → "Votação até HH:MM".
- [ ] A tela da partida mostra "0 de N já votaram" e quem falta.
- [ ] Como jogador: "Votar" → primeiro "Confira a súmula" → "Conferi a súmula".
- [ ] Notas com − e + (de 0,5 em 0,5, começando em 6,0); "Não vi jogar" e "Limpar" funcionam.
- [ ] Marcar "Não vi jogar" em mais da metade → erro ao enviar.
- [ ] Sem Craque → "Escolha o Craque da Partida"; sem Bola Murcha (beta = Premium) → pede Bola Murcha.
- [ ] "Salvar rascunho", sair e voltar: notas continuam. "Enviar voto" → "Voto enviado".
- [ ] Na partida: "1 de N já votaram"; seu nome sai da lista de quem falta; botão vira "Editar meu voto".
- [ ] Admin: "Corrigir súmula" (ex.: mais um gol) com motivo → "Versão 2". O jogador precisa conferir de novo para editar o voto.
- [ ] Admin tira um jogador com conta da súmula na correção → aviso "votação reiniciada".
- [ ] Quando o último vota → "Todo mundo votou: o resultado já saiu!".

## 11. Resultado
- [ ] Partida finalizada mostra Craque, Bola Murcha (se houver) e a lista de notas.
- [ ] Quem não votou vê "resultado detalhado bloqueado".
- [ ] Prazo vencido sem todos votarem: aparece "Encerrar votação" (o agendador também fecha a cada 5 minutos).
- [ ] Menos da metade votou → "Votação inválida", sem notas nem prêmios.

## 12. Carta, rankings e álbum
- [ ] Na pelada, "Minha carta" abre sua carta: overall grande, Bronze/Prata/Ouro, "Provisória: x de 5 jogos" nos 5 primeiros.
- [ ] Os 5 atributos (Finalização, Garçom, Presença, Pé Quente, Resenha) aparecem com barras de 0 a 100.
- [ ] Tocar no nome de outro jogador da lista abre a carta dele.
- [ ] "Temporada" mostra jogos, V/E/D, gols, assistências, média de nota e sequências.
- [ ] "Ver álbum de figurinhas": 9 coleções, 48 figurinhas; conquistadas com ★ e data; bloqueadas com progresso (ex.: 2/10).
- [ ] "Rankings": troque Overall / Gols / Assistências / Média / Jogos / Vitórias; empates aparecem como 1º, 1º, 3º.
- [ ] Tocar num nome do ranking abre a carta.
- [ ] Recordes da temporada aparecem (maior goleada, mais gols numa partida etc.).
- [ ] Depois que um mês fechar com partidas: "Prêmios de <mês>" mostra Rei do Mês, Artilheiro, Garçom e Maior evolução.

## 13. Conta, Premium, denúncia e bloqueio
- [ ] Na pelada, "Premium da pelada": no beta mostra "Premium liberado"; lista o que o Premium libera.
- [ ] Início → "Minha conta" abre a tela da conta.
- [ ] "Gerar código de transferência" mostra um código XXXX-XXXX-XXXX-XXXX e "Guardar o código" abre o compartilhar.
- [ ] Numa conta NOVA, sem pelada: "Recebi um código" com o código → "Histórico transferido". A conta antiga fica desativada.
- [ ] Numa conta que já está numa pelada, usar código → recusa explicando o motivo.
- [ ] Carta de OUTRO jogador: "Denunciar apelido", "Denunciar foto ou perfil", "Bloquear jogador". Na sua carta, nada disso aparece.
- [ ] Bloquear → o jogador aparece em "Minha conta > Jogadores bloqueados"; "Desbloquear" volta ao normal.
- [ ] Pelada → "Denunciar nome ou imagem da pelada": sem motivo o botão fica travado; com motivo → "Denúncia enviada".
- [ ] Excluir conta (use uma conta de TESTE): o botão só destrava com EXCLUIR digitado → a tela vira "Conta em exclusão".
- [ ] Na pelada, essa conta aparece como "Aposentado"; se era admin, outro virou admin.
- [ ] Entre de novo com a conta excluída: o início mostra "Sua conta será apagada em ..."; "Recuperar minha conta" devolve as peladas, como jogador.

## 14. Evolução V3 (22/10/2026)
Antes: o mesmo comando da seção 0 (`--tunnel`). Desde a V3, o que era "Carta" aparece como "Card" em todo o app (ex.: o botão "Minha carta" virou "Meu Card").

**Card novo (Modelo A, escudo)**
- [ ] "Meu Card": o formato é de escudo (topo com bico, base pontuda), com foto, overall e posição no alto à esquerda, escudo da pelada à direita, nome e FIN/GAR/PRE/PEQ/RES embaixo.
- [ ] A cor e a moldura batem com a categoria: bronze (contorno simples), prata (contorno duplo) ou ouro (moldura com detalhes no topo e nas laterais).
- [ ] Sem foto: aparecem as iniciais. Com nome longo: o nome encolhe e não quebra a composição.
- [ ] Elenco (Cards): os Cards pequenos não têm texto encavalado; dá para ler o overall e os atributos.
- [ ] "Compartilhar meu Card" → Stories e Post: a imagem no WhatsApp é igual ao Card da tela.

**Escudo (admin)**
- [ ] Configurações da pelada → "Trocar escudo" → escolha um PNG transparente redondo ou irregular: a imagem NÃO é cortada em quadrado.
- [ ] A prévia mostra o escudo nos Cards bronze, prata e ouro e no cabeçalho, sem fundo branco. "Salvar escudo" aplica; "Cancelar" não muda nada.
- [ ] Escolha uma foto JPG: aparece o aviso "não tem fundo transparente".

**Painel de pendências (admin ou assistente)**
- [ ] Na pelada, com súmula em rascunho: "Súmula em rascunho → Terminar súmula" abre a súmula.
- [ ] Com votação aberta: mostra quantos votaram e o horário; tocar abre a partida. Depois do prazo, o item fica vermelho ("Encerrar votação").
- [ ] Um jogador comum NÃO vê o painel.

**Artes da partida e pós-jogo**
- [ ] Partida finalizada → "Compartilhar meu pós-jogo": foto, vitória/empate/derrota, placar, gols, assistências e nota (se você votou). O selo Craque da Partida aparece só se você foi o Craque.
- [ ] "Compartilhar resultado": quem NÃO votou consegue gerar, mas sem notas.
- [ ] Troque entre "Stories 9:16" e "Post 4:5": nada fica cortado e o "MINUTO 91" aparece embaixo.
- [ ] Compartilhe no Instagram (Stories) e no WhatsApp: a imagem chega inteira.

**Retrospectiva da temporada**
- [ ] Na pelada, "Retrospectiva da temporada": números da pelada, top 3 (artilharia, garçons, Craque da Partida, presença), Reis do Mês e a sua temporada com o Card.
- [ ] Bola Murcha aparece só na tela, nunca nas artes.
- [ ] As artes "Retrospectiva da pelada" e "Minha temporada" geram nos dois formatos. "Rankings da temporada" aparece (beta = Premium para todos).

**Privacidade e bloqueio (precisa de uma segunda conta, criada por você)**
- [ ] A conta B bloqueia a A. Na conta A, o perfil de B não abre ("Perfil do jogador" sem dados) e a foto de B não aparece. Dentro da pelada, o apelido de B continua na súmula e nos rankings.
- [ ] Em Meu perfil, numa pelada sem Premium com temporadas antigas, o total diz "Total nas temporadas disponíveis".