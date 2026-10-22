# Minuto 91 — Relatório final da missão de auditoria e evolução (22/10/2026)

Período: 21 e 22/10/2026. Base: `95e219c` → `main` atual (13 commits, todos enviados ao GitHub).
Auditoria inicial, achados e resultados por fase: `docs/auditoria_inicial_2026-10-21.md` (seções 2, 5b, 5c e 5d).
Nenhum segredo neste documento.

## 1. Resumo

| Fase | Entregue | Verificado |
|---|---|---|
| 1 Segurança | Migração 026 (Premium/loja), remoção do template e da compra sem pelada, testes 019 e 020 | Testes 012, 019, 020 com PASS no Supabase dev |
| 2 Perfil | Migração 027 (foto privada, pé dominante, perfil só por RPC), Meu perfil, posição por pelada | Testes 020, 021 com PASS; foto testada na web |
| 3 Cartas | `PlayerCard` com foto, bronze/prata/ouro, arte 9:16 | Web (bronze real; prata/ouro simulados na tela); PNG 1080×1920 com a foto |
| 4 Experiência | Início, Minha conta, página da pelada, fundo branco | Web em 375 px com a conta do fundador |
| 5 Premium | Assinatura na tela da pelada, restaurar, gerenciar | Web: no beta não há compra. **Compra real não testada** |
| 6 Homologação | Regressão, bundles, varredura de segredos, este relatório | Ver seção 3 |

## 2. Arquivos

Novas migrações (aplicadas no dev): `026_premium_store_events.sql`, `027_profile_photo_foot.sql`.
Novos testes SQL: `019_premium_store_events`, `020_security_invariants`, `021_profile_photo_foot` (em `tests/` e
`tests_editor/`). Nova Edge Function: `supabase/functions/storage-cleanup` (não publicada).

App — novos: `src/app/perfil.tsx`, `src/lib/avatar.tsx`, `src/lib/purchases.ts`.
App — alterados: `_layout.tsx`, `index.tsx`, `conta.tsx`, `jogador/[id]/index.tsx`, `pelada/[id]/index.tsx`,
`pelada/[id]/premium.tsx`, `lib/arts.tsx`, `lib/career.ts`, `lib/errors.ts`, `lib/session.tsx`, `lib/theme.ts`,
`lib/ui.tsx`, `app.json` (permissão de fotos), `package.json` (+ `expo-image-picker`, `expo-image-manipulator`).
App — removidos: `explore.tsx`, `premium.tsx` (geral), `src/components/*`, `src/hooks/*`, `src/constants/theme.ts`,
`src/global.css`, imagens do template, `scripts/reset-project.js`.

## 3. Testes executados (resultados reais)

| Teste | Resultado |
|---|---|
| `npx tsc --noEmit` | OK |
| `npx expo lint` | OK |
| `npx expo-doctor` | 21/21 OK |
| `npx expo export` iOS e Android | OK (bundles de 5,1 MB e 5,4 MB) |
| Varredura de segredos nos bundles e no repositório | Só a chave publicável; nenhum `.env` versionado |
| SQL 012, 019, 020, 021 (SQL Editor do dev, pelo fundador) | PASS |
| Regressão web de 16 telas (início, perfil, conta, pelada, rankings, configurações, Premium, partida finalizada, partida anulada, súmula, votação, carta própria, carta de outro, álbum, criar pelada, entrar) | Todas abrem, sem erro no console, sem botão dentro de botão |
| Foto pela web (envio, recorte, troca, remoção, validação de tamanho) | OK (seletor de arquivo simulado) |
| Arte da carta exportada | 1080×1920 com a foto |

**Não executados**: SQL 001–018 nesta rodada (recomendo rodar todos de novo no dev, ver seção 6); builds nativos
(EAS) e testes em iPhone/Android; compra real; recorte nativo e permissão de fotos; push; testes de componente
(o projeto não tem framework de testes de componente).

## 4. Problemas ainda não resolvidos

| P | Item |
|---|---|
| P1 | Compra real, renovação, cancelamento, restauração e webhook nunca rodaram de ponta a ponta (dependem da seção 5). |
| P1 | Login com Apple obrigatório na App Store (o app oferece Google) — depende do Apple Developer. |
| P1 | Termos e Política não têm URL pública nem link no app (exigência das lojas). |
| P2 | Edge Function `storage-cleanup` não publicada (o app já apaga a foto antiga na hora). |
| P2 | Envio de push (Edge Function que lê `claim_notifications`) não existe. |
| P3 | Fonte Inter não carregada (usa a do sistema). |
| P3 | Quem não votou pode estimar a nota de uma partida pela diferença da média da temporada (decisão de produto). |
| P3 | Na web o recorte da foto é sempre central (no celular o usuário ajusta). |

