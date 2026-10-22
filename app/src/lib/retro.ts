// Retrospectiva da temporada (V3, Fase 6): tudo calculado a partir dos dados oficiais que o membro já
// lê (partidas finalizadas, estatísticas da temporada, prêmios ativos e Card). Partidas anuladas e
// prêmios revogados não entram. Nada é inventado: sem dado, o item não aparece.
import { Card as CardData } from './career';
import { supabase } from './supabase';

export type Top = { membershipId: string; name: string; value: number };
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

const top = (rows: { membership_id: string; v: number }[], nameOf: (id: string) => string, n = 3): Top[] =>
  rows
    .filter((r) => r.v > 0)
    .sort((a, b) => b.v - a.v)
    .slice(0, n)
    .map((r) => ({ membershipId: r.membership_id, name: nameOf(r.membership_id), value: r.v }));

const count = (ids: string[]) => {
  const m = new Map<string, number>();
  ids.forEach((id) => m.set(id, (m.get(id) ?? 0) + 1));
  return [...m.entries()].map(([membership_id, v]) => ({ membership_id, v }));
};

export async function loadRetro(peladaId: string, seasonId: string, myMembershipId: string | null): Promise<Retro> {
  const [{ data: ms, error: e1 }, { data: st, error: e2 }, { data: aw, error: e3 }, { data: mem, error: e4 }, card] =
    await Promise.all([
      supabase
        .from('matches')
        .select('id, played_at, team_a_name, team_b_name, team_a_score, team_b_score')
        .eq('season_id', seasonId)
        .eq('status', 'finalized'),
      supabase
        .from('player_season_stats')
        .select('membership_id, matches_played, wins, draws, losses, goals, assists, craque_awards')
        .eq('season_id', seasonId),
      supabase.from('awards').select('membership_id, award_type, period_month').eq('season_id', seasonId).eq('status', 'active'),
      // Nomes de todos os registros (inclui quem saiu: a história da temporada continua).
      supabase.from('pelada_memberships').select('id, player_name').eq('pelada_id', peladaId),
      myMembershipId
        ? supabase
            .from('player_cards')
            .select('id, position, finishing, assisting, attendance, winning, peer_rating, overall, tier, is_provisional, matches_played')
            .eq('membership_id', myMembershipId)
            .eq('season_id', seasonId)
            .maybeSingle()
        : Promise.resolve({ data: null }),
    ]);
  const err = e1 ?? e2 ?? e3 ?? e4;
  if (err) throw err;
  const names = new Map((mem ?? []).map((m) => [m.id as string, m.player_name as string]));
  const nameOf = (id: string) => names.get(id) ?? 'Jogador';
  const matches = (ms ?? []) as RetroMatch[];
  const stats = st ?? [];
  const awards = aw ?? [];

  const diff = (m: RetroMatch) => Math.abs(m.team_a_score - m.team_b_score);
  const total = (m: RetroMatch) => m.team_a_score + m.team_b_score;
  const biggestWin = matches.filter((m) => diff(m) > 0).sort((a, b) => diff(b) - diff(a) || total(b) - total(a))[0] ?? null;
  const mostGoals = matches.filter((m) => total(m) > 0).sort((a, b) => total(b) - total(a))[0] ?? null;

  const kingsByMonth = new Map<string, string[]>();
  awards
    .filter((a) => a.award_type === 'monthly_king' && a.period_month)
    .forEach((a) => kingsByMonth.set(a.period_month!, [...(kingsByMonth.get(a.period_month!) ?? []), nameOf(a.membership_id)]));

  const pelada: PeladaRetro = {
    matches: matches.length,
    goals: matches.reduce((s, m) => s + total(m), 0),
    biggestWin,
    mostGoals,
    scorers: top(stats.map((x) => ({ membership_id: x.membership_id, v: x.goals })), nameOf),
    assisters: top(stats.map((x) => ({ membership_id: x.membership_id, v: x.assists })), nameOf),
    presence: top(stats.map((x) => ({ membership_id: x.membership_id, v: x.matches_played })), nameOf),
    craques: top(count(awards.filter((a) => a.award_type === 'match_craque').map((a) => a.membership_id)), nameOf),
    kings: [...kingsByMonth.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([month, n]) => ({ month, names: n })),
    bolaMurcha: top(count(awards.filter((a) => a.award_type === 'bola_murcha').map((a) => a.membership_id)), nameOf),
  };

  const mine = myMembershipId ? stats.find((x) => x.membership_id === myMembershipId) : undefined;
  const me: PlayerRetro | null =
    mine && mine.matches_played > 0
      ? {
          matches: mine.matches_played,
          wins: mine.wins,
          draws: mine.draws,
          losses: mine.losses,
          goals: mine.goals,
          assists: mine.assists,
          craque: mine.craque_awards,
          kings: awards.filter((a) => a.award_type === 'monthly_king' && a.membership_id === myMembershipId).length,
          card: (card.data as CardData | null) ?? null,
        }
      : null;
  return { pelada, me };
}
