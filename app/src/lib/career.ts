// Temporadas, carta, estatísticas e álbum (dados calculados pelo servidor).
import { supabase } from './supabase';
import { colors } from './theme';

export type Season = { id: string; name: string; starts_on: string; ends_on: string; status: string; kind: string };

export type Card = {
  id: string;
  position: string;
  finishing: number;
  assisting: number;
  attendance: number;
  winning: number;
  peer_rating: number;
  overall: number;
  tier: 'bronze' | 'prata' | 'ouro';
  is_provisional: boolean;
  matches_played: number;
};

export type SeasonStats = {
  matches_played: number;
  wins: number;
  draws: number;
  losses: number;
  goals: number;
  assists: number;
  red_cards: number;
  valid_ratings: number;
  avg_final_rating: number | null;
  high_ratings: number;
  craque_awards: number;
  best_win_streak: number;
  best_unbeaten_streak: number;
  current_win_streak: number;
  current_unbeaten_streak: number;
};

export const ATTRIBUTES = [
  { key: 'finishing', label: 'Finalização', code: 'FIN' },
  { key: 'assisting', label: 'Garçom', code: 'GAR' },
  { key: 'attendance', label: 'Presença', code: 'PRE' },
  { key: 'winning', label: 'Pé Quente', code: 'PEQ' },
  { key: 'peer_rating', label: 'Resenha', code: 'RES' },
] as const;

// Categoria pelo overall exibido (inteiro), como no servidor. Cores só das cartas (a interface segue
// branco, azul e dourado). color = texto sobre branco (AA); bg = fundo da carta; frame = moldura;
// deep = texto pequeno sobre o fundo da carta (AA); sheen = opacidade do brilho metálico;
// level = quanto a moldura é elaborada (1 simples, 2 com filete, 3 com filete e ornamentos).
export const TIER = {
  bronze: { label: 'Bronze', color: '#8C5A3C', bg: '#EBD3BE', frame: '#9C6542', deep: '#5E3920', sheen: 0.18, level: 1 },
  prata: { label: 'Prata', color: '#5E6E86', bg: '#E4E8EF', frame: '#7F8B9E', deep: '#3A4556', sheen: 0.28, level: 2 },
  ouro: { label: 'Ouro', color: colors.darkGold, bg: '#F4E4B4', frame: '#B5862A', deep: '#634708', sheen: 0.38, level: 3 },
} as const;

export const AWARD_LABEL: Record<string, string> = {
  monthly_king: 'Rei do Mês',
  top_scorer: 'Artilheiro do mês',
  top_assist: 'Garçom do mês',
  most_improved: 'Maior evolução',
  match_craque: 'Craque da Partida',
  bola_murcha: 'Bola Murcha',
};

// "1 jogo", "2 jogos".
export const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

export const fmtMonth = (isoDate: string) =>
  new Date(`${isoDate}T12:00:00`).toLocaleDateString('pt-BR', { month: 'long', year: 'numeric' });

// Temporadas da pelada, da mais nova para a mais antiga.
export async function loadSeasons(peladaId: string) {
  const { data, error } = await supabase
    .from('seasons')
    .select('id, name, starts_on, ends_on, status, kind')
    .eq('pelada_id', peladaId)
    .order('starts_on', { ascending: false });
  if (error) throw error;
  return (data ?? []) as Season[];
}

// Temporada em andamento (ou a mais recente que já começou).
export function currentSeason(seasons: Season[]) {
  const today = new Date().toISOString().slice(0, 10);
  return seasons.find((s) => s.starts_on <= today && s.ends_on >= today) ?? seasons.find((s) => s.starts_on <= today) ?? seasons[0] ?? null;
}

export async function loadCard(membershipId: string, seasonId: string) {
  const [{ data: card, error: e1 }, { data: stats, error: e2 }] = await Promise.all([
    supabase
      .from('player_cards')
      .select('id, position, finishing, assisting, attendance, winning, peer_rating, overall, tier, is_provisional, matches_played')
      .eq('membership_id', membershipId)
      .eq('season_id', seasonId)
      .maybeSingle(),
    supabase
      .from('player_season_stats')
      .select(
        'matches_played, wins, draws, losses, goals, assists, red_cards, valid_ratings, avg_final_rating, high_ratings, craque_awards, best_win_streak, best_unbeaten_streak, current_win_streak, current_unbeaten_streak',
      )
      .eq('membership_id', membershipId)
      .eq('season_id', seasonId)
      .maybeSingle(),
  ]);
  if (e1) throw e1;
  if (e2) throw e2;
  return { card: card as Card | null, stats: stats as SeasonStats | null };
}
