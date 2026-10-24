// Central do Jogador 2.0 (24/10/2026): blocos da tela inicial. A tela (app/(tabs)/index.tsx) junta os dados; aqui
// ficam a apresentação e as duas leituras que dependem da pelada escolhida (OVR com a variação e o último jogo).
// Regras: tudo é da pelada selecionada (nunca misturar peladas), nada provisório aparece antes da publicação e nenhum
// valor é inventado para preencher a interface. As fórmulas (ATU, EST, PEQ, RES, DIS, OVR) e a votação não mudam aqui.
import { type ReactNode, useEffect, useState } from 'react';
import { Pressable, ScrollView, useWindowDimensions, View, type ViewStyle } from 'react-native';
import Svg, { Path } from 'react-native-svg';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Avatar } from './avatar';
import { Card as CardData, cardOverall, isV2, plural, TIER } from './career';
import { Crest } from './crest';
import { deltaA11y, deltaText, HistoryRow, leftLabel, matchRating, MatchRating, ovrDelta, resultOf } from './centrallogic';
import { friendly } from './errors';
import { fmtDate } from './match';
import { CARD_RATIO, PlayerCard } from './playercard';
import { supabase } from './supabase';
import { Text } from './text';
import { colors, positionLabel, positionShort, radius, shadow, type } from './theme';
import { hair, MatchScore, PlayerOVR, StatStrip, VotePendingRow } from './domain';

const box: ViewStyle = {
  backgroundColor: colors.white,
  borderRadius: radius.card,
  borderWidth: 1,
  borderColor: colors.line,
  padding: 16,
  gap: 8,
  ...shadow.card,
};
const link = { color: colors.blue, fontWeight: '700' as const, fontSize: 15 };

// ---------------------------------------------------------------------------------------------------------------
// Cabeçalho
// ---------------------------------------------------------------------------------------------------------------
function Bell({ color }: { color: string }) {
  const p = { stroke: color, strokeWidth: 1.9, fill: 'none', strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const };
  return (
    <Svg width={24} height={24} viewBox="0 0 24 24">
      <Path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15z" {...p} />
      <Path d="M10 20.5a2.2 2.2 0 0 0 4 0" {...p} />
    </Svg>
  );
}

const greeting = (h: number) => (h < 5 ? 'Boa noite' : h < 12 ? 'Bom dia' : h < 18 ? 'Boa tarde' : 'Boa noite');

export function CentralHeader({
  name,
  avatarPath,
  onProfile,
  onBell,
}: {
  name: string | null;
  avatarPath: string | null | undefined;
  onProfile: () => void;
  onBell: () => void;
}) {
  const first = name?.trim().split(/\s+/)[0] ?? '';
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
      <Pressable
        onPress={onProfile}
        accessibilityRole="button"
        accessibilityLabel="Abrir meu perfil"
        style={{ flexDirection: 'row', alignItems: 'center', gap: 12, flex: 1, minHeight: 48 }}>
        <Avatar path={avatarPath} name={name ?? ' '} size={44} />
        <View style={{ flex: 1 }}>
          <Text style={{ fontSize: 22, lineHeight: 28, fontWeight: '800', color: colors.deepBlue }} numberOfLines={1}>
            {name ? `${greeting(new Date().getHours())}, ${first}` : ' '}
          </Text>
        </View>
      </Pressable>
      <Pressable
        onPress={onBell}
        accessibilityRole="button"
        accessibilityLabel="Avisos e notificações"
        hitSlop={4}
        style={({ pressed }) => ({
          width: 44,
          height: 44,
          borderRadius: 22,
          alignItems: 'center',
          justifyContent: 'center',
          backgroundColor: pressed ? colors.bg : 'transparent',
        })}>
        <Bell color={colors.deepBlue} />
      </Pressable>
    </View>
  );
}

/** Área segura do topo: a Central não usa o cabeçalho das abas (o cabeçalho próprio já identifica a tela). */
export function useTopInset() {
  return useSafeAreaInsets().top;
}

// ---------------------------------------------------------------------------------------------------------------
// Seletor de pelada
// ---------------------------------------------------------------------------------------------------------------
export type PeladaOption = { id: string; name: string; crest_path: string | null; role: string };

