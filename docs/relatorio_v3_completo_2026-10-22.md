# Minuto 91 — Relatório completo da Evolução V3 (22/10/2026)

Um só documento com tudo da V3, nesta ordem:

1. Homologação final (resumo, testes, checklist, pendências)
2. Etapa 1: segurança, termos, Card definitivo, escudo, proposta do Min91 Pro
3. Fase 4: várias peladas e Premium isolado; painel de pendências do admin
4. Fase 5: artes para compartilhar
5. Fase 6: retrospectiva da temporada
6. Fase 7: proposta do Min91 Pro (estudo para aprovação)

**Status:** todas as fases da V3 entregues (a 7 é só proposta, nada ativado). Pendente: teste no iPhone real (seção 14 do roteiro).

---

## Minuto 91 — V3, Fase 8: homologação final (22/10/2026)

Resumo das fases e relatórios:

- [Etapa 1: segurança, termos, Card, escudo](relatorio_v3_etapa1_2026-10-22.md)
- [Fase 4: várias peladas e Premium isolado](relatorio_v3_fase4_2026-10-22.md)
- [Fase 5: artes](relatorio_v3_fase5_2026-10-22.md)
- [Fase 6: retrospectiva](relatorio_v3_fase6_2026-10-22.md)
- O painel de pendências do admin foi entregue entre as fases 4 e 5.
- A proposta do Min91 Pro está na seção 10 do relatório da etapa 1 (Fase 7 detalhada ainda não feita).

### 1. Verificações executadas (de verdade, nesta data)

| Verificação | Resultado |
|---|---|
| `npx tsc --noEmit` | Limpo |
| `npx expo lint` | Limpo |
| `npx expo-doctor` | 21/21 ok |
| `npx expo export --platform ios` (bundle de produção) | Gerado sem erro (5,4 MB) |
| SQL `025_blocks_both_ways`, `016_reports_blocks` (atualizado), `026_multi_pelada_premium` | PASS no dev (rodados pelo fundador) |
| SQL `001` a `024` | Sem nova execução nesta etapa. Nenhuma migração depois da 032 mexeu nessas áreas, mas rodar de novo antes do lançamento é recomendado |
| Revisão visual na web, 375 × 812 (iPhone pequeno) e 430 × 932 (iPhone grande): início, pelada (com pendências), Elenco, Card, Meu perfil, partida, artes e retrospectiva | Sem texto sobreposto ou cortado; console sem erros. Os escudos aparecem um instante depois do resto (carregamento da imagem) |
| iPhone real (Expo Go) | **Não feito**: roteiro na seção 14 de `docs/roteiro_teste_iphone.md` |

### 2. Cobertura dos testes pedidos na V3

| Caso | Como foi coberto |
|---|---|
| Bloqueio nos dois sentidos | SQL 025 e 016 (PASS) |
| Privacidade do perfil e da carreira | SQL 023 (V2) e 025 |
| Histórico parcial e completo | Auditoria da 030; aviso no app conferido no código. Na tela, só com pelada grátis com temporadas antigas (não existe no dev) |
| Premium independente por pelada | SQL 026 (PASS) |
| Usuário admin de várias peladas | SQL 026 (PASS) |
| Escudo PNG transparente, circular e irregular | Vitrine `/dev-cards` (web). Upload real: roteiro do iPhone |
| Card bronze, prata e ouro | Vitrine `/dev-cards` + imagens em `docs/evidencias_v3/` |
| Exportação de artes | 1080 × 1920 conferido na web (vitrine). Envio real (WhatsApp/Instagram): roteiro do iPhone |
| Partida anulada | Coberta pela 013/020 (V2) e excluída na retrospectiva e na carreira (consulta só `finalized`) |
| Resultado sem premiação apurada | A arte só mostra o Craque se existir o prêmio ativo; votação inválida mostra o aviso |
| Jogador sem estatísticas | Retrospectiva: "Você não jogou nenhuma partida finalizada nesta temporada" |
| Temporada encerrada | Retrospectiva marca "encerrada" ou "parcial". Não existe temporada encerrada no dev |
| Retrospectiva sem dados suficientes | Mensagens para 0 partidas e para menos de 3 |
| Uso em dispositivos móveis | Revisão a 375 e 430 px na web; iPhone real pendente |
| Desempenho com muitas partidas e jogadores | Elenco: 3 consultas e carregamento em blocos (V2). Retrospectiva: 5 consultas por temporada. Pendências: 2 consultas. **Não medido** com volume real |

### 3. Checklist de homologação (para você)

