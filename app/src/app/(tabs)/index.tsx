import AsyncStorage from '@react-native-async-storage/async-storage';
import { type Href, useFocusEffect, useIsFocused } from 'expo-router';
import { type ComponentProps, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AppState, Pressable, RefreshControl, ScrollView, type ScrollViewInstance, View } from 'react-native';

import {
  AttentionBlock,
  type AttentionItem,
  BlockTitle,
  CardEvolution,
  InlineError,
  Notice,
  officialOvr,
  Skeleton,
  UrgentVote,
  useTopInset,
  type VoteItem,
  voteLine,
} from '../../lib/central';
import {
  type CentralData,
  type HomeRatings,
  loadCentral,
  loadHomeLastGame,
  loadHomeRatings,
  loadLayout,
  loadUnread,
  useBlock,
} from '../../lib/centraldata';
import { leftLabel, nextVoteBoundary, voteState } from '../../lib/centrallogic';
import { type CareerSummary, loadCareerSummary, markGuide, referencePelada } from '../../lib/careerv2';
import { StatStrip } from '../../lib/domain';
import { refreshOutcome, syncedLabel } from '../../lib/loadstate';
import { GreetingHeader, HomeLastGameCard, NextGameCard } from '../../lib/homeui';
import { greetingText, pickCard, pickGreetingIndex, pickNextRound } from '../../lib/homelogic';
import { notify } from '../../lib/dialog';
import { haptic } from '../../lib/motion';
import { useGo } from '../../lib/nav';
import { PushPrompt } from '../../lib/push';
import { useAuth } from '../../lib/session';
import { supabase } from '../../lib/supabase';
import { onHomeTabRepress } from '../../lib/tabevents';
import { Text } from '../../lib/text';
import { colors, layout as L, type } from '../../lib/theme';
import { Icon } from '../../lib/icons';
import { Button, Card, EmptyState } from '../../lib/ui';
import { type BlockId, normalizeLayout, splitAttention, visibleSportBlocks } from '../../lib/v84logic';

// O convite guardado antes do login abre sozinho uma vez por sessão do app; depois fica como pendência até ser
// aceito (ou se mostrar inválido) na tela do convite, que o apaga.
let inviteOpened = false;
const GREETING_KEY = (uid: string) => `home_greeting:${uid}`;
// Ordem fixa dos blocos esportivos (REV-052): Card, Próximo Jogo, Último Jogo, Resumo da Carreira.
const SPORT_ORDER: BlockId[] = ['next_round', 'last_game', 'career_summary'];

