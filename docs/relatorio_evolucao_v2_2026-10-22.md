# Minuto 91 — Relatório da Evolução V2 (22/10/2026)

Base: `cfd0b3c` (relatório final da auditoria). 8 commits locais na `main` (push aguardando confirmação).
Nenhum segredo neste documento. Nada aqui é conclusão jurídica.

## 1. Plano inicial e decisões tomadas

Levantamento antes de alterar:
- `peladas.crest_path` já existia (003), mas sem bucket nem validação: `update_pelada_profile` aceitava qualquer caminho.
- A carta só existe com ≥ 1 partida finalizada; a carta com menos de 5 jogos é provisória (oficial pelo Doc 02).
- A carreira por pelada (`player_career_stats`) é Premium (PRD seção 7, RN-083).
- O teste grátis já valia 1 por pelada e 1 por conta, mas **a transferência de conta (024) permitia um segundo teste**.
- Quem sai de uma pelada perdia a leitura da própria história nela (a RLS exige membro ativo).

Decisões do fundador (22/10):
1. Carreira global **respeita o plano de cada pelada**: Premium (ou beta) mostra tudo; pelada grátis mostra a temporada atual e a anterior, com aviso.
2. "Privado" esconde **só a área global** (pé, lista de peladas, conquistas de fora, carreira). Dentro da pelada, nome, foto, carta e estatísticas continuam visíveis.
3. Teste grátis: **registro + alerta para revisão manual**, sem bloqueio automático.

Decisões de padrão (mais simples, documentadas no código):
- A Bola Murcha não conta como conquista.
- O Elenco mostra só membros ativos com carta; a carta provisória vem marcada.
- O padrão de privacidade é "minhas peladas" para todos, que é exatamente o que já era visível antes (nenhuma exposição nova).
- Médias e sequências não são somadas entre peladas; aparecem só por temporada.

## 2. Funcionalidades implementadas

| Pilar | Entrega | Situação |
|---|---|---|
| Cartas | Fundo na cor da categoria, moldura que evolui (bronze simples, prata com filete, ouro com filete e ornamentos), brilho metálico discreto, foto maior, escudo, temporada, escala para cartas menores | **Concluído** (web) |
| Escudo | Bucket privado, envio/troca/remoção só do admin, escudo padrão com iniciais, no topo da pelada, nas configurações, nas cartas, no Elenco e na arte da carta | **Concluído** (web) |
| Meu Perfil | Seções Visão geral, Carreira, Peladas, Conquistas, Cartas, Privacidade; edição de foto, nome e pé dentro da Visão geral | **Concluído** (web) |
| Carreira | Total geral, por pelada, por temporada, conquistas oficiais; inclui peladas de que saiu; respeita o Premium | **Concluído** (SQL + web) |
| Privacidade | Perfil e carreira independentes (privado / minhas peladas / público), aplicadas no banco; aviso sobre imagens compartilhadas fora do app | **Concluído** (SQL + web) |
| Perfil de outro jogador | Nova tela, aberta pela carta do jogador na pelada | **Concluído** (web) |
| Elenco | Cartas ou lista, busca, filtro por posição, ordem por overall/nome, estado vazio, carregamento em blocos de 20 | **Concluído** (web, 6 jogadores) |
| Teste grátis | Teste segue a pessoa na transferência (inclusive em cadeia), trava por conta contra concorrência, registro de concessões com sinais para revisão | **Concluído** (SQL); concorrência real **não testada** |

Fora do escopo desta entrega: imagem de capa da pelada (`image_path`), escudo nas artes de resultado e Seleção (só a arte da carta tem escudo), retrospectiva, tela de temporadas.

## 3. Arquivos