## 5. Instruções de configuração e deploy

Supabase (projeto de produção, quando criar):
1. Rodar as migrações 001 → 027 em ordem (incluindo 008b e 020b) no SQL Editor.
2. Rodar os testes `tests_editor/001..021` num projeto descartável (nunca em produção).
3. Auth: ligar confirmação de e-mail; configurar Google e Apple; Redirect URLs do app.
4. `private.app_config.premium_beta_open = false` só no dia em que a cobrança começar.
5. Edge Functions (painel → Edge Functions, JWT desligado nas duas):
   - `revenuecat-webhook`: secrets `REVENUECAT_WEBHOOK_AUTH` (o mesmo valor do header no painel do RevenueCat)
     e `REVENUECAT_ENVIRONMENT=PRODUCTION`.
   - `storage-cleanup`: secret `STORAGE_CLEANUP_AUTH`; agendar em Integrations → Cron uma chamada POST por hora com o
     header `Authorization` igual a esse secret.

RevenueCat e lojas:
1. Produto mensal de R$ 29,90 na App Store Connect e no Google Play; entitlement e offering "current" com pacote
   mensal no RevenueCat.
2. Webhook do RevenueCat apontando para a função `revenuecat-webhook`, com o header de autorização.
3. No app (`app/.env`, não versionado): `EXPO_PUBLIC_REVENUECAT_IOS_KEY` e `EXPO_PUBLIC_REVENUECAT_ANDROID_KEY`
   (chaves públicas do SDK).

App: development build com EAS (precisa de Apple Developer; avisar antes por custo), depois TestFlight e teste
interno do Google Play.

## 6. Checklist de lançamento

- [ ] Rodar `tests_editor/001..021` no dev e confirmar PASS em todos.
- [ ] Apple Developer pago; `eas init`; development build iOS e Android.
- [ ] Passada completa no iPhone e num Android (roteiro `docs/roteiro_teste_iphone.md` + foto, carta, Premium).
- [ ] Login com Apple funcionando.
- [ ] Projeto Supabase de produção com migrações e configurações da seção 5.
- [ ] Produtos nas lojas, RevenueCat e webhook; uma compra de teste (sandbox) com renovação, cancelamento,
      expiração e restauração; conferir `subscription_events` e o estado da pelada.
- [ ] Publicar `storage-cleanup` e agendar.
- [ ] Termos e Política revisados por advogado, publicados em URL e linkados no app e nas lojas.
- [ ] Atualizar documentos (seção 7).
- [ ] Ícone e splash definitivos (hoje são os do Expo).
- [ ] `premium_beta_open = false` só quando a cobrança for liberada.

## 7. Divergências documentais a atualizar (PDFs)

- Política v1.2: pé dominante (novo dado, opcional, só informativo); foto em armazenamento privado, visível só para
  quem joga com o titular e não o bloqueou, removida ao trocar, remover ou excluir a conta; "configurações de
  visibilidade" citadas na seção 7 não existem (remover ou definir).
- PRD/Doc 03: campo `dominant_foot` em `profiles`; nome editável renomeia as participações ativas; compra Premium só
  pela tela da pelada; eventos da loja tratados (026).
- Pendências anteriores: Seleção sem adaptação (Docs 02/03/04); retenção de 30 dias e cédulas (advogado, PT-05).
Nada aqui é conclusão jurídica.

## 8. Funcionalidades novas recomendadas e roadmap

Avaliação completa na seção 6 da auditoria. Sugestão de ordem (todas precisam da sua aprovação antes):
1. **v1.1 (logo após o lançamento)**: prévia da arte antes de compartilhar; recordes pessoais; comparação de cartas
   (RN-093, grátis).
2. **v1.2**: evolução visual dos atributos (snapshots da RN-069); linha do tempo de conquistas (Premium).
3. **v1.3**: retrospectiva mensal (grátis) e anual (Premium); escudo/imagem da pelada com moderação.
Pendentes já conhecidos fora desta missão: tela de temporadas (Premium), nomes dos times (Premium), push.
