# Minuto 91 — V4.6, Fase 0: auditoria da V4.5, diagnóstico e plano

23/10/2026. Base: `minuto91_v45_2026-10-23.zip` + `docs/relatorio_v45_2026-10-22.md`.
Nada foi aplicado no Supabase (dev ou produção). Nada foi publicado.

## 1. Ambiente e base

| Item | Valor |
|---|---|
| Sistema | Windows 10 Pro 10.0.19045 |
| Node / npm | 24.20.0 / 11.19.0 |
| Expo SDK | 57.0.31 (React Native, Expo Router, React Compiler) |
| supabase-js | ^2.118.0 |
| Banco local | PGlite 0.5.11 (suíte SQL) e PostgreSQL 17 real via `embedded-postgres` (concorrência) |

**A base confere:** os 233 arquivos de `app/` e `supabase/` do ZIP são idênticos ao commit `3e29c52` (comparação
arquivo a arquivo, ignorando fim de linha). O relatório da V4.5 não foi tomado como evidência: tudo abaixo foi
rodado de novo hoje.

## 2. Testes reproduzidos (23/10)

| Teste | Resultado | Observação |
|---|---|---|
| TypeScript (`npx tsc --noEmit`) | PASS (0 erros) | antes e depois das correções |
| ESLint (`npx expo lint`) | PASS (0 avisos) | antes e depois das correções |
| Expo Doctor | PASS (21/21) | |
| Lógica (`node --test`) | PASS (29/29) | push, Storage, dinheiro, paginador, conferência da exportação |
| Suíte SQL local (`node run.mjs`) | **38/39 na V4.5** | `037_v44_finance_reports` falhou em "mesmo formato" (ver P1-A). Rodado de novo isolado: passou 2×. Intermitente. |
| Suíte SQL local com a 048 | PASS (40/40) | inclui o novo 040 |
| Exportação concorrente (`ONLY_EXPORT=1 node concurrency.mjs 20`) | PASS | PostgreSQL 17 real, 4.000 movimentações, 40 exportações durante escritas |
| Testes no Supabase dev | **PENDENTE** | precisa de você no SQL Editor (aplicar 048, rodar 020, 037, 039, 040) |
| Builds Android/iOS | **PENDENTE** | EAS custa e a conta Apple ainda não foi paga; não rodei |
| Desempenho (`perf.mjs`, ~15 min) | não repetido | números da V4.5 lidos, não reproduzidos |

## 3. Matriz de problemas encontrados

| ID | Gravidade | Arquivo / função | Evidência | Impacto | Correção | Teste |
|---|---|---|---|---|---|---|
| P1-A | P3 | `044_finance_performance.sql` / `private.finance_charges_json` | Suíte local 38/39: 037 "mesmo formato" falha às vezes. Pagamentos da cobrança ordenados só por (data, criação); pagamentos lançados na mesma transação empatam e a ordem depende do plano (1 id × lista de ids). | Lista de pagamentos de uma cobrança pode trocar linhas de lugar entre recarregar e salvar. Valores e totais não mudam. | Migração `048_v46_payment_order.sql`: id como último desempate (mesma regra do livro-caixa). | `040_v46_payment_order.sql` + 037 de novo |
| P1-B | P3 | `app/.../financeiro/relatorio.tsx` / `exportar` | Leitura do código: a chamada `get_finance_export` não tinha tempo limite; supabase-js não desiste sozinho. | Conexão muito lenta ou caída: botão preso em "Lendo..." sem saída. | Tempo limite de 60 s (`AbortController` + `.abortSignal`), mensagem clara, nada é gerado. | tsc/lint; teste manual pendente (precisa de login) |
| V-1 | Visual | `lib/playercard.tsx` | Rodapé mostra o nome da temporada ("Temporada 2026") e "MINUTO 91". | Pedido V4.6: só o ano. | Fase C (protótipo aprovado antes). | — |
| V-2 | Visual | `lib/arts.tsx` / `StickerArt` | Figurinha usa o caractere "★" como arte. | Contraria 6.1 (sem ícone genérico como arte final). | Fase C: nove ilustrações próprias. | — |
| V-3 | Visual | `lib/arts.tsx` | Textos inteiros em maiúsculas ("FIGURINHA CONQUISTADA", "CARD DA TEMPORADA"). | Contraria 2.3. | Fase B. | — |
| V-4 | Visual | todo o app | Sem família tipográfica própria (fonte do sistema); tamanhos espalhados nas telas. | Inconsistência entre telas. | Fase B: Inter (licença OFL, `@expo-google-fonts/inter`, funciona no Expo Go) + escala única. | — |
| D-1 | Decisão | `015_rankings_awards.sql` | Já existem "Garçom do mês" (`top_assist`: mínimo 1, empate divide) e o destaque "Garçom da rodada" (`garcom_round`, expira na partida seguinte, sem histórico). | A regra nova do Garçom do Mês (mínimo 2, desempates) conflita com a atual. | Ver perguntas (seção 6). | — |
| D-2 | Decisão | `007_matches.sql` | `matches` guarda só o nome dos times, não a cor. | Bordas por time na Seleção não têm de onde vir. | Proposta de banco (seção 5). | — |

Sem problema encontrado (auditado e mantido):

- **Exportação (047)**: `get_finance_export` e `private.finance_ledger` são STABLE, então linhas e totais saem do
  mesmo instantâneo; estorno/pagamento durante a exportação entra inteiro ou fica de fora. Limite de 20.000 com erro
  explícito (`FINANCE_EXPORT_TOO_LARGE` → "Exporte um período menor"). Medido na V4.5: 10.000 movimentações =
  572 ms e 2,9 MB; 20.000 ≈ 1,2 s e ≈ 6 MB, longe do limite de 8 s do Supabase. O app exporta um mês por vez; uma
  pelada de 100 jogadores gera ~300 movimentações/mês. **O limite não é problema operacional.** Se um dia for:
  gerar o CSV no servidor (Edge Function numa transação REPEATABLE READ, arquivo no Storage, link assinado) — não
  implementado, só proposto. Isolamento: `require_finance` (permissão + Pelada Premium) antes de tudo.
