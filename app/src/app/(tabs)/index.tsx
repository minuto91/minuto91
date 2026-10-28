import AsyncStorage from '@react-native-async-storage/async-storage';
import { Href, useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { AppState, Pressable, ScrollView, View } from 'react-native';
import { Text } from '../../lib/text';

import {
  BlockTitle,
  CareerHero,
  CareerRecap,
  CentralHeader,
  InlineError,
  LastGame,
  NextRound,
  PeladaSwitcher,
  PendingItem,
  PendingList,
  Skeleton,
  UrgentVote,
  useLastGame,
  usePeladaRating,
  useTopInset,
  VoteItem,
  voteLine,
} from '../../lib/central';
import { leftLabel, nextVoteBoundary, ofPelada, pickPelada, serverOffset, voteState } from '../../lib/centrallogic';
import { CareerSummary, loadCareerSummary, markGuide } from '../../lib/careerv2';
import { friendly } from '../../lib/errors';
import { PushPrompt } from '../../lib/push';
import { useAuth } from '../../lib/session';
import { supabase } from '../../lib/supabase';
import { colors } from '../../lib/theme';
import { Button, Card, EmptyState } from '../../lib/ui';

type Pelada = {
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
type Central = {
  me: { display_name: string; avatar_path: string | null; dominant_foot: string | null } | null;
  primary_pelada_id: string | null;
  peladas: Pelada[];
  next_rounds: { lineup_id: string; pelada_id: string; pelada_name: string; label: string; team_name: string; opponent_name: string }[];
  pending: {
    // V5: votações v2 trazem o progresso (rated de total) e vão direto para a tela de votar.
    votes: VoteItem[];
    positions: { pelada_id: string; pelada_name: string; membership_id: string }[];
    profile: { photo: boolean; foot: boolean };
  };
  guide: { dismissed: boolean; seen: { career?: boolean; cards?: boolean } };
  server_time?: string;
};

// O convite guardado antes do login abre sozinho uma vez por sessão do app; depois fica como pendência até ser
// aceito (ou se mostrar inválido) na tela do convite, que o apaga.
let inviteOpened = false;
const PELADA_KEY = (uid: string) => `central_pelada:${uid}`;

// Central do Jogador 2.0 (24/10/2026): a tela inicial de todo mundo, administradores incluídos (as funções de
// administração continuam dentro de cada pelada). Tudo aparece no contexto da pelada escolhida: carta, OVR e
// variação, pendências da pelada, próxima rodada, último jogo e resumo. Leituras: get_player_central (peladas,
// pendências, próxima rodada, guia, horário do servidor), get_my_pending_rating_votes, get_player_career_summary
// (cartas e números por temporada) e, por pelada, get_player_rating + histórico e o último jogo (lib/central).
// Cada bloco tem o seu estado: uma falha secundária não derruba a tela. Nada aqui recalcula OVR, nota ou prazo.
export default function Home() {
  const { session } = useAuth();
  const router = useRouter();
  const top = useTopInset();
  const uid = session?.user.id ?? '';
  const [data, setData] = useState<Central | null>(null);
  const [admin, setAdmin] = useState<AdminPending[]>([]);
  const [err, setErr] = useState<string | null>(null);
  const [career, setCareer] = useState<CareerSummary | null>(null);
  const [careerErr, setCareerErr] = useState<string | null>(null);
  const [purgeAfter, setPurgeAfter] = useState<string | null>(null);
  const [pendingInvite, setPendingInvite] = useState<string | null>(null);
  const [stored, setStored] = useState<{ uid: string; id: string | null } | null>(null);
  const [offset, setOffset] = useState(0);
  const [, setTick] = useState(0); // redesenha quando uma votação entra na última hora ou termina
  const [reload, setReload] = useState(0); // incrementar = buscar de novo

  // Última pelada vista nesta conta (neste aparelho).
  useEffect(() => {
    if (!uid) return;
    let alive = true;
    AsyncStorage.getItem(PELADA_KEY(uid))
      .catch(() => null)
      .then((id) => alive && setStored({ uid, id }));
    return () => {
      alive = false;
    };
  }, [uid]);

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        // Convite recebido antes do login: continua de onde parou.
        const invite = await AsyncStorage.getItem('pending_invite');
        if (alive) setPendingInvite(invite);
        if (invite && !inviteOpened) {
          inviteOpened = true;
          router.push({ pathname: '/convite/[token]', params: { token: invite } });
          return;
        }
        if (!uid) return;
        void reload;
        const asked = Date.now();
        const [{ data: st }, central, ratingVotes, adminPending] = await Promise.all([
          supabase.rpc('get_account_status'),
          supabase.rpc('get_player_central'),
          supabase.rpc('get_my_pending_rating_votes'),
          supabase.rpc('get_my_admin_pending'),
        ]);
        if (!alive) return;
        setAdmin((adminPending.data ?? []) as AdminPending[]);
        setPurgeAfter((st as { purge_after: string | null } | null)?.purge_after ?? null);
        // Falha de rede não vira "nenhuma pelada".
        if (central.error || !central.data) return setErr('Não foi possível carregar a sua Central. Verifique a internet e tente de novo.');
        setErr(null);
        const c = central.data as Central;
        // Relógio do servidor: o meio da ida e volta é a melhor estimativa do instante em que ele respondeu.
        setOffset(serverOffset(c.server_time, (asked + Date.now()) / 2));
        const v2 = ((ratingVotes.data ?? []) as VoteItem[]).map((v) => ({ ...v, v2: true }));
        setData({ ...c, pending: { ...c.pending, votes: [...v2, ...c.pending.votes].sort((a, b) => a.closes_at.localeCompare(b.closes_at)) } });
      })();
      return () => {
        alive = false;
      };
    }, [uid, router, reload]),
  );

  // Resumo da carreira: leitura separada (se falhar, o resto da Central continua funcionando).
  useFocusEffect(
    useCallback(() => {
      if (!uid) return;
      let alive = true;
      void reload;
      (async () => {
        try {
          const c = await loadCareerSummary(uid);
          if (!alive) return;
          setCareer(c);
          setCareerErr(null);
        } catch (e) {
          if (alive) setCareerErr(friendly((e as Error).message));
        }
      })();
      return () => {
        alive = false;
      };
    }, [uid, reload]),
  );

  // Pendências se atualizam ao voltar para o app; a urgência muda sozinha quando falta 1 hora e quando o prazo vence
  // (aí também busca de novo: uma prorrogação aparece no prazo novo que o servidor devolve).
  useEffect(() => {
    const sub = AppState.addEventListener('change', (s) => s === 'active' && setReload((n) => n + 1));
    return () => sub.remove();
  }, []);
  const allVotes = data?.pending.votes;
  useEffect(() => {
    const at = nextVoteBoundary(
      (allVotes ?? []).map((v) => v.closes_at),
      offset,
    );
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
  // O tempo restante da votação urgente anda de minuto em minuto.
  const hasUrgent = (allVotes ?? []).some((v) => voteState(v.closes_at, offset) === 'urgent');
  useEffect(() => {
    if (!hasUrgent) return;
    const t = setInterval(() => setTick((n) => n + 1), 30000);
    return () => clearInterval(t);
  }, [hasUrgent]);

  const peladas = data?.peladas ?? [];
  const storedId = stored?.uid === uid ? stored.id : null;
  const pelada = stored?.uid === uid ? pickPelada(peladas, storedId) : null;
  const pid = pelada?.id ?? null;

  function selectPelada(id: string) {
    setStored({ uid, id });
    AsyncStorage.setItem(PELADA_KEY(uid), id).catch(() => {});
  }

  const rating = usePeladaRating(pelada?.membership_id ?? null, reload);
  const last = useLastGame(pid, pelada?.membership_id ?? null, reload);

  async function dispensarGuia() {
    await markGuide('dismiss').catch(() => {});
    setReload((n) => n + 1);
  }

  const me = data?.me;
  const openVote = (v: VoteItem) => router.push({ pathname: v.v2 ? '/partida/[id]/votar' : '/partida/[id]', params: { id: v.match_id } });

  // Votações: só as da pelada escolhida aparecem com detalhe; as de outras peladas viram um atalho para trocar.
  const votes = (allVotes ?? []).filter((v) => voteState(v.closes_at, offset) !== 'closed');
  const mine = ofPelada(votes, pid);
  const urgent = mine.filter((v) => voteState(v.closes_at, offset) === 'urgent');
  const calm = mine.filter((v) => voteState(v.closes_at, offset) === 'open');
  const elsewhere = [...new Map(votes.filter((v) => v.pelada_id !== pid).map((v) => [v.pelada_id, v])).values()];

  const pending: PendingItem[] = [
    ...calm.map((v) => ({
      key: `v${v.match_id}`,
      title: `Votação aberta: ${voteLine(v)}`,
      detail: `${leftLabel(v.closes_at, offset)}${v.v2 && v.total ? ` · você avaliou ${v.rated} de ${v.total}` : ''}`,
      action: v.v2 && v.started ? 'Continuar' : 'Votar',
      tone: 'blue' as const,
      onPress: () => openVote(v),
    })),
    ...(pendingInvite
      ? [
          {
            key: 'invite',
            title: 'Você tem um convite para aceitar',
            detail: 'Veja a pelada e entre.',
            action: 'Ver',
            tone: 'blue' as const,
            onPress: () => router.push({ pathname: '/convite/[token]', params: { token: pendingInvite } }),
          },
        ]
      : []),
    ...elsewhere.map((v) => ({
      key: `o${v.pelada_id}`,
      title: `Votação aberta em ${v.pelada_name}`,
      detail: leftLabel(v.closes_at, offset),
      action: 'Abrir',
      tone: 'blue' as const,
      onPress: () => selectPelada(v.pelada_id),
    })),
    // REV-028: resumo das pendências administrativas (só peladas que a pessoa administra, só o que existe).
    // A ação detalhada fica dentro da pelada; rascunhos continuam no item próprio abaixo.
    ...admin
      .map((a) => ({ a, text: adminSummary(a) }))
      .filter((x) => x.text)
      .map(({ a, text }) => ({
        key: `adm${a.pelada_id}`,
        title: a.pelada_name,
        detail: text,
        action: 'Ver',
        tone: 'gold' as const,
        onPress: () => router.push({ pathname: '/pelada/[id]', params: { id: a.pelada_id } }),
      })),
    ...(pelada && pelada.drafts > 0
      ? [
          {
            key: 'drafts',
            title: pelada.drafts === 1 ? '1 súmula em rascunho' : `${pelada.drafts} súmulas em rascunho`,
            detail: 'Publique para abrir a votação.',
            action: 'Ver',
            tone: 'gold' as const,
            onPress: () => router.push({ pathname: '/pelada/[id]/partidas', params: { id: pelada.id } }),
          },
        ]
      : []),
    ...ofPelada(data?.pending.positions ?? [], pid).map((p) => ({
      key: `p${p.membership_id}`,
      title: 'Escolha sua posição nesta pelada',
      action: 'Escolher',
      tone: 'gold' as const,
      onPress: () => router.push({ pathname: '/jogador/[id]', params: { id: p.membership_id } }),
    })),
    ...(data?.pending.profile.photo && peladas.length > 0
      ? [
          {
            key: 'photo',
            title: 'Coloque uma foto no seu perfil',
            detail: 'Ela aparece na sua carta.',
            action: 'Perfil',
            tone: 'gold' as const,
            onPress: () => router.push('/perfil'),
          },
        ]
      : []),
  ];

  // Carreira na pelada escolhida (cartas e números são sempre de uma pelada e de uma temporada).
  const visibleCareer = career?.visible ? career : null;
  const cp = visibleCareer?.peladas.find((p) => p.pelada_id === pid) ?? null;
  const season = cp?.seasons[0] ?? null;
  const cardSeason = cp?.seasons.find((s) => s.card) ?? null;
  const conquests = cp
    ? cp.trophies.match_craque + cp.trophies.monthly_king + (cp.trophies.monthly_garcom ?? 0)
    : 0; // Bola Murcha não é conquista
  const rounds = ofPelada(data?.next_rounds ?? [], pid);
  const steps = data ? guideSteps(data, (h) => router.push(h)) : [];
  const showGuide = !!data && !data.guide.dismissed && steps.some((s) => !s.done);
  const careerReady = !!career || !!careerErr;

  return (
    <ScrollView
      style={{ backgroundColor: colors.white }}
      contentContainerStyle={{ paddingHorizontal: 20, paddingTop: top + 12, paddingBottom: 28, gap: 12, flexGrow: 1 }}>
      <CentralHeader
        name={me?.display_name ?? null}
        avatarPath={me?.avatar_path}
        onProfile={() => router.push('/perfil')}
        onBell={() => router.push('/conta')}
      />

      {err && <InlineError text={err} onRetry={() => setReload((n) => n + 1)} />}
      {!data && !err && (
        <View style={{ gap: 12 }} accessibilityLabel="Carregando a sua Central">
          <Skeleton height={40} />
          <Skeleton height={210} />
          <Skeleton height={120} />
        </View>
      )}
      {purgeAfter && (
        <Pressable onPress={() => router.push('/conta')} accessibilityRole="button" style={{ minHeight: 44, justifyContent: 'center' }}>
          <Card>
            <Text style={{ color: colors.ink, fontWeight: '600' }}>
              Sua conta será apagada em {new Date(purgeAfter).toLocaleDateString('pt-BR')}.
            </Text>
            <Text style={{ color: colors.muted }}>Toque aqui para recuperar a conta e o seu histórico.</Text>
          </Card>
        </Pressable>
      )}

      {data && peladas.length === 0 && (
        <>
          {pendingInvite && <PendingList items={pending} />}
          <Card>
            <EmptyState
              title="Sua carreira começa numa pelada"
              hint="Crie a pelada da sua turma ou entre com o convite que recebeu. Depois de cinco partidas, sua carta ganha o OVR.">
              <Button title="Criar pelada" onPress={() => router.push('/criar-pelada')} />
              <Button title="Entrar com convite" kind="secondary" onPress={() => router.push('/entrar')} />
            </EmptyState>
          </Card>
        </>
      )}

      {data && pelada && (
        <>
          <PeladaSwitcher peladas={peladas} selected={pid} onSelect={selectPelada} />

          {urgent.map((v) => (
            <UrgentVote key={v.match_id} vote={v} offset={offset} onPress={() => openVote(v)} />
          ))}

          {careerErr && !cp ? (
            <InlineError text="Não foi possível carregar a sua carreira agora." onRetry={() => setReload((n) => n + 1)} />
          ) : !careerReady || (!rating && !careerErr) ? (
            <Skeleton height={210} />
          ) : (
            <CareerHero
              data={{
                name: me?.display_name ?? '',
                avatarPath: me?.avatar_path,
                peladaName: pelada.name,
                crestPath: pelada.crest_path,
                position: pelada.position_code ?? pelada.position,
                card: cardSeason?.card ?? null,
                seasonName: (cardSeason ?? season)?.name ?? null,
                seasonStart: (cardSeason ?? season)?.starts_on ?? null,
                season: cardSeason ?? season,
              }}
              rating={rating?.data ?? null}
              ratingLoading={!rating}
              onCareer={() => router.push('/carreira')}
            />
          )}

          {pending.length > 0 && (
            <>
              <BlockTitle>Pendências</BlockTitle>
              <PendingList items={pending} />
            </>
          )}

          {rounds.length > 0 && (
            <>
              <BlockTitle>Próxima rodada</BlockTitle>
              <NextRound
                round={rounds[0]}
                more={rounds.length - 1}
                onPress={() => router.push({ pathname: '/pelada/[id]/escalacoes', params: { id: rounds[0].pelada_id } })}
              />
            </>
          )}

          {(!last || last.data || last.error) && <BlockTitle>Último jogo</BlockTitle>}
          {!last && <Skeleton height={150} />}
          {last?.error && <InlineError text={last.error} onRetry={() => setReload((n) => n + 1)} />}
          {last?.data && (
            <LastGame game={last.data} onPress={() => router.push({ pathname: '/partida/[id]', params: { id: last.data!.match_id } })} />
          )}
          {last && !last.data && !last.error && (
            <Text style={{ color: colors.muted, fontSize: 14 }}>
              Ainda não há partidas nesta pelada. O último jogo aparece aqui assim que a primeira súmula for publicada.
            </Text>
          )}

          {cp && cp.totals.matches_played > 0 && (
            <>
              <BlockTitle>Resumo da carreira</BlockTitle>
              <CareerRecap totals={cp.totals} conquests={conquests} hiddenSeasons={cp.hidden_seasons} onPress={() => router.push('/carreira')} />
            </>
          )}

          <PushPrompt />
        </>
      )}

      {showGuide && (
        <Card>
          <View style={{ flexDirection: 'row', alignItems: 'center' }}>
            <Text style={{ flex: 1, fontWeight: '600', color: colors.muted, fontSize: 14 }}>Primeiros passos</Text>
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Dispensar o guia"
              onPress={dispensarGuia}
              style={{ minHeight: 44, minWidth: 44, justifyContent: 'center' }}>
              <Text style={{ color: colors.muted, fontWeight: '600' }}>Dispensar</Text>
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
              <Text
                style={{ fontSize: 16, color: s.done ? colors.blue : colors.muted, width: 20 }}
                accessibilityElementsHidden
                importantForAccessibility="no">
                {s.done ? '✓' : '○'}
              </Text>
              <Text style={{ flex: 1, color: s.done ? colors.muted : colors.ink, textDecorationLine: s.done ? 'line-through' : 'none' }}>
                {s.label}
              </Text>
              {!s.done && <Text style={{ color: colors.blue }}>›</Text>}
            </Pressable>
          ))}
        </Card>
      )}
    </ScrollView>
  );
}

