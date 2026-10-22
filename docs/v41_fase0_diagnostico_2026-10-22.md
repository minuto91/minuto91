# Minuto 91 — V4.1, Fase 0: diagnóstico da V3 (22/10/2026)

Base: commit `ebac632` (V3 homologada), árvore limpa. Nada foi alterado antes deste diagnóstico.

## 1. Verificações de base (executadas de verdade)

| Verificação | Resultado |
|---|---|
| `npx tsc --noEmit` | Limpo |
| `npx expo lint` | Limpo |
| Migrações 001 a 032 num Postgres local descartável (novo: `supabase/local_db`, PGlite) | As 34 aplicam sem erro, em ordem |
| Testes `supabase/tests_editor/001..026` no mesmo banco local | 24 passaram de primeira. 023 e 024 falharam por erro **do próprio teste** (ver 1.1). Corrigidos: 26 de 26 passam |

**Novidade da V4.1:** até a V3, os testes SQL só rodavam se o fundador colasse cada arquivo no SQL Editor.
Agora `supabase/local_db` sobe um Postgres em WebAssembly (PGlite) no próprio computador, aplica todas as
migrações e roda os mesmos arquivos de `tests_editor`. Não conecta ao Supabase. Limites: `auth` e `storage`
são simulados (`shim.sql`) e não há pg_cron. Não substitui rodar no Supabase dev antes do lançamento.

### 1.1 Testes que estavam errados (o banco estava certo)

- **023 (privacidade e carreira)**: esperava só 1 conquista (o Craque). O próprio roteiro do teste cria uma
  partida em jun/2025 com 1 gol; o fechamento do mês concede corretamente o **Artilheiro do mês**, que é
  conquista oficial (015). O teste passou a conferir "1 Craque, nenhuma Bola Murcha, nenhum prêmio anulado".
- **024 (teste grátis)**: esperava que a transferência de conta levasse 2 peladas, mas a conta 3 só participa
  de 1 no roteiro. A expectativa foi corrigida para 1.

O relatório da V2 lista esses dois testes como novos, mas não há registro de que tenham sido rodados no dev.

## 2. Tabela de diagnóstico

