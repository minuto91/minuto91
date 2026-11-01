import AsyncStorage from '@react-native-async-storage/async-storage';
import { type Href, useFocusEffect, useIsFocused } from 'expo-router';
import { type ComponentProps, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AppState, Pressable, RefreshControl, ScrollView, type ScrollViewInstance, View } from 'react-native';

import {
  AttentionBlock,
  type AttentionItem,
  BlockTitle,
  CardEvolution,
  CareerSummaryCard,
  CentralHeader,
  InlineError,
  LastGameCard,
  NextRoundCard,
  Notice,
  officialOvr,
  PeladaSelector,
  Skeleton,
  UrgentVote,
  useTopInset,
  type VoteItem,
  voteLine,
} from '../../lib/central';
import { type CentralData, loadCentral, loadLastGame, loadLayout, loadRating, loadUnread, type Pelada, useBlock } from '../../lib/centraldata';
import { leftLabel, nextVoteBoundary, ofPelada, voteState } from '../../lib/centrallogic';
import { type CareerSummary, loadCareerSummary, markGuide } from '../../lib/careerv2';
import { friendly } from '../../lib/errors';
import { refreshOutcome, syncedLabel } from '../../lib/loadstate';
import { haptic } from '../../lib/motion';
import { useGo } from '../../lib/nav';
import { PushPrompt } from '../../lib/push';
import { useAuth } from '../../lib/session';
import { supabase } from '../../lib/supabase';
import { onHomeTabRepress } from '../../lib/tabevents';
import { Text } from '../../lib/text';
import { colors, layout as L, type } from '../../lib/theme';
import { Button, Card, EmptyState } from '../../lib/ui';
import { type BlockId, normalizeLayout, splitAttention, visibleSportBlocks } from '../../lib/v84logic';

// O convite guardado antes do login abre sozinho uma vez por sessão do app; depois fica como pendência até ser
// aceito (ou se mostrar inválido) na tela do convite, que o apaga.
let inviteOpened = false;
const LEGACY_PELADA_KEY = (uid: string) => `central_pelada:${uid}`;

