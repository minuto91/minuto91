# Minuto 91 — V3, Fase 4: várias peladas e Premium isolado (22/10/2026)

## 1. O que foi auditado

- **Banco**: todas as funções que conferem Premium (`private.pelada_has_premium`) ou admin (`is_active_admin`, `is_active_staff`), as políticas que dependem delas e as RPCs que recebem uma pelada junto com outro objeto (membro, partida, convidado).
- **Loja**: `start_premium_purchase`, `apply_subscription_event` (026), teste grátis (031), webhook `supabase/functions/revenuecat-webhook` e `app/src/lib/purchases.ts` (compra, restauração, troca de usuário).
- **App**: de onde vêm o papel do usuário e o estado Premium em cada tela.

## 2. Resultado

**Nenhum vazamento entre peladas foi encontrado.**

| Ponto | Como é feito | Isolado? |
|---|---|---|
| Premium | `pelada_has_premium(p)` olha só `pelada_entitlements` daquela pelada (ou o beta, que libera todas de propósito) | Sim |
| Onde o Premium é cobrado | Temporada personalizada (006), nomes dos times (007), horário fixo de encerramento (010), Bola Murcha (010/013/025), temporadas antigas (015), carreira (019/030), limite de assistentes (005/019). Em todos, a pelada vem do próprio objeto (a partida, a temporada, a configuração), nunca de um parâmetro solto | Sim |
| Admin | Toda ação de admin confere `is_active_admin` da pelada do objeto. Membro, convidado ou partida de outra pelada é recusado (ex.: `save_match_sheet`, `set_assistant` e `set_successor` exigem `pelada_id` igual) | Sim |
| Compra | Uma conta da loja tem no máximo uma assinatura com período pago. A compra só começa pelo admin daquela pelada e fica registrada para ela. O webhook acha a compra pelo par comprador + pelada; nunca cria Premium numa pelada sem compra registrada | Sim |
| Restauração / TRANSFER | A compra só muda de comprador se a nova conta for admin ativa da mesma pelada; senão a pelada mantém o período pago | Sim |
| Teste grátis | Por pelada (`pelada_entitlements`) e um por pessoa (031) | Sim |
| App | O papel vem do membro daquela pelada (`members.find(...)` na tela da pelada, da partida e da súmula; no início, o papel de cada pelada). O Premium vem de `get_pelada_entitlement(id)` em cada tela. Nada fica guardado globalmente. As travas do app são só visuais: quem decide é o banco | Sim |

## 3. Correção feita

- **Atributo `pelada_id` antigo no RevenueCat** (`app/src/lib/purchases.ts`).
  - **Problema**: se o admin começasse a compra da pelada B e desistisse, o atributo continuava apontando para a B. Se depois um evento da loja chegasse sem outra pista melhor, o banco poderia ligá-lo a uma compra antiga da B.
  - **Correção**: quando a compra não termina (desistência ou erro), o app apaga o atributo.
  - **Segurança extra no banco**: o atributo só vale se aquele comprador iniciou compra naquela pelada. O teste 026 confirma que um atributo apontando para outra pelada não libera nada.

## 4. Riscos que ficam (sem correção agora)

1. **Mesmo Apple ID em duas peladas, uma depois da outra**: a Apple pode repetir o `original_transaction_id`. Hoje quem decide é o atributo `pelada_id`. É preciso testar no sandbox do RevenueCat antes do lançamento (checklist de lançamento).
2. **Temporadas antigas no plano grátis**: as telas e as RPCs respeitam o limite (temporada atual e anterior). Mas um membro tecnicamente conseguiria ler as estatísticas antigas da própria pelada direto na tabela. Não vaza nada para outra pelada; é só um "paywall" contornável dentro da pelada. O pedido diz para não restringir artificialmente as estatísticas básicas, então não mudei. Se quiser fechar, é uma migração pequena.
3. **Eventos ignorados**: `NON_RENEWING_PURCHASE` continua ignorado (já estava nas pendências).

## 5. Teste novo

`supabase/tests_editor/026_multi_pelada_premium.sql`. O usuário 1 é admin da A e da B e jogador da C; o usuário 2 é admin da C e jogador da A. O teste confere:

- **Papéis**: uma conta só, com papel diferente em cada pelada.
- **Admin não passa de pelada**: o admin da A e da B não consegue mexer na C (configurações, assistente, compra, teste grátis, escudo), e o admin da C não consegue mexer na A.
- **Compra da A**: só a A fica Premium. A B (mesmo admin) e a C (mesmo jogador) continuam grátis, também no que o app recebe.
- **Benefícios só na A**:
  - nomes dos times;
  - desligar a Bola Murcha;
  - 3 assistentes (na B, só 1);
  - temporada personalizada recusada na B.
- **A compra não migra**:
  - a mesma conta da loja não começa outra assinatura na B;
  - uma renovação da A com o atributo apontando para a B não libera a B.
- **Teste grátis**: o da B vale só para a B.
- **Expiração**: quando a A expira, o teste grátis da B não é afetado.

**Status**: PASS no dev (rodado pelo fundador no SQL Editor em 22/10). Na primeira execução falhou por erro do próprio teste: o evento de expiração tinha data de fim no futuro. O teste foi corrigido; o banco estava certo.

## 6. Jornada do admin e do jogador (diagnóstico)

O que já funciona bem:

- uma conta só;
- a lista de peladas no início com o papel em cada uma;
- "Falta o seu voto" no início;
- o admin joga e vota como qualquer jogador, sem "modo admin".

Oportunidades (para a próxima etapa, sem mudar o início):

1. **Painel de pendências dentro da pelada (só admin/assistente)**: súmulas em rascunho, votação vencida para encerrar, partida com correção pendente, convite expirado. Os dados já existem; é só uma consulta e um cartão.
2. **Depois de publicar a súmula**: ir direto para a partida, com "quem falta votar" visível.
3. **Criar pelada → convidar**: mostrar o link de convite logo depois de criar, em vez de exigir voltar à tela da pelada.

## 7. Arquivos

- `app/src/lib/purchases.ts`: apaga o atributo quando a compra não termina.
- `supabase/tests_editor/026_multi_pelada_premium.sql`: novo.
- Este relatório.

Sem migração nova.