- **Paginação (`lib/pager.ts`, `usePaged`)**: usada em Cobranças e Lançamentos (e na vitrine). Geração por carga
  descarta respostas atrasadas; uma página a mais por vez; filtro novo limpa; itens repetidos filtrados por id;
  `dispose`/`cancel` na saída da tela. Trocar de pelada abre outra tela (outro paginador). Histórico do Relatório
  usa trava própria e remove repetidos. Os 29 testes de lógica cobrem pedidos simultâneos e respostas fora de ordem.
- **Segurança**: teste 020 (RLS em toda tabela, nada executável por `anon`, todo SECURITY DEFINER com `search_path`)
  passa local. Gatilho da 047 remove a permissão financeira quando a pessoa deixa de ser assistente (teste 039).
  Falta repetir no dev (seção 2).

## 4. Diagnóstico visual (resumo)

- Cores da marca já centralizadas em `lib/theme.ts`; faltam tipografia, raios, sombras e espaçamentos como tokens.
- Navegação é uma pilha única (sem abas). A Central do Jogador já é a tela inicial de todos.
- Página da pelada: muitos atalhos no mesmo nível; proposta de três grupos (Jogo, Desempenho, Gestão).
- Card: silhueta e acabamentos bons; rodapé muda para o ano.
- Troféus: três desenhos atuais preservados; Garçom é novo.
- Álbum: 48 figurinhas em 9 coleções corretas no banco (6+6+6+6+5+5+5+4+5); arte genérica.
- Seleção: campo existente não é o verde pedido; marcadores sem foto e sem cor de time.

Protótipos para aprovação (dados simulados): https://claude.ai/artifact/GWbHssTCVcu3EGK6fhmL4J

## 5. Proposta de banco para a cor dos times (não aplicada)

- `matches.team_a_color` e `matches.team_b_color` (texto, opcional, paleta fixa de ~8 cores com contraste testado
  sobre o verde), escolhidas na súmula; padrão nulo.
- A Seleção pega o time de cada jogador naquela partida (`match_participants`) e a cor do time; sem cor → borda
  branca. Nenhuma cor é inventada nem fica presa ao jogador.
- Migração nova (nada é editado), teste SQL e mudança só na súmula e na Seleção.

## 6. Decisões que preciso de você

1. **Garçom do Mês** (D-1): hoje existe `top_assist` com regra antiga. Recomendo: criar o prêmio novo
   (`monthly_garcom`, regra V4.6) como o único "Garçom do Mês" daqui em diante, recalcular os meses já fechados com
   a regra nova e parar de conceder `top_assist` (o histórico antigo fica guardado, não aparece mais).
2. **Garçom da Partida**: vira prêmio oficial com histórico (`match_garcom`), com a mesma regra do destaque atual.
3. **Cor dos times** (D-2): aprovar a proposta da seção 5.
4. **Protótipos**: aprovar ou pedir ajustes (Cards, troféus, álbum, Seleção, navegação com quatro abas).

## 7. Resultados depois das correções da Fase A

Rodado em 23/10, local (evidências em `docs/evidencias_v46/`):

- Suíte SQL (PGlite, 50 migrações): **40/40 PASS**, incluindo 037 e o novo 040.
- `node --test`: 29/29. tsc e lint limpos depois da mudança no Relatório.
- Exportação concorrente, PostgreSQL 17 real, 4.000 movimentações no mês, outra conexão pagando, estornando, editando,
  lançando e cancelando ao mesmo tempo:
  - V4.5 (`get_finance_export`, um instantâneo): **40 de 40 exportações íntegras**, p50 464–493 ms, p95 673–915 ms.
  - V4.4 (páginas), para comparação: 4 exportações aceitas com linha repetida e somas erradas; o resto recusado.
  - Controle (mesma função VOLATILE): 0 íntegras, como esperado — prova que o teste detecta o problema.
- Não verificado: tempo limite de 60 s da exportação no aparelho (precisa de login real com Pelada Premium e
  acesso ao Financeiro); tudo no Supabase dev.

## 8. Plano por fases

| Fase | Conteúdo | Depende de |
|---|---|---|
| A — Homologação técnica | 048 (ordem dos pagamentos), tempo limite da exportação, suíte local, concorrência; no dev: aplicar 048 e rodar 020/037/039/040 | você, no SQL Editor |
| B — Design System | tokens (tipografia Inter, escala, raios, sombras, espaçamento), Button (4 variantes), Card, Field, Tabs, Modal, Loading, Empty, Error, Confirm; tirar maiúsculas | — |
| C — Componentes esportivos | Card com o ano; Garçom no `TrophyArt`; nove ilustrações e seis acabamentos no álbum | aprovação dos protótipos |
| D — Seleção da Rodada | campo verde, marcadores com foto e borda do time, logo, imagem 9:16 | aprovação + decisão 3 |
| E — Premiações Garçom | migração (tipos `match_garcom`/`monthly_garcom`, apuração idempotente, reprocessamento, isolamento), Sala de Troféus com 5, notificações; testes SQL de regra e desempate | decisões 1 e 2 |
| F — Homologação final | suítes, concorrência, regressão visual das telas, checklist, relatório V4.6, ZIP | — |

Navegação com abas: só depois da validação visual do protótipo (mudança estrutural).
