import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { AppState, Pressable, View } from 'react-native';
import { Text } from '../../../lib/text';
import { HOME , colors, needsPositionUpdate } from '../../../lib/theme';

import { currentSeason, loadSeasons } from '../../../lib/career';
import { Crest } from '../../../lib/crest';
import { confirm } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { Icon } from '../../../lib/icons';
import { fmtDate, fmtTime, Match, MATCH_COLUMNS, STATUS_LABEL } from '../../../lib/match';
import { AdminPending } from '../../../lib/pending';
import { CardsTracking, PositionRequests } from '../../../lib/ratingadmin';
import { ReportLink } from '../../../lib/report';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { Badge, Button, ErrorState, ListGroup, ListItemProps, MatchStatusBadge, Notice, Scoreboard, Screen, SectionHeader, Sub } from '../../../lib/ui';

type Member = { id: string; user_id: string | null; player_name: string; role: string; preferred_position: string; position_code?: string | null };
type Highlight = { match_id: string; membership_id: string; highlight_type: string };
type MyVote = { matchId: string; closesAt: string };

const HIGHLIGHT_LABEL: Record<string, string> = {
  craque: 'Craque da Partida',
  garcom_round: 'Garçom da rodada',
  bola_murcha: 'Bola Murcha',
};
const WEEKDAY = ['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado'];
const ROLE = (r: string) => (r === 'admin' ? 'Administrador' : r === 'assistant' ? 'Assistente' : 'Jogador');