// Guia inicial curto, com o estado real de cada passo (nada de formulário). Admin: os quatro passos da organização
// da pelada que ele administra; jogador: os cinco passos do jogador. Sem pelada: começa pelos dois caminhos.
function guideSteps(c: Central, push: (h: Href) => void) {
  const admin = c.peladas.find((p) => p.role === 'admin' && p.setup);
  const go = (path: Href) => () => push(path);
  if (admin?.setup) {
    const id = admin.id;
    return [
      { key: 'a1', label: 'Criar a pelada', done: true, go: go('/criar-pelada') },
      {
        key: 'a2',
        label: 'Configurar as informações básicas (escudo, votação)',
        done: admin.setup.configured,
        go: go({ pathname: '/pelada/[id]/configuracoes', params: { id } }),
      },
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

type AdminPending = {
  pelada_id: string;
  pelada_name: string;
  keeper_claims?: number;
  secondary_requests?: number;
  position_requests?: number;
  billing_pending?: number;
  votes_suspended?: number;
};

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** Uma linha curta por pelada; vazio quando não há nada além de rascunhos (que têm item próprio). */
function adminSummary(a: AdminPending) {
  return [
    a.billing_pending ? plural(a.billing_pending, 'classificação de mensalista', 'classificações de mensalista') : null,
    a.keeper_claims ? plural(a.keeper_claims, 'defesa para revisar', 'defesas para revisar') : null,
    a.position_requests || a.secondary_requests
      ? plural((a.position_requests ?? 0) + (a.secondary_requests ?? 0), 'pedido de posição', 'pedidos de posição')
      : null,
    a.votes_suspended ? plural(a.votes_suspended, 'votação interrompida', 'votações interrompidas') : null,
  ]
    .filter(Boolean)
    .join(' · ');
}
