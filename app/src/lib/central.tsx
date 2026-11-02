// Central do Jogador V8.4 (E01–E08, E10–E12): blocos da tela inicial. A tela (app/(tabs)/index.tsx) junta os dados;
// aqui ficam só a apresentação. Regras: tudo é da pelada ativa (nunca misturar peladas), nada provisório aparece antes
// da publicação oficial e nenhum valor é inventado. OVR, nota, prazo e estatística vêm prontos do servidor; as
// fórmulas (ATU, EST, PEQ, RES, DIS, OVR) e a votação não mudam aqui.
import { type ReactNode, useEffect, useState } from 'react';
import { ActivityIndicator, Animated, Pressable, View, type ViewStyle } from 'react-native';
import Svg, { Path } from 'react-native-svg';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Avatar } from './avatar';
import { Card as CardData, cardOverall, isV2, plural } from './career';
import type { LastGameRow, NextRoundItem, Pelada, PeladaRating } from './centraldata';
import { deltaA11y, deltaText, leftLabel, matchRating, type MatchRating } from './centrallogic';
import { Crest } from './crest';
import { hair, StatStrip, VotePendingRow } from './domain';
import { fmtDate } from './match';
import { haptic, useReducedMotion } from './motion';
import { CARD_RATIO, PlayerCard } from './playercard';
import { BottomSheet } from './sheet';
import { Text, TextInput } from './text';
import { colors, positionLabel, positionShort, radius, shadow, type } from './theme';
import { careerStats, filterPeladas, lastGameStats, orderForSelector, SEARCH_FROM, type StatCell } from './v84logic';

/** Cartão branco de borda sutil (E10): o padrão visual dos blocos da Central. */
export const box: ViewStyle = {
  backgroundColor: colors.white,
  borderRadius: radius.card,
  borderWidth: 1,
  borderColor: colors.line,
  padding: 16,
  gap: 10,
  ...shadow.card,
};
const link = { color: colors.blue, fontWeight: '600' as const, fontSize: 14 };
const eyebrow = { fontSize: 11, lineHeight: 14, fontWeight: '800' as const, letterSpacing: 0.9, color: colors.muted };

// ---------------------------------------------------------------------------------------------------------------
// E01 — Cabeçalho pessoal
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

/**
 * Foto circular de 52 px (iniciais como fallback), nome em destaque e, só se existirem, posição e OVR oficial da pelada
 * ativa. O sino é global (não filtra pela pelada) e mostra um ponto dourado quando há não lidas, nunca um número.
 */
export function CentralHeader({
  name,
  avatarPath,
  position,
  ovr,
  unread,
  onProfile,
  onBell,
}: {
  name: string | null;
  avatarPath: string | null | undefined;
  position: string | null;
  ovr: number | null;
  unread: boolean;
  onProfile: () => void;
  onBell: () => void;
}) {
  const sub = [position ? positionShort(position) : null, ovr !== null ? String(ovr) : null].filter(Boolean).join(' · ');
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
      <Pressable
        onPress={onProfile}
        accessibilityRole="button"
        accessibilityLabel={`Abrir meu perfil${name ? `, ${name}` : ''}`}
        style={{ flexDirection: 'row', alignItems: 'center', gap: 12, flex: 1, minHeight: 44 }}>
        <Avatar path={avatarPath} name={name ?? ' '} size={44} />
        <View style={{ flex: 1, minWidth: 0 }}>
          <Text style={{ fontSize: 20, lineHeight: 26, fontWeight: '700', color: colors.ink }} numberOfLines={1}>
            {name ?? ' '}
          </Text>
          {sub ? (
            <Text style={{ fontSize: 14, lineHeight: 19, fontWeight: '600', color: colors.muted }} numberOfLines={1} accessibilityLabel={ovr !== null ? `${position ? positionLabel(position) + ', ' : ''}OVR ${ovr}` : undefined}>
              {sub}
            </Text>
          ) : null}
        </View>
      </Pressable>
      <Pressable
        onPress={onBell}
        accessibilityRole="button"
        accessibilityLabel={unread ? 'Notificações, há avisos novos' : 'Notificações'}
        style={({ pressed }) => ({
          width: 48,
          height: 48,
          borderRadius: 24,
          alignItems: 'center',
          justifyContent: 'center',
          backgroundColor: pressed ? colors.bg : 'transparent',
        })}>
        <Bell color={colors.blue} />
        {unread && (
          <View
            accessibilityElementsHidden
            importantForAccessibility="no"
            style={{ position: 'absolute', top: 10, right: 11, width: 10, height: 10, borderRadius: 5, backgroundColor: colors.gold, borderWidth: 2, borderColor: colors.white }}
          />
        )}
      </Pressable>
    </View>
  );
}