1. [ ] iPhone: seção 14 do roteiro (Card, escudo, pendências, artes, retrospectiva).
2. [ ] iPhone: seções 9 a 13 de novo (súmula, votação, resultado), porque a tela da partida mudou.
3. [ ] Segunda conta (você cria): bloqueio, excluir/recuperar, código de transferência.
4. [ ] SQL Editor do dev: rodar `tests_editor/001` a `024` de novo (cada um deve terminar com "PASS").
5. [ ] Publicar a função `storage-cleanup` (fotos e escudos órfãos), pendente desde a V2.

### 4. Pendências externas (antes do lançamento)

- **Apple Developer (US$ 99/ano)** e development build. Login com Apple, push e RevenueCat dependem disso.
- **RevenueCat sandbox**: testar o mesmo Apple ID assinando duas peladas em sequência (risco anotado na Fase 4).
- **Documentos**:
  - Doc 02: bloqueio nos dois sentidos (RN-120) e Seleção sem adaptação (RN-075).
  - Doc 03: política de perfis.
  - Brand Book: termo "Card" e o Modelo A.
  - Política/Termos: imagens compartilhadas fora do app, retrospectiva.
- **Advogado**: 30 dias de recuperação, retenção do Aposentado e das cédulas, registro do teste grátis.
- **Produção**: projeto Supabase de produção, ligar a confirmação de e-mail, `premium_beta_open=false`, produtos nas lojas, TestFlight.

### 5. ZIP

ZIP atualizado gerado com `git archive` em `entregas/minuto91_v3_2026-10-22.zip`. Não vai para o GitHub: a pasta está no `.gitignore`.

### 6. Teste simulado de celular (22/10, feito pelo Claude no navegador)

Navegador embutido em modo celular (375 × 812, toque e navegador de celular), com a sua conta e a Pelada Teste do dev.

| Item da seção 14 do roteiro | Resultado |
|---|---|
| Card novo: formato, categoria, sem foto, nome longo | Ok (tela do Card, Elenco e vitrine `/dev-cards`) |
| Elenco com Cards pequenos legíveis | Ok |
| Exportação da imagem | Ok: a vitrine gerou PNG de 1080 × 1920 no modo celular, igual à tela |
| Painel de pendências: "Súmula em rascunho" abre a súmula | Ok |
| Pós-jogo e resultado nos dois formatos, sem cortes | Ok (conferidos na Fase 5) |
| Retrospectiva: números, Bola Murcha só na tela, três artes | Ok (conferidos na Fase 6) |
| Prévia do escudo (layout) | Ok na vitrine |

**Não dá para testar daqui (fica para o iPhone):**

- Escolher imagem na galeria (enviar escudo de verdade).
- Abrir a folha de compartilhar do iOS e enviar ao WhatsApp/Instagram. Na web, o botão baixaria um arquivo no seu computador.
- Teclado, gestos e aparência do Expo Go.
- Itens que pedem uma segunda conta real (bloqueio entre contas, exclusão, transferência). O Claude não pode criar contas nem digitar senhas.
- Jogador comum não vê o painel de pendências. Conferido só no código: o painel exige admin ou assistente, e não há login de bot para ver ao vivo.
- Votação nova até o fim: depende dos bots votarem pelo SQL Editor (você) e do prazo acabar.
---

## Minuto 91 — Evolução V3, etapa 1 (22/10/2026)

Escopo desta etapa: Fase 1 (segurança, carreira, termos), Fase 2 (Card definitivo, Modelo A) e Fase 3 (escudo transparente).
As Fases 4 a 8 estão planejadas na seção 9 e ainda não foram feitas.

### 1. Diagnóstico inicial

| Item | Situação encontrada | Gravidade |
|---|---|---|
| `profiles_read_peers` (029) | Só escondia o perfil de quem **o leitor** bloqueou. Quem **foi bloqueado** ainda lia nome e foto de quem bloqueou, direto da tabela, e pegava a foto pelo bucket `avatars`, porque a regra dele segue a dos perfis. Isso contrariava a decisão da V2 ("bloqueio nos dois sentidos"). O teste 016 conferia esse comportamento antigo de propósito. | Alta (privacidade) |
| `get_player_profile` / `get_player_career` | Já usavam `blocked_either_way` (dois sentidos), conta listada e visibilidade. Sem falha. | — |
| Carreira (030) | Totais somam só as temporadas mostradas. Partida anulada fica de fora (as projeções da 014 excluem; a 020 revoga prêmios e Seleção). Quem saiu da pelada mantém o histórico; o registro "Aposentado" nunca entra. Não há contagem dupla (cada partida pertence a uma pelada e uma temporada). Bola Murcha fora das conquistas. Sem overall global. | — |
| Total parcial | O app mostrava "Total na carreira" mesmo quando havia temporadas escondidas pelo plano grátis. | Média (UX enganosa) |
| Termos | "Carta/Cartas" em 12 arquivos de tela. Não havia "MVP". | Baixa |
| Escudo (`crest.tsx`) | Recorte quadrado forçado (editor do sistema e recorte central) e troca para JPEG quando o PNG passava de 1 MB, o que perdia a transparência. Sem prévia antes de salvar. | Média |
| Artes | O escudo não aparecia nas artes de resultado nem da Seleção (pendência da V2). Na exportação web, o escudo seria esticado (a captura ignora "contain"). | Média |
| Premium por pelada | `private.pelada_has_premium(p_pelada)` usa só o registro daquela pelada (`pelada_entitlements.pelada_id`). No beta, a chave `premium_beta_open` libera todas, como esperado. A compra leva o atributo `pelada_id`. Auditoria completa na Fase 4. | — |

