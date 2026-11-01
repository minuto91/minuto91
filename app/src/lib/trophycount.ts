// Total de troféus de uma carreira (função pura, testada em tests/v87.test.ts). V8.7 soma os três prêmios de temporada novos.
// BETA-02: `hidden` = tipos que a Sala não mostra (escopo core, ver lib/scope.ts); o total só soma o que a pessoa vê.
import type { TrophyCounts } from './trophies';

export const trophyTotal = (t: TrophyCounts | null | undefined, hidden: readonly string[] = []) => {
  if (!t) return 0;
  const n = (k: string, v: number | undefined) => (hidden.includes(k) ? 0 : (v ?? 0));
  return t.match_craque + t.monthly_king + t.bola_murcha + n('monthly_garcom', t.monthly_garcom) + n('monthly_goalkeeper', t.monthly_goalkeeper) +
    n('season_craque', t.season_craque) + n('season_top_scorer', t.season_top_scorer) + n('season_maestro', t.season_maestro) +
    n('season_golden_glove', t.season_golden_glove);
};
