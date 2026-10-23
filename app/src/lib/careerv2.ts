// Minha Carreira e Central do Jogador (V4.4, migração 045). Tudo vem pronto do servidor, que aplica privacidade,
// bloqueios e a regra do plano de cada pelada (Básico: temporada atual e a anterior). Aqui só se escolhe o que mostrar.
// Regra de contexto: contadores (jogos, gols, assistências, troféus) podem ser somados entre peladas ("Geral");
// overall e Card NUNCA: cada Card pertence a uma pelada e a uma temporada e aparece sempre com esse rótulo.
import { supabase } from './supabase';
import type { Totals } from './profile';
import type { TrophyCounts } from './trophies';
import type { Card as CardData } from './career';

export type SummarySeason = Totals & {
  season_id: string;
  name: string;
  starts_on: string;
  ends_on: string;
  status: string;
  valid_ratings: number;
  avg_final_rating: number | null;
  card: Omit<CardData, 'id'> | null;
};

export type SummaryPelada = {
  pelada_id: string;
  name: string;
  crest_path: string | null;
  membership_id: string;
  status: 'active' | 'left';
  position: string;
  position_code: string | null;
  full_history: boolean;
  hidden_seasons: number;
  totals: Totals;
  trophies: TrophyCounts;
  seasons: SummarySeason[];
};

export type CareerSummary =
  | { visible: false }
  | { visible: true; is_me: boolean; totals: Totals; partial: boolean; trophies: TrophyCounts; peladas: SummaryPelada[] };

export async function loadCareerSummary(userId: string) {
  const { data, error } = await supabase.rpc('get_player_career_summary', { p_user: userId });
  if (error) throw error;
  return data as CareerSummary;
}

/** Card mais recente de uma pelada (temporada mais nova com Card), com o contexto para o rótulo. */
export function latestCard(p: SummaryPelada) {
  const s = p.seasons.find((x) => x.card);
  return s?.card ? { season: s, card: s.card } : null;
}

/** Pelada de referência: a principal, senão a ativa com jogo mais recente, senão a primeira. */
export function referencePelada(peladas: SummaryPelada[], primaryId: string | null) {
  const active = peladas.filter((p) => p.status === 'active');
  return (
    active.find((p) => p.pelada_id === primaryId) ??
    [...active].sort((a, b) => (b.seasons[0]?.starts_on ?? '').localeCompare(a.seasons[0]?.starts_on ?? '') || b.totals.matches_played - a.totals.matches_played)[0] ??
    peladas[0] ??
    null
  );
}

export const trophyTotal = (t: TrophyCounts | null | undefined) => (t ? t.match_craque + t.monthly_king + t.bola_murcha : 0);

export async function markGuide(step: 'career' | 'cards' | 'dismiss' | 'restore') {
  await supabase.rpc('set_guide_state', { p_step: step });
}