### 2. Problemas corrigidos

1. **Bloqueio nos dois sentidos**: migração `032_block_both_ways.sql`. Dentro da pelada, o apelido do membro, a súmula, as estatísticas, os rankings e os Cards continuam aparecendo (não dependem da linha do perfil).
2. **Total parcial da carreira**: quando falta temporada, o título vira "Total nas temporadas disponíveis", com um aviso explicando o motivo; cada pelada afetada também ganha o rótulo.
3. **Terminologia**: "Card/Cards" em todos os textos visíveis (com concordância: "o Card", "provisório"). Tabelas, colunas e funções internas não foram renomeadas.
4. **Escudo**: sem recorte; só reduz o lado maior para até 512 px, mantendo a proporção. PNG e WEBP saem sempre em PNG (com transparência). Se passar de 1 MB, tenta 384 e 256 px, sem nunca virar JPEG. Só JPG e HEIC (que não têm transparência) saem em JPEG.
5. **Escudo nas artes** de resultado e da Seleção, com a proporção calculada à mão (a exportação fica igual à tela).

### 3. Funcionalidades desenvolvidas

- **Card definitivo, Modelo A** (`app/src/lib/playercard.tsx`):
  - Uma única silhueta em vetor (SVG), em código: topo com vértice central, laterais retas, base pontiaguda, cantos arredondados.
  - Mesmo layout nas três categorias. Bronze: contorno simples. Prata: contorno duplo com filete e recortes laterais. Ouro: moldura em camadas (dois filetes), chevron e pedra no topo, barras laterais em relevo.
  - Foto como protagonista, que se mistura ao metal no topo e ao painel escuro embaixo. Overall e posição no alto à esquerda; escudo transparente à direita; nome; FIN, GAR, PRE, PEQ e RES; temporada e "MINUTO 91" na ponta.
  - Sem foto: as iniciais. "Provisório" discreto abaixo da posição.
  - O mesmo componente atende Elenco (pequeno, sem rodapé), Perfil, tela do Card e exportação.
- **Prévia do escudo antes de salvar** (configurações da pelada): o escudo sobre os Cards bronze, prata e ouro e no cabeçalho da pelada. Aviso quando a imagem não tem transparência (JPG/HEIC sempre; PNG conferido na web; no celular não dá para saber sem biblioteca extra).
- **Vitrine de Cards** (`/dev-cards`): só em desenvolvimento, abre sem login, com valores de exemplo. Mostra as três categorias lado a lado, os casos difíceis, o tamanho do Elenco e um teste da exportação 1080 × 1920.

### 4. Arquivos alterados

- Novos:
  - `supabase/migrations/032_block_both_ways.sql`
  - `supabase/tests_editor/025_blocks_both_ways.sql`
  - `app/src/lib/playercard.tsx`
  - `app/src/app/dev-cards.tsx`
  - `docs/evidencias_v3/*.png`
  - este relatório
- Alterados:
  - `supabase/tests_editor/016_reports_blocks.sql` e `supabase/tests/016_reports_blocks.sql`: regra nova do bloqueio.
  - `app/src/lib/arts.tsx`: Card antigo removido, escudo no cabeçalho das artes, "CARD DA TEMPORADA".
  - `app/src/lib/crest.tsx`: `pickCrest`, `uploadCrest`, proporção manual.
  - `app/src/app/pelada/[id]/configuracoes.tsx`: prévia do escudo.
  - `app/src/app/partida/[id]/index.tsx`: escudo nas artes.
  - `app/src/lib/profile.tsx`: total parcial.
  - `app/src/app/_layout.tsx`: título "Card" e vitrine sem login só em desenvolvimento.
  - Textos das telas: `perfil`, `elenco`, `premium`, `pelada/[id]/index`, `conta`, `onboarding`, `atleta/[id]`, `jogador/[id]/index`, `annul.tsx`.
  - `app/package.json`: `react-native-svg` 15.15.4, instalado com `expo install` (já vem no Expo Go, sem development build).