/** Área segura do topo: a Central não usa o cabeçalho das abas (o cabeçalho próprio já identifica a tela). */
export function useTopInset() {
  return useSafeAreaInsets().top;
}

// ---------------------------------------------------------------------------------------------------------------
// E02 — Seletor da pelada ativa (cartão + Bottom Sheet)
// ---------------------------------------------------------------------------------------------------------------
const roleNote = (r: string) => (r === 'admin' ? 'Administrador' : r === 'assistant' ? 'Assistente' : 'Jogador');

function Chevrons({ color }: { color: string }) {
  const p = { stroke: color, strokeWidth: 1.9, fill: 'none', strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const };
  return (
    <Svg width={20} height={20} viewBox="0 0 24 24">
      <Path d="M7 9.5 12 5l5 4.5" {...p} />
      <Path d="M7 14.5 12 19l5-4.5" {...p} />
    </Svg>
  );
}

export function PeladaSelector({
  peladas,
  activeId,
  onSelect,
  disabledReason,
}: {
  peladas: Pelada[];
  activeId: string | null;
  /** Troca atômica: resolve só depois de o servidor confirmar; rejeita com a mensagem a mostrar. */
  onSelect: (id: string) => Promise<void>;
  /** Ex.: sem conexão. A troca exige o servidor. */
  disabledReason?: string | null;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const active = peladas.find((p) => p.id === activeId) ?? null;
  if (!active) return null;
  const several = peladas.length > 1;
  const ordered = filterPeladas(orderForSelector(peladas, activeId), query);

  const pick = async (id: string) => {
    if (busy) return;
    if (id === activeId) return setOpen(false);
    setBusy(id);
    setErr(null);
    try {
      await onSelect(id);
      haptic.select();
      setOpen(false);
      setQuery('');
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const body = (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
      <Crest path={active.crest_path} name={active.name} size={48} />
      <View style={{ flex: 1, minWidth: 0, gap: 2 }}>
        <Text style={eyebrow}>MINHA PELADA</Text>
        <Text style={{ fontSize: 17, lineHeight: 23, fontWeight: '700', color: colors.ink }} numberOfLines={1}>
          {active.name}
        </Text>
      </View>
      {several ? <Chevrons color={colors.muted} /> : null}
    </View>
  );

  return (
    <>
      {several ? (
        <Pressable
          onPress={() => {
            setErr(null);
            setOpen(true);
          }}
          accessibilityRole="button"
          accessibilityLabel={`Minha pelada: ${active.name}. Toque para trocar de pelada.`}
          style={({ pressed }) => ({ ...box, opacity: pressed ? 0.85 : 1, minHeight: 80, justifyContent: 'center' })}>
          {body}
        </Pressable>
      ) : (
        <View style={{ ...box, minHeight: 80, justifyContent: 'center' }} accessibilityLabel={`Minha pelada: ${active.name}`}>
          {body}
        </View>
      )}
      <BottomSheet visible={open} onClose={() => setOpen(false)} title="Escolher pelada">
        {peladas.length >= SEARCH_FROM && (
          <TextInput
            value={query}
            onChangeText={setQuery}
            placeholder="Buscar pelada"
            placeholderTextColor={colors.muted}
            accessibilityLabel="Buscar pelada"
            autoCorrect={false}
            style={{ borderWidth: 1, borderColor: colors.line, borderRadius: radius.md, paddingHorizontal: 14, minHeight: 48, fontSize: 16, color: colors.ink, marginBottom: 6 }}
          />
        )}
        {disabledReason ? <Text style={{ ...type.caption, color: colors.danger }}>{disabledReason}</Text> : null}
        {err ? (
          <Text style={{ ...type.caption, color: colors.danger }} accessibilityLiveRegion="polite">
            {err}
          </Text>
        ) : null}
        {ordered.length === 0 && <Text style={type.caption}>Nenhuma pelada com esse nome.</Text>}
        {ordered.map((p) => {
          const on = p.id === activeId;
          return (
            <Pressable
              key={p.id}
              onPress={() => pick(p.id)}
              disabled={!!disabledReason || !!busy}
              accessibilityRole="radio"
              accessibilityState={{ selected: on, busy: busy === p.id, disabled: !!disabledReason }}
              accessibilityLabel={`${p.name}, ${roleNote(p.role)}${on ? ', pelada ativa' : ''}`}
              style={({ pressed }) => ({
                flexDirection: 'row',
                alignItems: 'center',
                gap: 12,
                minHeight: 60,
                borderBottomWidth: 1,
                borderBottomColor: hair,
                opacity: disabledReason ? 0.5 : pressed ? 0.6 : 1,
              })}>
              <Crest path={p.crest_path} name={p.name} size={40} />
              <View style={{ flex: 1, minWidth: 0 }}>
                <Text style={{ fontSize: 16, fontWeight: on ? '800' : '600', color: colors.ink }} numberOfLines={1}>
                  {p.name}
                </Text>
                <Text style={type.meta}>{roleNote(p.role)}</Text>
              </View>
              {busy === p.id ? <ActivityIndicator color={colors.blue} /> : on ? <Text style={{ color: colors.blue, fontSize: 20, fontWeight: '800' }}>✓</Text> : null}
            </Pressable>
          );
        })}
      </BottomSheet>
    </>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Votação urgente (acima da Carta, E03) e Central de Atenção (E07)
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
export const voteLine = scoreLine;

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

export type AttentionItem = { key: string; rank: number; title: string; detail?: string; action: string; tone: 'blue' | 'gold'; onPress: () => void };

/**
 * E07: "Precisa de atenção" — 1 principal + até 2 secundárias; as demais ficam no Bottom Sheet. Some inteira quando não
 * há pendência elegível. Ler uma notificação não resolve pendência: a lista vem do estado real do servidor.
 */
export function AttentionBlock({ primary, secondary, rest, total, stale }: {
  primary: AttentionItem | null;
  secondary: AttentionItem[];
  rest: AttentionItem[];
  total: number;
  stale: boolean;
}) {
  const [open, setOpen] = useState(false);
  if (!primary) return null;
  const row = (p: AttentionItem, first: boolean) => (
    <VotePendingRow key={p.key} first={first} title={p.title} detail={p.detail} action={p.action} tone={p.tone} onPress={p.onPress} />
  );
  return (
    <View style={{ gap: 4 }}>
      <BlockTitle>Precisa de atenção</BlockTitle>
      <View style={{ ...box, paddingVertical: 6, gap: 0 }}>
        {row(primary, true)}
        {secondary.map((p) => row(p, false))}
        {rest.length > 0 && (
          <Pressable
            onPress={() => setOpen(true)}
            accessibilityRole="button"
            style={{ minHeight: 48, justifyContent: 'center', borderTopWidth: 1, borderTopColor: hair }}>
            <Text style={{ ...link, fontSize: 14 }}>{`Ver todas as pendências (${total})`}</Text>
          </Pressable>
        )}
        {stale && <Text style={{ ...type.meta, paddingBottom: 8 }}>Informação anterior: confirme ao abrir cada item.</Text>}
      </View>
      <BottomSheet visible={open} onClose={() => setOpen(false)} title="Pendências">
        {[primary, ...secondary, ...rest].map((p, i) => (
          <VotePendingRow key={p.key} first={i === 0} title={p.title} detail={p.detail} action={p.action} tone={p.tone} onPress={() => {
            setOpen(false);
            p.onPress();
          }} />
        ))}
      </BottomSheet>
    </View>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// E03 — Carta compacta e evolução
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
};

export const CARD_W = 150;

/** Carta "em avaliação" quando ainda não há carta: mesma silhueta neutra, sem número. */
function EvaluatingCard({ name, avatarPath, position }: { name: string; avatarPath: string | null | undefined; position: string | null }) {
  const height = Math.round(CARD_W * CARD_RATIO);
  return (
    <View
      accessibilityLabel={`Card de ${name} em avaliação`}
      style={{
        width: CARD_W,
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
      <Avatar path={avatarPath} name={name} size={Math.round(CARD_W * 0.46)} />
      <Text style={{ fontSize: 13, fontWeight: '800', color: colors.ink }}>{positionShort(position)}</Text>
      <Text style={{ fontSize: 12, fontWeight: '600', color: colors.muted, textAlign: 'center' }} numberOfLines={1} adjustsFontSizeToFit minimumFontScale={0.7}>
        {name}
      </Text>
    </View>
  );
}

/** OVR oficial exibido: o da V5; sem registro na V5, o da carta (nunca antes de 5 partidas disputadas e publicadas). */
export function officialOvr(rating: PeladaRating | null, card: Omit<CardData, 'id'> | null): number | null {
  const r = rating?.rating ?? null;
  if (r) return r.eligible ? r.ovr : null;
  const legacy = card ? cardOverall(card) : null;
  return legacy !== null && (card?.matches_played ?? 0) >= 5 ? legacy : null;
}

export function OvrDelta({ delta }: { delta: number }) {
  const up = delta > 0;
  const fg = up ? '#0B6B3A' : '#9A3412';
  const bg = up ? '#E7F5EC' : '#FDEEE6';
  return (
    <View
      accessibilityLabel={`Card ${deltaA11y(delta)}`}
      style={{ flexDirection: 'row', alignItems: 'center', gap: 4, paddingHorizontal: 10, paddingVertical: 4, borderRadius: radius.pill, backgroundColor: bg, alignSelf: 'flex-start' }}>
      {/* Seta e sinal: a variação não depende só da cor. */}
      <Text style={{ fontSize: 12, fontWeight: '800', color: fg }} importantForAccessibility="no" accessibilityElementsHidden>
        {up ? '▲' : '▼'}
      </Text>
      <Text style={{ fontSize: 17, fontWeight: '800', color: fg, fontVariant: ['tabular-nums'] }}>{deltaText(delta)}</Text>
    </View>
  );
}

/**
 * Carta oficial compacta (104 px) à esquerda; à direita, "variação do Card" desde a última publicação oficial, e o link
 * Minha Carreira. A Carta e o link abrem o MESMO destino. Sem variação "+0"/"−0"; sem OVR duplicado ao lado da Carta.
 */
export function CardEvolution({
  data,
  rating,
  loading,
  unavailable,
  stale,
  onCareer,
}: {
  data: HeroData;
  rating: PeladaRating | null;
  loading: boolean;
  /** A leitura do OVR falhou: não se afirma "primeira avaliação" nem variação. */
  unavailable?: boolean;
  stale: boolean;
  onCareer: () => void;
}) {
  const card = data.card;
  const ovr = officialOvr(rating, card);
  const r = rating?.rating ?? null;
  const played = r?.matches_played ?? card?.matches_played ?? 0;
  const delta = rating?.delta ?? null;
  const showOfficialCard = !!card && (ovr !== null || isV2(card));

  let evolution: ReactNode;
  if (loading) {
    evolution = <Skeleton height={20} style={{ width: 120 }} />;
  } else if (unavailable) {
    evolution = <Text style={type.meta}>Evolução indisponível agora</Text>;
  } else if (ovr === null) {
    const needed = Math.max(0, 5 - played);
    evolution = (
      <View style={{ gap: 6 }} accessibilityLabel={`Aguardando avaliação: ${Math.min(played, 5)} de 5 partidas`}>
        <Text style={{ fontSize: 16, fontWeight: '800', color: colors.ink }}>Aguardando avaliação</Text>
        <View style={{ flexDirection: 'row', gap: 4 }}>
          {[0, 1, 2, 3, 4].map((i) => (
            <View key={i} style={{ flex: 1, height: 6, borderRadius: 3, backgroundColor: i < played ? colors.blue : colors.line }} />
          ))}
        </View>
        <Text style={type.meta}>
          {Math.min(played, 5)} de 5 partidas
          {needed > 0 ? ` · faltam ${plural(needed, 'partida', 'partidas')}` : ''}
        </Text>
      </View>
    );
  } else if (delta !== null && delta !== 0) {
    evolution = (
      <View style={{ gap: 4 }}>
        <OvrDelta delta={delta} />
      </View>
    );
  } else if (delta === 0) {
    evolution = null;
  } else {
    evolution = null;
  }

  const hasSide = evolution !== null || (stale && !loading);
  return (
    <View style={{ ...box, flexDirection: 'row', gap: 16, alignItems: 'center' }}>
      <Pressable onPress={onCareer} accessibilityRole="button" accessibilityLabel="Abrir Minha Carreira pelo Card" accessibilityHint="Abre Minha Carreira">
        {showOfficialCard ? (
          <PlayerCard
            card={{ id: 'central', ...card! }}
            playerName={data.name}
            photoPath={data.avatarPath}
            peladaName={data.peladaName}
            crestPath={data.crestPath}
            seasonName={data.seasonName ?? ''}
            seasonStart={data.seasonStart}
            width={CARD_W}
          />
        ) : (
          <EvaluatingCard name={data.name} avatarPath={data.avatarPath} position={data.position} />
        )}
      </Pressable>
      {hasSide && (
        <View style={{ flex: 1, minWidth: 0, gap: 8 }}>
          {evolution}
          {stale && !loading && <Text style={type.meta}>Pode estar desatualizada</Text>}
        </View>
      )}
    </View>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// E04 — Próxima Rodada
// ---------------------------------------------------------------------------------------------------------------
export function NextRoundCard({ round, crestPath, more, stale, onPress }: { round: NextRoundItem; crestPath?: string | null; more: number; stale: boolean; onPress: () => void }) {
  // Data, horário e local só aparecem quando oficialmente existem (o servidor ainda não guarda esses dados).
  const when = round.scheduled_at ? new Date(round.scheduled_at) : null;
  const hasDate = !!when && !Number.isNaN(when.getTime());
  const time = hasDate ? when!.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }) : null;
  const day = hasDate ? when!.toLocaleDateString('pt-BR', { weekday: 'short', day: '2-digit', month: '2-digit' }) : null;
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`Próxima rodada: ${round.label}. ${round.team_name} contra ${round.opponent_name}. Você está no ${round.team_name}.${time ? ` ${time}.` : ''}${round.location ? ` ${round.location}.` : ''} Ver rodada.`}
      style={({ pressed }) => ({ ...box, flexDirection: 'row', gap: 14, alignItems: 'center', opacity: pressed ? 0.9 : 1 })}>
      {/* Escudo da pelada em que a partida será jogada. */}
      <Crest path={crestPath} name={round.pelada_name} size={56} />
      <View style={{ flex: 1, minWidth: 0, gap: 3 }}>
        <Text style={{ fontSize: 16, lineHeight: 21, fontWeight: '700', color: colors.ink }} numberOfLines={1}>
          {round.team_name} × {round.opponent_name}
        </Text>
        <Text style={type.meta} numberOfLines={2}>
          {[round.pelada_name, round.label, day, time, round.location, round.rescheduled ? 'Remarcada' : null, 'Escalação prevista'].filter(Boolean).join(' · ')}
          {more > 0 ? ` · +${more} ${more === 1 ? 'rodada' : 'rodadas'}` : ''}
        </Text>
        {stale ? <Text style={type.meta}>Informação anterior: confirme na rodada.</Text> : null}
        <Text style={{ ...link, fontSize: 14 }}>Ver rodada ›</Text>
      </View>
    </Pressable>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// E05 — Último Jogo
// ---------------------------------------------------------------------------------------------------------------
const fmtRating = (v: number) => v.toFixed(1).replace('.', ',');

function ratingOf(g: LastGameRow): MatchRating {
  return matchRating({
    played: true,
    result: { final_rating: g.final_rating, has_valid_rating: g.has_valid_rating },
    session: g.rating_session_status ? { status: g.rating_session_status } : null,
    legacyFinalized: g.legacy_finalized,
  });
}

export function LastGameCard({ game, stale, onPress }: { game: LastGameRow; stale: boolean; onPress: () => void }) {
  const rating = ratingOf(game);
  const stats: StatCell[] = lastGameStats(game.position, game);
  const side = (name: string, mine: boolean, align: 'left' | 'right') => (
    <View style={{ flex: 1, minWidth: 0, alignItems: align === 'right' ? 'flex-end' : 'flex-start', gap: 2 }}>
      <Text style={{ fontSize: 16, lineHeight: 21, fontWeight: mine ? '800' : '500', color: mine ? colors.blue : colors.muted, textAlign: align }} numberOfLines={2}>
        {name}
      </Text>
    </View>
  );
  const noteText = rating.kind === 'rated' ? fmtRating(rating.value) : 'Aguardando nota';
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`Último jogo, ${fmtDate(game.played_at)}. ${game.team_a_name} ${game.team_a_score} a ${game.team_b_score} ${game.team_b_name}. Sua nota: ${noteText}. Ver partida.`}
      style={({ pressed }) => ({ ...box, opacity: pressed ? 0.9 : 1 })}>
      <Text style={eyebrow}>
        {fmtDate(game.played_at).toUpperCase()}
        {stale ? ' · PODE ESTAR DESATUALIZADO' : ''}
      </Text>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        {side(game.team_a_name, game.my_team === 'A', 'right')}
        <Text style={{ fontSize: 32, lineHeight: 38, fontWeight: '900', color: colors.ink, fontVariant: ['tabular-nums'] }}>
          {game.team_a_score}–{game.team_b_score}
        </Text>
        {side(game.team_b_name, game.my_team === 'B', 'left')}
      </View>
      <View style={{ flexDirection: 'row', alignItems: 'flex-start', gap: 16, borderTopWidth: 1, borderTopColor: hair, paddingTop: 10 }}>
        <View accessible accessibilityLabel={`Sua nota: ${noteText}`} style={{ minWidth: 88 }}>
          <Text style={{ fontSize: rating.kind === 'rated' ? 26 : 14, lineHeight: 32, fontWeight: rating.kind === 'rated' ? '800' : '600', color: rating.kind === 'rated' ? colors.ink : colors.muted, fontVariant: ['tabular-nums'] }}>
            {noteText}
          </Text>
          {rating.kind === 'rated' && <Text style={{ fontSize: 11, fontWeight: '800', letterSpacing: 0.8, color: colors.muted }}>SUA NOTA</Text>}
        </View>
        <View style={{ flex: 1 }}>
          <StatStrip size="sm" items={stats.map((s) => ({ value: s.value, label: s.label }))} />
        </View>
      </View>
      <Text style={link}>Ver partida ›</Text>
    </Pressable>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// E06 — Resumo da Carreira
// ---------------------------------------------------------------------------------------------------------------
export function CareerSummaryCard({
  position,
  totals,
  stale,
  onPress,
}: {
  position: string | null;
  totals: { matches_played: number; wins: number; draws: number; losses: number; goals: number; assists: number };
  stale: boolean;
  onPress: () => void;
}) {
  const stats = careerStats(position, totals);
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`Resumo da carreira. ${stats.map((s) => `${s.label}: ${s.value}`).join('. ')}. Abrir Minha Carreira.`}
      style={({ pressed }) => ({ ...box, opacity: pressed ? 0.9 : 1 })}>
      <StatStrip items={stats.map((s) => ({ value: s.value, label: s.label }))} />
      <View style={{ flexDirection: 'row', alignItems: 'center', minHeight: 44 }}>
        <Text style={{ ...type.meta, flex: 1 }}>{stale ? 'Pode estar desatualizado' : 'Nesta pelada'}</Text>
        <Text style={link}>Minha Carreira ›</Text>
      </View>
    </Pressable>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// E08 — Minhas Peladas
// ---------------------------------------------------------------------------------------------------------------
export function MyPeladasBlock({
  shown,
  seeAll,
  onOpen,
  onSeeAll,
}: {
  shown: Pelada[];
  seeAll: boolean;
  onOpen: (p: Pelada) => void;
  onSeeAll: () => void;
}) {
  return (
    <View style={{ gap: 4 }}>
      <BlockTitle right={seeAll ? <Pressable onPress={onSeeAll} accessibilityRole="button" style={{ minHeight: 44, justifyContent: 'center' }}><Text style={{ ...link, fontSize: 14 }}>Ver todas ›</Text></Pressable> : undefined}>
        Minhas Peladas
      </BlockTitle>
      <View style={{ ...box, paddingVertical: 4, gap: 0 }}>
        {shown.map((p, i) => (
          <Pressable
            key={p.id}
            onPress={() => onOpen(p)}
            accessibilityRole="button"
            accessibilityLabel={`Abrir ${p.name}, ${roleNote(p.role)}`}
            style={({ pressed }) => ({ flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 60, borderTopWidth: i ? 1 : 0, borderTopColor: hair, opacity: pressed ? 0.6 : 1 })}>
            <Crest path={p.crest_path} name={p.name} size={40} />
            <View style={{ flex: 1, minWidth: 0 }}>
              <Text style={{ fontSize: 16, fontWeight: '700', color: colors.ink }} numberOfLines={1}>
                {p.name}
              </Text>
              <Text style={type.meta}>{roleNote(p.role)}</Text>
            </View>
            <Text style={{ color: colors.muted, fontSize: 20 }}>›</Text>
          </Pressable>
        ))}
      </View>
    </View>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// E11/E16 — Placeholders, títulos e avisos
// ---------------------------------------------------------------------------------------------------------------
/** Skeleton discreto (E16-05/07/37): sem pulsar quando o sistema pede movimento reduzido. */
export function Skeleton({ height, style }: { height: number; style?: ViewStyle }) {
  const reduced = useReducedMotion();
  const [opacity] = useState(() => new Animated.Value(1));
  useEffect(() => {
    if (reduced) {
      opacity.setValue(1);
      return;
    }
    const loop = Animated.loop(
      Animated.sequence([Animated.timing(opacity, { toValue: 0.55, duration: 900, useNativeDriver: true }), Animated.timing(opacity, { toValue: 1, duration: 900, useNativeDriver: true })]),
    );
    loop.start();
    return () => loop.stop();
  }, [reduced, opacity]);
  return <Animated.View style={[{ height, borderRadius: radius.card, backgroundColor: colors.bg, opacity }, style]} accessibilityElementsHidden importantForAccessibility="no" />;
}

export function BlockTitle({ children, right }: { children: string; right?: ReactNode }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', minHeight: 28 }}>
      <Text style={{ ...type.section, fontSize: 17, lineHeight: 22, flex: 1 }} accessibilityRole="header">
        {children}
      </Text>
      {right}
    </View>
  );
}

/** Erro localizado de um bloco (E16-10/11): só aquele bloco, com "tentar de novo". */
export function InlineError({ text, onRetry }: { text: string; onRetry?: () => void }) {
  return (
    <View style={{ ...box, flexDirection: 'row', alignItems: 'center', gap: 12, borderColor: '#F3C7C2', shadowOpacity: 0, elevation: 0 }} accessibilityLiveRegion="polite">
      <Text style={{ ...type.caption, flex: 1, color: colors.danger }}>{text}</Text>
      {onRetry && (
        <Pressable onPress={onRetry} accessibilityRole="button" hitSlop={8} style={{ minHeight: 44, justifyContent: 'center' }}>
          <Text style={{ ...link, fontSize: 14 }}>Tentar de novo</Text>
        </Pressable>
      )}
    </View>
  );
}

/** Aviso geral único (E11/E16-43): offline ou desatualizado, proporcional, com a última sincronização só se real. */
export function Notice({ tone, children }: { tone: 'warn' | 'info'; children: ReactNode }) {
  return (
    <View
      accessibilityRole="alert"
      accessibilityLiveRegion="polite"
      style={{ borderRadius: radius.md, backgroundColor: tone === 'warn' ? '#FFF6E0' : colors.bg, paddingHorizontal: 14, paddingVertical: 10 }}>
      <Text style={{ fontSize: 13, lineHeight: 18, color: tone === 'warn' ? colors.darkGold : colors.deepBlue, fontWeight: '600' }}>{children}</Text>
    </View>
  );
}
