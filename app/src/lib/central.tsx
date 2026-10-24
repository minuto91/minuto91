// Central do Jogador 2.0 (24/10/2026): blocos da tela inicial. A tela (app/(tabs)/index.tsx) junta os dados; aqui
// ficam a apresentação e as duas leituras que dependem da pelada escolhida (OVR com a variação e o último jogo).
// Regras: tudo é da pelada selecionada (nunca misturar peladas), nada provisório aparece antes da publicação e nenhum
// valor é inventado para preencher a interface. As fórmulas (ATU, EST, PEQ, RES, DIS, OVR) e a votação não mudam aqui.
import { type ReactNode, useEffect, useState } from 'react';
import { Pressable, ScrollView, useWindowDimensions, View, type ViewStyle } from 'react-native';
import Svg, { Circle, Path } from 'react-native-svg';
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
          <Text style={{ ...type.meta, color: colors.muted }} numberOfLines={1}>
            Central do Jogador
          </Text>
          <Text style={{ fontSize: 20, lineHeight: 26, fontWeight: '800', color: colors.deepBlue }} numberOfLines={1}>
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
    <View accessibilityRole="tablist" accessibilityLabel="Escolher a pelada">
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8, paddingRight: 4 }}>
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
                borderWidth: 1.5,
                borderColor: on ? colors.blue : colors.line,
                backgroundColor: on ? '#EAF1FD' : colors.white,
              }}>
              <Crest path={p.crest_path} name={p.name} size={26} />
              <Text
                style={{ fontSize: 14, fontWeight: on ? '700' : '500', color: on ? colors.deepBlue : colors.ink, flexShrink: 1 }}
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
      style={{ ...box, borderColor: colors.gold, borderWidth: 1.5, backgroundColor: '#FFFBF0' }}
      accessibilityRole="summary"
      accessibilityLabel={`Votação perto do fim. ${scoreLine(vote)}. ${left}.`}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: colors.darkGold }} />
        <Text style={{ fontSize: 14, fontWeight: '700', color: colors.darkGold, flex: 1 }} numberOfLines={1}>
          Última hora
        </Text>
        <Text style={{ fontSize: 14, fontWeight: '800', color: colors.darkGold, fontVariant: ['tabular-nums'] }}>{left}</Text>
      </View>
      <Text style={type.cardTitle} numberOfLines={2}>
        {scoreLine(vote)}
      </Text>
      {progress !== null && (
        <View style={{ gap: 4 }}>
          <View style={{ height: 6, borderRadius: 3, backgroundColor: '#F1E6C8', overflow: 'hidden' }}>
            <View style={{ width: `${Math.round(progress * 100)}%`, height: 6, backgroundColor: colors.blue }} />
          </View>
          <Text style={type.meta}>
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
          backgroundColor: colors.blue,
          opacity: pressed ? 0.85 : 1,
          alignItems: 'center',
          justifyContent: 'center',
          marginTop: 2,
        })}>
        <Text style={{ color: colors.white, fontWeight: '700', fontSize: 16 }}>{vote.v2 && vote.started ? 'Continuar votação' : 'Votar agora'}</Text>
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
    <View style={{ ...box, paddingVertical: 4, gap: 0 }}>
      {shown.map((p, i) => (
        <Pressable
          key={p.key}
          onPress={p.onPress}
          accessibilityRole="button"
          accessibilityLabel={`${p.title}${p.detail ? `. ${p.detail}` : ''}. ${p.action}`}
          style={({ pressed }) => ({
            flexDirection: 'row',
            alignItems: 'center',
            gap: 12,
            minHeight: 60,
            paddingVertical: 8,
            borderTopWidth: i ? 1 : 0,
            borderTopColor: '#EEF2F8',
            opacity: pressed ? 0.7 : 1,
          })}>
          <View style={{ width: 4, alignSelf: 'stretch', borderRadius: 2, backgroundColor: p.tone === 'blue' ? colors.blue : colors.gold }} />
          <View style={{ flex: 1, gap: 2 }}>
            <Text style={{ fontSize: 15, fontWeight: '600', color: colors.ink }} numberOfLines={2}>
              {p.title}
            </Text>
            {p.detail ? (
              <Text style={type.meta} numberOfLines={2}>
                {p.detail}
              </Text>
            ) : null}
          </View>
          <Text style={{ ...link, fontSize: 14 }}>{p.action} ›</Text>
        </Pressable>
      ))}
      {items.length > 3 && (
        <Pressable
          onPress={() => setOpen((o) => !o)}
          accessibilityRole="button"
          accessibilityState={{ expanded: open }}
          style={{ minHeight: 44, justifyContent: 'center', borderTopWidth: 1, borderTopColor: '#EEF2F8' }}>
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

function Stat({ value, label }: { value: number | string; label: string }) {
  return (
    <View style={{ flex: 1, minWidth: 0 }} accessibilityLabel={`${label}: ${value}`}>
      <Text style={{ fontSize: 20, lineHeight: 24, fontWeight: '800', color: colors.deepBlue, fontVariant: ['tabular-nums'] }} numberOfLines={1}>
        {value}
      </Text>
      <Text style={{ fontSize: 12, color: colors.muted }} numberOfLines={1} adjustsFontSizeToFit minimumFontScale={0.8}>
        {label}
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

  // V6.0: o OVR aparece só dentro da carta compacta. A lateral traz a variação desde a última publicação e os
  // números da temporada; o bloco inteiro abre Minha Carreira.
  const delta = rating?.delta ?? null;
  const a11y = [
    `${data.name}, ${positionLabel(data.position)}`,
    ovr !== null ? `OVR ${ovr}${tier ? `, ${TIER[tier].label}` : ''}` : `avaliação em andamento, ${Math.min(played, 5)} de 5 partidas`,
    ovr !== null && delta !== null ? `variação ${deltaA11y(delta)}` : null,
    `${data.season?.matches_played ?? 0} jogos, ${data.season?.goals ?? 0} gols, ${data.season?.assists ?? 0} assistências`,
    'Abrir Minha Carreira',
  ]
    .filter(Boolean)
    .join('. ');

  return (
    <Pressable
      onPress={onCareer}
      accessibilityRole="button"
      accessibilityLabel={a11y}
      style={({ pressed }) => ({ ...box, padding: 14, gap: 12, opacity: pressed ? 0.92 : 1 })}>
      <View style={{ flexDirection: 'row', gap: narrow ? 12 : 16, alignItems: 'center' }} importantForAccessibility="no-hide-descendants">
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

        <View style={{ flex: 1, minWidth: 0, gap: 10 }}>
          <View style={{ gap: 2 }}>
            <Text style={{ ...type.cardTitle, color: colors.deepBlue }} numberOfLines={1}>
              {data.name}
            </Text>
            <Text style={type.meta} numberOfLines={1}>
              {positionLabel(data.position)}
              {tier && ovr !== null ? ` · ${TIER[tier].label}` : ''}
            </Text>
          </View>
          {ovr !== null ? (
            <View style={{ gap: 4 }}>
              <Text style={eyebrow}>Desde a última publicação</Text>
              {ratingLoading ? (
                <View style={{ height: 22, width: 56, borderRadius: radius.pill, backgroundColor: colors.bg }} />
              ) : delta !== null ? (
                <OvrDelta delta={delta} />
              ) : (
                <Text style={type.meta}>Sem publicação anterior</Text>
              )}
            </View>
          ) : (
            <View style={{ gap: 6 }}>
              <Text style={{ fontSize: 15, fontWeight: '800', color: colors.deepBlue }}>Avaliação em andamento</Text>
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
          <View style={{ flexDirection: 'row', gap: 6, borderTopWidth: 1, borderTopColor: '#EEF2F8', paddingTop: 10 }}>
            <Stat value={data.season?.matches_played ?? 0} label="Jogos" />
            <Stat value={data.season?.goals ?? 0} label="Gols" />
            <Stat value={data.season?.assists ?? 0} label="Assist." />
          </View>
        </View>
      </View>
      <View
        style={{ flexDirection: 'row', alignItems: 'center', borderTopWidth: 1, borderTopColor: '#EEF2F8', paddingTop: 10, minHeight: 34 }}
        importantForAccessibility="no-hide-descendants">
        <Text style={{ ...type.meta, flex: 1 }} numberOfLines={1}>
          {data.seasonName ?? data.peladaName}
        </Text>
        <Text style={link}>Minha Carreira ›</Text>
      </View>
    </Pressable>
  );
}

const eyebrow = { fontSize: 12, fontWeight: '600' as const, color: colors.muted };

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
      <View style={box}>
        <Text style={{ ...type.meta, color: colors.muted }} numberOfLines={1}>
          {round.label} · {round.pelada_name}
        </Text>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
          <Text style={{ ...type.cardTitle, flex: 1, textAlign: 'right' }} numberOfLines={1}>
            {round.team_name}
          </Text>
          <Text style={{ fontSize: 13, fontWeight: '800', color: colors.muted }}>×</Text>
          <Text style={{ ...type.cardTitle, flex: 1 }} numberOfLines={1}>
            {round.opponent_name}
          </Text>
        </View>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
          <Text style={{ ...type.meta, flex: 1 }} numberOfLines={2}>
            Você está escalado no {round.team_name}
            {more > 0 ? ` · +${more} ${more === 1 ? 'rodada' : 'rodadas'}` : ''}
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
        .select('id, played_at, status, team_a_name, team_b_name, team_a_score, team_b_score')
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
const RESULT_COLOR = { win: colors.blue, draw: colors.darkGold, loss: colors.danger } as const;
const fmtRating = (v: number) => v.toFixed(1).replace('.', ',');

export function LastGame({ game, onPress }: { game: LastGameData; onPress: () => void }) {
  const res = game.me ? resultOf(game.me.team, game.team_a_score, game.team_b_score) : null;
  const official = game.status === 'finalized';
  const mineA = game.me?.team === 'A';
  const mineB = game.me?.team === 'B';
  return (
    <Pressable onPress={onPress} accessibilityRole="button" accessibilityHint="Abre os detalhes da partida">
      <View style={box}>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
          <Text style={{ ...type.meta, flex: 1 }} numberOfLines={1}>
            {fmtDate(game.played_at)}
            {official ? '' : ' · resultado ainda não oficial'}
          </Text>
          {res && (
            <View
              style={{
                paddingHorizontal: 8,
                paddingVertical: 2,
                borderRadius: radius.pill,
                backgroundColor: res === 'win' ? '#EAF1FD' : res === 'loss' ? '#FDECEA' : '#FBF3DF',
              }}>
              <Text style={{ fontSize: 12, fontWeight: '800', color: RESULT_COLOR[res] }}>{RESULT[res]}</Text>
            </View>
          )}
        </View>
        <View
          style={{ flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 4 }}
          accessibilityLabel={`${game.team_a_name} ${game.team_a_score} a ${game.team_b_score} ${game.team_b_name}`}>
          <Text
            style={{ ...type.cardTitle, flex: 1, textAlign: 'right', fontWeight: mineA ? '800' : '500', color: mineA ? colors.deepBlue : colors.ink }}
            numberOfLines={2}>
            {game.team_a_name}
          </Text>
          <Text style={{ fontSize: 28, lineHeight: 34, fontWeight: '900', color: colors.deepBlue, fontVariant: ['tabular-nums'] }}>
            {game.team_a_score}
            <Text style={{ color: colors.muted, fontWeight: '600' }}> – </Text>
            {game.team_b_score}
          </Text>
          <Text
            style={{ ...type.cardTitle, flex: 1, fontWeight: mineB ? '800' : '500', color: mineB ? colors.deepBlue : colors.ink }}
            numberOfLines={2}>
            {game.team_b_name}
          </Text>
        </View>
        {game.me ? (
          <View style={{ flexDirection: 'row', gap: 6, borderTopWidth: 1, borderTopColor: '#EEF2F8', paddingTop: 10 }}>
            <Stat value={game.me.goals} label={game.me.goals === 1 ? 'Gol' : 'Gols'} />
            <Stat value={game.me.assists} label="Assist." />
            <RatingCell rating={game.rating} />
          </View>
        ) : (
          <Text style={type.meta}>Você não jogou esta partida.</Text>
        )}
        <Text style={link}>Ver partida ›</Text>
      </View>
    </Pressable>
  );
}

function RatingCell({ rating }: { rating: MatchRating }) {
  if (rating.kind === 'rated') return <Stat value={fmtRating(rating.value)} label="Nota da partida" />;
  const text = rating.kind === 'pending' ? 'Aguardando publicação' : rating.kind === 'insufficient' ? 'Avaliação insuficiente' : 'Sem votação';
  return (
    <View style={{ flex: 1.4, minWidth: 0 }} accessibilityLabel={`Nota da partida: ${text}`}>
      <Text
        style={{ fontSize: 13, lineHeight: 17, fontWeight: '700', color: colors.muted, minHeight: 24 }}
        numberOfLines={2}>
        {text}
      </Text>
      <Text style={{ fontSize: 12, color: colors.muted }}>Nota da partida</Text>
    </View>
  );
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
      <View style={box}>
        <View style={{ flexDirection: 'row', gap: 6 }}>
          <Stat value={totals.matches_played} label="Jogos" />
          <Stat value={winRate === null ? '–' : `${winRate}%`} label="Vitórias" />
          <Stat value={totals.goals + totals.assists} label="Gols e assist." />
          <View style={{ flex: 1, minWidth: 0 }} accessibilityLabel={`Prêmios: ${conquests}`}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
              <Svg width={14} height={14} viewBox="0 0 24 24">
                <Circle cx={12} cy={9} r={6} stroke={colors.gold} strokeWidth={2.2} fill="none" />
                <Path d="M8.5 14 7 21l5-2.5L17 21l-1.5-7" stroke={colors.gold} strokeWidth={2.2} fill="none" strokeLinejoin="round" />
              </Svg>
              <Text style={{ fontSize: 20, lineHeight: 24, fontWeight: '800', color: colors.darkGold, fontVariant: ['tabular-nums'] }}>
                {conquests}
              </Text>
            </View>
            <Text style={{ fontSize: 12, color: colors.muted }} numberOfLines={2}>
              Prêmios
            </Text>
          </View>
        </View>
        <Text style={type.meta}>
          Toda a sua história nesta pelada
          {hiddenSeasons > 0 ? ' (temporadas disponíveis no plano)' : ''}.
        </Text>
        <Text style={link}>Ver histórico completo ›</Text>
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
