# Minuto 91 — Auditoria inicial e plano (21/10/2026)

Base: commit `95e219c` (main). Fontes: Documentação Completa (PRD v2.5.0, Doc 02 v3.1, Doc 03 v2.1, Doc 04 v1.1,
Brand Book v2.1), Termos v1.1, Política v1.2, `docs/contexto_proximo_chat.md`.
Nenhum arquivo do app ou do banco foi alterado nesta etapa.

Legenda de tipo: **DEF** defeito confirmado · **DOC** divergência documental · **RISCO** risco não reproduzido ·
**UX** melhoria de experiência · **NOVA** funcionalidade nova proposta.
Prioridade: **P0** bloqueia lançamento / perda de dinheiro ou dados · **P1** importante antes do lançamento ·
**P2** relevante · **P3** acabamento.

## 1. Verificações executadas (resultados reais)

| Verificação | Resultado |
|---|---|
| `npx tsc --noEmit` (app) | OK, sem erros |
| `npx expo lint` | OK, sem avisos |
| `npx expo-doctor` | 21/21 checks OK |
| `search_path` em funções `security definer` | Todas as funções definer das 25 migrações fixam `search_path = ''` |
| RLS nas tabelas | 35 `create table` e 35 `enable row level security` |
| Grants de `apply_subscription_event`, `claim_notifications`, `resolve_content_report` | Só `service_role` (correto) |
| Testes SQL (`supabase/tests_editor`) | **Não executados**: não há Postgres/psql/Docker nesta máquina. Rodam no SQL Editor do Supabase dev. |
| Builds Android/iOS, testes de componente | **Não executados**: sem conta Apple paga; o projeto não tem framework de testes de componente. |

## 2. Achados

### 2.1 Premium (seção 5.1 da missão)

| # | Tipo | P | Onde | Causa | Consequência |
|---|---|---|---|---|---|
| PR-1 | DEF | P0 | `app/src/app/premium.tsx:33-41` | `Purchases.purchasePackage` sem chamar `start_premium_purchase(p_pelada)` e sem escolher pelada | O webhook não acha comprador (`apply_subscription_event` devolve `unmatched`, 019:184-185): **o admin paga e a pelada não vira Premium** |
| PR-2 | DEF | P0 | `premium.tsx` + botão em `index.tsx:96` | Tela aberta a qualquer usuário, sem checar admin nem `premium_beta_open` | Com as chaves do RevenueCat configuradas, um jogador comum poderia ser cobrado durante o beta |
| PR-3 | DEF | P1 | `019_premium.sql:182-183, 204-206` | `EXPIRATION` marca o comprador como `expired`; a busca seguinte ignora `expired` | Evento de expiração atrasado (fora de ordem) + `RENEWAL` → renovação vira `unmatched`; **pelada perde o Premium pago** |
| PR-4 | RISCO | P1 | `019_premium.sql:197` | `premium_until = greatest(...)` nunca reduz | Reembolso/estorno pela loja mantém Premium até a data antiga |
| PR-5 | DEF | P1 | `019_premium.sql:159-164` | Comprador pode ter linhas `pending` em várias peladas; webhook escolhe a mais recente | Compra pode cair na pelada errada |
| PR-6 | DEF | P2 | `019_premium.sql:177-178, 214` | Evento `unmatched` é gravado com o `event_id` | Reenvio do RevenueCat volta `duplicate`: o evento nunca é reprocessado |
| PR-7 | DOC | P2 | `019_premium.sql:208-209` | `TRANSFER`, `BILLING_ISSUE`, `SUBSCRIPTION_EXTENDED`, `REFUND_REVERSED`, `NON_RENEWING_PURCHASE` ignorados | Restauração em outra conta (TRANSFER) não migra o vínculo; RF-012 exige restaurar compras |
| PR-8 | DEF | P2 | `premium.tsx:23` | `Purchases.configure` a cada montagem; não há `restorePurchases` nem `logIn/logOut` ao trocar de conta | Comprador errado após troca de conta; RF-012 (restaurar) ausente |
| PR-9 | UX | P2 | `pelada/[id]/premium.tsx` | Tela da pelada não tem fluxo de assinatura (só teste grátis) | Fluxo correto deve morar aqui, para o admin daquela pelada |

O que já está certo: webhook com segredo em tempo constante, filtro de ambiente, chave secreta só na Edge Function,
idempotência por `event_id`, travas de pelada/comprador, só o admin inicia, teste grátis 1x por pelada e por admin.

### 2.2 Tela de exemplo do Expo (5.2)

