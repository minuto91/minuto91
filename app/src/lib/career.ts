// Temporadas, carta, estatísticas e álbum (dados calculados pelo servidor).
import { todayIn } from './dates';
import { supabase } from './supabase';
import { colors } from './theme';

export type Season = { id: string; name: string; starts_on: string; ends_on: string; status: string; kind: string };

export type Card = {
  id: string;
  /** Setor do Card (o que a fórmula oficial usa). */
  position: string;
  /** V4.3: sigla atual do jogador; o Card mostra a sigla quando ela é do mesmo setor do Card. */
  position_code?: string | null;
  finishing: number;
  assisting: number;
  attendance: number;
  winning: number;
  peer_rating: number;
  overall: number;
  tier: 'bronze' | 'prata' | 'ouro';
  is_provisional: boolean;
  matches_played: number;
  /** V5 (formula_version 2): OVR do Prompt Master v2.0 e seus cinco componentes; nulos nas cartas antigas. */
  formula_version?: number | null;
  atu?: number | null;
  est?: number | null;
  peq?: number | null;
  res?: number | null;
  dis?: number | null;
  ovr_display?: number | null;
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

// V5: os cinco atributos do OVR, iguais para todas as posições (goleiro sem GAR: o EST dele já é defesas + defesa).
export const ATTRIBUTES_V2 = [
  { key: 'atu', label: 'Atuação', code: 'ATU' },
  { key: 'est', label: 'Estatísticas', code: 'EST' },
  { key: 'peq', label: 'Performance da Equipe', code: 'PEQ' },
  { key: 'res', label: 'Regularidade', code: 'RES' },
  { key: 'dis', label: 'Disciplina', code: 'DIS' },
] as const;

// Basta a parte da carta que as telas recebem (algumas listas vêm sem id).
type CardLike = Pick<Card, 'overall' | 'tier' | 'matches_played'> & Partial<Pick<Card, 'formula_version' | 'atu' | 'ovr_display'>>;

export const isV2 = (c: Partial<Pick<Card, 'formula_version' | 'atu'>>) => (c.formula_version ?? 1) >= 2 && c.atu !== null && c.atu !== undefined;
export const cardAttributes = (c: Partial<Pick<Card, 'formula_version' | 'atu'>>) => (isV2(c) ? ATTRIBUTES_V2 : ATTRIBUTES);
/** OVR mostrado: null = avaliação em andamento (menos de 5 partidas, sem número fictício). */
export const cardOverall = (c: CardLike): number | null => (isV2(c) ? (c.ovr_display ?? null) : Math.round(c.overall));

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
  monthly_garcom: 'Garçom do Mês',
  match_garcom: 'Garçom da Partida',
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

// A06: só as temporadas que o plano da pelada libera (grátis: atual e anterior; Pelada Premium: todas).
// Banco sem a migração 037: cai na lista completa (o servidor continua bloqueando os números).
export async function loadReadableSeasons(peladaId: string) {
  const { data, error } = await supabase.rpc('get_readable_seasons', { p_pelada: peladaId });
  if (error) return loadSeasons(peladaId);
  return (data ?? []) as Season[];
}

// Temporada em andamento (ou a mais recente que já começou).
export function currentSeason(seasons: Season[]) {
  const today = todayIn();
  return seasons.find((s) => s.starts_on <= today && s.ends_on >= today) ?? seasons.find((s) => s.starts_on <= today) ?? seasons[0] ?? null;
}

export async function loadCard(membershipId: string, seasonId: string) {
  const [{ data: card, error: e1 }, { data: stats, error: e2 }] = await Promise.all([
    supabase
      .from('player_cards')
      .select('id, position, finishing, assisting, attendance, winning, peer_rating, overall, tier, is_provisional, matches_played, formula_version, atu, est, peq, res, dis, ovr_display')
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

// Texto curto do overall com a categoria; antes de 5 partidas (V5), "em avaliação" sem número.
export const overallLabel = (c: CardLike) => {
  const o = cardOverall(c);
  return o === null ? 'Em avaliação (menos de 5 partidas na pelada)' : `Overall ${o} · ${TIER[c.tier].label}`;
};
