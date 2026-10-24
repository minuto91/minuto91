# Minuto 91 — V6.0 Redesign — relatório (24/10/2026)

## 1. Resumo executivo
Primeira rodada da V6.0: Design System consolidado (tokens e 10 componentes compartilhados), ajuste obrigatório da
Central do Jogador (OVR só dentro da carta) e redesign das telas de maior uso: Minha Carreira, Central da Pelada,
lista e detalhe de partidas, votação, rankings, Perfil, Financeiro e Login. Nenhuma fórmula, regra de votação,
premiação, permissão, consulta ao banco ou migração foi alterada. **Não é o redesign completo de todas as 48 rotas**:
as telas da seção 6 (pendências) seguem com o visual V4.6, já compatível com os tokens.

## 2. Auditoria (matriz)

| Tela | Rota | Função | Problemas encontrados | V6.0 | Risco |
|---|---|---|---|---|---|
| Central do Jogador | `/(tabs)/index` | Início | OVR duplicado ao lado da carta; só o link final abria a Carreira | **Feito** | baixo |
| Minha Carreira | `/(tabs)/carreira` | carreira | cabeçalho sem OVR/categoria; cartões dentro de cartão; troféus e álbum misturados; histórico em caixas | **Feito** | baixo |
| Perfil | `/(tabs)/perfil` | perfil | repetia o resumo da carreira; ações em pilha de botões; sem "Sair" | **Feito** | baixo |
| Peladas | `/(tabs)/peladas` | lista | ok (V4.6) | pendente | — |
| Central da Pelada | `/pelada/[id]` | pelada | Group/Row/Scoreboard locais; administração misturada ao conteúdo | **Feito** | médio (navegação) |
| Partidas | `/pelada/[id]/partidas` | lista | estado só por cor; cartões com texto corrido; "Carregando..." solto | **Feito** | baixo |
| Partida | `/partida/[id]` | placar e resultado | placar como título de texto | **Feito (cabeçalho)** | baixo |
| Votação | `/partida/[id]/votar` | notas | trilho fino; progresso não distinguia pulados; card dentro de tela | **Feito** | baixo |
| Rankings | `/pelada/[id]/rankings` | classificação | pódio sem destaque; prêmios/recordes em cartões de texto | **Feito** | baixo |
| Financeiro | `/pelada/[id]/financeiro` | caixa | grade de atalhos + cartões; pendências em cartão | **Feito** | baixo |
| Login | `/login` | acesso | sem rótulos, sem marca, provedores sem separação | **Feito** | baixo |
| Súmula | `/partida/[id]/sumula` | admin | formulário longo, já com Stepper/Chips | pendente | alto (fluxo crítico) |
| Cobranças, Lançamentos, Mensalistas, Relatório | `/pelada/[id]/financeiro/*` | admin | ok (V4.3) | pendente | médio |
| Elenco, Jogadores, Escalações, Sorteio, Duelo, Temporadas, Retrospectiva | `/pelada/[id]/*` | pelada | consistentes com V4.6 | pendente | baixo |
| Configurações, Convidar, Premium | `/pelada/[id]/*` | admin | ok | pendente | médio |
| Card, Álbum, Atleta | `/jogador/[id]`, `/atleta/[id]` | carreira | carta oficial aprovada (não mexer) | preservado | — |
| Criar pelada, Entrar, Convite, Onboarding, Redefinir senha, Conta, Termos, Privacidade | raiz | secundárias | já usam os componentes base | pendente | baixo |
| Vitrines `dev-*` | raiz | só desenvolvimento | — | fora do escopo | — |

Inconsistências gerais encontradas: literais `#EEF2F8` e cores de sucesso/alerta repetidos; três `Stat`, dois `Row`
e um `Group` locais; estados de carregamento como texto "Carregando..." sem indicador; estado de partida só por cor.

## 3. O que mudou
- **Central do Jogador**: lateral da carta compacta agora traz nome, posição/categoria, variação desde a última publicação
  (ou "Sem publicação anterior"), jogos, gols e assistências. O OVR fica **só dentro da carta**. O bloco inteiro é um
  botão para Minha Carreira, com rótulo único para leitor de tela. Votação urgente, pendências e quatro abas inalteradas.
- **Minha Carreira**: faixa azul com foto, nome, posição, pelada, OVR e categoria (só quando a carta oficial existe);
  carta oficial em palco cinza; estatísticas sem cartão; "Conquistas" com Sala de Troféus e Álbum (lista por pelada)
  separados; histórico em lista única com selo Vitória/Empate/Derrota.