### 5. Migrações novas e implantação

- **032_block_both_ways**: troca só a política `profiles_read_peers`. Nenhuma migração aplicada foi editada.
- **Versões antigas do app**: leem só `id, display_name, avatar_path` (desde a 029). Uma linha escondida é o mesmo caso que já tratam do lado de quem bloqueou (caem no apelido e nas iniciais). Sem quebra.
- **028 a 031**: dependências conferidas (`shares_pelada` 003, `is_active_admin` 003, `user_blocks` 023, `pelada_has_premium` 019, `account_deletion_requests` 021). A 032 depende de `blocked_either_way` e `can_view_global` (029).
- **Rollback**: recriar a política da 029 (não recomendado, reabre a falha).

### 6. Testes executados (de verdade)

| Teste | Resultado |
|---|---|
| `npx tsc --noEmit` | Limpo |
| `npx expo lint` | Limpo |
| `npx expo-doctor` | 21/21 ok |
| Visual no navegador (web): três categorias, sem foto, nome longo, provisório, escudos redondo/triangular/tradicional/irregular, tamanho do Elenco, prévia do escudo | Ok, após 3 correções (atributos das pontas encostavam na moldura; foto vazava 1–2 px na lateral; brilho aparecia sobre o painel escuro) |
| Exportação 1080 × 1920 (mesma captura do compartilhar) | Ok após corrigir o escudo esticado; a imagem gerada corresponde à tela |
| SQL `025_blocks_both_ways` e `016` atualizado | PASS no dev (rodados pelo fundador no SQL Editor em 22/10, depois de aplicar a 032) |
| Celular (Expo Go) | **Não testado** nesta etapa |
| Upload real de escudo | **Não testado** (precisa do login de admin) |

### 7. Problemas ainda existentes

- Na web, o nome longo é cortado com reticências (o ajuste automático de fonte só funciona no celular).
- A prévia não detecta transparência de PNG no celular. Remoção de fundo foi só estudada: as opções estáveis são serviço pago (remove.bg e afins) ou modelo no aparelho (precisa de development build). Não foi implementado, como pedido.
- **Premiações a confirmar**: o banco tem `top_scorer` (Artilheiro do mês), `top_assist` (Garçom do mês) e `most_improved` (Maior Evolução), vindos do Doc 02 (prêmios do mês, migração 015), além dos três confirmados (Craque da Partida, Rei do Mês, Bola Murcha). Nada foi apagado nem renomeado. **Decisão do fundador (22/10): manter os três**, além dos confirmados.
- Artes 4:5, arte pós-jogo individual, retrospectivas e jornadas multi-pelada ainda não foram feitas (seção 9).

### 8. Checklist de homologação (esta etapa)

1. SQL Editor do dev: colar e rodar `supabase/migrations/032_block_both_ways.sql`.
2. Rodar `supabase/tests_editor/025_blocks_both_ways.sql` e o `016`: os dois devem terminar com "PASS".
3. Web: abrir `http://localhost:8081/dev-cards` e conferir as três categorias.
4. Celular (Expo Go): abrir um Card seu, o Elenco e "Compartilhar meu Card".
5. Configurações da pelada (admin): enviar um PNG transparente redondo, conferir a prévia e salvar; enviar um JPG e ver o aviso.
6. Partida finalizada: "Compartilhar resultado" com o escudo no topo.

### 9. Próximas etapas (plano das Fases 4 a 8)

1. **Multi-peladas e Premium isolado**: auditar RPCs, políticas e o webhook com um usuário admin de duas peladas (uma Premium e uma grátis). Criar teste SQL `026`.
2. **Jornada do admin**: painel de pendências por pelada dentro da tela da pelada (súmula em rascunho, votação para encerrar, correções), sem mudar o início.
3. **Artes**: sistema reutilizável 9:16 e 4:5, arte da partida e arte pós-jogo individual (gols, assistências, nota só se autorizada, Craque), com aviso de que a imagem compartilhada fica fora do app.
4. **Retrospectiva** da pelada e individual (básica grátis; especial no Premium da pelada; individual sem cobrança).
5. **Min91 Pro**: proposta na seção 10.

### 10. Proposta Min91 Pro (só estudo, nada ativado)

- **Entitlements separados**:
  - `pelada_premium`: coletivo, ligado à pelada; o que existe hoje em `pelada_entitlements`.
  - `player_pro`: individual, ligado à conta; tabela nova `player_entitlements(user_id, pro_until, source)`.
  - Nenhuma função de Premium da pelada consulta `player_pro`. A regra fica num teste de invariante.