// Central da Rodada (V4.1): a própria página da pelada. Mostra o que importa agora (pendências, última
// rodada, votação aberta) e atalhos para o resto. Só dados oficiais e persistidos: não existe
// agendamento de partidas, então não há bloco de "próxima partida".
export default function CentralDaRodada() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const router = useRouter();
  const [pelada, setPelada] = useState<{
    name: string;
    status: string;
    crest_path: string | null;
    successor_membership_id: string | null;
    recurring_weekday: number | null;
    recurring_time: string | null;
  } | null>(null);
  const [season, setSeason] = useState<string | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [matches, setMatches] = useState<Match[]>([]);
  const [highlights, setHighlights] = useState<Highlight[]>([]);
  const [myVotes, setMyVotes] = useState<MyVote[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reload, setReload] = useState(0); // incrementar = buscar de novo
  const [premium, setPremium] = useState(false);
  const [finance, setFinance] = useState(false);

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        void reload; // recarregar (AppState, Tentar de novo)
        const uid = session?.user.id ?? '';
        const [{ data: p }, { data: ms, error: e1 }, { data: xs, error: e2 }, { data: hs }, ss, { data: vs }, { data: ent }, { data: fin }] = await Promise.all([
          supabase
            .from('peladas')
            .select('name, status, successor_membership_id, crest_path, recurring_weekday, recurring_time')
            .eq('id', id)
            .maybeSingle(),
          supabase
            .from('pelada_memberships')
            .select('id, user_id, player_name, role, preferred_position, position_code')
            .eq('pelada_id', id)
            .eq('status', 'active')
            .order('joined_at', { ascending: true }),
          // Rascunhos só chegam para admin e assistentes (RLS).
          supabase.from('matches').select(MATCH_COLUMNS).eq('pelada_id', id).order('played_at', { ascending: false }).limit(20),
          // Destaques da última partida finalizada (os anteriores expiram quando outra é finalizada).
          supabase.from('highlights').select('match_id, membership_id, highlight_type').eq('pelada_id', id).is('expires_at', null),
          loadSeasons(id).catch(() => []),
          // A13: votação vencida (o agendador fecha em até 5 min) não aparece mais como pendência.
          supabase.from('voting_sessions').select('id, match_id, closes_at').eq('pelada_id', id).eq('status', 'open').gt('closes_at', new Date().toISOString()),
          supabase.rpc('get_pelada_entitlement', { p_pelada: id }),
          // V4.3: o Financeiro só aparece para quem tem acesso (admin ou assistente autorizado); nada financeiro vem aqui.
          supabase.rpc('get_finance_access', { p_pelada: id }),
        ]);
        if (!alive) return;
        // A21: erro de rede não vira "pelada sem partidas".
        const error = e1 ?? e2;
        if (error) {
          setMsg(friendly(error.message));
          setLoaded(true);
          return;
        }
        const list = (ms ?? []) as Member[];
        const mine = list.find((m) => m.user_id === uid);
        // Pendência pessoal: votação aberta em que sou eleitor e ainda não votei.
        let votes: MyVote[] = [];
        if (mine && (vs ?? []).length) {
          const ids = (vs ?? []).map((v) => v.id as string);
          const [{ data: el }, { data: rc }] = await Promise.all([
            supabase.from('voting_eligible_members').select('session_id').eq('membership_id', mine.id).in('session_id', ids),
            supabase.from('vote_receipts').select('session_id').eq('membership_id', mine.id).in('session_id', ids),
          ]);
          const eligible = new Set((el ?? []).map((e) => e.session_id as string));
          const voted = new Set((rc ?? []).map((r) => r.session_id as string));
          votes = (vs ?? [])
            .filter((v) => eligible.has(v.id) && !voted.has(v.id))
            .map((v) => ({ matchId: v.match_id as string, closesAt: v.closes_at as string }));
        }
        if (!alive) return;
        setPelada(p ?? null);
        setPremium(!!(ent as { is_premium?: boolean } | null)?.is_premium);
        setFinance(!!(fin as { can_access?: boolean } | null)?.can_access);
        setMembers(list);
        setMatches((xs ?? []) as Match[]);
        setHighlights((hs ?? []) as Highlight[]);
        setSeason(currentSeason(ss)?.name ?? null);
        setMyVotes(votes);
        setMsg(null);
        setLoaded(true);
      })();
      return () => {
        alive = false;
      };
    }, [id, session, reload]),
  );

  // A13: recarrega ao voltar para o app.
  useEffect(() => {
    const sub = AppState.addEventListener('change', (st) => st === 'active' && setReload((n) => n + 1));
    return () => sub.remove();
  }, []);

  const me = members.find((m) => m.user_id === session?.user.id);
  const isAdmin = me?.role === 'admin';
  const isStaff = isAdmin || me?.role === 'assistant';
  const nameOf = (mid: string) => members.find((m) => m.id === mid)?.player_name ?? 'Jogador';
  const lastFinal = matches.find((m) => m.status === 'finalized') ?? null;
  const inVoting = matches.filter((m) => m.status === 'voting_open' || m.status === 'finalizing');
  const recent = matches.filter((m) => m.status !== 'draft').slice(0, 3);
  const empty = loaded && !msg && !matches.some((m) => m.status !== 'draft');
  const lastHighlights = lastFinal ? highlights.filter((h) => h.match_id === lastFinal.id) : [];

  const openMatch = (mid: string) => router.push({ pathname: '/partida/[id]', params: { id: mid } });
  const convidar = () => router.push({ pathname: '/pelada/[id]/convidar', params: { id } });

  async function lancarPartida() {
    setBusy(true);
    setMsg(null);
    const { data, error } = await supabase.rpc('create_match', { p_pelada: id, p_played_at: new Date().toISOString() });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    router.push({ pathname: '/partida/[id]/sumula', params: { id: String(data) } });
  }

  function sair() {
    confirm(
      'Sair da pelada?',
      isAdmin
        ? 'Você é o administrador. A administração passa automaticamente: primeiro o sucessor indicado, depois o assistente mais antigo, depois o jogador mais antigo.'
        : 'Seu histórico fica guardado e você pode voltar por um novo convite.',
      'Sair',
      async () => {
        const { error } = await supabase.rpc('leave_pelada', { p_pelada: id });
        if (error) return setMsg(friendly(error.message));
        router.replace(HOME);
      },
    );
  }

  // V6.0: a pelada é a protagonista. Conteúdo esportivo primeiro (rodada, elenco, desempenho, histórico) e a
  // administração agrupada por contexto (Rodadas, Jogadores, Financeiro, Configurações), cada grupo com uma
  // ação principal. As permissões são as mesmas da V4.6; só a organização mudou.
  const go = (pathname: Parameters<typeof router.push>[0]) => () => router.push(pathname);
  const pro = (on?: boolean) => (on && !premium ? 'Premium' : undefined);
  const jogo: GroupItem[] = [
    { icon: 'escalacao', title: 'Escalações', sub: 'Times da próxima rodada', onPress: go({ pathname: '/pelada/[id]/escalacoes', params: { id } }) },
    { icon: 'elenco', title: 'Elenco', sub: loaded ? `${members.length} ${members.length === 1 ? 'jogador' : 'jogadores'}` : 'Jogadores da pelada', onPress: go({ pathname: '/pelada/[id]/elenco', params: { id } }) },
    { icon: 'duelo', title: 'Duelo', sub: 'Compare dois jogadores', badge: pro(true), onPress: go({ pathname: '/pelada/[id]/duelo', params: { id } }) },
  ];
  const desempenho: GroupItem[] = [
    { icon: 'rankings', title: 'Rankings', sub: 'Overall, gols, assistências e prêmios do mês', onPress: go({ pathname: '/pelada/[id]/rankings', params: { id } }) },
    ...(me ? [{ icon: 'card' as const, title: 'Meu Card', sub: 'Overall, atributos e álbum', onPress: go({ pathname: '/jogador/[id]', params: { id: me.id } }) }] : []),
    { icon: 'jogadores', title: 'Jogadores e estatísticas', sub: 'Cards e números de cada um', onPress: go({ pathname: '/pelada/[id]/jogadores', params: { id } }) },
  ];
  const historico: GroupItem[] = [
    { icon: 'partidas', title: 'Partidas', sub: 'Súmula, votação e resultado', onPress: go({ pathname: '/pelada/[id]/partidas', params: { id } }) },
    { icon: 'retro', title: 'Retrospectiva', sub: 'Resumo da temporada', onPress: go({ pathname: '/pelada/[id]/retrospectiva', params: { id } }) },
    { icon: 'temporadas', title: 'Temporadas', sub: 'Atual e anteriores', onPress: go({ pathname: '/pelada/[id]/temporadas', params: { id } }) },
  ];
  // Gestão por contexto (só aparece o que a pessoa pode usar).
  const rodadas: GroupItem[] = isStaff
    ? [
        { icon: 'sorteio', title: 'Sorteio de times', sub: 'Times equilibrados por posição', badge: pro(true), onPress: go({ pathname: '/pelada/[id]/sorteio', params: { id } }) },
        { icon: 'partidas', title: 'Súmulas e votações', sub: 'Rascunhos, correções, prorrogação e publicação', onPress: go({ pathname: '/pelada/[id]/partidas', params: { id } }) },
      ]
    : [];
  const jogadores: GroupItem[] = isAdmin
    ? [
        { icon: 'convite', title: 'Convidar jogadores', sub: 'Link de convite', onPress: convidar },
        { icon: 'jogadores', title: 'Assistentes e sucessor', sub: 'Funções dos membros da pelada', onPress: go({ pathname: '/pelada/[id]/jogadores', params: { id } }) },
      ]
    : [];
  // Financeiro (V4.3): só admin e assistentes com permissão financeira; nenhum valor aparece fora dele.
  const financeiro: GroupItem[] = finance
    ? [{ icon: 'financeiro', title: 'Financeiro', sub: 'Mensalidades, cobranças e relatórios', badge: pro(true), onPress: go({ pathname: '/pelada/[id]/financeiro', params: { id } }) }]
    : [];
  const ajustes: GroupItem[] = [
    ...(isAdmin ? [{ icon: 'config' as const, title: 'Configurações', sub: 'Escudo, votação, assistentes', onPress: go({ pathname: '/pelada/[id]/configuracoes', params: { id } }) }] : []),
    { icon: 'card', title: 'Pelada Premium', sub: premium ? 'Ativa nesta pelada' : 'Recursos extras para a pelada', onPress: go({ pathname: '/pelada/[id]/premium', params: { id } }) },
  ];

  // Dia habitual (004), se o admin tiver definido. Não é uma partida agendada.
  const wd = pelada?.recurring_weekday;
  const habit =
    wd !== null && wd !== undefined && WEEKDAY[wd]
      ? `Costuma jogar ${wd === 0 || wd === 6 ? 'aos' : 'às'} ${WEEKDAY[wd]}s${pelada?.recurring_time ? `, ${pelada.recurring_time.slice(0, 5)}` : ''}`
      : null;

  return (
    <Screen>
      {/* Cabeçalho: escudo, nome, temporada e o essencial. Configurações discretas, só para o admin. */}
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14, paddingBottom: 14, borderBottomWidth: 1, borderBottomColor: colors.divider }}>
        {pelada ? <Crest path={pelada.crest_path} name={pelada.name} size={64} /> : <View style={{ width: 64, height: 64 }} />}
        <View style={{ flex: 1, gap: 3 }}>
          {premium && <Badge label="Pelada Premium" tone="gold" />}
          <Text style={{ fontSize: 24, lineHeight: 30, fontWeight: '800', color: colors.deepBlue }} numberOfLines={2} accessibilityRole="header">
            {pelada?.name ?? ' '}
          </Text>
          <Text style={{ fontSize: 13, color: colors.muted }} numberOfLines={2}>
            {[season, loaded ? `${members.length} ${members.length === 1 ? 'jogador' : 'jogadores'}` : null, me ? ROLE(me.role) : null]
              .filter(Boolean)
              .join(' · ')}
          </Text>
          {habit && <Text style={{ fontSize: 13, color: colors.muted }}>{habit}</Text>}
        </View>
        {isAdmin && (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Configurações da pelada"
            hitSlop={8}
            onPress={() => router.push({ pathname: '/pelada/[id]/configuracoes', params: { id } })}
            style={{ width: 44, height: 44, alignItems: 'center', justifyContent: 'center' }}>
            <Icon name="config" size={24} color={colors.muted} />
          </Pressable>
        )}
      </View>
      {pelada?.status === 'restricted' && <Notice tone="warning">Pelada restrita: sem administrador elegível.</Notice>}
      {msg && <ErrorState message={msg} onRetry={() => setReload((n) => n + 1)} />}

      {/* Pendência pessoal: o meu voto. */}
      {myVotes.map((v) => {
        const m = matches.find((x) => x.id === v.matchId);
        return (
          <Pressable key={v.matchId} accessibilityRole="button" onPress={() => openMatch(v.matchId)}>
            <View style={[box, { borderColor: colors.blue, borderWidth: 1.5, backgroundColor: colors.blueSoft }]}>
              <Text style={label(colors.blue)}>Falta o seu voto</Text>
              {m && <Scoreboard teamA={m.team_a_name} teamB={m.team_b_name} scoreA={m.team_a_score} scoreB={m.team_b_score} />}
              <Sub>Votação até {fmtDate(v.closesAt)}, {fmtTime(v.closesAt)}</Sub>
              <Text style={{ color: colors.blue, fontWeight: '700' }}>Votar ›</Text>
            </View>
          </Pressable>
        );
      })}

      {isStaff && loaded && (
        <AdminPending peladaId={id} matches={matches} members={members} successor={pelada?.successor_membership_id ?? null} isAdmin={isAdmin} onInvite={convidar} />
      )}
      {/* V5: pedidos de troca de posição e registro de cartões (só o admin decide). */}
      {isAdmin && loaded && (
        <>
          <PositionRequests peladaId={id} isAdmin={isAdmin} />
          <CardsTracking peladaId={id} isAdmin={isAdmin} />
        </>
      )}

      {/* Rodada em votação (para quem já votou ou não vota): o resultado sai quando a votação fechar. */}
      {inVoting
        .filter((m) => !myVotes.some((v) => v.matchId === m.id))
        .map((m) => (
          <Pressable key={m.id} accessibilityRole="button" onPress={() => openMatch(m.id)}>
            <View style={box}>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                <Text style={[label(colors.deepBlue), { flex: 1 }]}>Rodada em votação</Text>
                <MatchStatusBadge status={m.status} />
              </View>
              <Scoreboard teamA={m.team_a_name} teamB={m.team_b_name} scoreA={m.team_a_score} scoreB={m.team_b_score} />
              <Sub>{fmtDate(m.played_at)} · O Craque e as notas saem quando a votação fechar.</Sub>
            </View>
          </Pressable>
        ))}

      {/* Última rodada finalizada. O compartilhamento usa as artes da tela da partida (V3). */}
      {lastFinal && (
        <Pressable accessibilityRole="button" accessibilityHint="Abre a partida, com súmula, notas e artes para compartilhar" onPress={() => openMatch(lastFinal.id)}>
          <View style={box}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
              <Text style={[label(colors.deepBlue), { flex: 1 }]}>Último resultado · {fmtDate(lastFinal.played_at)}</Text>
              <MatchStatusBadge status={lastFinal.status} />
            </View>
            <Scoreboard teamA={lastFinal.team_a_name} teamB={lastFinal.team_b_name} scoreA={lastFinal.team_a_score} scoreB={lastFinal.team_b_score} size="lg" />
            {Object.keys(HIGHLIGHT_LABEL)
              .filter((t) => lastHighlights.some((h) => h.highlight_type === t))
              .map((t) => (
                <View key={t} style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                  {t === 'craque' && <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: colors.gold }} />}
                  <Text style={{ color: t === 'craque' ? colors.darkGold : colors.muted, fontWeight: t === 'craque' ? '800' : '500', fontSize: 14, flex: 1 }}>
                    {HIGHLIGHT_LABEL[t]}:{' '}
                    <Text style={{ color: colors.ink }}>
                      {lastHighlights
                        .filter((h) => h.highlight_type === t)
                        .map((h) => nameOf(h.membership_id))
                        .join(', ')}
                    </Text>
                  </Text>
                </View>
              ))}
            {lastHighlights.length === 0 && <Sub>Sem Craque apurado nesta rodada.</Sub>}
            <Text style={{ color: colors.blue, fontWeight: '700', marginTop: 2 }}>Ver partida e compartilhar ›</Text>
          </View>
        </Pressable>
      )}

      {/* Pelada recém-criada: o próximo passo, sem parecer app vazio. */}
      {empty && (
        <View style={[box, { gap: 10 }]}>
          <Text style={label(colors.deepBlue)}>{isStaff ? 'Primeiros passos' : 'Ainda sem partidas'}</Text>
          {isStaff ? (
            <>
              {isAdmin && (
                <Step n={1} title="Chame a turma" text="Mande o convite no grupo. Quem entra escolhe a posição." />
              )}
              <Step
                n={isAdmin ? 2 : 1}
                title="Depois do jogo, lance a partida"
                text="Times, placar, gols e assistências. Ao publicar, a votação abre e o app calcula Cards e rankings."
              />
              {isAdmin && <Button title="Convidar jogadores" onPress={convidar} />}
            </>
          ) : (
            <Sub>Quando o administrador lançar a súmula depois do jogo, o resultado, a votação e os destaques aparecem aqui.</Sub>
          )}
        </View>
      )}

      {/* V4.3: cadastro antigo (Defensor, Meio-campista, Atacante) sem a posição específica. Aviso discreto. */}
      {me && needsPositionUpdate(me) && (
        <Pressable
          accessibilityRole="button"
          onPress={() => router.push({ pathname: '/jogador/[id]', params: { id: me.id } })}
          style={{ minHeight: 44, justifyContent: 'center', paddingHorizontal: 12, borderRadius: 10, borderWidth: 1, borderColor: colors.gold }}>
          <Text style={{ color: colors.darkGold, fontWeight: '600', fontSize: 14 }}>Atualize sua posição: agora são dez posições oficiais ›</Text>
        </Pressable>
      )}

      {isStaff && !empty && <Button title="Lançar partida" onPress={lancarPartida} loading={busy} />}
      {isStaff && empty && <Button title="Lançar a primeira partida" kind={isAdmin ? 'secondary' : 'primary'} onPress={lancarPartida} loading={busy} />}

      <ListGroup title="Rodada e elenco" items={jogo} />

      {recent.length > 0 && (
        <View style={{ gap: 2 }}>
          <SectionHeader title="Partidas recentes" action="Ver todas" onAction={() => router.push({ pathname: '/pelada/[id]/partidas', params: { id } })} />
          {recent.map((x) => (
            <Pressable
              key={x.id}
              accessibilityRole="button"
              accessibilityLabel={`${x.team_a_name} ${x.team_a_score} x ${x.team_b_score} ${x.team_b_name}, ${fmtDate(x.played_at)}, ${STATUS_LABEL[x.status] ?? x.status}`}
              onPress={() => openMatch(x.id)}
              style={{ minHeight: 56, paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: colors.divider, flexDirection: 'row', alignItems: 'center', gap: 8 }}>
              <View style={{ flex: 1, gap: 4 }}>
                <Text style={{ color: colors.ink, fontSize: 15, fontWeight: '600' }} numberOfLines={1}>
                  {x.team_a_name} <Text style={{ color: colors.deepBlue, fontWeight: '800', fontVariant: ['tabular-nums'] }}>{x.team_a_score} x {x.team_b_score}</Text> {x.team_b_name}
                </Text>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                  <Text style={{ color: colors.muted, fontSize: 13 }}>{fmtDate(x.played_at)}</Text>
                  <MatchStatusBadge status={x.status} />
                </View>
              </View>
              <Text style={{ color: colors.muted, fontSize: 18 }}>›</Text>
            </Pressable>
          ))}
        </View>
      )}

      <ListGroup title="Desempenho" items={desempenho} />
      <ListGroup title="Histórico" items={historico} />

      {(rodadas.length > 0 || jogadores.length > 0 || financeiro.length > 0) && (
        <View style={{ gap: 4, marginTop: 14, paddingTop: 14, borderTopWidth: 1, borderTopColor: colors.divider }}>
          <Text style={{ ...section, marginTop: 0 }} accessibilityRole="header">
            Administração
          </Text>
          <Sub>Ferramentas de quem organiza a pelada, separadas por assunto.</Sub>
        </View>
      )}
      {rodadas.length > 0 && <ListGroup title="Rodadas e resultados" items={rodadas} />}
      {jogadores.length > 0 && <ListGroup title="Jogadores" items={jogadores} />}
      {financeiro.length > 0 && <ListGroup title="Financeiro" items={financeiro} />}
      <ListGroup title="Pelada" items={ajustes}>
        <ListItemDanger onPress={sair} />
      </ListGroup>
      {me && (
        <View style={{ marginTop: 6 }}>
          <ReportLink peladaId={id} targetType="pelada" targetId={id} label="Denunciar nome ou imagem da pelada" />
        </View>
      )}
    </Screen>
  );
}