Migrações (aplicadas no dev pelo fundador): `028_pelada_crest.sql`, `029_profile_privacy.sql`, `030_global_career.sql`, `031_trial_protection.sql`.
Testes SQL novos (em `tests/` e `tests_editor/`): `022_pelada_crest`, `023_privacy_career`, `024_trial_protection`.
Testes alterados: `021` (lê o pé por `get_my_profile`, porque a coluna não é mais lida direto), `020` (inclui as funções de serviço de fotos e escudos).
Edge Function alterada: `storage-cleanup` (também limpa `crests`).

App — novos: `src/lib/crest.tsx`, `src/lib/profile.tsx`, `src/app/atleta/[id].tsx`, `src/app/pelada/[id]/elenco.tsx`.
App — alterados: `_layout.tsx`, `perfil.tsx`, `jogador/[id]/index.tsx`, `pelada/[id]/index.tsx`, `pelada/[id]/configuracoes.tsx`,
`lib/arts.tsx`, `lib/avatar.tsx` (URL assinada genérica), `lib/career.ts` (cores das categorias), `lib/errors.ts`, `lib/session.tsx`
(onboarding por RPC, com leitura antiga se o banco ainda não tiver a 029), `lib/ui.tsx` (Chips com papel e estado para leitor de tela).

## 4. Segurança adicionada

- **Storage `crests`**: privado, PNG/JPEG até 1 MB, nome `<pelada>/<uuid>.png|jpg`; inserir/apagar só o admin ativo; ler só membros da pelada que aponta para aquele arquivo (e o admin).
- **RPCs** `set_pelada_crest`, `clear_pelada_crest` (admin, trava a pelada, auditoria); `update_pelada_profile` recusa trocar escudo/imagem.
- **profiles**: o app lê direto só `id`, `display_name`, `avatar_path`. Pé, consentimentos e privacidade só por `get_my_profile` (dono) e `get_player_profile` (outros, com a regra de visibilidade).
- **Visibilidade** (`private.can_view_global`): dono sempre; privado = ninguém; minhas peladas = pelada ativa em comum; público = qualquer autenticado. Bloqueio nos dois sentidos e conta transferida ou em exclusão escondem tudo. Não autenticado não executa nada.
- **Carreira** (`get_player_career`): só leitura das projeções oficiais (finalizadas, não anuladas); quem não pode ver recebe só `{"visible": false}`.
- **Teste grátis**: `private.account_lineage` (preenchida por trigger ao resgatar código, com back-fill), `private.premium_trial_grants` e a visão `private.trial_review` — nada disso é acessível ao app.

## 5. Testes executados (resultados reais)

| Teste | Resultado |
|---|---|
| `npx tsc --noEmit` e `npx expo lint` | OK (depois de cada etapa) |
| `npx expo-doctor` | 21/21 OK |
| `npx expo export` iOS e Android | OK (5,1 MB e 5,5 MB) |
| Varredura de segredos nos bundles e no repositório | Só a chave publicável; nenhum `.env` versionado |
| SQL `020`, `021`, `022`, `023`, `024` no SQL Editor do dev (pelo fundador, após aplicar 028–031) | **PASS** |
| Web 390 px, conta do fundador, Pelada Teste: Meu Perfil (6 seções), carreira com dados reais, privacidade (salvar privado e voltar ao padrão), Elenco (cartas, lista, busca, filtro), envio de escudo (imagem 600×400 recortada para quadrado), escudo no topo, na carta e no Elenco, perfil de outro jogador | OK, sem erro do app no console |
| Arte da carta exportada | 1080×1920, com escudo e fundo da categoria |
| Cartas prata e ouro, nome longo e sem foto | Vistas com **dados simulados** numa tela temporária (já removida); o dev só tem cartas bronze |

O que o teste 023 cobre (consulta direta, não só tela): titular, colega da mesma pelada, de outra pelada, sem pelada, bloqueado nos dois sentidos, não autenticado; perfil e carreira privados, restritos e públicos; mudança de privacidade; jogador sem partidas; várias peladas; temporada de 2024 escondida no grátis e mostrada no Premium; partida anulada fora dos totais; saída de pelada; conta em exclusão.
O 024 cobre: beta não consome o teste; uma vez por pelada e por conta; só o admin; renomear, expirar e trocar de admin não devolvem o teste; transferência simples e em cadeia; pelada recriada com o mesmo grupo (concede e marca); ninguém do app lê os registros.

