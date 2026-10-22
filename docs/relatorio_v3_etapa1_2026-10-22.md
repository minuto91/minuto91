# Minuto 91 — Evolução V3, etapa 1 (22/10/2026)

Escopo desta etapa: Fase 1 (segurança, carreira, termos), Fase 2 (Card definitivo, Modelo A) e Fase 3 (escudo transparente).
As Fases 4 a 8 estão planejadas na seção 9 e ainda não foram feitas.

## 1. Diagnóstico inicial

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

## 2. Problemas corrigidos

1. **Bloqueio nos dois sentidos**: migração `032_block_both_ways.sql`. Dentro da pelada, o apelido do membro, a súmula, as estatísticas, os rankings e os Cards continuam aparecendo (não dependem da linha do perfil).
2. **Total parcial da carreira**: quando falta temporada, o título vira "Total nas temporadas disponíveis", com um aviso explicando o motivo; cada pelada afetada também ganha o rótulo.
3. **Terminologia**: "Card/Cards" em todos os textos visíveis (com concordância: "o Card", "provisório"). Tabelas, colunas e funções internas não foram renomeadas.
4. **Escudo**: sem recorte; só reduz o lado maior para até 512 px, mantendo a proporção. PNG e WEBP saem sempre em PNG (com transparência). Se passar de 1 MB, tenta 384 e 256 px, sem nunca virar JPEG. Só JPG e HEIC (que não têm transparência) saem em JPEG.
5. **Escudo nas artes** de resultado e da Seleção, com a proporção calculada à mão (a exportação fica igual à tela).

## 3. Funcionalidades desenvolvidas

- **Card definitivo, Modelo A** (`app/src/lib/playercard.tsx`):
  - Uma única silhueta em vetor (SVG), em código: topo com vértice central, laterais retas, base pontiaguda, cantos arredondados.
  - Mesmo layout nas três categorias. Bronze: contorno simples. Prata: contorno duplo com filete e recortes laterais. Ouro: moldura em camadas (dois filetes), chevron e pedra no topo, barras laterais em relevo.
  - Foto como protagonista, que se mistura ao metal no topo e ao painel escuro embaixo. Overall e posição no alto à esquerda; escudo transparente à direita; nome; FIN, GAR, PRE, PEQ e RES; temporada e "MINUTO 91" na ponta.
  - Sem foto: as iniciais. "Provisório" discreto abaixo da posição.
  - O mesmo componente atende Elenco (pequeno, sem rodapé), Perfil, tela do Card e exportação.
- **Prévia do escudo antes de salvar** (configurações da pelada): o escudo sobre os Cards bronze, prata e ouro e no cabeçalho da pelada. Aviso quando a imagem não tem transparência (JPG/HEIC sempre; PNG conferido na web; no celular não dá para saber sem biblioteca extra).
- **Vitrine de Cards** (`/dev-cards`): só em desenvolvimento, abre sem login, com valores de exemplo. Mostra as três categorias lado a lado, os casos difíceis, o tamanho do Elenco e um teste da exportação 1080 × 1920.

## 4. Arquivos alterados

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

## 5. Migrações novas e implantação

- **032_block_both_ways**: troca só a política `profiles_read_peers`. Nenhuma migração aplicada foi editada.
- **Versões antigas do app**: leem só `id, display_name, avatar_path` (desde a 029). Uma linha escondida é o mesmo caso que já tratam do lado de quem bloqueou (caem no apelido e nas iniciais). Sem quebra.
- **028 a 031**: dependências conferidas (`shares_pelada` 003, `is_active_admin` 003, `user_blocks` 023, `pelada_has_premium` 019, `account_deletion_requests` 021). A 032 depende de `blocked_either_way` e `can_view_global` (029).
- **Rollback**: recriar a política da 029 (não recomendado, reabre a falha).

## 6. Testes executados (de verdade)

| Teste | Resultado |
|---|---|
| `npx tsc --noEmit` | Limpo |
| `npx expo lint` | Limpo |
| `npx expo-doctor` | 21/21 ok |
| Visual no navegador (web): três categorias, sem foto, nome longo, provisório, escudos redondo/triangular/tradicional/irregular, tamanho do Elenco, prévia do escudo | Ok, após 3 correções (atributos das pontas encostavam na moldura; foto vazava 1–2 px na lateral; brilho aparecia sobre o painel escuro) |
| Exportação 1080 × 1920 (mesma captura do compartilhar) | Ok após corrigir o escudo esticado; a imagem gerada corresponde à tela |
| SQL `025_blocks_both_ways` e `016` atualizado | **Não executados**: precisam da 032 aplicada no dev pelo SQL Editor |
| Celular (Expo Go) | **Não testado** nesta etapa |
| Upload real de escudo | **Não testado** (precisa do login de admin) |

## 7. Problemas ainda existentes

- Na web, o nome longo é cortado com reticências (o ajuste automático de fonte só funciona no celular).
- A prévia não detecta transparência de PNG no celular. Remoção de fundo foi só estudada: as opções estáveis são serviço pago (remove.bg e afins) ou modelo no aparelho (precisa de development build). Não foi implementado, como pedido.
- **Premiações a confirmar**: o banco tem `top_scorer` (Artilheiro do mês), `top_assist` (Garçom do mês) e `most_improved` (Maior Evolução), vindos do Doc 02 (prêmios do mês, migração 015), além dos três confirmados (Craque da Partida, Rei do Mês, Bola Murcha). Nada foi apagado nem renomeado. Preciso da sua decisão.
- Artes 4:5, arte pós-jogo individual, retrospectivas e jornadas multi-pelada ainda não foram feitas (seção 9).

## 8. Checklist de homologação (esta etapa)

1. SQL Editor do dev: colar e rodar `supabase/migrations/032_block_both_ways.sql`.
2. Rodar `supabase/tests_editor/025_blocks_both_ways.sql` e o `016`: os dois devem terminar com "PASS".
3. Web: abrir `http://localhost:8081/dev-cards` e conferir as três categorias.
4. Celular (Expo Go): abrir um Card seu, o Elenco e "Compartilhar meu Card".
5. Configurações da pelada (admin): enviar um PNG transparente redondo, conferir a prévia e salvar; enviar um JPG e ver o aviso.
6. Partida finalizada: "Compartilhar resultado" com o escudo no topo.

## 9. Próximas etapas (plano das Fases 4 a 8)

1. **Multi-peladas e Premium isolado**: auditar RPCs, políticas e o webhook com um usuário admin de duas peladas (uma Premium e uma grátis). Criar teste SQL `026`.
2. **Jornada do admin**: painel de pendências por pelada dentro da tela da pelada (súmula em rascunho, votação para encerrar, correções), sem mudar o início.
3. **Artes**: sistema reutilizável 9:16 e 4:5, arte da partida e arte pós-jogo individual (gols, assistências, nota só se autorizada, Craque), com aviso de que a imagem compartilhada fica fora do app.
4. **Retrospectiva** da pelada e individual (básica grátis; especial no Premium da pelada; individual sem cobrança).
5. **Min91 Pro**: proposta na seção 10.

## 10. Proposta Min91 Pro (só estudo, nada ativado)

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

## 11. Pendências externas

- Aplicar a 032 no dev e rodar os testes 025 e 016 (você, no SQL Editor).
- Decidir sobre Artilheiro do mês, Garçom do mês e Maior Evolução.
- Atualizar os documentos oficiais:
  - Doc 02 (bloqueio nos dois sentidos, RN-120).
  - Doc 03 (política de perfis).
  - Brand Book (termo "Card" e o Modelo A).
- Push dos commits (aguarda sua confirmação).
