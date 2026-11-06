import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { AppState, Pressable, View } from 'react-native';
import { Text } from '../../../lib/text';
import { HOME , colors, needsPositionUpdate } from '../../../lib/theme';

import { currentSeason, loadSeasons } from '../../../lib/career';
import { Crest } from '../../../lib/crest';
import { confirm } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { Icon, IconName } from '../../../lib/icons';
import { fmtDate, fmtTime, Match, MATCH_COLUMNS, scoreLine, STATUS_LABEL } from '../../../lib/match';
import { AdminPending } from '../../../lib/pending';
import { PositionRequests } from '../../../lib/ratingadmin';
import { ReportLink } from '../../../lib/report';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { Body, Button, ErrorText, ListGroup, ListRow, Screen, Sub, LinkLabel } from '../../../lib/ui';
import { MatchScore } from '../../../lib/domain';

type Member = { id: string; user_id: string | null; player_name: string; role: string; preferred_position: string; position_code?: string | null };
type Highlight = { match_id: string; membership_id: string; highlight_type: string };
type MyVote = { matchId: string; closesAt: string };

const HIGHLIGHT_LABEL: Record<string, string> = {
  // REV-145: sem o destaque "Garçom da rodada" aqui (dados de assistências, rankings e prêmios seguem intactos).
  craque: 'Craque da Partida',
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
  const [myTeam, setMyTeam] = useState<'A' | 'B' | null>(null);
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
        // REV-144: time em que eu atuei no último jogo (negrito); sem participação, nenhum time em destaque.
        const lf = ((xs ?? []) as Match[]).find((m) => m.status === 'finalized');
        let team: 'A' | 'B' | null = null;
        if (lf && mine) {
          const { data: pp } = await supabase.from('match_participants').select('team').eq('match_id', lf.id).eq('membership_id', mine.id).maybeSingle();
          team = (pp?.team as 'A' | 'B' | undefined) ?? null;
        }
        if (!alive) return;
        setMyTeam(team);
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

  // V4.6: a pelada em três grupos claros (protótipo aprovado): Jogo, Desempenho e Gestão (conforme as permissões).
  // Linhas com ícone, nome e uma linha de apoio, em vez de uma grade de atalhos pequenos. Recursos da Pelada Premium
  // levam a marca dourada quando a pelada ainda está no Básico.
  const go = (pathname: Parameters<typeof router.push>[0]) => () => router.push(pathname);
  const jogo: GroupItem[] = [
    { icon: 'partidas', label: 'Partidas', sub: 'Súmula, votação e resultado', onPress: go({ pathname: '/pelada/[id]/partidas', params: { id } }) },
    { icon: 'elenco', label: 'Elenco', sub: loaded ? `${members.length} ${members.length === 1 ? 'jogador' : 'jogadores'}` : 'Jogadores da pelada', onPress: go({ pathname: '/pelada/[id]/elenco', params: { id } }) },
    { icon: 'escalacao', label: 'Escalações', sub: 'Times da próxima rodada', onPress: go({ pathname: '/pelada/[id]/escalacoes', params: { id } }) },
    ...(isStaff ? [{ icon: 'sorteio' as const, label: 'Sorteio', sub: 'Times equilibrados por posição', premium: true, onPress: go({ pathname: '/pelada/[id]/sorteio', params: { id } }) }] : []),
    { icon: 'duelo', label: 'Duelo', sub: 'Compare dois jogadores', premium: true, onPress: go({ pathname: '/pelada/[id]/duelo', params: { id } }) },
  ];
  const desempenho: GroupItem[] = [
    { icon: 'rankings', label: 'Rankings', sub: 'Overall, gols, assistências e prêmios do mês', onPress: go({ pathname: '/pelada/[id]/rankings', params: { id } }) },
    ...(me ? [{ icon: 'card' as const, label: 'Meu Card', sub: 'Overall, atributos e álbum', onPress: go({ pathname: '/jogador/[id]', params: { id: me.id } }) }] : []),
    { icon: 'jogadores', label: 'Jogadores e estatísticas', sub: 'Cards e números de cada um', onPress: go({ pathname: '/pelada/[id]/jogadores', params: { id } }) },
    { icon: 'retro', label: 'Retrospectiva', sub: 'Resumo da temporada', onPress: go({ pathname: '/pelada/[id]/retrospectiva', params: { id } }) },
    { icon: 'rankings', label: 'Craque da Temporada', sub: 'Votação no fim da temporada', onPress: go({ pathname: '/pelada/[id]/craque-temporada', params: { id } }) },
    { icon: 'rankings', label: 'Prêmios da temporada', sub: 'Artilheiro, Maestro e Luva de Ouro', onPress: go({ pathname: '/pelada/[id]/premios-temporada', params: { id } }) },
    { icon: 'temporadas', label: 'Temporadas', sub: 'Atual e anteriores', onPress: go({ pathname: '/pelada/[id]/temporadas', params: { id } }) },
  ];
  const gestao: GroupItem[] = [
    ...(isAdmin ? [{ icon: 'convite' as const, label: 'Convidar jogadores', sub: 'Link de convite', onPress: convidar }] : []),
    // Financeiro (V4.3): só admin e assistentes com permissão financeira; nenhum valor aparece fora dele.
    ...(finance ? [{ icon: 'financeiro' as const, label: 'Financeiro', sub: 'Mensalidades, cobranças e relatórios', premium: true, onPress: go({ pathname: '/pelada/[id]/financeiro', params: { id } }) }] : []),
    ...(isAdmin ? [{ icon: 'config' as const, label: 'Configurações', sub: 'Escudo, votação, assistentes e Premium', onPress: go({ pathname: '/pelada/[id]/configuracoes', params: { id } }) }] : []),
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
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        {pelada ? <Crest path={pelada.crest_path} name={pelada.name} size={56} /> : <View style={{ width: 56, height: 56 }} />}
        <View style={{ flex: 1, gap: 2 }}>
          <Text style={{ fontSize: 24, fontWeight: '800', color: colors.ink }} numberOfLines={2}>
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
            style={{ padding: 6, borderRadius: 10, backgroundColor: colors.blueSoft, borderWidth: 1, borderColor: colors.blue }}>
            <Icon name="config" size={24} color={colors.blue} />
          </Pressable>
        )}
      </View>
      {pelada?.status === 'restricted' && <Sub>Pelada restrita: sem administrador elegível.</Sub>}
      <ErrorText>{msg}</ErrorText>
      {msg && <Button title="Tentar de novo" kind="secondary" onPress={() => setReload((n) => n + 1)} />}

      {/* Pendência pessoal: o meu voto. */}
      {myVotes.map((v) => {
        const m = matches.find((x) => x.id === v.matchId);
        return (
          <Pressable key={v.matchId} accessibilityRole="button" onPress={() => openMatch(v.matchId)}>
            <View style={[box, { borderColor: colors.blue, borderWidth: 1.5 }]}>
              <Text style={label(colors.blue)}>Falta o seu voto</Text>
              {m && (
                <Body>
                  {scoreLine(m)}
                </Body>
              )}
              <Sub>Votação até {fmtDate(v.closesAt)}, {fmtTime(v.closesAt)}</Sub>
              <LinkLabel style={{ color: colors.blue, fontWeight: '700' }}>Votar</LinkLabel>
            </View>
          </Pressable>
        );
      })}

      {isStaff && loaded && (
        <AdminPending peladaId={id} matches={matches} members={members} successor={pelada?.successor_membership_id ?? null} isAdmin={isAdmin} onInvite={convidar} />
      )}
      {/* V5: pedidos de troca de posição (só o admin decide). Registro de cartões: Configurações (REV-014). */}
      {isAdmin && loaded && (
        <>
          <PositionRequests peladaId={id} isAdmin={isAdmin} />
        </>
      )}

      {/* Rodada em votação (para quem já votou ou não vota): o resultado sai quando a votação fechar. */}
      {inVoting
        .filter((m) => !myVotes.some((v) => v.matchId === m.id))
        .map((m) => (
          <Pressable key={m.id} accessibilityRole="button" onPress={() => openMatch(m.id)}>
            <View style={box}>
              <Text style={label(colors.deepBlue)}>Rodada em votação</Text>
              <Body>
                {scoreLine(m)}
              </Body>
              <Sub>
                {fmtDate(m.played_at)} · {STATUS_LABEL[m.status]}. O Craque e as notas saem quando a votação fechar.
              </Sub>
            </View>
          </Pressable>
        ))}

      {/* Última rodada finalizada. O compartilhamento usa as artes da tela da partida (V3). */}
      {lastFinal && (
        <Pressable accessibilityRole="button" accessibilityHint="Abre a partida, com súmula, notas e artes para compartilhar" onPress={() => openMatch(lastFinal.id)}>
          <View style={{ gap: 8 }}>
            <MatchScore
              a={lastFinal.team_a_name}
              b={lastFinal.team_b_name}
              scoreA={lastFinal.team_a_score}
              scoreB={lastFinal.team_b_score}
              mine={myTeam}
              compact
              top={
                <Text style={{ fontSize: 12, fontWeight: '700', letterSpacing: 0.6, color: colors.muted }} numberOfLines={1}>
                  ÚLTIMO JOGO · {fmtDate(lastFinal.played_at).toUpperCase()}
                </Text>
              }
            />
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
            <LinkLabel style={{ color: colors.blue, fontWeight: '700', marginTop: 2 }}>Ver partida e compartilhar</LinkLabel>
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
            <Sub>O resultado aparece aqui depois da súmula.</Sub>
          )}
        </View>
      )}

      {/* V4.3: cadastro antigo (Defensor, Meio-campista, Atacante) sem a posição específica. Aviso discreto. */}
      {me && needsPositionUpdate(me) && (
        <Pressable
          accessibilityRole="button"
          onPress={() => router.push({ pathname: '/jogador/[id]', params: { id: me.id } })}
          style={{ minHeight: 44, justifyContent: 'center', paddingHorizontal: 12, borderRadius: 10, borderWidth: 1, borderColor: colors.gold }}>
          <LinkLabel style={{ color: colors.darkGold, fontWeight: '600', fontSize: 14 }}>Atualize sua posição: agora são dez posições oficiais</LinkLabel>
        </Pressable>
      )}

      {isStaff && !empty && <Button title="Lançar partida" onPress={lancarPartida} loading={busy} />}
      {isStaff && empty && <Button title="Lançar a primeira partida" kind={isAdmin ? 'secondary' : 'primary'} onPress={lancarPartida} loading={busy} />}

      <Group title="Jogo" items={jogo} premium={premium} />

      {recent.length > 0 && (
        <View style={{ gap: 2 }}>
          <Text style={section}>Partidas recentes</Text>
          {recent.map((x) => (
            <Pressable
              key={x.id}
              accessibilityRole="button"
              onPress={() => openMatch(x.id)}
              style={{ paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: colors.line, flexDirection: 'row', alignItems: 'center', gap: 8 }}>
              <View style={{ flex: 1 }}>
                <Text style={{ color: colors.ink, fontSize: 15 }} numberOfLines={1}>
                  {scoreLine(x)}
                </Text>
                <Text style={{ color: colors.muted, fontSize: 13 }}>
                  {fmtDate(x.played_at)} · {STATUS_LABEL[x.status] ?? x.status}
                </Text>
              </View>
              <Icon name="chevron" size={20} color={colors.muted} />
            </Pressable>
          ))}
          <Pressable accessibilityRole="button" onPress={() => router.push({ pathname: '/pelada/[id]/partidas', params: { id } })}>
            <LinkLabel style={{ color: colors.blue, fontWeight: '700', paddingVertical: 8 }}>Ver todas as partidas</LinkLabel>
          </Pressable>
        </View>
      )}

      <Group title="Desempenho" items={desempenho} premium={premium} />
      {gestao.length > 0 && <Group title="Gestão" items={gestao} premium={premium} />}
      <Text style={section}>Pelada</Text>
      <ListGroup>
        <ListRow title="Pelada Premium" onPress={() => router.push({ pathname: '/pelada/[id]/premium', params: { id } })} />
        <ListRow title="Sair da pelada" danger onPress={sair} />
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

type GroupItem = { icon: IconName; label: string; sub: string; premium?: boolean; onPress: () => void };

function Group({ title, items, premium }: { title: string; items: GroupItem[]; premium: boolean }) {
  return (
    <View style={{ marginTop: 10 }}>
      <ListGroup title={title}>
        {items.map((a) => (
          <ListRow
            key={a.label}
            icon={a.icon}
            title={a.label}
            subtitle={a.sub}
            accessibilityLabel={a.premium && !premium ? `${a.label}, recurso da Pelada Premium` : a.label}
            onPress={a.onPress}
            trailing={a.premium && !premium ? <Text style={{ fontSize: 12, fontWeight: '700', color: colors.blue }}>Premium</Text> : undefined}
          />
        ))}
      </ListGroup>
    </View>
  );
}

const box = { backgroundColor: colors.bg, borderRadius: 12, padding: 14, gap: 6 };
const label = (color: string) => ({ fontSize: 14, fontWeight: '700' as const, color });
const section = { fontSize: 19, lineHeight: 25, fontWeight: '700' as const, color: colors.ink, marginTop: 10 };