// Central do Jogador V8.4: a tela inicial de todos, administradores incluídos (as funções de administração continuam
// dentro de cada pelada). Tudo aparece no contexto da pelada ATIVA, que é a do servidor (set_primary_pelada) e só
// muda pelo seletor. Cada bloco tem o seu próprio estado (useBlock): uma falha localizada não derruba a tela, o cache
// do aparelho só alimenta leitura, e nada aqui recalcula OVR, nota ou prazo.
export default function Home() {
  const { session } = useAuth();
  const go = useGo();
  const top = useTopInset();
  const focused = useIsFocused();
  const uid = session?.user.id ?? '';
  const [reload, setReload] = useState(0);
  const [pendingInvite, setPendingInvite] = useState<string | null>(null);
  // Pelada escolhida agora, confirmada pelo servidor; vale só até a próxima leitura da Central (atSync) trazer a verdade.
  const [override, setOverride] = useState<{ uid: string; id: string; atSync: number | null } | null>(null);
  const [, setTick] = useState(0);
  const [awaiting, setAwaiting] = useState(false);
  const [refreshMsg, setRefreshMsg] = useState<string | null>(null);
  const scrollRef = useRef<ScrollViewInstance>(null);
  const scrollY = useRef(0);
  const armed = useRef(false);
  const lastForeground = useRef(0);

  // ---- Leituras independentes (E16-03) ----------------------------------------------------------------------
  const central = useBlock<CentralData>({ uid, scope: 'central', load: loadCentral, reload });
  const peladas = central.data?.peladas ?? [];
  const serverActive = central.data?.primary_pelada_id ?? null;
  const wanted = override && override.uid === uid && override.atSync === central.syncedAt ? override.id : serverActive;
  const pelada: Pelada | null = peladas.find((p) => p.id === wanted) ?? peladas[0] ?? null;
  const pid = pelada?.id ?? null;
  const mid = pelada?.membership_id ?? null;

  const layoutBlock = useBlock<unknown>({ uid, scope: 'layout', load: loadLayout, reload });
  const unread = useBlock<boolean>({ uid, scope: 'unread', load: loadUnread, reload, cacheable: false });
  const career = useBlock<CareerSummary>({ uid, scope: 'career', load: async () => ({ data: await loadCareerSummary(uid) }), reload });
  const rating = useBlock({ uid, scope: mid ? `rating:${mid}` : null, load: () => loadRating(mid!), reload });
  const last = useBlock({ uid, scope: pid ? `last:${pid}` : null, load: () => loadLastGame(pid!), reload });
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

  // Migração única: quem escolhia a pelada só neste aparelho passa a tê-la guardada no servidor.
  useEffect(() => {
    if (!uid || !fresh || !central.data || central.data.primary_pelada_id) return;
    (async () => {
      const local = await AsyncStorage.getItem(LEGACY_PELADA_KEY(uid)).catch(() => null);
      if (!local) return;
      await AsyncStorage.removeItem(LEGACY_PELADA_KEY(uid)).catch(() => {});
      if (!central.data!.peladas.some((p) => p.id === local)) return;
      const { error } = await supabase.rpc('set_primary_pelada', { p_pelada: local });
      if (!error) setReload((n) => n + 1);
    })().catch(() => {});
  }, [uid, fresh, central.data]);

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
  const tracked = [central, career, ...(pid ? [rating, last] : [])];
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

  // ---- Troca da pelada ativa (E02): atômica e confirmada pelo servidor -----------------------------------------------
  const offline = tracked.some((b) => b.status === 'offline_cached' || b.status === 'offline_uncached');
  const selectPelada = useCallback(
    async (id: string) => {
      if (offline) throw new Error('Sem conexão. Para trocar de pelada é preciso estar online.');
      const { error } = await supabase.rpc('set_primary_pelada', { p_pelada: id });
      if (error) throw new Error(friendly(error.message));
      setOverride({ uid, id, atSync: central.syncedAt });
      setReload((n) => n + 1);
    },
    [uid, offline, central.syncedAt],
  );

  // ---- Blocos derivados -----------------------------------------------------------------------------------------
  const lay = useMemo(() => (layoutBlock.status === 'loaded' || layoutBlock.status === 'offline_cached' ? normalizeLayout(layoutBlock.data) : normalizeLayout(null)), [layoutBlock.status, layoutBlock.data]);
  const me = central.data?.me;
  const centralTrusted = fresh;
  const careerData = career.data?.visible ? career.data : null;
  const cp = careerData?.peladas.find((p) => p.pelada_id === pid) ?? null;
  const cardSeason = cp?.seasons.find((s) => s.card) ?? null;
  const season = cp?.seasons[0] ?? null;
  const position = pelada ? (pelada.position_code ?? pelada.position) : null;
  const headerOvr = officialOvr(rating.data, cardSeason?.card ?? null);

  const votes = (central.data?.pending.votes ?? []).filter((v) => voteState(v.closes_at, offset) !== 'closed');
  const urgent = centralTrusted ? ofPelada(votes, pid).filter((v) => voteState(v.closes_at, offset) === 'urgent') : [];
  const urgentIds = new Set(urgent.map((v) => v.match_id));
  const openVote = (v: VoteItem) => go({ pathname: v.v2 ? '/partida/[id]/votar' : '/partida/[id]', params: { id: v.match_id } });

  const attention: AttentionItem[] = [
    ...votes
      .filter((v) => !urgentIds.has(v.match_id))
      .map((v) => ({
        key: `v${v.match_id}`,
        rank: 1,
        title: v.pelada_id === pid ? `Votação aberta: ${voteLine(v)}` : `Votação aberta em ${v.pelada_name}`,
        detail: `${centralTrusted ? leftLabel(v.closes_at, offset) : 'Prazo a confirmar'}${v.v2 && v.total ? ` · você avaliou ${v.rated} de ${v.total}` : ''}`,
        action: v.v2 && v.started ? 'Continuar' : 'Votar',
        tone: 'blue' as const,
        onPress: () => openVote(v), // abre a votação sem trocar a pelada ativa (E15-04)
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
    ...ofPelada(central.data?.pending.positions ?? [], pid).map((p) => ({
      key: `p${p.membership_id}`,
      rank: 3,
      title: 'Escolha sua posição nesta pelada',
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
            detail: 'Ela aparece na sua carta.',
            action: 'Perfil',
            tone: 'gold' as const,
            onPress: () => go('/perfil'),
          },
        ]
      : []),
  ];
  const att = splitAttention(attention);

  const rounds = ofPelada(central.data?.next_rounds ?? [], pid);
  const stale = central.stale;
  const sync = syncedLabel(central.syncedAt, Date.now());

  async function dispensarGuia() {
    await markGuide('dismiss').catch(() => {});
    setReload((n) => n + 1);
  }
  const steps = central.data ? guideSteps(central.data, (h) => go(h)) : [];
  const showGuide = !!central.data && !central.data.guide.dismissed && steps.some((s) => !s.done);

  // ---- Renderização dos blocos E04–E06 ---------------------------------------------------------------------------
  function renderBlock(id: BlockId) {
    if (!pid) return null;
    if (id === 'next_round') {
      if (rounds.length === 0) return null;
      return (
        <View key={id} style={{ gap: 4 }}>
          <BlockTitle>Próxima Rodada</BlockTitle>
          <NextRoundCard
            round={rounds[0]}
            more={rounds.length - 1}
            stale={!centralTrusted}
            onPress={() =>
              rounds[0].composition_id
                ? go({ pathname: '/pelada/[id]/composicao/[cid]', params: { id: rounds[0].pelada_id, cid: rounds[0].composition_id } })
                : go({ pathname: '/pelada/[id]/escalacoes', params: { id: rounds[0].pelada_id } })
            }
          />
        </View>
      );
    }
    if (id === 'last_game') {
      return (
        <View key={id} style={{ gap: 4 }}>
          <BlockTitle>Último Jogo</BlockTitle>
          {last.status === 'loading' && <Skeleton height={176} />}
          {(last.status === 'error' || last.status === 'access_denied') && <InlineError text={last.error ?? 'Não foi possível carregar o último jogo.'} onRetry={() => setReload((n) => n + 1)} />}
          {last.status === 'offline_uncached' && <InlineError text="Sem conexão e sem dados salvos do último jogo." onRetry={() => setReload((n) => n + 1)} />}
          {last.status === 'session_expired' && <InlineError text="Sua sessão expirou. Entre de novo." />}
          {last.status === 'empty_confirmed' && <Text2>Você ainda não disputou nenhuma partida publicada nesta pelada.</Text2>}
          {last.data && (last.status === 'loaded' || last.status === 'offline_cached') && (
            <>
              <LastGameCard game={last.data} stale={last.stale} onPress={() => go({ pathname: '/partida/[id]', params: { id: last.data!.match_id } })} />
              {last.error && <InlineError text={last.error} onRetry={() => setReload((n) => n + 1)} />}
            </>
          )}
        </View>
      );
    }
    if (id === 'career_summary') {
      if (career.status === 'loading') return <Skeleton key={id} height={120} />;
      if (!cp || cp.totals.matches_played <= 0) return null;
      return (
        <View key={id} style={{ gap: 4 }}>
          <BlockTitle>Resumo da Carreira</BlockTitle>
          <CareerSummaryCard position={position} totals={cp.totals} stale={career.stale} onPress={() => go('/carreira')} />
        </View>
      );
    }
    return null;
  }

  const ratingLoading = !!mid && rating.status === 'loading';
  const heroLoading = career.status === 'loading' || ratingLoading;

  return (
    <ScrollView
      ref={scrollRef}
      style={{ backgroundColor: colors.white }}
      contentContainerStyle={{ alignItems: 'center', paddingTop: top + 12, paddingBottom: 32, flexGrow: 1 }}
      scrollEventThrottle={32}
      onScroll={(e) => {
        scrollY.current = e.nativeEvent.contentOffset.y;
      }}
      refreshControl={<RefreshControl refreshing={awaiting} onRefresh={startRefresh} tintColor={colors.blue} colors={[colors.blue]} />}>
      <View style={{ width: '100%', maxWidth: L.maxWidth, paddingHorizontal: L.gutter, gap: L.gap }}>
        <CentralHeader
          name={me?.display_name ?? null}
          avatarPath={me?.avatar_path}
          position={pelada ? position : null}
          ovr={headerOvr}
          unread={unread.data === true}
          onProfile={() => go('/perfil')}
          onBell={() => go('/notificacoes')}
        />

        {/* Um aviso geral por vez (E11/E16-43): offline, ou desatualizado; a última sincronização só se for real. */}
        {offline && central.data ? (
          <Notice tone="warn">{`Sem conexão. Você vê os dados salvos neste aparelho${sync ? ` (${sync.toLowerCase()})` : ''}. Nada pode ser alterado até reconectar.`}</Notice>
        ) : stale && central.data ? (
          <Notice tone="warn">{`Alguns dados podem estar desatualizados${sync ? ` (${sync.toLowerCase()})` : ''}. Puxe para atualizar.`}</Notice>
        ) : refreshMsg ? (
          <Notice tone="info">{refreshMsg}</Notice>
        ) : null}

        {central.status === 'loading' && (
          <View style={{ gap: L.gap }} accessibilityLabel="Carregando a sua Central" accessibilityLiveRegion="polite">
            <Skeleton height={80} />
            <Skeleton height={156} />
            <Skeleton height={110} />
          </View>
        )}
        {central.status === 'error' && <InlineError text={central.error ?? 'Não foi possível carregar a sua Central.'} onRetry={() => setReload((n) => n + 1)} />}
        {central.status === 'offline_uncached' && (
          <InlineError text="Sem conexão e sem dados salvos neste aparelho. Conecte-se para ver a sua Central." onRetry={() => setReload((n) => n + 1)} />
        )}
        {central.status === 'session_expired' && <InlineError text="Sua sessão expirou. Entre de novo para continuar." />}
        {central.status === 'access_denied' && <InlineError text="Você não tem acesso a esta Central." />}

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
                hint="Crie a pelada da sua turma ou entre com o convite que recebeu. A carta ganha o OVR depois de cinco partidas disputadas e publicadas.">
                <Button title="Criar pelada" onPress={() => go('/criar-pelada')} />
                <Button title="Entrar com convite" kind="secondary" onPress={() => go('/entrar')} />
              </EmptyState>
            </Card>
          </>
        )}

        {central.data && pelada && (
          <>
            <PeladaSelector
              peladas={peladas}
              activeId={pid}
              onSelect={selectPelada}
              disabledReason={offline ? 'Sem conexão. Para trocar de pelada é preciso estar online.' : null}
            />

            {urgent.map((v) => (
              <UrgentVote key={v.match_id} vote={v} offset={offset} onPress={() => openVote(v)} />
            ))}

            {career.status === 'error' && !cp ? (
              <InlineError text="Não foi possível carregar a sua carreira agora." onRetry={() => setReload((n) => n + 1)} />
            ) : heroLoading ? (
              <Skeleton height={156} />
            ) : (
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
                rating={rating.data}
                loading={false}
                unavailable={rating.status === 'error' || (rating.status === 'loaded' && rating.stale && !rating.data)}
                stale={rating.stale || career.stale}
                onCareer={() => go('/carreira')}
              />
            )}

            {visibleSportBlocks(lay).map(renderBlock)}

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
                    <Text2 style={{ width: 20, color: s.done ? colors.blue : colors.muted }}>{s.done ? '✓' : '○'}</Text2>
                    <Text2 style={{ flex: 1, color: s.done ? colors.muted : colors.ink, textDecorationLine: s.done ? 'line-through' : 'none' }}>{s.label}</Text2>
                    {!s.done && <Text2 style={{ color: colors.blue }}>›</Text2>}
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
