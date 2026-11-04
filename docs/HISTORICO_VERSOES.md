# Histórico oficial de versões — Minuto 91

Só consta aqui o que está comprovado na documentação e no histórico do repositório (nomes de relatórios, `CHANGELOG.md`).
Onde não há detalhe, está escrito **histórico não detalhado**. Nada foi inferido.

**Identificação no código:** `app/src/lib/version.ts` (`APP_VERSION`, `APP_VERSION_LABEL`, `BUILD_NUMBER`) e `app/app.json`
(`version`, `ios.buildNumber`, `android.versionCode`). O teste `app/tests/version.test.ts` falha se os dois divergirem.
**Versão funcional** (ex.: V10.0 = `10.0.0`) é diferente do **número de build** das lojas (`BUILD_NUMBER`, hoje 1).

| Versão | Data comprovada | Fonte | Resumo comprovado |
|---|---|---|---|
| V3 | 22/10/2026 | `docs/relatorio_v3_*_2026-10-22.md` | Histórico não detalhado aqui (ver relatórios V3: etapa 1, fases 4–6, homologação) |
| V4.1 a V4.5 | 22/10/2026 | `docs/relatorio_v41…v45_2026-10-22.md` | Histórico não detalhado aqui (ver relatórios) |
| V4.6 | 23/10/2026 | `docs/relatorio_v46_2026-10-23.md` | Histórico não detalhado aqui |
| V5 | 23/10/2026 | `docs/relatorio_v5_2026-10-23.md` | Histórico não detalhado aqui |
| V6.1 | 24/10/2026 | `docs/relatorio_v61_2026-10-24.md` | Histórico não detalhado aqui |
| V7.7 | 24/10/2026 | `docs/relatorio_v77_2026-10-24.md`, `docs/v77/` | Integridade de votos, anulação/restauração, motor de referência |
| V8.0 (REV-001 a 050) | 26/10/2026 (registro) | `docs/ESPECIFICACAO_V8.0.md`, `docs/rev80/` | Especificação histórica das 50 primeiras revisões |
| V8.1 | 28/10/2026 | `CHANGELOG.md` | Auditoria, ciclo de vida da temporada, telas do ciclo |
| V8.2 | 28/10/2026 | `CHANGELOG.md`, `RELATORIO_V82.md` | Tela de login |
| V8.4 | 28/10/2026 | `CHANGELOG.md`, `V8.4_*` | Central do Jogador e padronização global |
| V8.6 | 29/10/2026 | `CHANGELOG.md`, `V8.6_*` | Paredão do Mês e Craque da Temporada |
| V8.7 | 29/10/2026 | `CHANGELOG.md`, `V8.7_*` | Artilheiro/Maestro da Temporada, Luva de Ouro, Meus Prêmios |
| V8.9 | 29/10 e 01/11/2026 | `CHANGELOG.md`, `V8.9_IMPLEMENTACAO.md` | Oficialização do motor V7.7 (DEF/LET-REF/APR/RES/DIS) |
| V9.1 | 01/11/2026 | `CHANGELOG.md`, `V9.1_IMPLEMENTACAO.md` | Revitalização visual e simplificação (só app) |
| **V10.0** | 04/11/2026 | `docs/V10.0_IMPLEMENTACAO.md` | Execução das REV-051 a REV-148 (ver registro) |

Versões V4.x, V6.x e V8.x intermediárias não listadas (V4.2…V4.5 individualmente, V8.5) existem apenas como relatórios
próprios: **histórico não detalhado** neste quadro.
