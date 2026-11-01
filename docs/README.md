# Minuto 91 — Documentação permanente

Criada na V8.1 (28/10/2026). **Este é o ponto de partida de qualquer alteração futura.** Os documentos antigos
(`docs/v77/`, `docs/rev80/`, relatórios `relatorio_*`, PDFs) foram preservados e continuam valendo como fonte histórica.

## Versões

| Versão | Escopo | Estado |
|---|---|---|
| V7.7 | Motor de notas congelado, votação, anulação, Seleção 4-3-3 | Entregue (`docs/v77/`) |
| V8.0 | 50 revisões REV-001–050 | Entregue, REV-024/025 bloqueadas (`docs/rev80/`) |
| V8.1 | 45 etapas da Sala de Troféus, sete troféus, branding, documentação permanente | **Em andamento — ver CHANGELOG** |
| V8.4 | Central do Jogador (E01–E16) + padronização global | Entrega A com pendências; Entrega B parcial (`V8.4_*.md`) |
| V8.5 | Sorteio, escalação oficial, partidas, súmula, Central e avisos | Entregue (`V8.5_*.md`) |
| V8.6 | Paredão do Mês e Craque da Temporada | Parcial, com bloqueios fail-closed (`V8.6_*.md`) |
| V8.7 | Artilheiro da Temporada, Maestro da Temporada, Luva de Ouro, Meus Prêmios (32 decisões) | Implementada localmente; ver `V8.7_IMPLEMENTACAO.md` e `V8.7_MATRIZ_RASTREABILIDADE.md` |
| V8.8 | 11 troféus 3D (citada na V8.9) | **Não existe no repositório** |
| V8.9 | Motor V7.7 oficial (DEF, LET/REF, APR, RES, DIS) em todo o histórico; Resenha na votação | Aplicada no Supabase dev em 01/11/2026 (`V8.9_IMPLEMENTACAO.md`) |

## Documentos

| Arquivo | Para quê |
|---|---|
| `DECISOES_MESTRE.md` | Registro permanente de decisões (ID, versão, status, fonte, precedência). Nunca se apaga; substituição vira "superada". |
| `ESPECIFICACAO_V8.0.md` | As 50 revisões REV-001–050. **Texto original ausente do repositório**: ver aviso no arquivo. |
| `ESPECIFICACAO_V8.1.md` | Especificação da V8.1: escopo, restrições, 45 escolhas, regras comprovadas, aceite, lacunas. |
| `TROFEUS_BRANDING.md` | Sete troféus, logo, paleta, restrições visuais e arquivos oficiais pendentes. |
| `MATRIZ_RASTREABILIDADE.md` | Cada etapa/requisito: fonte, arquivos, testes, resultado. |
| `CHANGELOG.md` | Só trabalho efetivamente feito, por versão. |
| `V8.7_DECISOES_COMPLETAS.md` | Anexo normativo da V8.7, integral (32 decisões). |
| `V8.7_IMPLEMENTACAO.md` | Auditoria, divergências, ADR, limitação da REF móvel, testes, rollback e pendências da V8.7. |
| `V8.7_MATRIZ_RASTREABILIDADE.md` | Cada ID da V8.7 → código → teste → status. |
| `CHECKLIST_LANCAMENTO.md` | O que depende do fundador para o beta e o lançamento (contas, lojas, Supabase de produção, jurídico, arte), com o próximo passo de cada item. |

## Ordem de leitura

1. `DECISOES_MESTRE.md` (regras vigentes e o que foi superado)
2. `ESPECIFICACAO_V8.1.md` → `ESPECIFICACAO_V8.0.md`
3. `TROFEUS_BRANDING.md` (se tocar em troféus, logo ou telas de carreira)
4. `MATRIZ_RASTREABILIDADE.md` (estado real, lacunas)
5. `CHANGELOG.md`

## Fonte principal e precedência

1. Decisão **expressa e posterior** do fundador (registrada em `DECISOES_MESTRE.md`) vence a anterior.
2. Sem substituição expressa, a regra anterior continua valendo (a V8.1 complementa a V8.0; a V8.0, a V7.7).
3. Em conflito entre código e documento: não decidir sozinho; registrar em `DECISOES_MESTRE.md` como pendente e perguntar.
4. As letras das 45 escolhas (A/B/C) são registro histórico, **nunca** especificação.
5. Fonte da governança: `MIN91_Registro_Decisoes_Conversa_2026-10-26.md` (arquivo do fundador; não está no repositório).
   O nome sugerido ali (`MIN91_DECISOES_MESTRE.md`) corresponde a `docs/DECISOES_MESTRE.md`.

## Como atualizar (a cada alteração)

1. Ler as decisões pertinentes; identificar dependências, precedência e conflitos.
2. Implementar só o autorizado; preservar o que não foi substituído (motor V7.7 intocável).
3. Rodar os testes (`supabase/local_db`: `node run.mjs`; `app`: `npm run check`).
4. Atualizar `DECISOES_MESTRE.md`, `MATRIZ_RASTREABILIDADE.md` e `CHANGELOG.md` **na mesma entrega**.
5. Marcar "implementada" somente com código **e** teste executado. Aprovação não equivale a implementação.
