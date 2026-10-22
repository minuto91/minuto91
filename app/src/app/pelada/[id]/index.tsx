import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { AppState, Pressable, Text, View } from 'react-native';

import { currentSeason, loadSeasons } from '../../../lib/career';
import { Crest } from '../../../lib/crest';
import { confirm } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { Icon, IconName } from '../../../lib/icons';
import { fmtDate, fmtTime, Match, MATCH_COLUMNS, STATUS_LABEL } from '../../../lib/match';
import { AdminPending } from '../../../lib/pending';
import { ReportLink } from '../../../lib/report';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, needsPositionUpdate } from '../../../lib/theme';
import { Body, Button, ErrorText, Screen, Sub } from '../../../lib/ui';

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
        router.replace('/');
      },
    );
  }

  const actions: { icon: IconName; label: string; onPress: () => void }[] = [
    { icon: 'elenco', label: 'Elenco', onPress: () => router.push({ pathname: '/pelada/[id]/elenco', params: { id } }) },
    { icon: 'rankings', label: 'Rankings', onPress: () => router.push({ pathname: '/pelada/[id]/rankings', params: { id } }) },
    ...(me ? [{ icon: 'card' as const, label: 'Meu Card', onPress: () => router.push({ pathname: '/jogador/[id]', params: { id: me.id } }) }] : []),
    { icon: 'partidas', label: 'Partidas', onPress: () => router.push({ pathname: '/pelada/[id]/partidas', params: { id } }) },
    { icon: 'retro', label: 'Retrospectiva', onPress: () => router.push({ pathname: '/pelada/[id]/retrospectiva', params: { id } }) },
    { icon: 'jogadores', label: 'Jogadores', onPress: () => router.push({ pathname: '/pelada/[id]/jogadores', params: { id } }) },
  ];

  // Organização (V4.2): escalações, sorteio, Duelo e temporadas num grupo só, para não lotar a Central.
  // Recursos da Pelada Premium levam a marca dourada quando a pelada ainda está no Básico.
  const organize: { icon: IconName; label: string; premium?: boolean; onPress: () => void }[] = [
    { icon: 'escalacao', label: 'Escalações', onPress: () => router.push({ pathname: '/pelada/[id]/escalacoes', params: { id } }) },
    ...(isStaff ? [{ icon: 'sorteio' as const, label: 'Sorteio', premium: true, onPress: () => router.push({ pathname: '/pelada/[id]/sorteio', params: { id } }) }] : []),
    { icon: 'duelo', label: 'Duelo', premium: true, onPress: () => router.push({ pathname: '/pelada/[id]/duelo', params: { id } }) },
    { icon: 'temporadas', label: 'Temporadas', onPress: () => router.push({ pathname: '/pelada/[id]/temporadas', params: { id } }) },
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
          <Text style={{ fontSize: 24, fontWeight: '800', color: colors.deepBlue }} numberOfLines={2}>
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
            style={{ padding: 6 }}>
            <Icon name="config" size={24} color={colors.muted} />
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
              <Text style={label(colors.blue)}>FALTA O SEU VOTO</Text>
              {m && (
                <Body>
                  {m.team_a_name} {m.team_a_score} x {m.team_b_score} {m.team_b_name}
                </Body>
              )}
              <Sub>Votação até {fmtDate(v.closesAt)}, {fmtTime(v.closesAt)}</Sub>
              <Text style={{ color: colors.blue, fontWeight: '700' }}>Votar ›</Text>
            </View>
          </Pressable>
        );
      })}

      {isStaff && loaded && (
        <AdminPending peladaId={id} matches={matches} members={members} successor={pelada?.successor_membership_id ?? null} isAdmin={isAdmin} onInvite={convidar} />
      )}

      {/* Rodada em votação (para quem já votou ou não vota): o resultado sai quando a votação fechar. */}
      {inVoting
        .filter((m) => !myVotes.some((v) => v.matchId === m.id))
        .map((m) => (
          <Pressable key={m.id} accessibilityRole="button" onPress={() => openMatch(m.id)}>
            <View style={box}>
              <Text style={label(colors.deepBlue)}>RODADA EM VOTAÇÃO</Text>
              <Body>
                {m.team_a_name} {m.team_a_score} x {m.team_b_score} {m.team_b_name}
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
          <View style={box}>
            <Text style={label(colors.deepBlue)}>ÚLTIMA RODADA · {fmtDate(lastFinal.played_at).toUpperCase()}</Text>
            <Scoreboard m={lastFinal} />
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
          <Text style={label(colors.deepBlue)}>{isStaff ? 'PRIMEIROS PASSOS' : 'AINDA SEM PARTIDAS'}</Text>
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

      {/* Atalhos: grade compacta, 3 por linha. */}
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
        {actions.map((a) => (
          <Pressable
            key={a.label}
            accessibilityRole="button"
            onPress={a.onPress}
            style={({ pressed }) => ({
              flexBasis: '31%',
              flexGrow: 1,
              alignItems: 'center',
              gap: 6,
              paddingVertical: 12,
              borderRadius: 12,
              borderWidth: 1,
              borderColor: colors.line,
              backgroundColor: pressed ? colors.bg : colors.white,
            })}>
            <Icon name={a.icon} size={24} />
            <Text style={{ fontSize: 13, fontWeight: '600', color: colors.ink }} numberOfLines={1}>
              {a.label}
            </Text>
          </Pressable>
        ))}
      </View>

      <Text style={section}>Organização</Text>
      <View style={{ flexDirection: 'row', gap: 8 }}>
        {organize.map((a) => (
          <Pressable
            key={a.label}
            accessibilityRole="button"
            accessibilityLabel={a.premium && !premium ? `${a.label}, recurso da Pelada Premium` : a.label}
            onPress={a.onPress}
            style={({ pressed }) => ({
              flex: 1,
              alignItems: 'center',
              gap: 4,
              paddingVertical: 10,
              borderRadius: 12,
              borderWidth: 1,
              borderColor: a.premium && !premium ? colors.gold : colors.line,
              backgroundColor: pressed ? colors.bg : colors.white,
            })}>
            <Icon name={a.icon} size={22} />
            <Text style={{ fontSize: 12, fontWeight: '600', color: colors.ink }} numberOfLines={1}>
              {a.label}
            </Text>
            {a.premium && !premium && <Text style={{ fontSize: 9, fontWeight: '800', letterSpacing: 1, color: colors.darkGold }}>PREMIUM</Text>}
          </Pressable>
        ))}
      </View>

      {isStaff && !empty && <Button title="Lançar partida" onPress={lancarPartida} loading={busy} />}
      {isStaff && empty && <Button title="Lançar a primeira partida" kind={isAdmin ? 'secondary' : 'primary'} onPress={lancarPartida} loading={busy} />}

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
                  {x.team_a_name} {x.team_a_score} x {x.team_b_score} {x.team_b_name}
                </Text>
                <Text style={{ color: x.status === 'annulled' ? colors.danger : colors.muted, fontSize: 13 }}>
                  {fmtDate(x.played_at)} · {STATUS_LABEL[x.status] ?? x.status}
                </Text>
              </View>
              <Text style={{ color: colors.muted, fontSize: 18 }}>›</Text>
            </Pressable>
          ))}
          <Pressable accessibilityRole="button" onPress={() => router.push({ pathname: '/pelada/[id]/partidas', params: { id } })}>
            <Text style={{ color: colors.blue, fontWeight: '700', paddingVertical: 8 }}>Ver todas as partidas ›</Text>
          </Pressable>
        </View>
      )}

      {(isAdmin || finance) && (
        <>
          <Text style={section}>Administração</Text>
          {isAdmin && <Row title="Convidar jogadores" onPress={convidar} />}
          {isAdmin && <Row title="Configurações da pelada" onPress={() => router.push({ pathname: '/pelada/[id]/configuracoes', params: { id } })} />}
          {/* Financeiro (V4.3): só admin e assistentes com permissão financeira; nenhum valor aparece na Central. */}
          {finance && (
            <Row title={premium ? 'Financeiro' : 'Financeiro · Pelada Premium'} onPress={() => router.push({ pathname: '/pelada/[id]/financeiro/index', params: { id } })} />
          )}
        </>
      )}
      <Text style={section}>Pelada</Text>
      <Row title="Pelada Premium" onPress={() => router.push({ pathname: '/pelada/[id]/premium', params: { id } })} />
      <Row title="Sair da pelada" danger onPress={sair} />
      {me && (
        <View style={{ marginTop: 6 }}>
          <ReportLink peladaId={id} targetType="pelada" targetId={id} label="Denunciar nome ou imagem da pelada" />
        </View>
      )}
    </Screen>
  );
}