| # | Tipo | P | Onde | Achado |
|---|---|---|---|---|
| EX-1 | DEF | P2 | `app/src/app/explore.tsx` | Rota real (`minuto91://explore`), sem link no app, com conteúdo do template |
| EX-2 | DEF | P3 | `src/components/*` (app-tabs, themed-*, hint-row, collapsible, web-badge, animated-icon, external-link), `src/hooks/*`, `src/constants/theme.ts`, `assets/images/{react-logo*,expo-*,tutorial-web,tabIcons}`, `scripts/reset-project.js` | Só usados pelo template; código morto |

### 2.3 Fotografia (5.3)

| # | Tipo | P | Achado |
|---|---|---|---|
| FT-1 | DEF | P1 | Não existe bucket, política de Storage nem tela de foto. `profiles.avatar_path` nunca é usado pelo app. Política v1.2 §7 já promete foto. |
| FT-2 | RISCO | P1 | `002_profiles.sql:42` permite ao cliente gravar qualquer texto em `avatar_path` (sem validar dono/caminho). Precisa virar RPC antes de existir Storage. |
| FT-3 | DEF | P1 | Exclusão de conta (021) não prevê apagar o arquivo da foto (RN-102: Aposentado sem foto). |
| FT-4 | DOC | P2 | Política §7 fala em "configurações de visibilidade" da foto; não existem no app nem no PRD. |

### 2.4 Pé dominante (5.4)

| # | Tipo | P | Achado |
|---|---|---|---|
| PD-1 | DOC | P2 | Campo **não existe no PRD nem na Política**. Pedido nesta missão → precisa de nova migração e de atualização da Política (novo dado coletado). Não entra em fórmula. |

### 2.5 Posição (5.5)

| # | Tipo | P | Onde | Achado |
|---|---|---|---|---|
| PS-1 | DEF | P1 | `004_settings_invites.sql:133` | `set_my_position` existe e está correta (snapshot por partida em 008/009, carta usa a posição da última partida em 014), mas **não há tela** para o jogador trocar |
| PS-2 | DOC | P2 | RN-068 | Aviso "o overall pode mudar pela nova função" não aparece no app |
| PS-3 | DOC | P3 | `lib/theme.ts:19` | Rótulo "Meia"; a missão usa "Meio-campista" (docs usam meio-campista) |

### 2.6 Cartas (5.6)

| # | Tipo | P | Onde | Achado |
|---|---|---|---|---|
| CA-1 | DEF | P1 | `lib/arts.tsx:182` (`CardArt`) | Sem foto e sem identidade da pelada além do nome; Brand Book 6.2 prevê foto |
| CA-2 | UX | P2 | `CardArt` | Moldura só por cor da borda; redesenho com bronze/prata/ouro discretos |

Fórmulas, pesos e atributos FIN/GAR/PRE/PEQ/RES estão no banco (013/014) e **não serão tocados**.

### 2.7 Tela inicial (5.7) e Minha conta (5.8)

| # | Tipo | P | Onde | Achado |
|---|---|---|---|---|
| HM-1 | UX | P2 | `index.tsx:94-98` | Cinco botões empilhados (criar, entrar, conta, Premium, sair) competem com "Minhas peladas"; Premium geral aparece a todos |
| HM-2 | UX | P2 | `index.tsx` | Sem atividade real (última partida, votação aberta, resultado). Os dados existem (partidas/votação) |
| CT-1 | UX | P2 | `conta.tsx` | Mistura transferência, bloqueios e exclusão; **não há edição de nome/perfil**, nem links para Termos/Política, nem "Sair" (fica na tela inicial) |

### 2.8 Identidade visual

| # | Tipo | P | Achado |
|---|---|---|---|
| BR-1 | DOC | P3 | Fundo das telas `#F4F7FC` (`theme.ts:7`); Brand Book 5.1 pede fundo branco e cinza claro só em superfícies secundárias |
| BR-2 | DOC | P3 | Fonte Inter (Brand Book 4) não é carregada; usa a fonte do sistema. Adicioná-la exige `@expo-google-fonts/inter` (decisão sua) |

### 2.9 Supabase (amostra desta etapa)

Revisado com atenção: 002, 003, 004, 019, 020b, grants de 022/023, `search_path`, RLS por tabela.
Sem achado novo além dos acima. **Ainda não revisados linha a linha nesta etapa**: 005–018, 020–025
(votação, finalização, cartas, rankings, exclusão, transferência). Ficam na Fase 1, com testes adversariais novos.