- **RevenueCat**:
  - Dois entitlements no mesmo projeto: `pelada_premium` (com o atributo `pelada_id` em cada compra) e `player_pro` (sem atributo).
  - O webhook separa pelo `entitlement_id`.
  - O `appUserID` já é o id do usuário, então restaurar compras funciona para os dois.
- **Cancelamento e reembolso**: mesmo tratamento da 026 (eventos fora de ordem, `premium_until`).
- **Transferência de conta (024)**: o `player_pro` acompanha a pessoa, como o teste grátis (031). No RevenueCat, usar o "transfer" do novo `appUserID`.
- **Conflitos**: ter Pro e Premium da pelada ao mesmo tempo não muda nada coletivo. O Pro libera só extras pessoais: retrospectiva individual especial, artes extras e carreira completa só do próprio jogador.
  - A carreira completa precisa de decisão de produto, porque hoje o histórico é limitado pelo plano de cada pelada.
- **Custos e riscos**:
  - Taxa da loja (15–30%) e RevenueCat (tem faixa grátis até um teto de receita mensal; conferir o preço atual antes).
  - Risco de confundir o usuário com dois produtos: a tela precisa dizer claramente "para você" ou "para a pelada".
- **Implementação estimada**: uma migração, uma mudança no webhook, uma tela. Só depois da sua aprovação.

### 11. Pendências externas

- Atualizar os documentos oficiais:
  - Doc 02 (bloqueio nos dois sentidos, RN-120).
  - Doc 03 (política de perfis).
  - Brand Book (termo "Card" e o Modelo A).
- Push dos commits (aguarda sua confirmação).

---

## Minuto 91 — V3, Fase 4: várias peladas e Premium isolado (22/10/2026)

### 1. O que foi auditado

- **Banco**: todas as funções que conferem Premium (`private.pelada_has_premium`) ou admin (`is_active_admin`, `is_active_staff`), as políticas que dependem delas e as RPCs que recebem uma pelada junto com outro objeto (membro, partida, convidado).
- **Loja**: `start_premium_purchase`, `apply_subscription_event` (026), teste grátis (031), webhook `supabase/functions/revenuecat-webhook` e `app/src/lib/purchases.ts` (compra, restauração, troca de usuário).
- **App**: de onde vêm o papel do usuário e o estado Premium em cada tela.

### 2. Resultado

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

### 3. Correção feita

- **Atributo `pelada_id` antigo no RevenueCat** (`app/src/lib/purchases.ts`).
  - **Problema**: se o admin começasse a compra da pelada B e desistisse, o atributo continuava apontando para a B. Se depois um evento da loja chegasse sem outra pista melhor, o banco poderia ligá-lo a uma compra antiga da B.
  - **Correção**: quando a compra não termina (desistência ou erro), o app apaga o atributo.
  - **Segurança extra no banco**: o atributo só vale se aquele comprador iniciou compra naquela pelada. O teste 026 confirma que um atributo apontando para outra pelada não libera nada.

### 4. Riscos que ficam (sem correção agora)

1. **Mesmo Apple ID em duas peladas, uma depois da outra**: a Apple pode repetir o `original_transaction_id`. Hoje quem decide é o atributo `pelada_id`. É preciso testar no sandbox do RevenueCat antes do lançamento (checklist de lançamento).
2. **Temporadas antigas no plano grátis**: as telas e as RPCs respeitam o limite (temporada atual e anterior). Mas um membro tecnicamente conseguiria ler as estatísticas antigas da própria pelada direto na tabela. Não vaza nada para outra pelada; é só um "paywall" contornável dentro da pelada. O pedido diz para não restringir artificialmente as estatísticas básicas, então não mudei. Se quiser fechar, é uma migração pequena.
3. **Eventos ignorados**: `NON_RENEWING_PURCHASE` continua ignorado (já estava nas pendências).

### 5. Teste novo

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

### 6. Jornada do admin e do jogador (diagnóstico)

O que já funciona bem:

- uma conta só;
- a lista de peladas no início com o papel em cada uma;
- "Falta o seu voto" no início;
- o admin joga e vota como qualquer jogador, sem "modo admin".

Oportunidades (para a próxima etapa, sem mudar o início):

1. **Painel de pendências dentro da pelada (só admin/assistente)**: súmulas em rascunho, votação vencida para encerrar, partida com correção pendente, convite expirado. Os dados já existem; é só uma consulta e um cartão.
2. **Depois de publicar a súmula**: ir direto para a partida, com "quem falta votar" visível.
3. **Criar pelada → convidar**: mostrar o link de convite logo depois de criar, em vez de exigir voltar à tela da pelada.

### 7. Arquivos

- `app/src/lib/purchases.ts`: apaga o atributo quando a compra não termina.
- `supabase/tests_editor/026_multi_pelada_premium.sql`: novo.
- Este relatório.

Sem migração nova.

