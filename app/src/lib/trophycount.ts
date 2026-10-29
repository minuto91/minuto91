// Total de troféus de uma carreira (função pura, testada em tests/v87.test.ts). V8.7 soma os três prêmios de temporada novos.
import type { TrophyCounts } from './trophies';

export const trophyTotal = (t: TrophyCounts | null | undefined) =>
  t
    ? t.match_craque + t.monthly_king + t.bola_murcha + (t.monthly_garcom ?? 0) + (t.monthly_goalkeeper ?? 0) + (t.season_craque ?? 0) +
      (t.season_top_scorer ?? 0) + (t.season_maestro ?? 0) + (t.season_golden_glove ?? 0)
    : 0;