### 2.10 Telas ainda não inspecionadas em detalhe
Partida, súmula, votação, rankings, álbum, configurações, convite, login/onboarding. Ficam na Fase 4
(o contexto registra que foram testadas pela web em 21/10).

## 3. Decisões que preciso de você

1. **Pé dominante**: guardar no perfil da conta (`profiles.dominant_foot`: direito/esquerdo/ambos), igual em todas
   as peladas. Motivo: é característica da pessoa, não da pelada. Exige atualizar a Política.
2. **Foto**: bucket **privado** `avatars`, arquivo `<id do usuário>/<aleatório>.jpg`, leitura só por quem divide pelada
   com o dono, exibição por URL temporária (assinada), gravação do caminho por RPC que valida o dono, remoção do arquivo
   antigo ao trocar e na exclusão da conta. Precisa de **2 dependências novas** do Expo: `expo-image-picker`
   (galeria + recorte quadrado nativo) e `expo-image-manipulator` (reduzir para ~800 px e comprimir).
3. **Vínculo compra↔pelada**: tirar a tela Premium geral; a compra passa a ser só em "Premium da pelada", pelo admin,
   bloqueada enquanto o beta estiver aberto. Antes de comprar: `start_premium_purchase` (que passa a cancelar outros
   pendentes do mesmo comprador) e o id da pelada vai como atributo do assinante no RevenueCat. Nova migração corrige
   PR-3 a PR-7. Os testes de loja real só rodam com development build (Apple Developer pago).

## 4. Plano por fases (cada item = commit pequeno, sem push sem sua confirmação)

**Fase 1 — Segurança e limpeza**
1. Migração `026_premium_fixes.sql`: PR-3, PR-5, PR-6, PR-7 (TRANSFER, BILLING_ISSUE), PR-4 (expiração/estorno só reduz
   quando o evento é o mais recente) + teste `tests_editor/019_premium_events.sql` (duplicado, fora de ordem, renovação,
   cancelamento, expiração, reativação, não-admin, compra em 2 peladas).
2. Remover `explore.tsx`, componentes/assets do template e a tela Premium geral (botão da tela inicial).
3. Revisão linha a linha de 005–018 e 020–025 com testes adversariais (outra pelada, não membro, não admin).

**Fase 2 — Perfil do jogador**
4. Migração `027_profile_photo_foot.sql`: bucket privado + políticas, RPC `set_my_avatar`/`clear_my_avatar`,
   `dominant_foot`, revogar update direto de `avatar_path`, limpeza do arquivo na exclusão.
5. Tela "Meu perfil" (foto, nome, pé) e "Meu perfil na pelada" (posição com aviso RN-068).

**Fase 3 — Cartas**: `CardArt` com foto, posição, overall proporcional, 5 atributos, temporada, pelada, moldura
bronze/prata/ouro discreta; imagem substituta (iniciais).

**Fase 4 — Experiência**: tela inicial (peladas + votação aberta/último resultado reais, perfil no topo, criar/entrar
discretos), Minha conta dividida (Perfil · Conta · Privacidade e Termos · Sair), fundo branco, estados de carregando/erro/vazio.

**Fase 5 — Premium no app**: assinatura na tela da pelada, restaurar compras, `logIn/logOut` no RevenueCat.

**Fase 6 — Homologação**: rodar `tests_editor` no SQL Editor (você), regressão pela web, passada no iPhone,
atualização dos docs (pé dominante, Seleção sem adaptação, foto).

## 5. Atualizações documentais necessárias
- Política v1.2: pé dominante (novo dado); detalhar foto (armazenamento privado, quem vê, remoção na exclusão);
  "configurações de visibilidade" (FT-4) — remover ou definir.
- PRD/Doc 03: campo `dominant_foot`; Premium só pela tela da pelada; eventos da loja tratados.
- Pendências já conhecidas: Seleção sem adaptação (Docs 02/03/04), retenção 30 dias e cédulas (advogado, PT-05).
Nada aqui é conclusão jurídica; validar com advogado.

## 5b. Fase 1 — resultado (21/10/2026)

Feito:
- `026_premium_store_events.sql`: PR-3 a PR-7 (detalhes no cabeçalho da migração). O app, na Fase 5, deve chamar
  `start_premium_purchase` e gravar o atributo `pelada_id` no RevenueCat (`Purchases.setAttributes`) antes de comprar.
  A Edge Function não precisou mudar (o evento inteiro, com `subscriber_attributes`, já chega ao banco).