---

## Minuto 91 — V3, Fase 5: artes para compartilhar (22/10/2026)

### O que foi feito

- **Dois formatos em todas as artes**: Stories 9:16 (1080 × 1920) e post 4:5 (1080 × 1350). A pessoa escolhe no painel, antes de compartilhar. Cada arte se ajusta ao 4:5 (escudo menor, foto ao lado do nome, menos linhas).
- **Arte da partida** (`ResultArt`):
  - Antes só existia para quem via as notas. Agora todo membro pode gerar, desde que a partida esteja **finalizada** (nada provisório).
  - Mostra: escudo, nome da pelada, data, placar, times, quantos jogaram, total de gols, Craque da Partida (só quando apurado oficialmente), autores dos gols e Garçom.
  - As notas aparecem só para quem pode vê-las (o banco não as entrega a quem não votou): top 3 nos Stories, e nenhuma no 4:5.
- **Arte pós-jogo individual** (`PostGameArt`), diferente do Card:
  - Mostra o desempenho naquela partida: foto, nome, pelada, data, resultado do ponto de vista do jogador (vitória, empate ou derrota), placar, gols, assistências e nota oficial (só se existir e for visível para ele). Selo "Craque da Partida" quando for o caso.
  - Zero gols ou zero assistências aparecem como 0, o número oficial.
  - Só a própria pessoa gera a sua, e só se jogou a partida.
- **Aviso de privacidade** no painel: ao compartilhar, a imagem sai do app e pode continuar acessível fora dele.
- **Nada é publicado sozinho**: o app só abre o compartilhamento do sistema quando a pessoa toca.

### Arquivos

- `app/src/lib/arts.tsx`: formatos, contexto `useArtFormat`, arte da partida, pós-jogo, ajustes do 4:5 na Seleção, no Card e na figurinha.
- `app/src/lib/share.ts`: tamanho da imagem por formato.
- `app/src/app/partida/[id]/index.tsx`: monta as duas artes; busca a própria foto.
- `docs/evidencias_v3/`: `pos_jogo_stories_9x16.jpg`, `pos_jogo_post_4x5.png`, `partida_stories_9x16.jpg`, `partida_post_4x5.png`.

### Testes

| Teste | Resultado |
|---|---|
| tsc e lint | Limpos |
| Navegador, partida real da Pelada Teste (2 × 2, Craque Rafa) | Pós-jogo e arte da partida conferidos nos dois formatos. Corrigido: o 4:5 do pós-jogo e os Stories da partida passavam do limite (logo cortado) |
| Exportação da imagem em 1080 × 1350 | **Não testada de ponta a ponta**: na web o botão baixaria um arquivo. A captura usa o mesmo caminho já testado em 1080 × 1920 |
| Seleção da Rodada no 4:5 | **Não vista**: a partida de teste não tem Seleção (poucos jogadores) |
| Celular (Expo Go) | **Não testado** |

### Pendências

- Testar no iPhone: compartilhar no WhatsApp e no Instagram (Stories e post).
- Seleção da Rodada no 4:5, quando houver uma partida com Seleção.

---

## Minuto 91 — V3, Fase 6: retrospectiva da temporada (22/10/2026)

### O que foi feito

Nova tela **Retrospectiva da temporada** (`pelada/[id]/retrospectiva`), aberta pelo botão na tela da pelada.

- **A temporada da pelada**:
  - Partidas finalizadas, gols, maior placar e jogo com mais gols.
  - Artilharia, Garçons, Craque da Partida (mais vezes) e Mais presentes (top 3 de cada).
  - Reis do Mês, mês a mês.
  - Bola Murcha aparece só na tela, em tom neutro, e nunca vai para as artes (não é conquista).
- **Sua temporada**: jogos, gols, assistências, vitórias, empates, derrotas, vezes Craque da Partida e Rei do Mês, e o Card da temporada.
- **Dados**: tudo vem dos dados oficiais (partidas finalizadas, estatísticas da temporada, prêmios ativos). Partida anulada e prêmio revogado não entram. Sem dado, o item não aparece.
- **Casos especiais**:
  - Temporada em andamento: aparece como "parcial".
  - Sem partidas finalizadas: mensagem própria.
  - Menos de 3 partidas: aviso de poucos dados.
  - Quem não jogou na temporada: aviso, sem números inventados.

### Artes (9:16 e 4:5)

| Arte | Quem | Plano |
|---|---|---|
| Retrospectiva da pelada: partidas, gols, gols por jogo, artilheiro, mais vezes Craque, Reis do Mês, maior placar | Todo membro | Grátis |
| Minha temporada: foto, jogos, gols, assistências, V/E/D, selos de Craque da Partida e Rei do Mês | Só a própria pessoa | Grátis |
| Rankings da temporada (top 3 de artilharia, garçons, Craque da Partida, presença) | Todo membro | **Premium da pelada** (a versão especial) |

