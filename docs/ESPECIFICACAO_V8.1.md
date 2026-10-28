# Especificação V8.1 — Sala de Troféus, branding e documentação permanente

Fontes: (1) prompt mestre V8.1 (28/10/2026); (2) `MIN91_Registro_Decisoes_Conversa_2026-10-26.md` (v1.0, "consolidado com lacunas").
Base: V8.0 (50 revisões). Motor matemático: **V7.7, intocável**. A V8.1 **complementa** a V8.0; só substitui regra com alteração expressa e comprovada.

Legenda de prova: **[C]** comprovada (texto recuperado) · **[P]** parcialmente recuperada · **[L]** lacuna (sem texto; não inferir).

## 1. Missão e restrições absolutas

Atualizar o código existente (sem reconstruir), com migrações incrementais, autorização no servidor, RLS e testes de regressão.

- **Matemática:** congelar fórmulas, pesos e OVR da V7.7; preservar calibração posicional V7.5 (diferença média aceita 3,22); sem curva LET V7.9; sem cálculo concorrente no frontend; nunca alterar valores para aprovar teste.
- **Regras existentes:** preservar votação, quórum, elegibilidade, publicação, histórico e alteração de votos, correção/restauração de súmulas, estatísticas, conquistas, rankings, permissões e demais decisões não substituídas expressamente.
- **Dados:** não apagar histórico; evitar duplicação, inconsistência, concessão prematura e reprocessamento não idempotente.
- **Escopo:** nenhuma funcionalidade/categoria/premiação extra; sem Etapa 46; sem Maior Evolução; a luva de goleiro da exploração visual não é categoria.
- **Decisões:** escolhas técnicas pequenas são permitidas; conflito relevante exige registro e esclarecimento; nunca inventar requisito.
- **Evidências:** não declarar implementação, teste ou recuperação documental sem comprovação.

## 2. Auditoria e classificação

Antes de editar: inspecionar arquitetura, componentes, banco, funções SQL, RLS, testes, assets e documentação (Sala de Troféus, Minha Carreira, figurinhas, rankings, notificações, compartilhamento, conquistas, temporadas, partidas, vínculos, apuração, correções, anulações, marca).
Classificar cada requisito: **implementado · parcial · ausente · conflitante · pendente de fonte**. Resultado: `MATRIZ_RASTREABILIDADE.md`.

## 3. As 45 etapas

Pertencem à auditoria da Sala de Troféus e **não são** as REV-001–050 da V8.0.

### 3.1 Escolhas históricas (letras — não são especificação)

| Etapas | Alternativas |
|---|---|
| 1–10 | C, B, B, B, B, B, B, B, B, B |
| 11–20 | B, B, B, B, B, B, B, B, B, B |
| 21–30 | C, B, B, B, B, C, C, B, C, B |
| 31–40 | A, A, A, B, B, B, B, B, B, B |
| 41–45 | B, B, B, B, B |

### 3.2 Conteúdo funcional

**Etapas 1–7 — Coleção e apresentação [P: bloco sem associação exata por etapa]**
Troféus premium com identidade própria · conquistas repetidas com contador e histórico · Sala global do jogador agregando peladas, com identificação e filtro por pelada · bloqueados em escala de cinza · hierarquia visual por relevância esportiva · catálogo controlado sem categorias automáticas · Seleção da Rodada integrada à coleção · Sala independente do Álbum de Figurinhas.

**Etapas 8–9 [L]:** conteúdo individual indisponível. **Etapas 16–19 [L]:** idem; preservar comportamento atual.

**Etapas 10–15 [P]** — Notificações pertinentes sem excesso · histórico detalhado conforme plano · identidade visual igual em troféus compartilhados · anonimização conforme exclusão definitiva de conta · reconfirmações em reaberturas e correções oficiais · competência mensal pela **data efetiva da partida** (nunca registro/edição/publicação).

**Etapas 20–29 [P]** — Visibilidade por perfil, vínculo e permissão · Bola Murcha privada por padrão · histórico de peladas encerradas preservado · correções oficiais auditáveis · conquista identificada pela pelada de origem, integrada à carreira global · elegibilidade histórica de ex-integrantes nos períodos válidos · celebrações individuais e acumuladas · compartilhamento 1:1 e 9:16 respeitando privacidade.

**Etapas 30–35 [P]** — Pendências de premiação tratadas no encerramento oficial · alterar datas só se compatível com a integridade das competições · todos os artilheiros elegíveis empatados reconhecidos; sem gols/partidas, sem vencedor inventado · sem Garçom da Partida histórico · prêmios mensais só após consolidação oficial · regras anteriores de correção/encerramento preservadas.

**Etapas 36–40 [P]** — Conquistas válidas preservadas após mudança de configuração · disputas e premiações pendentes respeitadas · elegibilidade por vínculo e período · saída da pelada não elimina histórico · avisos de pendência sem antecipar resultado · nada encerra ou premia por inatividade (exceções originais a conferir).