// Início do jogador (V10.0, REV-051 a REV-095): visão geral de TODAS as peladas, sem pelada ativa nem seletor. O Card é o
// de maior OVR entre as peladas; Próximo/Último Jogo e Resumo da Carreira somam todas. Cada bloco carrega sozinho
// (useBlock): uma falha localizada não derruba a tela, o cache só alimenta leitura e nada aqui recalcula OVR ou nota.
export default function Home() {
  const { session } = useAuth();
  const go = useGo();
  const top = useTopInset();
  const focused = useIsFocused();
  const uid = session?.user.id ?? '';
  const [reload, setReload] = useState(0);
  const [pendingInvite, setPendingInvite] = useState<string | null>(null);
  const [, setTick] = useState(0);
  const [awaiting, setAwaiting] = useState(false);
  const [refreshMsg, setRefreshMsg] = useState<string | null>(null);
  const [greetIdx, setGreetIdx] = useState(0);
  const scrollRef = useRef<ScrollViewInstance>(null);
  const scrollY = useRef(0);
  const armed = useRef(false);
  const lastForeground = useRef(0);

  // ---- Leituras independentes (E16-03) ----------------------------------------------------------------------
  const central = useBlock<CentralData>({ uid, scope: 'central', load: loadCentral, reload });
  const peladas = central.data?.peladas ?? [];
  const peladaKey = peladas.map((p) => p.membership_id).join(',');

  const layoutBlock = useBlock<unknown>({ uid, scope: 'layout', load: loadLayout, reload });
  const unread = useBlock<boolean>({ uid, scope: 'unread', load: loadUnread, reload, cacheable: false });
  const career = useBlock<CareerSummary>({ uid, scope: 'career', load: async () => ({ data: await loadCareerSummary(uid) }), reload });
  const ratings = useBlock<HomeRatings>({ uid, scope: peladas.length ? `ratings:${peladaKey}` : null, load: () => loadHomeRatings(peladas), reload });
  const last = useBlock({ uid, scope: 'home-last', load: loadHomeLastGame, reload });
  const account = useBlock<{ purge_after: string | null }>({
    uid,
    scope: 'account',
    reload,
    cacheable: false,
    load: async () => {
      const { data, error } = await supabase.rpc('get_account_status');
      if (error) throw error;
      return { data: { purge_after: (data as { purge_after: string | null } | null)?.purge_after ?? null } };
    },
  });
  const purgeAfter = account.data?.purge_after ?? null;

  // Relógio do servidor só de resposta confirmada agora (nunca de cache): base de qualquer afirmação de prazo.
  const fresh = central.status === 'loaded' && !central.stale;
  const offset = fresh ? (central.data?.offset_ms ?? 0) : 0;

  // Convite recebido antes do login: continua de onde parou (uma vez por sessão do app).
  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        const invite = await AsyncStorage.getItem('pending_invite').catch(() => null);
        if (!alive) return;
        setPendingInvite(invite);
        if (invite && !inviteOpened) {
          inviteOpened = true;
          go({ pathname: '/convite/[token]', params: { token: invite } });
        }
      })();
      return () => {
        alive = false;
      };
    }, [go]),
  );

  // Saudação (REV-053/093): sorteada ao entrar na tela, sem repetir a anterior (guardada no aparelho); atualizar dados
  // não sorteia de novo — só voltar à aba.
  useEffect(() => {
    if (!focused || !uid) return;
    let alive = true;
    (async () => {
      const prevRaw = await AsyncStorage.getItem(GREETING_KEY(uid)).catch(() => null);
      const next = pickGreetingIndex(prevRaw === null || Number.isNaN(Number(prevRaw)) ? null : Number(prevRaw));
      if (alive) setGreetIdx(next);
      await AsyncStorage.setItem(GREETING_KEY(uid), String(next)).catch(() => {});
    })();
    return () => {
      alive = false;
    };
  }, [focused, uid]);

  // Ao voltar para o app: relê (no máximo a cada 20 s). Leitura apenas.
  useEffect(() => {
    const sub = AppState.addEventListener('change', (s) => {
      if (s !== 'active') return;
      const now = Date.now();
      if (now - lastForeground.current < 20_000) return;
      lastForeground.current = now;
      setReload((n) => n + 1);
    });
    return () => sub.remove();
  }, []);

  // Voltar a esta aba depois de abrir outra tela relê também (dados podem ter mudado lá dentro).
  const seenFocus = useRef(false);
  useEffect(() => {
    if (!focused) return;
    if (seenFocus.current) setReload((n) => n + 1);
    seenFocus.current = true;
  }, [focused]);

  // E09: toque repetido na aba Início. Na raiz rolada: topo. Na raiz e no topo: atualização de leitura (deduplicada).
  useEffect(
    () =>
      onHomeTabRepress(() => {
        if (!focused) return;
        if (scrollY.current > 8) scrollRef.current?.scrollTo({ y: 0, animated: true });
        else if (!awaiting) startRefresh();
      }),
    [focused, awaiting],
  );

  // Urgência muda sozinha quando falta 1 hora e quando o prazo vence (e relê: prorrogação vem no prazo novo).
  const allVotes = fresh ? central.data?.pending.votes : undefined;
  useEffect(() => {
    const at = nextVoteBoundary((allVotes ?? []).map((v) => v.closes_at), offset);
    if (!at) return;
    const timer = setTimeout(
      () => {
        setTick((n) => n + 1);
        setReload((n) => n + 1);
      },
      Math.min(at - Date.now() + 1000, 2 ** 31 - 1),
    );
    return () => clearTimeout(timer);
  }, [allVotes, offset]);
  const hasUrgent = (allVotes ?? []).some((v) => voteState(v.closes_at, offset) === 'urgent');
  useEffect(() => {
    if (!hasUrgent) return;
    const t = setInterval(() => setTick((n) => n + 1), 30000);
    return () => clearInterval(t);
  }, [hasUrgent]);

  // ---- Atualização por puxar (E16-15/18/39): só leitura, conteúdo válido preservado ------------------------------
  function startRefresh() {
    armed.current = false;
    setRefreshMsg(null);
    setAwaiting(true);
    setReload((n) => n + 1);
  }
  const tracked = [central, career, last, ...(peladas.length ? [ratings] : [])];
  const anyBusy = tracked.some((b) => b.refreshing || b.status === 'loading');
  useEffect(() => {
    if (!awaiting) return;
    if (anyBusy) {
      armed.current = true;
      return;
    }
    if (!armed.current) return;
    setAwaiting(false);
    const outcome = refreshOutcome(tracked.map((b) => (b.status === 'loaded' || b.status === 'empty_confirmed') && !b.stale ? 'ok' : 'fail'));
    setRefreshMsg(outcome === 'complete' ? 'Atualizado.' : outcome === 'partial' ? 'Atualizado em parte: alguns blocos não carregaram.' : 'Não foi possível atualizar agora.');
    if (outcome === 'complete') haptic.success();
    const t = setTimeout(() => setRefreshMsg(null), 3500);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [awaiting, anyBusy]);

  const offline = tracked.some((b) => b.status === 'offline_cached' || b.status === 'offline_uncached');

  // ---- Blocos derivados -----------------------------------------------------------------------------------------
  const lay = useMemo(() => (layoutBlock.status === 'loaded' || layoutBlock.status === 'offline_cached' ? normalizeLayout(layoutBlock.data) : normalizeLayout(null)), [layoutBlock.status, layoutBlock.data]);
  const visibleSet = new Set(visibleSportBlocks(lay));
  const me = central.data?.me;
  const centralTrusted = fresh;
  const careerData = career.data?.visible ? career.data : null;

  // Card (REV-055/079/080): o de maior OVR entre as peladas; sem OVR elegível, a pelada de referência com o estado
  // "Aguardando avaliação" (nunca um valor inventado).
  const candidates = peladas.map((p) => {
    const cp = careerData?.peladas.find((x) => x.pelada_id === p.id) ?? null;
    const card = cp?.seasons.find((s) => s.card)?.card ?? null;
    const r = ratings.data?.[p.id] ?? null;
    const ovr = officialOvr(r?.rating ?? null, card);
    return { pelada_id: p.id, eligible: ovr !== null, ovr, matches: cp?.totals.matches_played ?? 0, last_played_at: r?.lastPlayedAt ?? null };
  });
  const best = pickCard(candidates);
  const refId = referencePelada(careerData?.peladas ?? [], central.data?.primary_pelada_id ?? null)?.pelada_id ?? peladas[0]?.id ?? null;
  const cardPid = best?.pelada_id ?? refId;
  const pelada = peladas.find((p) => p.id === cardPid) ?? null;
  const cp = careerData?.peladas.find((p) => p.pelada_id === cardPid) ?? null;
  const cardSeason = cp?.seasons.find((s) => s.card) ?? null;
  const season = cp?.seasons[0] ?? null;
  const position = pelada ? (pelada.position_code ?? pelada.position) : null;
  const cardRating = cardPid ? (ratings.data?.[cardPid]?.rating ?? null) : null;

  // Pendências: todas as peladas (não há pelada ativa).
  const votes = (central.data?.pending.votes ?? []).filter((v) => voteState(v.closes_at, offset) !== 'closed');
  const urgent = centralTrusted ? votes.filter((v) => voteState(v.closes_at, offset) === 'urgent') : [];
  const urgentIds = new Set(urgent.map((v) => v.match_id));
  const openVote = (v: VoteItem) => go({ pathname: v.v2 ? '/partida/[id]/votar' : '/partida/[id]', params: { id: v.match_id } });

  const attention: AttentionItem[] = [
    ...votes
      .filter((v) => !urgentIds.has(v.match_id))
      .map((v) => ({
        key: `v${v.match_id}`,
        rank: 1,
        title: `Votação aberta: ${voteLine(v)}`,
        detail: `${v.pelada_name} · ${centralTrusted ? leftLabel(v.closes_at, offset) : 'Prazo a confirmar'}${v.v2 && v.total ? ` · você avaliou ${v.rated} de ${v.total}` : ''}`,
        action: v.v2 && v.started ? 'Continuar' : 'Votar',
        tone: 'blue' as const,
        onPress: () => openVote(v),
      })),
    ...(pendingInvite
      ? [
          {
            key: 'invite',
            rank: 2,
            title: 'Você tem um convite para aceitar',
            detail: 'Veja a pelada e entre.',
            action: 'Ver',
            tone: 'blue' as const,
            onPress: () => go({ pathname: '/convite/[token]', params: { token: pendingInvite } }),
          },
        ]
      : []),
    ...(central.data?.pending.positions ?? []).map((p) => ({
      key: `p${p.membership_id}`,
      rank: 3,
      title: `Escolha sua posição em ${p.pelada_name}`,
      action: 'Escolher',
      tone: 'gold' as const,
      onPress: () => go({ pathname: '/jogador/[id]', params: { id: p.membership_id } }),
    })),
    ...(central.data?.pending.profile.photo && peladas.length > 0
      ? [
          {
            key: 'photo',
            rank: 4,
            title: 'Coloque uma foto no seu perfil',
            detail: 'Ela aparece no seu Card.',
            action: 'Perfil',
            tone: 'gold' as const,
            onPress: () => go('/perfil'),
          },
        ]
      : []),
  ];
  const att = splitAttention(attention);

  const nextGame = pickNextRound(central.data?.next_rounds ?? []);
  const stale = central.stale;
  const sync = syncedLabel(central.syncedAt, Date.now());

  async function dispensarGuia() {
    await markGuide('dismiss').catch(() => {});
    setReload((n) => n + 1);
  }
  const steps = central.data ? guideSteps(central.data, (h) => go(h)) : [];
  const showGuide = !!central.data && !central.data.guide.dismissed && steps.some((s) => !s.done);

  // ---- Blocos esportivos (REV-056 a REV-058) ------------------------------------------------------------------------
  function renderBlock(id: BlockId) {
    if (id === 'next_round') {
      return (
        <View key={id} style={{ gap: 4 }}>
          <BlockTitle>Próximo Jogo</BlockTitle>
          {nextGame ? (
            <NextGameCard
              round={nextGame}
              crestPath={peladas.find((x) => x.id === nextGame.pelada_id)?.crest_path}
              stale={!centralTrusted}
              onPress={async () => {
                // REV-096: se a partida foi cancelada ou removida, avisa e atualiza em vez de abrir.
                if (nextGame.match_id) {
                  const { data: mm } = await supabase.from('matches').select('status').eq('id', nextGame.match_id).maybeSingle();
                  if (!mm || mm.status === 'cancelled' || mm.status === 'annulled') {
                    notify('Partida indisponível', 'Esta partida foi cancelada ou removida. Os dados foram atualizados.');
                    setReload((n) => n + 1);
                    return;
                  }
                }
                if (nextGame.match_id) go({ pathname: '/partida/[id]', params: { id: nextGame.match_id } });
                else if (nextGame.composition_id)
                  go({ pathname: '/pelada/[id]/composicao/[cid]', params: { id: nextGame.pelada_id, cid: nextGame.composition_id } });
                else go({ pathname: '/pelada/[id]/escalacoes', params: { id: nextGame.pelada_id } });
              }}
            />
          ) : (
            <Text2>Nenhum jogo marcado</Text2>
          )}
        </View>
      );
    }
    if (id === 'last_game') {
      return (
        <View key={id} style={{ gap: 4 }}>
          <BlockTitle>Último Jogo</BlockTitle>
          {last.status === 'loading' && <Skeleton height={150} />}
          {(last.status === 'error' || last.status === 'access_denied') && <InlineError text={last.error ?? 'Não foi possível carregar o último jogo.'} onRetry={() => setReload((n) => n + 1)} />}
          {last.status === 'offline_uncached' && <InlineError text="Sem conexão e sem dados salvos do último jogo." onRetry={() => setReload((n) => n + 1)} />}
          {last.status === 'session_expired' && <InlineError text="Sua sessão expirou. Entre de novo." />}
          {last.status === 'empty_confirmed' && <Text2>Você ainda não tem partidas</Text2>}
          {last.data && (last.status === 'loaded' || last.status === 'offline_cached') && (
            <>
              <HomeLastGameCard
                game={last.data}
                stale={last.stale}
                onPress={() => go({ pathname: '/partida/[id]', params: { id: last.data!.match_id } })}
                onSelection={() => go({ pathname: '/partida/[id]/selecao', params: { id: last.data!.match_id } })}
              />
              {last.error && <InlineError text={last.error} onRetry={() => setReload((n) => n + 1)} />}
            </>
          )}
        </View>
      );
    }
    if (id === 'career_summary') {
      if (career.status === 'loading') return <Skeleton key={id} height={96} />;
      if (career.status === 'error') return <InlineError key={id} text="Não foi possível carregar a sua carreira agora." onRetry={() => setReload((n) => n + 1)} />;
      // REV-058/075: quatro indicadores somados de todas as peladas; sem dados, zero (nunca valor inventado).
      const t = careerData?.totals;
      const items = [
        { value: t?.matches_played ?? 0, label: 'Jogos' },
        { value: t?.goals ?? 0, label: 'Gols' },
        { value: t?.assists ?? 0, label: 'Assist.' },
        { value: t?.wins ?? 0, label: 'Vitórias' },
      ];
      return (
        <View key={id} style={{ gap: 4 }}>
          <BlockTitle>Resumo da Carreira</BlockTitle>
          <Pressable
            onPress={() => go('/carreira')}
            accessibilityRole="button"
            accessibilityLabel={`Resumo da carreira. ${items.map((s) => `${s.label}: ${s.value}`).join('. ')}. Abrir Minha Carreira.`}
            style={({ pressed }) => ({ backgroundColor: colors.white, borderRadius: 16, borderWidth: 1, borderColor: colors.line, padding: 16, opacity: pressed ? 0.9 : 1 })}>
            <StatStrip items={items} />
          </Pressable>
        </View>
      );
    }
    return null;
  }

  const heroLoading = career.status === 'loading' || (peladas.length > 0 && ratings.status === 'loading');

  return (
    <ScrollView
      ref={scrollRef}
      style={{ backgroundColor: colors.screen }}
      contentContainerStyle={{ alignItems: 'center', paddingTop: top + 12, paddingBottom: 32, flexGrow: 1 }}
      scrollEventThrottle={32}
      onScroll={(e) => {
        scrollY.current = e.nativeEvent.contentOffset.y;
      }}
      refreshControl={<RefreshControl refreshing={awaiting} onRefresh={startRefresh} tintColor={colors.blue} colors={[colors.blue]} />}>
      <View style={{ width: '100%', maxWidth: L.maxWidth, paddingHorizontal: L.gutter, gap: L.gap }}>
        {me || central.status !== 'loading' ? (
          <GreetingHeader text={greetingText(greetIdx, me?.display_name)} unread={unread.data === true} onBell={() => go('/notificacoes')} />
        ) : (
          <Skeleton height={48} />
        )}

        {/* Um aviso geral por vez (E11/E16-43): offline, ou desatualizado; a última sincronização só se for real. */}
        {offline && central.data ? (
          <Notice tone="warn">{`Sem conexão. Você vê os dados salvos neste aparelho${sync ? ` (${sync.toLowerCase()})` : ''}. Nada pode ser alterado até reconectar.`}</Notice>
        ) : stale && central.data ? (
          <Notice tone="warn">{`Alguns dados podem estar desatualizados${sync ? ` (${sync.toLowerCase()})` : ''}. Puxe para atualizar.`}</Notice>
        ) : refreshMsg ? (
          <Notice tone="info">{refreshMsg}</Notice>
        ) : null}

        {central.status === 'loading' && (
          <View style={{ gap: L.gap }} accessibilityLabel="Carregando o seu Início" accessibilityLiveRegion="polite">
            <Skeleton height={156} />
            <Skeleton height={110} />
          </View>
        )}
        {central.status === 'error' && <InlineError text={central.error ?? 'Não foi possível carregar o seu Início.'} onRetry={() => setReload((n) => n + 1)} />}
        {central.status === 'offline_uncached' && (
          <InlineError text="Sem conexão e sem dados salvos neste aparelho. Conecte-se para ver o seu Início." onRetry={() => setReload((n) => n + 1)} />
        )}
        {central.status === 'session_expired' && <InlineError text="Sua sessão expirou. Entre de novo para continuar." />}
        {central.status === 'access_denied' && <InlineError text="Você não tem acesso a esta tela." />}

        {purgeAfter && (
          <Pressable onPress={() => go('/conta')} accessibilityRole="button" style={{ minHeight: 44, justifyContent: 'center' }}>
            <Card>
              <Text2 strong>Sua conta será apagada em {new Date(purgeAfter).toLocaleDateString('pt-BR')}.</Text2>
              <Text2>Toque aqui para recuperar a conta e o seu histórico.</Text2>
            </Card>
          </Pressable>
        )}

        {/* Zero peladas: primeira experiência (E11), sem OVR nem carta fictícia. */}
        {central.data && peladas.length === 0 && (
          <>
            {att.primary && <AttentionBlock primary={att.primary} secondary={att.secondary} rest={att.rest} total={att.total} stale={stale} />}
            <Card>
              <EmptyState
                title="Sua carreira começa numa pelada"
                hint="Crie a pelada da sua turma ou entre com o convite que recebeu. O Card ganha o OVR depois de cinco partidas disputadas e publicadas.">
                <Button title="Criar pelada" onPress={() => go('/criar-pelada')} />
                <Button title="Entrar com convite" kind="secondary" onPress={() => go('/entrar')} />
              </EmptyState>
            </Card>
          </>
        )}

        {central.data && peladas.length > 0 && (
          <>
            {urgent.map((v) => (
              <UrgentVote key={v.match_id} vote={v} offset={offset} onPress={() => openVote(v)} />
            ))}

            {career.status === 'error' && !cp ? (
              <InlineError text="Não foi possível carregar a sua carreira agora." onRetry={() => setReload((n) => n + 1)} />
            ) : heroLoading ? (
              <Skeleton height={156} />
            ) : pelada ? (
              <CardEvolution
                data={{
                  name: me?.display_name ?? '',
                  avatarPath: me?.avatar_path,
                  peladaName: pelada.name,
                  crestPath: pelada.crest_path,
                  position,
                  card: cardSeason?.card ?? null,
                  seasonName: (cardSeason ?? season)?.name ?? null,
                  seasonStart: (cardSeason ?? season)?.starts_on ?? null,
                }}
                rating={ratings.data?.[pelada.id] ? { rating: cardRating?.rating ?? null, delta: cardRating?.delta ?? null } : null}
                loading={false}
                unavailable={ratings.status === 'error' || (ratings.status === 'loaded' && ratings.stale && !ratings.data)}
                stale={ratings.stale || career.stale}
                onCareer={() => go({ pathname: '/carreira', params: { pelada: pelada.id } })}
              />
            ) : null}

            {SPORT_ORDER.filter((b) => visibleSet.has(b)).map(renderBlock)}

            <AttentionBlock primary={att.primary} secondary={att.secondary} rest={att.rest} total={att.total} stale={!centralTrusted} />

            <PushPrompt />

            {showGuide && (
              <Card>
                <View style={{ flexDirection: 'row', alignItems: 'center' }}>
                  <Text2 strong style={{ flex: 1 }}>Primeiros passos</Text2>
                  <Pressable accessibilityRole="button" accessibilityLabel="Dispensar o guia" onPress={dispensarGuia} style={{ minHeight: 44, minWidth: 44, justifyContent: 'center' }}>
                    <Text2 strong>Dispensar</Text2>
                  </Pressable>
                </View>
                {steps.map((s) => (
                  <Pressable
                    key={s.key}
                    accessibilityRole="button"
                    accessibilityState={{ checked: s.done }}
                    disabled={s.done}
                    onPress={s.go}
                    style={{ flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 44 }}>
                    <View style={{ width: 20 }}>
                      <Icon name={s.done ? 'selecionado' : 'pendente'} size={18} color={s.done ? colors.blue : colors.muted} />
                    </View>
                    <Text2 style={{ flex: 1, color: s.done ? colors.muted : colors.ink, textDecorationLine: s.done ? 'line-through' : 'none' }}>{s.label}</Text2>
                    {!s.done && <Icon name="chevron" size={18} color={colors.blue} />}
                  </Pressable>
                ))}
              </Card>
            )}
          </>
        )}
      </View>
    </ScrollView>
  );
}

