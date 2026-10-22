# Minuto 91 — Fase 7: proposta do Min91 Pro (22/10/2026)

> **Só estudo, para aprovação.** Nada foi implementado. Nenhuma cobrança, produto na loja ou assinatura individual foi criada. Preços e taxas de terceiros devem ser conferidos na hora de decidir.

## 1. O que é

Uma assinatura **individual**, da pessoa, separada do Premium da pelada (que é coletivo e continua como está).

| | Premium da pelada (existe) | Min91 Pro (proposta) |
|---|---|---|
| De quem é | Da pelada | Da conta da pessoa |
| Quem compra | O admin daquela pelada | Qualquer jogador |
| Quem aproveita | Todos os membros daquela pelada | Só a própria pessoa, em qualquer pelada |
| Preço atual | R$ 29,90/mês por pelada | A definir (seção 6) |

**Regra de ouro**: o Pro **nunca** libera recursos coletivos de uma pelada. Temporada personalizada, nomes dos times, horário fixo, Bola Murcha desligável, mais assistentes, histórico completo da pelada e arte especial de rankings continuam sendo só do Premium da pelada. Assim, o Pro não canibaliza o Premium, e nenhum jogador consegue "liberar a pelada" pagando sozinho.

## 2. Benefícios possíveis (para você escolher)

Todos são pessoais e usam só dados que a pessoa já pode ver.

| Benefício | Custo de construir | Observação |
|---|---|---|
| Retrospectiva individual especial (mais telas e formatos, animação) | Médio | Já previsto na V3 como "possível benefício futuro" |
| Artes extras: modelos alternativos do Card e do pós-jogo, fundos especiais | Médio | Não muda o Card oficial (fórmula, categoria e moldura continuam iguais para todos) |
| Carreira completa **só do próprio jogador**, mesmo em pelada grátis | Baixo no código, **decisão de produto** | Hoje, pelada grátis mostra só a temporada atual e a anterior. Liberar o histórico pessoal pode reduzir o motivo para a pelada assinar o Premium. Recomendo **não incluir** no começo |
| Estatísticas pessoais avançadas (evolução do overall, comparação entre temporadas) | Médio | Só os números da própria pessoa |
| Selo "Pro" no perfil | Baixo | Cosmético; avaliar se não cria pressão social na pelada |

**Recomendação**: lançar o Pro com 2 ou 3 benefícios (retrospectiva especial, artes extras, estatísticas pessoais) e sem a carreira completa.

## 3. Arquitetura de dados

Nova tabela, separada das do Premium da pelada:

```
public.player_entitlements
  user_id        uuid  (dono; chave)
  plan           'free' | 'pro'
  status         'active' | 'cancelled' | 'expired' | 'trial'
  pro_until      timestamptz   -- fim do período pago
  source         'store' | 'trial' | 'support'
  store_ref      text          -- original_transaction_id
  last_event_at  timestamptz   -- eventos fora de ordem, como na 026
```

- **Função única**: `private.player_has_pro(p_user)`. Só as telas e RPCs de benefícios pessoais consultam essa função.
- **Isolamento garantido por teste**: um teste de invariante (no estilo do 020) confere que **nenhuma** função que use `pelada_has_premium` consulta `player_entitlements`, e vice-versa. O teste 026 ganha casos: "jogador Pro numa pelada grátis não libera nada coletivo".
- **Por que não reutilizar `subscription_purchasers`**: essa tabela tem a regra "uma assinatura ativa por comprador". Se o Pro morasse ali, quem assina o Premium de uma pelada não poderia assinar o Pro. Com tabelas separadas, as duas assinaturas convivem.
- **Leitura**: o app lê só o próprio estado (`get_my_entitlements`). Ninguém lê se o outro é Pro (exceto o selo, se for aprovado).

## 4. RevenueCat e lojas

- **No mesmo projeto do RevenueCat**:
  - entitlement `pelada_premium` (o atual, com o atributo `pelada_id` em cada compra);
  - entitlement `player_pro` (novo, sem atributo).
