// V8.4 — E16: leituras da Central, cada bloco com o seu estado (carregando / ok / vazio confirmado / erro localizado /
// offline com cache autorizado / acesso negado / sessão expirada). Só leitura: nada aqui escreve no servidor, e o
// cache do aparelho nunca é fonte oficial nem habilita ação. Respostas velhas são descartadas (createGate).
import AsyncStorage from '@react-native-async-storage/async-storage';
import { useEffect, useRef, useState } from 'react';

import { HistoryRow, ovrDelta, serverOffset } from './centrallogic';
import { friendly } from './errors';
import { type BlockEvent, type BlockState, classifyError, createCache, createGate, initialBlock, type KV, reduceBlock } from './loadstate';
import { supabase } from './supabase';
import type { VoteItem } from './central';

const gate = createGate();
const cache = createCache(AsyncStorage as KV);

/** Logout / troca de conta (E16-27, E15-21): invalida respostas em voo e apaga o cache da Central deste aparelho. */
export async function resetCentralData() {
  gate.reset();
  await cache.clearAll();
}

export type Loaded<T> = { data: T | null; empty?: boolean };

/**
 * Carrega um bloco. scope = identifica usuário + pelada + recurso (null = bloco inativo). A cada mudança de scope ou
 * de `reload` um novo pedido invalida o anterior; o cache (do mesmo usuário e escopo) só semeia o primeiro desenho e
 * fica marcado como não confirmado até o servidor responder.
 */
export function useBlock<T>(o: { uid: string; scope: string | null; load: () => Promise<Loaded<T>>; reload: number; cacheable?: boolean }): BlockState<T> {
  const { uid, scope, reload, cacheable = true } = o;
  const loadRef = useRef(o.load);
  // O pedido sempre usa a leitura mais recente declarada pela tela (atualizada depois de cada desenho).
  useEffect(() => {
    loadRef.current = o.load;
  });
  const [box, setBox] = useState<{ key: string | null; state: BlockState<T> }>({ key: null, state: initialBlock<T>() });
  const key = scope && uid ? `${uid}:${scope}` : null;

  useEffect(() => {
    if (!key || !scope) return;
    const pass = gate.take(key);
    const apply = (ev: BlockEvent<T>) => {
      if (!gate.isCurrent(pass)) return; // resposta de pedido antigo, de outra pelada ou de conta anterior
      setBox((prev) => ({ key, state: reduceBlock(prev.key === key ? prev.state : initialBlock<T>(), ev) }));
    };
    if (cacheable) {
      cache
        .get<T>(uid, scope)
        .then((c) => c && apply({ type: 'seed', data: c.data, syncedAt: c.at }))
        .catch(() => {});
    }
    (async () => {
      apply({ type: 'start' });
      try {
        const r = await loadRef.current();
        apply({ type: 'success', data: r.data, empty: r.empty, now: Date.now() });
        if (cacheable && gate.isCurrent(pass)) {
          if (r.data !== null && !r.empty) void cache.set(uid, scope, r.data, Date.now());
          else void cache.remove(uid, scope);
        }
      } catch (e) {
        const kind = classifyError(e);
        apply({ type: 'failure', kind, message: friendly((e as { message?: string })?.message ?? '') });
      }
    })();
  }, [key, scope, uid, reload, cacheable]);

  return key && box.key === key ? box.state : initialBlock<T>();
}

// ---------------------------------------------------------------------------------------------------------------
// Tipos e leituras
// ---------------------------------------------------------------------------------------------------------------
export type Pelada = {
  id: string;
  name: string;
  crest_path: string | null;
  role: 'admin' | 'assistant' | 'player';
  membership_id: string;
  position: string;
  position_code: string | null;
  is_primary: boolean;
  drafts: number;
  setup: { members: number; matches: number; configured: boolean; invited: boolean } | null;
};

export type NextRoundItem = {
  /** Escalação anterior à V8.5 (planned_lineups); null nas rodadas pré-cadastradas da V8.5. */
  lineup_id: string | null;
  /** V8.5: partida pré-cadastrada e escalação oficial de origem. */
  match_id?: string | null;
  composition_id?: string | null;
  rescheduled?: boolean;
  pelada_id: string;
  pelada_name: string;
  label: string;
  team_name: string;
  opponent_name: string;
  // V8.5: data/horário (partida pré-cadastrada) e local da pelada, quando existem (E04).
  scheduled_at?: string | null;
  location?: string | null;
};

export type CentralData = {
  me: { display_name: string; avatar_path: string | null; dominant_foot: string | null } | null;
  primary_pelada_id: string | null;
  peladas: Pelada[];
  next_rounds: NextRoundItem[];
  pending: {
    votes: VoteItem[];
    positions: { pelada_id: string; pelada_name: string; membership_id: string }[];
    profile: { photo: boolean; foot: boolean };
  };
  guide: { dismissed: boolean; seen: { career?: boolean; cards?: boolean } };
  server_time?: string;
  /** Diferença servidor − aparelho (ms) medida na resposta; só vale para dado confirmado agora, nunca para cache. */
  offset_ms?: number;
};

/** get_player_central + votações da V5 (get_my_pending_rating_votes). Falha em qualquer uma = falha do bloco. */
export async function loadCentral(): Promise<Loaded<CentralData>> {
  const asked = Date.now();
  const [central, ratingVotes] = await Promise.all([supabase.rpc('get_player_central'), supabase.rpc('get_my_pending_rating_votes')]);
  if (central.error) throw central.error;
  if (!central.data) throw new Error('empty central');
  // As votações da V5 são parte do estado de atenção: sem elas não dá para afirmar que não há votação pendente.
  if (ratingVotes.error) throw ratingVotes.error;
  const c = central.data as CentralData;
  const v2 = ((ratingVotes.data ?? []) as VoteItem[]).map((v) => ({ ...v, v2: true }));
  // Relógio do servidor: o meio da ida e volta é a melhor estimativa do instante em que ele respondeu.
  const offset_ms = serverOffset(c.server_time, (asked + Date.now()) / 2);
  return {
    data: { ...c, offset_ms, pending: { ...c.pending, votes: [...v2, ...c.pending.votes].sort((a, b) => a.closes_at.localeCompare(b.closes_at)) } },
  };
}