| Funcionalidade | Situação encontrada | Arquivos | Alteração necessária | Risco de regressão |
|---|---|---|---|---|
| Página da pelada | Tudo numa coluna só: botões grandes (Meu Card, Elenco, Rankings, Retrospectiva), pendências, destaques, 20 partidas, lista completa de jogadores com gestão, configurações. Não mostra temporada nem um resumo da última rodada. Sem estado vazio orientado | `app/src/app/pelada/[id]/index.tsx`, `lib/pending.tsx` | Virar a Central da Rodada (Fase 1). Partidas e lista de jogadores com gestão vão para telas próprias | Médio: gestão de assistente/sucessor muda de lugar (mesmas RPCs) |
| Pendências | `AdminPending` (rascunhos, votações abertas, poucos jogadores, sem sucessor) só para staff. Pendência pessoal (meu voto) só existe no início do app | `lib/pending.tsx`, `app/index.tsx` | Reaproveitar; acrescentar "Falta o seu voto" na Central | Baixo |
| Próxima rodada | Não existe agendamento de partidas. Existe só o dia/horário habitual (`peladas.recurring_weekday/time`), que o app nunca preenche | migração 004 | Não criar bloco de próxima partida. Registrar como evolução | Nenhum |
| Rankings | 6 métricas como chips iguais; lista só com "1º Nome valor" (sem foto, sem categoria); empates já em ranking de competição (1, 1, 3) no servidor; ordem entre empatados por id (instável para o usuário) | `pelada/[id]/rankings.tsx`, migração 015 | Reorganizar (Artilharia, Assistências, Overall em destaque; demais em "Mais"); foto/iniciais, categoria, desempate visual por nome. Sem tocar no cálculo | Baixo |
| Premiações | Todas as 6 existem no banco e são concedidas: Craque da Partida e Bola Murcha (013, votação); Rei do Mês, Artilheiro do mês, Garçom do mês e Maior evolução (015, fechamento do mês). Bola Murcha não conta como conquista (V2) | migrações 013, 015, 030; `lib/career.ts` | Nenhuma alteração. Ver seção 3 | — |
| Card do jogador | Card, atributos, temporada, posição, prêmios e um resumo em texto. Sem médias por partida, sem participações em gols, sem histórico | `jogador/[id]/index.tsx`, `lib/career.ts` | Fase 3: bloco de números e gráficos de evolução | Baixo (Card não muda) |
| Histórico do Card | **Já existe**: `card_snapshots` guarda os 5 atributos, overall, posição e categoria do Card a cada partida finalizada (014). Anulação recalcula o Card sem criar snapshot e deixa o snapshot da partida anulada no banco | migrações 014, 020 | Ler os snapshots só de partidas finalizadas, por RPC que respeita o acesso à temporada. Não precisa de armazenamento novo | Baixo |
| Convites | Token de 64 caracteres, só o hash fica no banco, 7 dias, 100 usos, revogação (sem botão no app), só o admin. Link `Linking.createURL` (no Expo Go vira `exp://...`, no app instalado `minuto91://...`, que o WhatsApp não deixa clicável). Depois de entrar, o app volta para o início em vez de abrir a pelada. Criar pelada não oferece convite. Tela de código não aceita o link colado | `pelada/[id]/index.tsx`, `convite/[token].tsx`, `entrar.tsx`, `criar-pelada.tsx`, migração 004 | Fase 4: tela de convite (WhatsApp, copiar, compartilhar, gerar novo), prévia do nome da pelada, abrir a pelada ao entrar, aceitar link colado, base pública configurável | Baixo |
| Notificações | Banco pronto (fila, deduplicação, limite de 3 de engajamento por semana, gatilhos). **Falha:** `claim_notifications` marca como `sent` antes de enviar; se o envio cair, o aviso se perde. Não há função de envio, nem `expo-notifications` no app, nem preferências | migração 022 | Fase 5: nova migração (reserva com prazo, tentativas, confirmação, recibos, preferências, checagem de acesso), Edge Function `push-sender`, registro no app | Médio (mexe na fila; nada em produção ainda) |
| Assinaturas | Premium por pelada (026), comprador = id do usuário, atributo `pelada_id`. Risco anotado na V3: mesmo Apple ID em duas peladas | `lib/purchases.ts`, webhook, 019/026 | Nenhuma alteração nesta versão (regra 12 e 13) | — |
| Privacidade/bloqueio | Bloqueio esconde perfil e foto nos dois sentidos (032); dentro da pelada estatísticas e Cards continuam visíveis (decisão V2) | 029, 030, 032 | Novas telas leem fotos só por `profiles` (RLS), como o resto do app | Baixo |
| Card em temporadas antigas | A tela do Card lê `player_cards` de qualquer temporada pela RLS (só exige ser membro); os Rankings exigem Premium para temporadas mais antigas que a anterior (RN-083) | `jogador/[id]/index.tsx`, 014, 015 | Não mexer agora (mudaria comportamento). Registrado para a auditoria da V4.2 | — |

## 3. Premiações: situação oficial

| Prêmio | Onde nasce | Regra no banco | Tela |
|---|---|---|---|
| Craque da Partida | 013, votação válida | Mais votos de Craque; empate compartilhado | Partida, destaques, Card, carreira |
| Bola Murcha | 013, votação válida (pode exigir Premium, 025) | Mais votos de Bola Murcha | Partida e destaques; **não** é conquista (V2) |
| Rei do Mês | 015, fechamento do mês | Melhor média de notas válidas, mínimo 3 jogos; desempate por Craques no mês; depois compartilhado | Rankings, Card, carreira |
| Artilheiro do mês | 015 | Mais gols no mês (mínimo 1), empate compartilhado | Rankings, Card, carreira |
| Garçom do mês | 015 | Mais assistências no mês (mínimo 1), empate compartilhado | Rankings, Card, carreira |
| Maior evolução | 015 | Maior ganho de overall no mês, mínimo 3 jogos, quem mudou de posição não concorre | Rankings, Card, carreira |

Conflito a registrar (não resolvido aqui): "Garçom da rodada" aparece nos destaques da pelada (015,
`garcom_round`), mas não é prêmio (não fica em `awards`). Está coerente com o banco; só precisa constar no Doc 02.

## 4. Plano de execução

Fases 1 a 7 na ordem pedida. Cada fase termina com tsc, lint e os testes SQL locais.