export function PeladaSwitcher({
  peladas,
  selected,
  onSelect,
}: {
  peladas: PeladaOption[];
  selected: string | null;
  onSelect: (id: string) => void;
}) {
  if (peladas.length === 0) return null;
  const roleNote = (r: string) => (r === 'admin' ? ' · Administrador' : r === 'assistant' ? ' · Assistente' : '');
  // Uma pelada só: o contexto aparece, sem controle de troca.
  if (peladas.length === 1) {
    const p = peladas[0];
    return (
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }} accessibilityLabel={`Pelada: ${p.name}`}>
        <Crest path={p.crest_path} name={p.name} size={24} />
        <Text style={{ ...type.meta, color: colors.ink, flexShrink: 1 }} numberOfLines={1}>
          {p.name}
          <Text style={{ color: colors.muted }}>{roleNote(p.role)}</Text>
        </Text>
      </View>
    );
  }
  return (
    <View accessibilityRole="tablist" accessibilityLabel="Escolher a pelada" style={{ backgroundColor: colors.bg, borderRadius: radius.pill, padding: 4 }}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 4 }}>
        {peladas.map((p) => {
          const on = p.id === selected;
          return (
            <Pressable
              key={p.id}
              onPress={() => onSelect(p.id)}
              accessibilityRole="tab"
              accessibilityState={{ selected: on }}
              accessibilityLabel={`${p.name}${roleNote(p.role)}`}
              style={{
                flexDirection: 'row',
                alignItems: 'center',
                gap: 8,
                minHeight: 40,
                maxWidth: 220,
                paddingLeft: 6,
                paddingRight: 14,
                borderRadius: radius.pill,
                backgroundColor: on ? colors.white : 'transparent',
                ...(on ? shadow.card : null),
              }}>
              <Crest path={p.crest_path} name={p.name} size={26} />
              <Text
                style={{ fontSize: 14, fontWeight: on ? '700' : '500', color: on ? colors.deepBlue : colors.muted, flexShrink: 1 }}
                numberOfLines={1}>
                {p.name}
              </Text>
            </Pressable>
          );
        })}
      </ScrollView>
    </View>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Votação urgente (acima da carta) e pendências (abaixo)
// ---------------------------------------------------------------------------------------------------------------
export type VoteItem = {
  match_id: string;
  pelada_id: string;
  pelada_name: string;
  closes_at: string;
  team_a_name: string;
  team_b_name: string;
  team_a_score: number;
  team_b_score: number;
  rated?: number;
  total?: number;
  started?: boolean;
  v2?: boolean;
};

const scoreLine = (v: VoteItem) => `${v.team_a_name} ${v.team_a_score} x ${v.team_b_score} ${v.team_b_name}`;

export function UrgentVote({ vote, offset, onPress }: { vote: VoteItem; offset: number; onPress: () => void }) {
  const progress = vote.v2 && vote.total ? Math.min(1, (vote.rated ?? 0) / vote.total) : null;
  const left = leftLabel(vote.closes_at, offset);
  return (
    <View
      style={{ backgroundColor: colors.deepBlue, borderRadius: radius.card, padding: 16, gap: 10 }}
      accessibilityRole="summary"
      accessibilityLabel={`Votação perto do fim. ${scoreLine(vote)}. ${left}.`}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        <Text style={{ fontSize: 12, fontWeight: '800', letterSpacing: 0.8, color: '#9DB8E8', flex: 1 }} numberOfLines={1}>
          ÚLTIMA HORA
        </Text>
        <View style={{ backgroundColor: colors.white, borderRadius: radius.pill, paddingHorizontal: 10, paddingVertical: 3 }}>
          <Text style={{ fontSize: 13, fontWeight: '800', color: colors.danger, fontVariant: ['tabular-nums'] }}>{left}</Text>
        </View>
      </View>
      <Text style={{ fontSize: 18, lineHeight: 24, fontWeight: '700', color: colors.white }} numberOfLines={2}>
        {scoreLine(vote)}
      </Text>
      {progress !== null && (
        <View style={{ gap: 4 }}>
          <View style={{ height: 4, borderRadius: 2, backgroundColor: 'rgba(255,255,255,0.2)', overflow: 'hidden' }}>
            <View style={{ width: `${Math.round(progress * 100)}%`, height: 4, backgroundColor: colors.white }} />
          </View>
          <Text style={{ fontSize: 13, color: '#C9D6EE' }}>
            Você avaliou {vote.rated} de {vote.total}
          </Text>
        </View>
      )}
      <Pressable
        onPress={onPress}
        accessibilityRole="button"
        style={({ pressed }) => ({
          minHeight: 48,
          borderRadius: radius.md,
          backgroundColor: colors.white,
          opacity: pressed ? 0.85 : 1,
          alignItems: 'center',
          justifyContent: 'center',
        })}>
        <Text style={{ color: colors.blue, fontWeight: '800', fontSize: 16 }}>{vote.v2 && vote.started ? 'Continuar votação' : 'Votar agora'}</Text>
      </Pressable>
    </View>
  );
}