**Etapa 41 [C] Empates em rankings:** colocação compartilhada (1º, 1º, 3º); sem desempate artificial quando a regra reconhece empate.
**Etapa 42 [C] Movimentação:** subida/queda/estabilidade entre rankings oficiais consecutivos; **sem gráficos**.
**Etapa 43 [C] Temporada interrompida:** permanece em disputa; diferenciar suspensão formal de ausência recente de atividade; não encerrar por inatividade.
**Etapa 44 [C] Temporada cancelada:** preserva partidas, estatísticas, troféus válidos e histórico auditável; não concede títulos sazonais pendentes.
**Etapa 45 [C] Reativação excepcional:** reativação auditável de temporada cancelada mantendo identidade, partidas, estatísticas, conquistas e histórico; sem concessão automática de título sazonal, duplicação ou reprocessamento inconsistente.
**Etapa 46:** NÃO aprovada; não implementar.

### 3.3 Lacunas documentais

Recuperar textos originais das etapas 8–9, 16–19 e condições individuais incompletas das 20–40. Para cada lacuna: consultar documentação, código e testes; registrar fonte, conteúdo comprovado e pendência. Itens comprovados e independentes seguem sem bloquear o projeto; não declarar conclusão de etapa sem especificação.

## 4. Sete troféus oficiais (arquivos visuais oficiais; sem emoji/CSS/SVG/nova IA)

Detalhe em `TROFEUS_BRANDING.md`. Craque da Partida · Artilheiro da Temporada (chuteira + bola) · Artilheiro do Mês (chuteira **sem bola**) · Rei do Mês (coroa) · Garçom do Mês (mão **no centro da base**, bandeja e bola) · Seleção da Rodada (escudo, jogadores, louros) · Bola Murcha (desinflada, discreta, privada por padrão).
Fora do catálogo: Maior Evolução, Garçom da Partida/Rodada como troféu histórico, luva de goleiro.
**Conflito conhecido:** pedestal do Artilheiro do Mês (V8.0 "sem pedestal" × arte posterior com base) — não decidir unilateralmente.

## 5. Branding

Produto esportivo profissional; branco predominante, azul institucional, dourado; tipografia legível; componentes discretos; animações sutis. Evitar tema escuro como identidade, verde institucional, degradês/sombras excessivos, ícones inconsistentes, textos redundantes, aparência genérica de IA.
Logo: **somente o arquivo original** (ícone quadrado arredondado, azul degradê, "91" branco, faixa diagonal dourada, apóstrofo dourado). Aplicar em Sala de Troféus, Minha Carreira, conquistas, rankings, compartilhamentos, estados bloqueado/desbloqueado e navegação relacionada. Manter Central do Jogador única (Início, Peladas, Carreira, Perfil). Assets: PNG/WebP transparente, validados (fidelidade, resolução, enquadramento, proporção, peso, sem cortes).

## 6. Sala de Troféus e integridade

Integrada a Minha Carreira; Álbum separado. Conquistados e bloqueados, contadores e histórico, datas/períodos/temporadas, identificação e filtro por pelada, vínculos anteriores, compartilhamento autorizado, permanentes × destaques temporários. Prevenir: duplicidade, concessão prematura, partida cancelada na apuração, estatística inválida, perda de histórico, jogador errado, divergência com ranking, reprocessamento não idempotente, falha de permissão, inconsistência após saída/retorno. Correções só pelos fluxos oficiais, com auditoria; validação no servidor e RLS.

## 7. Documentação, testes e aceite

Documentação: ver `README.md`. Protocolo permanente: ler decisões → identificar precedência → preservar → implementar só o autorizado → testar → atualizar mestre, matriz e changelog → manter superadas. **Sem essas atualizações, nada é "concluído".**
Testes obrigatórios: conquistas · carreira · temporadas (interrupção, cancelamento, reativação) · integridade · segurança/RLS/privacidade da Bola Murcha · visual (responsivo, assets, transparência, logo) · regressão V7.7/V8.0 · documentação.
Execução obrigatória: diagnóstico → cobertura → docs → banco → regras → interface → branding → QA → docs finais → relatório.
**Aceite integral** exige: requisitos aplicáveis comprovados; 45 etapas documentadas sem lacuna preenchida; sete troféus integrados (com arquivos oficiais); logo/branding fiéis; Sala integrada à carreira; dados/segurança/V7.7/V8.0 preservados; testes registrados; docs completas; nenhuma decisão apagada; nada não aprovado adicionado. Itens comprovados podem ser entregues em separado.

**Princípio:** o usuário decide uma vez; o Minuto 91 registra, preserva, implementa e respeita essa decisão nas versões seguintes.