- **Produtos separados** nas lojas, por exemplo `min91_pro_mensal` e `min91_pro_anual`, num **grupo de assinatura diferente** do Premium da pelada. Na Apple, assinaturas do mesmo grupo se substituem; em grupos diferentes, convivem.
- **Webhook** (`revenuecat-webhook`): separa pelo `entitlement_id` (ou pelo produto). Eventos do Pro vão para uma nova função `apply_player_event`, que não toca nada de pelada. A função atual continua igual para o Premium da pelada.
- **Restaurar compras**: o comprador já é o id do usuário (`appUserID`), então a restauração devolve o Pro à mesma pessoa. Em outra conta do app, o RevenueCat manda TRANSFER e o Pro vai para a conta nova.
- **Cancelamento e reembolso**: mesma lógica da 026. Cancelar mantém o período pago; reembolso encerra na data da loja; eventos antigos não mudam nada.
- **Eventos hoje ignorados** (`SUBSCRIPTION_EXTENDED`, `REFUND_REVERSED`, `NON_RENEWING_PURCHASE`): tratar no Pro desde o início.

## 5. Transferência de conta e teste grátis

- **Transferência por código (024)**: o Pro **acompanha a pessoa**, como o teste grátis (031). Ao usar o código, `player_entitlements` passa para a conta nova, usando a mesma cadeia de contas (`private.account_lineage`). Na loja, a assinatura continua no Apple ID ou na conta Google; o app manda "Restaurar compras" na conta nova.
- **Exclusão de conta (021)**: o Pro não é cancelado pelo app (só a loja cancela). A tela de exclusão avisa: "cancele a assinatura na App Store/Google Play". Isso é exigência das lojas.
- **Teste grátis do Pro**: recomendo **7 dias**, 1 por pessoa (cadeia de contas), começando pela loja (oferta introdutória). Assim não é preciso controle próprio como na 031.

## 6. Proposta comercial

| Item | Proposta | Motivo |
|---|---|---|
| Preço mensal | R$ 7,90 a R$ 9,90 | Bem abaixo dos R$ 29,90 da pelada, para não competir; compra por impulso de um jogador |
| Preço anual | ≈ 10× o mensal (ex.: R$ 79,90) | Padrão de mercado ("2 meses grátis") |
| Teste | 7 dias | Suficiente para uma pelada semanal e uma retrospectiva |
| Quando lançar | Depois do Premium da pelada estar estável em produção | Uma assinatura de cada vez; aprender com a primeira |

- **Taxas da loja**: em geral 15% para assinaturas (Apple Small Business Program e Google). Conferir as regras vigentes.
- **RevenueCat**: tem faixa grátis até um teto de receita mensal; conferir antes.
- **Exemplo ilustrativo** (não é previsão): 1.000 jogadores Pro a R$ 9,90 ≈ R$ 9.900/mês bruto; menos 15% da loja ≈ R$ 8.400/mês.

## 7. Riscos

| Risco | Mitigação |
|---|---|
| Confundir "Premium da pelada" com "Pro" | Nomes e telas diferentes: "para a sua pelada" × "para você"; nunca vender o Pro na tela do Premium da pelada |
| Pro canibalizar o Premium da pelada | Regra de ouro (seção 1) e carreira completa fora do Pro |
| Pressão social ("só quem paga tem arte bonita") | Artes básicas continuam grátis e boas; o Pro é extra, não o mínimo |
| Vazamento entre os dois produtos | Tabelas e funções separadas + teste de invariante + casos novos no 026 |
| Duas assinaturas ao mesmo tempo (Pro + Premium da pelada) | Permitido por desenho (grupos diferentes); o teste confere que convivem |
| Revisão da Apple | Benefícios claros na tela de compra, link de termos e restaurar compras visível |
| Dados pessoais | Nenhum dado novo; o Pro só usa o que a pessoa já vê. Política: mencionar a assinatura individual |

## 8. Esforço estimado (se aprovado)

1. **Migração 033**: `player_entitlements`, `player_has_pro`, `get_my_entitlements`, `apply_player_event`, transferência na 024 (via nova função) e testes SQL (027 + invariantes).
2. **Webhook**: separar por entitlement.
3. **App**: tela "Min91 Pro" (em Minha conta), compra, restauração e os 2 ou 3 benefícios escolhidos.
4. **Lojas**: produtos e grupo de assinatura (precisa da conta Apple Developer e do development build).

Ordem sugerida: só depois do lançamento com o Premium da pelada funcionando em produção.

## 9. Decisões que preciso de você (quando for a hora)

1. Quais benefícios entram (seção 2).
2. Preço mensal e anual.
3. Teste grátis de 7 dias: sim ou não.
4. Selo "Pro" no perfil: sim ou não.
5. Carreira completa pessoal no Pro: confirmar que fica de fora.