- **Central da Pelada**: cabeçalho com escudo 64 px e selo Premium; "Último resultado" com placar grande e selo de estado;
  ordem: rodada e elenco → partidas recentes → desempenho → histórico → **Administração** (Rodadas e resultados,
  Jogadores, Financeiro) → Pelada (Configurações, Premium, Sair). Mesmas condições de permissão de antes.
- **Partidas / Partida**: `Scoreboard` + `MatchStatusBadge`; lista em grupo único; estado vazio com próximo passo.
- **Votação**: nota em 52 px, trilho 10 px com marcas, polegar 32 px; progresso por jogador (confirmado azul, pulado com
  contorno dourado e contagem em texto); card do avaliado com gols e assistências em destaque. Mesmas RPCs e mesma ordem.
- **Rankings**: 1º/2º/3º com anel ouro/prata/bronze, foto maior e fundo dourado claro no 1º; prêmios e recordes em linhas.
  A posição continua vindo do servidor.
- **Perfil**: Dados pessoais, Dados esportivos, Preferências (notificações, privacidade) e Conta (Minha conta, Termos,
  Privacidade, Sair). Abas Carreira/Peladas/Conquistas/Cards/Privacidade mantidas. Sucesso e erro como `Notice`.
- **Financeiro**: pendências em faixa de alerta, atalhos em lista "Operação" com resumo dos mensalistas. Valores intocados.
- **Login**: marca, rótulos visíveis, autocompletar, separador "ou".

## 4. Arquivos modificados
`app/src/lib/theme.ts`, `app/src/lib/ui.tsx`, `app/src/lib/central.tsx`, `app/src/lib/ratingvote.tsx`,
`app/src/app/(tabs)/carreira.tsx`, `app/src/app/(tabs)/perfil.tsx`, `app/src/app/login.tsx`,
`app/src/app/partida/[id]/index.tsx`, `app/src/app/partida/[id]/votar.tsx`, `app/src/app/pelada/[id]/index.tsx`,
`app/src/app/pelada/[id]/partidas.tsx`, `app/src/app/pelada/[id]/rankings.tsx`, `app/src/app/pelada/[id]/financeiro/index.tsx`.
Novos: `docs/v6_design_system.md`, este relatório, `docs/evidencias_v6/`.

## 5. Testes

| Item | Situação |
|---|---|
| `npx tsc --noEmit` | **passou** |
| `npx expo lint` | **passou** (sem erros nem avisos) |
| Build web de produção (`npx expo export --platform web`) | **passou** |
| `node --experimental-strip-types --test tests/central.test.ts` | **18 de 18 passaram** |
| Capturas web (Chromium, 390 e 320 px): Login e Central (ovr-up, ovr-down, urgente, avaliação) | **feito**, 10 capturas em `docs/evidencias_v6/`, sem rolagem horizontal |
| Telas com dados reais (Carreira, Pelada, Partida, Votação, Rankings, Perfil, Financeiro) | **não verificado visualmente**: exigem login e o Supabase dev, indisponíveis neste ambiente |
| Navegação, permissões, formulários, integração e regressão dos fluxos críticos | **não executados** (sem banco/login) |
| iPhone/Android/tablet, leitor de tela | **não homologado em dispositivo real** |

Observação: `node --test tests/` (diretório) falha neste Node 22 por resolução do caminho; o arquivo direto passa.

## 6. Pendências
1. Redesign das telas marcadas "pendente" na matriz (súmula, telas do Financeiro, elenco, configurações, telas secundárias).
2. Roteiro manual no iPhone (`docs/roteiro_teste_iphone.md`) cobrindo as telas desta rodada, com atenção à Central da
   Pelada para admin, assistente e jogador.
3. Presença/data/local da rodada continuam inexistentes no produto (decisão de produto, sem mudança aqui).
4. Gráficos de evolução e Seleção da Rodada: componentes aprovados mantidos sem alteração.

## 7. Como conferir
`cd $HOME\Documents\minuto91\app; npx expo start --go --tunnel -c` → abrir as abas Início, Carreira e Perfil, e uma pelada.
Vitrine sem login: `http://localhost:8081/dev-central?s=ovr-up` (também `ovr-down`, `urgente`, `avaliacao`).
