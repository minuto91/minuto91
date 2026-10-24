// Regras de exibição de partida sem dependências (testáveis em node): partida anulada não mostra placar.
export type ScoreView = {
  status: string;
  team_a_name: string;
  team_b_name: string;
  team_a_score: number | null;
  team_b_score: number | null;
};

/** Placar para texto. Anulada (ou sem placar entregue pelo servidor) vira só o confronto. */
export const scoreLine = (m: ScoreView) =>
  m.status === 'annulled' || m.team_a_score === null || m.team_b_score === null
    ? `${m.team_a_name} x ${m.team_b_name}`
    : `${m.team_a_name} ${m.team_a_score} x ${m.team_b_score} ${m.team_b_name}`;