export type PendingItem = { key: string; title: string; detail?: string; action: string; tone: 'blue' | 'gold'; onPress: () => void };

/** Pendências não urgentes: lista compacta; acima de três, o resto fica atrás de "ver todas". */
export function PendingList({ items }: { items: PendingItem[] }) {
  const [open, setOpen] = useState(false);
  if (items.length === 0) return null;
  const shown = open ? items : items.slice(0, 3);
  return (
    <View>
      {shown.map((p, i) => (
        <VotePendingRow key={p.key} first={i === 0} title={p.title} detail={p.detail} action={p.action} tone={p.tone} onPress={p.onPress} />
      ))}
      {items.length > 3 && (
        <Pressable
          onPress={() => setOpen((o) => !o)}
          accessibilityRole="button"
          accessibilityState={{ expanded: open }}
          style={{ minHeight: 44, justifyContent: 'center', borderTopWidth: 1, borderTopColor: hair }}>
          <Text style={{ ...link, fontSize: 14 }}>{open ? 'Mostrar menos' : `Ver todas (${items.length})`}</Text>
        </Pressable>
      )}
    </View>
  );
}

export const voteLine = scoreLine;

// ---------------------------------------------------------------------------------------------------------------
// OVR oficial da pelada e variação desde a última publicação
// ---------------------------------------------------------------------------------------------------------------
type RatingRow = {
  eligible: boolean;
  matches_played: number;
  matches_needed?: number;
  ovr: number | null;
  tier: 'bronze' | 'prata' | 'ouro' | null;
  position?: string;
};
export type PeladaRating = { rating: RatingRow | null; delta: number | null };

/**
 * OVR atual (get_player_rating, 051) e o histórico oficial da mesma inscrição (player_rating_history, mesma regra de
 * acesso das cartas). Inscrição sem registro na V5 (rating sem "position"): a Central usa a carta da temporada.
 */
export function usePeladaRating(membershipId: string | null, reload: number) {
  const [state, setState] = useState<{ key: string; data: PeladaRating | null; error: string | null } | null>(null);
  useEffect(() => {
    if (!membershipId) return;
    let alive = true;
    void reload;
    (async () => {
      const [r, h] = await Promise.all([
        supabase.rpc('get_player_rating', { p_membership: membershipId }),
        supabase
          .from('player_rating_history')
          .select('match_id, ovr_display, created_at')
          .eq('membership_id', membershipId)
          .not('ovr_display', 'is', null)
          .order('created_at', { ascending: false })
          .limit(40),
      ]);
      if (!alive) return;
      if (r.error) return setState({ key: membershipId, data: null, error: friendly(r.error.message) });
      const row = r.data as RatingRow;
      const rating = row && row.position ? row : null;
      setState({
        key: membershipId,
        data: { rating, delta: rating?.eligible ? ovrDelta(rating.ovr, (h.data ?? []) as HistoryRow[]) : null },
        error: null,
      });
    })();
    return () => {
      alive = false;
    };
  }, [membershipId, reload]);
  // Troca de pelada: o dado da pelada anterior nunca aparece na nova.
  return state && state.key === membershipId ? state : null;
}

