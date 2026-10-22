# Minuto 91 — V3, Fase 8: homologação final (22/10/2026)

Resumo das fases e relatórios:

- [Etapa 1: segurança, termos, Card, escudo](relatorio_v3_etapa1_2026-10-22.md)
- [Fase 4: várias peladas e Premium isolado](relatorio_v3_fase4_2026-10-22.md)
- [Fase 5: artes](relatorio_v3_fase5_2026-10-22.md)
- [Fase 6: retrospectiva](relatorio_v3_fase6_2026-10-22.md)
- O painel de pendências do admin foi entregue entre as fases 4 e 5.
- A proposta do Min91 Pro está na seção 10 do relatório da etapa 1 (Fase 7 detalhada ainda não feita).

## 1. Verificações executadas (de verdade, nesta data)

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

## 2. Cobertura dos testes pedidos na V3

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

## 3. Checklist de homologação (para você)

1. [ ] iPhone: seção 14 do roteiro (Card, escudo, pendências, artes, retrospectiva).
2. [ ] iPhone: seções 9 a 13 de novo (súmula, votação, resultado), porque a tela da partida mudou.
3. [ ] Segunda conta (você cria): bloqueio, excluir/recuperar, código de transferência.
4. [ ] SQL Editor do dev: rodar `tests_editor/001` a `024` de novo (cada um deve terminar com "PASS").
5. [ ] Publicar a função `storage-cleanup` (fotos e escudos órfãos), pendente desde a V2.

## 4. Pendências externas (antes do lançamento)

- **Apple Developer (US$ 99/ano)** e development build. Login com Apple, push e RevenueCat dependem disso.
- **RevenueCat sandbox**: testar o mesmo Apple ID assinando duas peladas em sequência (risco anotado na Fase 4).
- **Documentos**:
  - Doc 02: bloqueio nos dois sentidos (RN-120) e Seleção sem adaptação (RN-075).
  - Doc 03: política de perfis.
  - Brand Book: termo "Card" e o Modelo A.
  - Política/Termos: imagens compartilhadas fora do app, retrospectiva.
- **Advogado**: 30 dias de recuperação, retenção do Aposentado e das cédulas, registro do teste grátis.
- **Produção**: projeto Supabase de produção, ligar a confirmação de e-mail, `premium_beta_open=false`, produtos nas lojas, TestFlight.

## 5. ZIP

ZIP atualizado gerado com `git archive` em `entregas/minuto91_v3_2026-10-22.zip`. Não vai para o GitHub: a pasta está no `.gitignore`.
