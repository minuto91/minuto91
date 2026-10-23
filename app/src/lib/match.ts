// Partidas: tipos e leituras compartilhadas pelas telas de súmula, partida e votação.
import { supabase } from './supabase';

export type Team = 'A' | 'B';

export type Member = {
  id: string;
  user_id: string | null;
  player_name: string;
  preferred_position: string;
  position_code?: string | null;
  role: string;
  status: string;
};

export type Guest = { id: string; display_name: string };

export type Match = {
  id: string;
  pelada_id: string;
  played_at: string;
  status: string;
  team_a_name: string;
  team_b_name: string;
  team_a_score: number;
  team_b_score: number;
  sheet_version: number;
};

// Um jogador na súmula (membro ou convidado) com seus lances.
export type SheetPlayer = {
  key: string; // m:<membership> ou g:<guest>
  membership_id?: string;
  guest_id?: string;
  team: Team;
  position: string;
  goals: number;
  assists: number;
  reds: number;
  /** V5: amarelo (0 ou 1) e expulsão por segundo amarelo (0 ou 1, vale como um vermelho). */
  yellows?: number;
  secondYellow?: number;
  /** Id na súmula (só das súmulas já gravadas). */
  participant_id?: string;
};

// Gols que não são de um jogador: gol sem autor e gol contra, pelo time que se beneficiou.
export type TeamExtras = { unattributed: Record<Team, number>; ownGoals: Record<Team, number> };

export const emptyExtras = (): TeamExtras => ({ unattributed: { A: 0, B: 0 }, ownGoals: { A: 0, B: 0 } });

export const STATUS_LABEL: Record<string, string> = {
  draft: 'Rascunho',
  voting_open: 'Votação aberta',
  finalizing: 'Encerrando',
  finalized: 'Finalizada',
  annulled: 'Anulada',
};

export const MATCH_COLUMNS =
  'id, pelada_id, played_at, status, team_a_name, team_b_name, team_a_score, team_b_score, sheet_version';

export const fmtDate = (iso: string) =>
  new Date(iso).toLocaleDateString('pt-BR', { weekday: 'short', day: '2-digit', month: '2-digit' });

export const fmtTime = (iso: string) =>
  new Date(iso).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });

export const fmtRating = (v: number) => v.toFixed(1).replace('.', ',');

export async function loadMatch(id: string) {
  const { data, error } = await supabase.from('matches').select(MATCH_COLUMNS).eq('id', id).maybeSingle();
  if (error) throw error;
  return data as Match | null;
}

// Todos os registros da pelada (inclusive quem saiu), para mostrar nomes na súmula.
export async function loadMembers(peladaId: string) {
  const { data, error } = await supabase
    .from('pelada_memberships')
    .select('id, user_id, player_name, preferred_position, position_code, role, status')
    .eq('pelada_id', peladaId)
    .order('joined_at', { ascending: true });
  if (error) throw error;
  return (data ?? []) as Member[];
}

export async function loadGuests(peladaId: string) {
  const { data, error } = await supabase
    .from('guests')
    .select('id, display_name')
    .eq('pelada_id', peladaId)
    .order('created_at', { ascending: true });
  if (error) throw error;
  return (data ?? []) as Guest[];
}

export async function loadSheet(matchId: string) {
  const [{ data: parts, error: e1 }, { data: events, error: e2 }] = await Promise.all([
    supabase
      .from('match_participants')
      .select('id, membership_id, guest_id, team, primary_position, position_code')
      .eq('match_id', matchId),
    supabase.from('match_events').select('participant_id, team, event_type, quantity').eq('match_id', matchId),
  ]);
  if (e1) throw e1;
  if (e2) throw e2;
  const byId = new Map<string, SheetPlayer>();
  for (const p of parts ?? []) {
    byId.set(p.id, {
      key: p.membership_id ? `m:${p.membership_id}` : `g:${p.guest_id}`,
      participant_id: p.id,
      membership_id: p.membership_id ?? undefined,
      guest_id: p.guest_id ?? undefined,
      team: p.team as Team,
      position: p.position_code ?? p.primary_position, // V4.3: sigla registrada na súmula (antigas: só o setor)
      goals: 0,
      assists: 0,
      reds: 0,
      yellows: 0,
      secondYellow: 0,
    });
  }
  const extras = emptyExtras();
  for (const e of events ?? []) {
    const player = e.participant_id ? byId.get(e.participant_id) : undefined;
    if (e.event_type === 'goal' && player) player.goals += e.quantity;
    else if (e.event_type === 'assist' && player) player.assists += e.quantity;
    else if (e.event_type === 'red_card' && player) player.reds += e.quantity;
    else if (e.event_type === 'yellow_card' && player) player.yellows = (player.yellows ?? 0) + e.quantity;
    else if (e.event_type === 'second_yellow' && player) player.secondYellow = 1;
    else if (e.event_type === 'unattributed_goal') extras.unattributed[e.team as Team] += e.quantity;
    else if (e.event_type === 'own_goal') extras.ownGoals[e.team as Team] += e.quantity;
  }
  return { players: [...byId.values()], extras };
}

// Formato esperado por save_match_sheet / correct_match_sheet.
export function sheetPayload(players: SheetPlayer[], extras: TeamExtras) {
  const participants = players.map((p) =>
    p.membership_id
      ? { membership_id: p.membership_id, team: p.team }
      : { guest_id: p.guest_id, team: p.team, position: p.position },
  );
  const events: Record<string, unknown>[] = [];
  for (const p of players) {
    const who = p.membership_id ? { membership_id: p.membership_id } : { guest_id: p.guest_id };
    if (p.goals) events.push({ ...who, type: 'goal', quantity: p.goals });
    if (p.assists) events.push({ ...who, type: 'assist', quantity: p.assists });
    if (p.reds) events.push({ ...who, type: 'red_card', quantity: p.reds });
    if (p.yellows) events.push({ ...who, type: 'yellow_card', quantity: p.yellows });
    if (p.secondYellow) events.push({ ...who, type: 'second_yellow', quantity: 1 });
  }
  for (const t of ['A', 'B'] as Team[]) {
    if (extras.unattributed[t]) events.push({ type: 'unattributed_goal', team: t, quantity: extras.unattributed[t] });
    if (extras.ownGoals[t]) events.push({ type: 'own_goal', team: t, quantity: extras.ownGoals[t] });
  }
  return { participants, events };
}

// Placar como o servidor calcula: gols dos jogadores + gols sem autor + gols contra a favor.
export function sheetScore(players: SheetPlayer[], extras: TeamExtras) {
  const score = { A: extras.unattributed.A + extras.ownGoals.A, B: extras.unattributed.B + extras.ownGoals.B };
  for (const p of players) score[p.team] += p.goals;
  return score;
}

// Chave de idempotência do envio de voto.
export const newKey = () => `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`;