function Step({ n, title, text }: { n: number; title: string; text: string }) {
  return (
    <View style={{ flexDirection: 'row', gap: 10 }}>
      <View style={{ width: 24, height: 24, borderRadius: 12, backgroundColor: colors.blue, alignItems: 'center', justifyContent: 'center' }}>
        <Text style={{ color: colors.white, fontWeight: '800', fontSize: 13 }}>{n}</Text>
      </View>
      <View style={{ flex: 1, gap: 2 }}>
        <Text style={{ fontWeight: '700', color: colors.ink }}>{title}</Text>
        <Text style={{ color: colors.muted, fontSize: 14 }}>{text}</Text>
      </View>
    </View>
  );
}

type GroupItem = ListItemProps;

// "Sair da pelada" fecha o grupo Pelada, em vermelho e sem seta (ação destrutiva com confirmação).
function ListItemDanger({ onPress }: { onPress: () => void }) {
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={({ pressed }) => ({ minHeight: 52, paddingHorizontal: 14, justifyContent: 'center', borderTopWidth: 1, borderTopColor: colors.divider, backgroundColor: pressed ? colors.bg : colors.white })}>
      <Text style={{ fontSize: 16, fontWeight: '600', color: colors.danger }}>Sair da pelada</Text>
    </Pressable>
  );
}

const box = { backgroundColor: colors.white, borderRadius: 14, borderWidth: 1, borderColor: colors.line, padding: 14, gap: 6 };
const label = (color: string) => ({ fontSize: 14, fontWeight: '700' as const, color });
const section = { fontSize: 19, lineHeight: 25, fontWeight: '700' as const, color: colors.deepBlue, marginTop: 10 };