export type LastGameRow = {
  match_id: string;
  played_at: string;
  team_a_name: string;
  team_b_name: string;
  team_a_score: number;
  team_b_score: number;
  my_team: 'A' | 'B';
  position: string | null;
  goals: number;
  assists: number;
  red_cards: number;
  hard_saves: number | null;
  final_rating: number | null;
  has_valid_rating: boolean;
  rating_session_status: string | null;
  legacy_finalized: boolean;
};

/** E05: último jogo disputado e publicado da pelada (get_my_last_game, 060). Vazio confirmado = ainda não jogou nenhum. */
export async function loadLastGame(peladaId: string): Promise<Loaded<LastGameRow>> {
  const { data, error } = await supabase.rpc('get_my_last_game', { p_pelada: peladaId });
  if (error) throw error;
  const game = (data as { game: LastGameRow | null } | null)?.game ?? null;
  return game ? { data: game } : { data: null, empty: true };
}

export async function loadLayout() {
  const { data, error } = await supabase.rpc('get_central_layout');
  if (error) throw error;
  return { data };
}

export async function loadUnread(): Promise<Loaded<boolean>> {
  const { data, error } = await supabase.rpc('has_unread_notifications');
  if (error) throw error;
  return { data: data === true };
}

export type RatingRow = {
  eligible: boolean;
  matches_played: number;
  matches_needed?: number;
  ovr: number | null;
  tier: 'bronze' | 'prata' | 'ouro' | null;
  position?: string;
  formula_version?: number;
};
export type PeladaRating = { rating: RatingRow | null; delta: number | null };

/**
 * OVR oficial da pelada (get_player_rating, 051) e o histórico oficial da mesma inscrição para a variação desde a
 * publicação anterior. Nada é recalculado aqui. Inscrição sem registro na V5: a Central usa a carta da temporada.
 */
export async function loadRating(membershipId: string): Promise<Loaded<PeladaRating>> {
  const [r, h] = await Promise.all([
    supabase.rpc('get_player_rating', { p_membership: membershipId }),
    supabase
      .from('player_rating_history')
      .select('match_id, ovr_display, created_at, formula_version')
      .eq('membership_id', membershipId)
      .not('ovr_display', 'is', null)
      .order('created_at', { ascending: false })
      .limit(40),
  ]);
  if (r.error) throw r.error;
  // Sem o histórico não dá para afirmar a variação: falha o bloco em vez de omitir em silêncio.
  if (h.error) throw h.error;
  const row = r.data as RatingRow;
  const rating = row && row.position ? row : null;
  // V7.7: a variação compara só com publicações da mesma fórmula (sem "salto" na troca da V5 para a V7.7).
  const same = ((h.data ?? []) as (HistoryRow & { formula_version?: number })[]).filter((x) => (x.formula_version ?? 2) === (rating?.formula_version ?? 2));
  return { data: { rating, delta: rating?.eligible ? ovrDelta(rating.ovr, same) : null } };
}

// ---------------------------------------------------------------------------------------------------------------
// V10.0 — Início agregado (REV-051 a REV-095): todas as peladas do jogador, sem "pelada ativa".
// ---------------------------------------------------------------------------------------------------------------
export type HomeLastGame = {
  match_id: string;
  played_at: string;
  pelada_id: string;
  pelada_name: string;
  team_a_name: string;
  team_b_name: string;
  team_a_color?: string | null;
  team_b_color?: string | null;
  team_a_score: number | null;
  team_b_score: number | null;
  /** played = entrou em campo; listed = relacionado sem entrada confirmada; none = não participou. */
  participation: 'played' | 'listed' | 'none';
  my_team: 'A' | 'B' | null;
  position: string | null;
  goals: number | null;
  assists: number | null;
  red_cards: number | null;
  hard_saves: number | null;
  final_rating: number | null;
  has_valid_rating: boolean;
  rating_session_status: string | null;
  legacy_finalized: boolean;
};

/** REV-057/067: partida oficial concluída mais recente entre todas as peladas (get_my_home_last_game, 082). */
export async function loadHomeLastGame(): Promise<Loaded<HomeLastGame>> {
  const { data, error } = await supabase.rpc('get_my_home_last_game');
  if (error) throw error;
  const game = (data as { game: HomeLastGame | null } | null)?.game ?? null;
  return game ? { data: game } : { data: null, empty: true };
}

export type HomeRatings = Record<string, { rating: PeladaRating; lastPlayedAt: string | null }>;

/** OVR oficial (e variação) de cada pelada, mais a data do último jogo dela — insumos do desempate do Card (REV-080). */
export async function loadHomeRatings(peladas: Pelada[]): Promise<Loaded<HomeRatings>> {
  if (peladas.length === 0) return { data: {}, empty: true };
  const rows = await Promise.all(
    peladas.map(async (p) => {
      const [r, g] = await Promise.all([loadRating(p.membership_id), loadLastGame(p.id)]);
      return [p.id, { rating: r.data as PeladaRating, lastPlayedAt: g.data?.played_at ?? null }] as const;
    }),
  );
  return { data: Object.fromEntries(rows) };
}