- Testes novos: `019_premium_store_events.sql` (beta, não admin, anon, duas peladas, duplicado, fora de ordem,
  cobrança pendente, troca de admin, TRANSFER, reembolso, expiração, reativação, reprocessamento, atributo forjado)
  e `020_security_invariants.sql` (RLS em toda tabela pública, nenhuma escrita direta além de nome/foto do perfil,
  nada executável por anon, `search_path` em toda função definer, funções de serviço fora do app).
- Removidos: `explore.tsx`, `premium.tsx` (geral), componentes/hooks/imagens do template, script `reset-project`.
  Conferido pela web: `/explore` dá "rota não encontrada" e a tela inicial abre sem o botão Premium.

Revisão de autorização de 005–025 (políticas, grants e entrada de cada função pública):
- Toda função pública passa por um verificador (`lock_match_draft`, `lock_voter`, `lock_annullable_match`,
  `check_season_access`, `is_active_*`) ou é só de `service_role`. Cédulas sem grant; recibos expõem só quem votou.
- Nenhum defeito novo de autorização encontrado.
- RISCO P3: `player_season_stats` (média da temporada) é legível por quem não votou; comparando antes/depois de uma
  partida dá para estimar a nota daquela partida. Mudar exige decisão de produto (RN-098 só fala da arte).
- Não revisado nesta fase: a lógica esportiva (fórmulas, prêmios, figurinhas) linha a linha — já coberta pelos
  testes 009–013 e pela planilha aprovada; não foi alterada.

**Pendente de você**: aplicar a 026 no Supabase dev e rodar no SQL Editor `012_premium`, `019_premium_store_events`
e `020_security_invariants` (todos devem terminar com "PASS"). Eu não tenho acesso ao banco.

## 5c. Fases 2 e 3 — resultado (21/10/2026)

Fase 2 (migração 027, aplicada no dev; testes 020 e 021 com PASS):
- Foto: bucket privado `avatars`; app escolhe, recorta (nativo no celular, central na web), reduz a 800 px JPEG,
  envia, troca e remove; link assinado de 15 min, cache da CDN de 5 min; iniciais quando não há foto.
- Pé dominante no perfil da conta; nome editável (renomeia as participações ativas); posição por pelada na carta,
  com aviso da RN-068. Rótulo "Meio-campista".
- Conferido pela web com imagens geradas no navegador: 1200×900 → 800×800; troca apaga o arquivo antigo; remoção
  esvazia a pasta; 100×100 recusada com mensagem. O seletor de arquivos foi simulado (o navegador embutido não abre
  a janela de arquivos). **Não testado no celular** (recorte nativo e permissão de fotos do iOS).
- Edge Function `storage-cleanup`: escrita, **ainda não publicada** (o app já apaga a foto antiga na hora).

Fase 3 (`PlayerCard` em `lib/arts.tsx`):
- Carta com foto quadrada em destaque, overall compacto e sigla da posição no canto, selo da categoria, nome,
  posição, FIN/GAR/PRE/PEQ/RES, pelada e temporada no rodapé; moldura dupla fina bronze/prata/ouro e fundo suave no
  topo; sem brilho nem 3D. Mesma carta na tela e na arte 9:16.
- Conferido pela web: bronze com dados reais; prata e ouro simulando só a resposta na tela (nada gravado);
  arte exportada em 1080×1920 com a foto incluída. Fórmulas e pesos não foram tocados.

## 6. Funcionalidades novas (avaliação, nada será implementado sem aprovação)

| Proposta | Valor | Complexidade | Risco | Retenção | Compartilhamento | Plano |
|---|---|---|---|---|---|---|
| Prévia da arte antes de compartilhar | Alto | Baixa | Baixo | Médio | Alto | Grátis |
| Recordes pessoais | Alto | Baixa (dados em 015) | Baixo | Alto | Médio | Grátis (temporada atual/anterior) |
| Evolução visual de atributos | Alto | Média (snapshots RN-069) | Baixo | Alto | Médio | Grátis curto / Premium completo |
| Comparação de cartas | Médio | Baixa | Baixo | Médio | Alto | Grátis (RN-093) |
| Linha do tempo de conquistas | Médio | Média | Baixo | Alto | Médio | Premium (histórico completo) |
| Retrospectiva da temporada | Alto | Alta | Médio | Alto | Alto | Mensal grátis / anual Premium (RN-093/094) |
| Seleção da Rodada melhorada | Médio | Baixa | Baixo | Médio | Alto | Grátis |
| Personalização da pelada (escudo/imagem) | Médio | Média (Storage) | Médio (moderação) | Médio | Médio | Grátis (escudo); nomes dos times Premium |