export function OvrDelta({ delta }: { delta: number | null }) {
  if (delta === null) return null;
  const up = delta > 0;
  const down = delta < 0;
  const fg = up ? '#0B6B3A' : down ? '#9A3412' : colors.muted;
  const bg = up ? '#E7F5EC' : down ? '#FDEEE6' : colors.bg;
  return (
    <View
      accessibilityLabel={`OVR ${deltaA11y(delta)}`}
      style={{
        flexDirection: 'row',
        alignItems: 'center',
        gap: 3,
        paddingHorizontal: 8,
        paddingVertical: 3,
        borderRadius: radius.pill,
        backgroundColor: bg,
        alignSelf: 'flex-start',
      }}>
      {/* Seta e sinal: a variação não depende só da cor. */}
      <Text style={{ fontSize: 12, fontWeight: '800', color: fg }} importantForAccessibility="no" accessibilityElementsHidden>
        {up ? '▲' : down ? '▼' : '='}
      </Text>
      <Text style={{ fontSize: 13, fontWeight: '800', color: fg, fontVariant: ['tabular-nums'] }}>{deltaText(delta)}</Text>
    </View>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Card principal: carta compacta + resumo
// ---------------------------------------------------------------------------------------------------------------
export type HeroData = {
  name: string;
  avatarPath: string | null | undefined;
  peladaName: string;
  crestPath: string | null;
  position: string | null; // posição atual na pelada (sigla ou setor antigo)
  card: Omit<CardData, 'id'> | null;
  seasonName: string | null;
  seasonStart: string | null;
  season: { matches_played: number; goals: number; assists: number } | null;
};

/** Carta "em avaliação" quando ainda não há carta: mesma silhueta neutra, sem número. */
function EvaluatingCard({
  width,
  name,
  avatarPath,
  position,
}: {
  width: number;
  name: string;
  avatarPath: string | null | undefined;
  position: string | null;
}) {
  const height = Math.round(width * CARD_RATIO);
  return (
    <View
      accessibilityLabel={`Card de ${name} em avaliação`}
      style={{
        width,
        height,
        borderRadius: 14,
        borderWidth: 1.5,
        borderStyle: 'dashed',
        borderColor: '#B8C4D8',
        backgroundColor: colors.bg,
        alignItems: 'center',
        justifyContent: 'center',
        gap: 8,
        padding: 8,
      }}>
      <Avatar path={avatarPath} name={name} size={Math.round(width * 0.46)} />
      <Text style={{ fontSize: 13, fontWeight: '800', color: colors.deepBlue }}>{positionShort(position)}</Text>
      <Text
        style={{ fontSize: 12, fontWeight: '600', color: colors.muted, textAlign: 'center' }}
        numberOfLines={1}
        adjustsFontSizeToFit
        minimumFontScale={0.7}>
        {name}
      </Text>
    </View>
  );
}

export function CareerHero({
  data,
  rating,
  ratingLoading,
  onCareer,
}: {
  data: HeroData;
  rating: PeladaRating | null;
  ratingLoading: boolean;
  onCareer: () => void;
}) {
  const { width: screen } = useWindowDimensions();
  // Carta proporcional à tela: 104 px em telas de 320, até 132 px em telas largas; o resumo ocupa o resto.
  const cardW = Math.max(100, Math.min(132, Math.round((Math.min(screen, 520) - 40) * 0.33)));
  const narrow = screen < 350;
  const r = rating?.rating ?? null;
  const card = data.card;
  // OVR exibido: o oficial da V5; sem registro na V5, o da carta (e nunca antes de 5 partidas).
  const legacyOvr = card ? cardOverall(card) : null;
  const ovr = r ? (r.eligible ? r.ovr : null) : legacyOvr !== null && (card?.matches_played ?? 0) >= 5 ? legacyOvr : null;
  const played = r?.matches_played ?? card?.matches_played ?? data.season?.matches_played ?? 0;
  const needed = Math.max(0, 5 - played);
  const tier = (r?.tier ?? card?.tier ?? null) as keyof typeof TIER | null;
  const showOfficialCard = !!card && (ovr !== null || isV2(card));

  return (
    <View style={{ backgroundColor: colors.bg, borderRadius: radius.lg, padding: narrow ? 12 : 16, gap: 12 }}>
      <View style={{ flexDirection: 'row', gap: narrow ? 12 : 16, alignItems: 'center' }}>
        {showOfficialCard ? (
          <PlayerCard
            card={{ id: 'central', ...card! }}
            playerName={data.name}
            photoPath={data.avatarPath}
            peladaName={data.peladaName}
            crestPath={data.crestPath}
            seasonName={data.seasonName ?? ''}
            seasonStart={data.seasonStart}
            width={cardW}
            mini
          />
        ) : (
          <EvaluatingCard width={cardW} name={data.name} avatarPath={data.avatarPath} position={data.position} />
        )}

        <View style={{ flex: 1, minWidth: 0, gap: 6 }}>
          <Text style={{ fontSize: 13, fontWeight: '600', color: colors.muted }} numberOfLines={1}>
            {positionLabel(data.position)}
            {tier && ovr !== null ? ` · ${TIER[tier].label}` : ''}
          </Text>
          {ovr !== null ? (
            <PlayerOVR
              ovr={ovr}
              color={tier ? TIER[tier].color : colors.deepBlue}
              narrow={narrow}
              aside={ratingLoading ? null : <OvrDelta delta={rating?.delta ?? null} />}
            />
          ) : (
            <View style={{ gap: 6 }} accessibilityLabel={`Avaliação em andamento: ${played} de 5 partidas`}>
              <Text style={{ fontSize: 17, fontWeight: '800', color: colors.deepBlue }}>Avaliação em andamento</Text>
              <View style={{ flexDirection: 'row', gap: 4 }}>
                {[0, 1, 2, 3, 4].map((i) => (
                  <View key={i} style={{ flex: 1, height: 6, borderRadius: 3, backgroundColor: i < played ? colors.blue : colors.line }} />
                ))}
              </View>
              <Text style={type.meta}>
                {Math.min(played, 5)} de 5 partidas ·{' '}
                {needed > 0 ? `o OVR aparece depois de ${plural(needed, 'partida', 'partidas')}` : 'aguardando o cálculo'}
              </Text>
            </View>
          )}
          <StatStrip
            size="sm"
            items={[
              { value: data.season?.matches_played ?? 0, label: 'Jogos' },
              { value: data.season?.goals ?? 0, label: 'Gols' },
              { value: data.season?.assists ?? 0, label: 'Assist.' },
            ]}
          />
        </View>
      </View>
      <View style={{ flexDirection: 'row', alignItems: 'center', borderTopWidth: 1, borderTopColor: colors.line, paddingTop: 4 }}>
        <Text style={{ ...type.meta, flex: 1 }} numberOfLines={1}>
          {data.seasonName ?? data.peladaName}
        </Text>
        <Pressable
          onPress={onCareer}
          accessibilityRole="button"
          accessibilityLabel="Abrir Minha Carreira"
          hitSlop={8}
          style={{ minHeight: 44, justifyContent: 'center' }}>
          <Text style={link}>Minha Carreira ›</Text>
        </Pressable>
      </View>
    </View>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Próxima rodada (escalação planejada; o app não tem data, local nem confirmação de presença)
// ---------------------------------------------------------------------------------------------------------------
export type NextRoundData = { lineup_id: string; pelada_id: string; pelada_name: string; label: string; team_name: string; opponent_name: string };

export function NextRound({ round, more, onPress }: { round: NextRoundData; more: number; onPress: () => void }) {
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`Próxima rodada: ${round.label}. ${round.team_name} contra ${round.opponent_name}. Você está no ${round.team_name}. Ver rodada.`}>
      <View style={{ gap: 8 }}>
        <MatchScore
          a={round.team_name}
          b={round.opponent_name}
          scoreA={null}
          scoreB={null}
          mine="A"
          light
          top={
            <Text style={{ fontSize: 12, fontWeight: '700', letterSpacing: 0.6, color: colors.muted }} numberOfLines={1}>
              {round.label.toUpperCase()} · {round.pelada_name}
            </Text>
          }
        />
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 44 }}>
          <Text style={{ ...type.meta, flex: 1 }} numberOfLines={2}>
            Escalado no {round.team_name}
            {more > 0 ? ` · +${more} ${more === 1 ? 'rodada' : 'rodadas'} planejadas` : ''}
          </Text>
          <Text style={link}>Ver rodada ›</Text>
        </View>
      </View>
    </Pressable>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Último jogo da pelada selecionada
// ---------------------------------------------------------------------------------------------------------------
export type LastGameData = {
  match_id: string;
  played_at: string;
  status: string;
  team_a_name: string;
  team_b_name: string;
  team_a_score: number;
  team_b_score: number;
  me: { team: 'A' | 'B'; goals: number; assists: number } | null; // null = o jogador não jogou
  rating: MatchRating;
};

/**
 * Última partida oficial (ou em votação) da pelada: placar, se o jogador jogou, gols e assistências dele e a nota
 * publicada. Leituras com a mesma regra de acesso da tela da partida (RLS de membro ativo).
 */
export function useLastGame(peladaId: string | null, membershipId: string | null, reload: number) {
  const [state, setState] = useState<{ key: string; data: LastGameData | null; error: string | null } | null>(null);
  const key = `${peladaId}:${membershipId}`;
  useEffect(() => {
    if (!peladaId || !membershipId) return;
    let alive = true;
    void reload;
    (async () => {
      const { data: m, error } = await supabase
        .from('matches')
        .select('id, played_at, status, team_a_name, team_b_name, team_a_score:public_team_a_score, team_b_score:public_team_b_score')
        .eq('pelada_id', peladaId)
        .in('status', ['voting_open', 'finalizing', 'finalized'])
        .order('played_at', { ascending: false })
        .order('id', { ascending: false })
        .limit(1)
        .maybeSingle();
      if (!alive) return;
      if (error) return setState({ key, data: null, error: friendly(error.message) });
      if (!m) return setState({ key, data: null, error: null });
      const [part, res, sess, legacy] = await Promise.all([
        supabase.from('match_participants').select('id, team').eq('match_id', m.id).eq('membership_id', membershipId).maybeSingle(),
        supabase
          .from('match_player_results')
          .select('final_rating, has_valid_rating')
          .eq('match_id', m.id)
          .eq('membership_id', membershipId)
          .maybeSingle(),
        supabase.from('rating_vote_sessions').select('status, closes_at').eq('match_id', m.id).maybeSingle(),
        supabase.from('voting_sessions').select('status').eq('match_id', m.id).eq('status', 'finalized').maybeSingle(),
      ]);
      if (!alive) return;
      if (part.error) return setState({ key, data: null, error: friendly(part.error.message) });
      let me: LastGameData['me'] = null;
      if (part.data) {
        const { data: ev } = await supabase
          .from('match_events')
          .select('event_type, quantity')
          .eq('match_id', m.id)
          .eq('participant_id', part.data.id);
        if (!alive) return;
        const sum = (t: string) => (ev ?? []).filter((e) => e.event_type === t).reduce((n, e) => n + Number(e.quantity ?? 1), 0);
        me = { team: part.data.team as 'A' | 'B', goals: sum('goal'), assists: sum('assist') };
      }
      // Sessão v2 vencida mas ainda "open" no banco: para a Central já está aguardando publicação.
      const s = sess.data
        ? { status: sess.data.status === 'open' && new Date(sess.data.closes_at).getTime() <= Date.now() ? 'awaiting_publication' : sess.data.status }
        : null;
      const rating = matchRating({ played: !!me, result: res.data ?? null, session: s, legacyFinalized: !!legacy.data });
      setState({ key, data: { ...(m as Omit<LastGameData, 'me' | 'rating' | 'match_id'>), match_id: m.id, me, rating }, error: null });
    })();
    return () => {
      alive = false;
    };
  }, [peladaId, membershipId, reload, key]);
  return state && state.key === key ? state : null;
}

const RESULT = { win: 'Vitória', draw: 'Empate', loss: 'Derrota' } as const;
const RESULT_COLOR = { win: colors.blue, draw: colors.muted, loss: colors.danger } as const;
const fmtRating = (v: number) => v.toFixed(1).replace('.', ',');

export function LastGame({ game, onPress }: { game: LastGameData; onPress: () => void }) {
  const res = game.me ? resultOf(game.me.team, game.team_a_score, game.team_b_score) : null;
  const official = game.status === 'finalized';
  const mineA = game.me?.team === 'A';
  const mineB = game.me?.team === 'B';
  return (
    <Pressable onPress={onPress} accessibilityRole="button" accessibilityHint="Abre os detalhes da partida">
      <View style={{ gap: 10 }}>
        <MatchScore
          a={game.team_a_name}
          b={game.team_b_name}
          scoreA={game.team_a_score}
          scoreB={game.team_b_score}
          mine={mineA ? 'A' : mineB ? 'B' : null}
          top={
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
              <Text style={{ fontSize: 12, fontWeight: '700', letterSpacing: 0.4, color: '#9DB8E8', flex: 1 }} numberOfLines={1}>
                {fmtDate(game.played_at).toUpperCase()}
                {official ? '' : ' · NÃO OFICIAL'}
              </Text>
              {res && (
                <View style={{ paddingHorizontal: 8, paddingVertical: 2, borderRadius: radius.pill, backgroundColor: colors.white }}>
                  <Text style={{ fontSize: 12, fontWeight: '800', color: RESULT_COLOR[res] }}>{RESULT[res]}</Text>
                </View>
              )}
            </View>
          }
        />
        {game.me ? (
          <StatStrip
            items={[
              { value: game.me.goals, label: game.me.goals === 1 ? 'Gol' : 'Gols' },
              { value: game.me.assists, label: 'Assist.' },
              ratingItem(game.rating),
            ]}
          />
        ) : (
          <Text style={type.meta}>Você não jogou esta partida.</Text>
        )}
        <Text style={link}>Ver partida ›</Text>
      </View>
    </Pressable>
  );
}

function ratingItem(rating: MatchRating) {
  if (rating.kind === 'rated') return { value: fmtRating(rating.value), label: 'Nota da partida' };
  const text = rating.kind === 'pending' ? 'Aguardando' : rating.kind === 'insufficient' ? 'Insuficiente' : 'Sem votação';
  return { value: <Text style={{ fontSize: 14, lineHeight: 18, fontWeight: '700', color: colors.muted }}>{text}</Text>, label: 'Nota da partida', a11y: `Nota da partida: ${text}` };
}

// ---------------------------------------------------------------------------------------------------------------
// Resumo complementar (incentiva a aba Carreira; não repete o card)
// ---------------------------------------------------------------------------------------------------------------
export function CareerRecap({
  totals,
  conquests,
  hiddenSeasons,
  onPress,
}: {
  totals: { matches_played: number; wins: number; goals: number; assists: number };
  conquests: number;
  hiddenSeasons: number;
  onPress: () => void;
}) {
  const winRate = totals.matches_played ? Math.round((totals.wins / totals.matches_played) * 100) : null;
  return (
    <Pressable onPress={onPress} accessibilityRole="button" accessibilityLabel="Ver o histórico em Minha Carreira">
      <View style={{ gap: 10 }}>
        <StatStrip
          items={[
            { value: totals.matches_played, label: 'Jogos' },
            { value: winRate === null ? '–' : `${winRate}%`, label: 'Vitórias' },
            { value: totals.goals + totals.assists, label: 'Gols e assist.' },
            { value: conquests, label: 'Prêmios', gold: true, a11y: `Prêmios: ${conquests}` },
          ]}
        />
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 44 }}>
          <Text style={{ ...type.meta, flex: 1 }} numberOfLines={2}>
            Desde o primeiro jogo nesta pelada{hiddenSeasons > 0 ? ' (temporadas antigas no plano)' : ''}
          </Text>
          <Text style={link}>Carreira ›</Text>
        </View>
      </View>
    </Pressable>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Placeholders discretos e títulos
// ---------------------------------------------------------------------------------------------------------------
export function Skeleton({ height, style }: { height: number; style?: ViewStyle }) {
  return <View style={[{ height, borderRadius: radius.card, backgroundColor: colors.bg }, style]} accessibilityLabel="Carregando" />;
}

export function BlockTitle({ children, right }: { children: string; right?: ReactNode }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', marginTop: 8 }}>
      <Text style={{ ...type.section, fontSize: 17, lineHeight: 22, flex: 1 }} accessibilityRole="header">
        {children}
      </Text>
      {right}
    </View>
  );
}

export function InlineError({ text, onRetry }: { text: string; onRetry?: () => void }) {
  return (
    <View
      style={{ ...box, flexDirection: 'row', alignItems: 'center', gap: 12, borderColor: '#F3C7C2', shadowOpacity: 0, elevation: 0 }}
      accessibilityLiveRegion="polite">
      <Text style={{ ...type.caption, flex: 1, color: colors.danger }}>{text}</Text>
      {onRetry && (
        <Pressable onPress={onRetry} accessibilityRole="button" hitSlop={8} style={{ minHeight: 44, justifyContent: 'center' }}>
          <Text style={{ ...link, fontSize: 14 }}>Tentar de novo</Text>
        </Pressable>
      )}
    </View>
  );
}