**Não executados**: SQL `001`–`019` nesta rodada; chamadas simultâneas reais; builds nativos, iPhone e Android; recorte nativo do escudo; compra real; teste de carga com elenco grande (só a lógica de blocos de 20 foi conferida).

Procedimento para testar concorrência do teste grátis (opcional, no dev):
1. Crie duas peladas com a mesma conta de teste, com o beta desligado.
2. Num terminal com `psql`, abra duas sessões, ponha `set role authenticated` e `set request.jwt.claim.sub` com o id da conta, e rode `begin; select public.start_premium_trial('<pelada 1>');` numa e o mesmo com a pelada 2 na outra, sem `commit`.
3. A segunda fica esperando a primeira; dê `commit` na primeira. A segunda deve responder `TRIAL_ALREADY_USED`.
4. Ligue o beta de novo.

## 6. Problemas não resolvidos

| P | Item |
|---|---|
| P1 | Pendências anteriores continuam: compra real, login com Apple, Termos/Política sem URL (relatório de 22/10, seção 4). |
| P2 | Sem perfil visível, o botão "Ver perfil e carreira" não aparece mesmo se a carreira for pública (caso raro). |
| P2 | Escudo ainda não aparece nas artes de resultado e da Seleção. |
| P2 | `storage-cleanup` (agora também para escudos) ainda não publicada. |
| P3 | Na web o recorte do escudo é sempre central (no celular o admin ajusta). |
| P3 | A média de nota por temporada aparece na carreira, como já aparecia na carta para os colegas (ver P3 anterior sobre estimar notas). |

## 7. Pendências de configuração
- Publicar `storage-cleanup` com `STORAGE_CLEANUP_AUTH` e agendar (painel → Edge Functions; Integrations → Cron).
- Revisar de tempos em tempos `select * from private.trial_review;` no SQL Editor e marcar `reviewed_at` / `review_note`.

## 8. Melhorias futuras recomendadas
Escudo nas artes de resultado e Seleção; busca global de jogadores para perfis públicos (só se fizer sentido para o produto);
virtualização do Elenco para 100 cartas; evolução do overall na carreira (snapshots da RN-069).

## 9. Instruções de deploy (produção)
Seguir o relatório de 22/10 (seção 5), agora com as migrações **001 → 031** (incluindo 008b e 020b) e os testes `001..024`
num projeto descartável. A ordem importa: o app novo funciona com o banco antigo (só não mostra perfil e carreira),
mas **um app anterior a esta versão quebra depois da 029** (ele lia direto colunas que agora só saem por RPC: o
onboarding voltaria a aparecer e a carta perderia a foto). Hoje não há app publicado, então não há risco; depois do
lançamento, mudanças assim precisam de uma fase de transição.

## 10. Checklist de validação
- [x] Cartas com fundo e moldura da categoria, evoluindo de bronze a ouro.
- [x] Escudo nas cartas e gerenciado pelo admin.
- [x] Perfil independente das cartas.
- [x] Carreira consolidando as peladas, consistente com os dados (SQL 023).
- [x] Privacidade no backend (SQL 023, consultas diretas).
- [x] Elenco só com cartas oficiais; quem não tem carta continua nas áreas da pelada.
- [x] Teste grátis protegido contra reutilização (SQL 024).
- [ ] Rodar `001..019` de novo no dev.
- [ ] Concorrência real do teste grátis (procedimento acima).
- [ ] iPhone e Android (development build).
- [ ] Atualizar PDFs: Política (visibilidade configurável, escudo, aviso de compartilhamento externo), PRD/Doc 03 (perfil, carreira, Elenco, `profile_visibility`, `career_visibility`, registro de testes).