- **Acesso às temporadas**: igual aos rankings (RN-083). No grátis, a temporada atual e a anterior; no Premium da pelada, todas.
- **Estatísticas básicas**: nunca são bloqueadas.
- **Versão especial individual**: não foi criada (é um possível benefício do futuro Min91 Pro). Nenhuma cobrança nova.

### Arquivos

- `app/src/lib/retro.ts`: cálculo da retrospectiva, com 5 consultas por temporada.
- `app/src/app/pelada/[id]/retrospectiva.tsx`: tela.
- `app/src/lib/arts.tsx`: `RetroPeladaArt`, `RetroRankingsArt`, `RetroPlayerArt`.
- `app/src/app/pelada/[id]/index.tsx`: botão.
- `app/src/app/_layout.tsx`: título da tela.
- `docs/evidencias_v3/retro_*.jpg`.

### Testes

| Teste | Resultado |
|---|---|
| tsc e lint | Limpos |
| Navegador, Pelada Teste (temporada 2026, 1 partida) | Os números batem com a partida real (4 gols, Bot 4 artilheiro, Rafa Craque, Bot 1 Bola Murcha só na tela). As três artes nos dois formatos cabem |
| Temporada com muitas partidas | **Não testado** (o dev só tem 1 partida finalizada). Por segurança, o 4:5 mostra no máximo 3 destaques |
| Temporada encerrada e temporadas antigas (Premium) | **Não testado** (o dev só tem 2026) |
| Celular | **Não testado** |

### Observações

- Empates no top 3 aparecem em ordem qualquer, sem marcar empate (ex.: três jogadores com 1 jogo). Dá para tratar se você quiser.
- Com poucos dados, a arte dos Stories fica com bastante espaço em branco embaixo.

---

## Minuto 91 — Fase 7: proposta do Min91 Pro (22/10/2026)

> **Só estudo, para aprovação.** Nada foi implementado. Nenhuma cobrança, produto na loja ou assinatura individual foi criada. Preços e taxas de terceiros devem ser conferidos na hora de decidir.

### 1. O que é

Uma assinatura **individual**, da pessoa, separada do Premium da pelada (que é coletivo e continua como está).

| | Premium da pelada (existe) | Min91 Pro (proposta) |
|---|---|---|
| De quem é | Da pelada | Da conta da pessoa |
| Quem compra | O admin daquela pelada | Qualquer jogador |
| Quem aproveita | Todos os membros daquela pelada | Só a própria pessoa, em qualquer pelada |
| Preço atual | R$ 29,90/mês por pelada | A definir (seção 6) |

**Regra de ouro**: o Pro **nunca** libera recursos coletivos de uma pelada. Temporada personalizada, nomes dos times, horário fixo, Bola Murcha desligável, mais assistentes, histórico completo da pelada e arte especial de rankings continuam sendo só do Premium da pelada. Assim, o Pro não canibaliza o Premium, e nenhum jogador consegue "liberar a pelada" pagando sozinho.

### 2. Benefícios possíveis (para você escolher)

Todos são pessoais e usam só dados que a pessoa já pode ver.

| Benefício | Custo de construir | Observação |
|---|---|---|
| Retrospectiva individual especial (mais telas e formatos, animação) | Médio | Já previsto na V3 como "possível benefício futuro" |
| Artes extras: modelos alternativos do Card e do pós-jogo, fundos especiais | Médio | Não muda o Card oficial (fórmula, categoria e moldura continuam iguais para todos) |
| Carreira completa **só do próprio jogador**, mesmo em pelada grátis | Baixo no código, **decisão de produto** | Hoje, pelada grátis mostra só a temporada atual e a anterior. Liberar o histórico pessoal pode reduzir o motivo para a pelada assinar o Premium. Recomendo **não incluir** no começo |
| Estatísticas pessoais avançadas (evolução do overall, comparação entre temporadas) | Médio | Só os números da própria pessoa |
| Selo "Pro" no perfil | Baixo | Cosmético; avaliar se não cria pressão social na pelada |

**Recomendação**: lançar o Pro com 2 ou 3 benefícios (retrospectiva especial, artes extras, estatísticas pessoais) e sem a carreira completa.

### 3. Arquitetura de dados

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

### 4. RevenueCat e lojas

- **No mesmo projeto do RevenueCat**:
  - entitlement `pelada_premium` (o atual, com o atributo `pelada_id` em cada compra);
  - entitlement `player_pro` (novo, sem atributo).