function Scoreboard({ m }: { m: Match }) {
  const aWon = m.team_a_score > m.team_b_score;
  const bWon = m.team_b_score > m.team_a_score;
  const team = (name: string, won: boolean, align: 'left' | 'right') => (
    <Text style={{ flex: 1, textAlign: align, fontSize: 15, fontWeight: won ? '800' : '500', color: colors.ink }} numberOfLines={2}>
      {name}
    </Text>
  );
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 4 }}>
      {team(m.team_a_name, aWon, 'left')}
      <Text style={{ fontSize: 30, fontWeight: '800', color: colors.deepBlue, fontVariant: ['tabular-nums'] }}>
        {m.team_a_score} x {m.team_b_score}
      </Text>
      {team(m.team_b_name, bWon, 'right')}
    </View>
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

function Row({ title, onPress, danger }: { title: string; onPress: () => void; danger?: boolean }) {
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={{ flexDirection: 'row', alignItems: 'center', paddingVertical: 12, borderBottomWidth: 1, borderBottomColor: colors.line }}>
      <Text style={{ flex: 1, fontSize: 15, color: danger ? colors.danger : colors.ink, fontWeight: '500' }}>{title}</Text>
      {!danger && <Text style={{ color: colors.muted, fontSize: 18 }}>›</Text>}
    </Pressable>
  );
}

const box = { backgroundColor: colors.white, borderRadius: 12, borderWidth: 1, borderColor: colors.line, padding: 14, gap: 6 };
const label = (color: string) => ({ fontSize: 12, fontWeight: '800' as const, letterSpacing: 1, color });
const section = { fontSize: 13, fontWeight: '800' as const, color: colors.deepBlue, letterSpacing: 0.5, marginTop: 10 };