// Texto corrido da Central (escala única do tema).
function Text2({ strong, style, ...rest }: ComponentProps<typeof Text> & { strong?: boolean }) {
  return <Text {...rest} style={[strong ? { ...type.cardTitle, fontSize: 15 } : type.caption, style]} />;
}

// Guia inicial curto, com o estado real de cada passo (nada de formulário). Admin: os quatro passos da organização
// da pelada que ele administra; jogador: os cinco passos do jogador. Sem pelada: começa pelos dois caminhos.
function guideSteps(c: CentralData, push: (h: Href) => void) {
  const admin = c.peladas.find((p) => p.role === 'admin' && p.setup);
  const go = (path: Href) => () => push(path);
  if (admin?.setup) {
    const id = admin.id;
    return [
      { key: 'a1', label: 'Criar a pelada', done: true, go: go('/criar-pelada') },
      { key: 'a2', label: 'Configurar as informações básicas (escudo, votação)', done: admin.setup.configured, go: go({ pathname: '/pelada/[id]/configuracoes', params: { id } }) },
      { key: 'a3', label: 'Convidar os jogadores', done: admin.setup.members > 1, go: go({ pathname: '/pelada/[id]/convidar', params: { id } }) },
      { key: 'a4', label: 'Lançar a primeira partida', done: admin.setup.matches > 0, go: go({ pathname: '/pelada/[id]/partidas', params: { id } }) },
      { key: 'p4', label: 'Conhecer Minha Carreira', done: !!c.guide.seen.career, go: go('/carreira') },
    ];
  }
  const firstMembership = c.pending.positions[0]?.membership_id ?? c.peladas[0]?.membership_id;
  return [
    { key: 'p1', label: 'Entrar numa pelada (ou criar a sua)', done: c.peladas.length > 0, go: go('/entrar') },
    { key: 'p2', label: 'Completar o perfil (foto e pé dominante)', done: !c.pending.profile.photo && !c.pending.profile.foot, go: go('/perfil') },
    {
      key: 'p3',
      label: 'Escolher sua posição',
      done: c.peladas.length > 0 && c.pending.positions.length === 0,
      go: firstMembership ? go({ pathname: '/jogador/[id]', params: { id: firstMembership } }) : go('/entrar'),
    },
    { key: 'p4', label: 'Conhecer Minha Carreira', done: !!c.guide.seen.career, go: go('/carreira') },
    { key: 'p5', label: 'Entender Cards e premiações', done: !!c.guide.seen.cards, go: go('/guia-cards') },
  ];
}