- **Produtos separados** nas lojas, por exemplo `min91_pro_mensal` e `min91_pro_anual`, num **grupo de assinatura diferente** do Premium da pelada. Na Apple, assinaturas do mesmo grupo se substituem; em grupos diferentes, convivem.
- **Webhook** (`revenuecat-webhook`): separa pelo `entitlement_id` (ou pelo produto). Eventos do Pro vão para uma nova função `apply_player_event`, que não toca nada de pelada. A função atual continua igual para o Premium da pelada.
- **Restaurar compras**: o comprador já é o id do usuário (`appUserID`), então a restauração devolve o Pro à mesma pessoa. Em outra conta do app, o RevenueCat manda TRANSFER e o Pro vai para a conta nova.
- **Cancelamento e reembolso**: mesma lógica da 026. Cancelar mantém o período pago; reembolso encerra na data da loja; eventos antigos não mudam nada.
- **Eventos hoje ignorados** (`SUBSCRIPTION_EXTENDED`, `REFUND_REVERSED`, `NON_RENEWING_PURCHASE`): tratar no Pro desde o início.

### 5. Transferência de conta e teste grátis

- **Transferência por código (024)**: o Pro **acompanha a pessoa**, como o teste grátis (031). Ao usar o código, `player_entitlements` passa para a conta nova, usando a mesma cadeia de contas (`private.account_lineage`). Na loja, a assinatura continua no Apple ID ou na conta Google; o app manda "Restaurar compras" na conta nova.
- **Exclusão de conta (021)**: o Pro não é cancelado pelo app (só a loja cancela). A tela de exclusão avisa: "cancele a assinatura na App Store/Google Play". Isso é exigência das lojas.
- **Teste grátis do Pro**: recomendo **7 dias**, 1 por pessoa (cadeia de contas), começando pela loja (oferta introdutória). Assim não é preciso controle próprio como na 031.

### 6. Proposta comercial

| Item | Proposta | Motivo |
|---|---|---|
| Preço mensal | R$ 7,90 a R$ 9,90 | Bem abaixo dos R$ 29,90 da pelada, para não competir; compra por impulso de um jogador |
| Preço anual | ≈ 10× o mensal (ex.: R$ 79,90) | Padrão de mercado ("2 meses grátis") |
| Teste | 7 dias | Suficiente para uma pelada semanal e uma retrospectiva |
| Quando lançar | Depois do Premium da pelada estar estável em produção | Uma assinatura de cada vez; aprender com a primeira |

- **Taxas da loja**: em geral 15% para assinaturas (Apple Small Business Program e Google). Conferir as regras vigentes.
- **RevenueCat**: tem faixa grátis até um teto de receita mensal; conferir antes.
- **Exemplo ilustrativo** (não é previsão): 1.000 jogadores Pro a R$ 9,90 ≈ R$ 9.900/mês bruto; menos 15% da loja ≈ R$ 8.400/mês.

### 7. Riscos

| Risco | Mitigação |
|---|---|
| Confundir "Premium da pelada" com "Pro" | Nomes e telas diferentes: "para a sua pelada" × "para você"; nunca vender o Pro na tela do Premium da pelada |
| Pro canibalizar o Premium da pelada | Regra de ouro (seção 1) e carreira completa fora do Pro |
| Pressão social ("só quem paga tem arte bonita") | Artes básicas continuam grátis e boas; o Pro é extra, não o mínimo |
| Vazamento entre os dois produtos | Tabelas e funções separadas + teste de invariante + casos novos no 026 |
| Duas assinaturas ao mesmo tempo (Pro + Premium da pelada) | Permitido por desenho (grupos diferentes); o teste confere que convivem |
| Revisão da Apple | Benefícios claros na tela de compra, link de termos e restaurar compras visível |
| Dados pessoais | Nenhum dado novo; o Pro só usa o que a pessoa já vê. Política: mencionar a assinatura individual |

### 8. Esforço estimado (se aprovado)

1. **Migração 033**: `player_entitlements`, `player_has_pro`, `get_my_entitlements`, `apply_player_event`, transferência na 024 (via nova função) e testes SQL (027 + invariantes).
2. **Webhook**: separar por entitlement.
3. **App**: tela "Min91 Pro" (em Minha conta), compra, restauração e os 2 ou 3 benefícios escolhidos.
4. **Lojas**: produtos e grupo de assinatura (precisa da conta Apple Developer e do development build).

Ordem sugerida: só depois do lançamento com o Premium da pelada funcionando em produção.

### 9. Decisões que preciso de você (quando for a hora)

1. Quais benefícios entram (seção 2).
2. Preço mensal e anual.
3. Teste grátis de 7 dias: sim ou não.
4. Selo "Pro" no perfil: sim ou não.
5. Carreira completa pessoal no Pro: confirmar que fica de fora.
