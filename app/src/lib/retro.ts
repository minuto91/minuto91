// Retrospectiva da temporada (V3, Fase 6): tudo calculado a partir dos dados oficiais que o membro já
// lê (partidas finalizadas, estatísticas da temporada, prêmios ativos e Card). Partidas anuladas e
// prêmios revogados não entram. Nada é inventado: sem dado, o item não aparece.
import { Card as CardData } from './career';
import { supabase } from './supabase';

// rank: posição com empate compartilhado (1, 1, 3), como nos rankings do servidor (V4.1).
export type Top = { membershipId: string; name: string; value: number; rank: number };
export type RetroMatch = { id: string; played_at: string; team_a_name: string; team_b_name: string; team_a_score: number; team_b_score: number };

export type PeladaRetro = {
  matches: number;
  goals: number;
  biggestWin: RetroMatch | null;
  mostGoals: RetroMatch | null;
  scorers: Top[];
  assisters: Top[];
  presence: Top[];
  craques: Top[];
  kings: { month: string; names: string[] }[];
  bolaMurcha: Top[]; // só na tela, nunca como conquista
};

export type PlayerRetro = {
  matches: number;
  wins: number;
  draws: number;
  losses: number;
  goals: number;
  assists: number;
  craque: number;
  kings: number;
  card: CardData | null;
};

export type Retro = { pelada: PeladaRetro; me: PlayerRetro | null };

type RawTop = { membership_id: string; name: string; value: number; rank: number };
const tops = (rows: RawTop[] | null): Top[] =>
  (rows ?? []).map((r) => ({ membershipId: r.membership_id, name: r.name, value: Number(r.value), rank: Number(r.rank) }));

// A20: tudo agregado no banco (get_season_retrospective, migração 037), sem o corte de 1.000 linhas das
// leituras diretas; o servidor também aplica o acesso da temporada (A06). Entre empatados, todos os que
// dividem a última posição exibida aparecem (8.4), em ordem alfabética.
export async function loadRetro(_peladaId: string, seasonId: string, myMembershipId: string | null): Promise<Retro> {
  const [{ data, error }, card] = await Promise.all([
    supabase.rpc('get_season_retrospective', { p_season: seasonId, p_membership: myMembershipId }),
    myMembershipId
      ? supabase
          .from('player_cards')
          .select('id, position, finishing, assisting, attendance, winning, peer_rating, overall, tier, is_provisional, matches_played, formula_version, atu, est, peq, res, dis, ovr_display')
          .eq('membership_id', myMembershipId)
          .eq('season_id', seasonId)
          .maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  if (error) throw error;
  const r = data as {
    matches: number;
    goals: number;
    biggest_win: RetroMatch | null;
    most_goals: RetroMatch | null;
    scorers: RawTop[];
    assisters: RawTop[];
    presence: RawTop[];
    craques: RawTop[];
    bola_murcha: RawTop[];
    kings: { month: string; names: string[] }[];
    me: { matches: number; wins: number; draws: number; losses: number; goals: number; assists: number; craque: number; kings: number } | null;
  };
  const pelada: PeladaRetro = {
    matches: Number(r.matches),
    goals: Number(r.goals),
    biggestWin: r.biggest_win,
    mostGoals: r.most_goals,
    scorers: tops(r.scorers),
    assisters: tops(r.assisters),
    presence: tops(r.presence),
    craques: tops(r.craques),
    kings: r.kings ?? [],
    bolaMurcha: tops(r.bola_murcha),
  };
  const me: PlayerRetro | null = r.me ? { ...r.me, card: (card.data as CardData | null) ?? null } : null;
  return { pelada, me };
}
