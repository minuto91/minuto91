import AsyncStorage from '@react-native-async-storage/async-storage';
import { Href, useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { AppState, Pressable, Text, View } from 'react-native';

import { Avatar } from '../lib/avatar';
import { TIER } from '../lib/career';
import { CareerSummary, latestCard, loadCareerSummary, markGuide, referencePelada, trophyTotal } from '../lib/careerv2';
import { Crest } from '../lib/crest';
import { friendly } from '../lib/errors';
import { fmtDate, fmtTime, STATUS_LABEL } from '../lib/match';
import { PushPrompt } from '../lib/push';
import { useAuth } from '../lib/session';
import { supabase } from '../lib/supabase';
import { colors, positionLabel } from '../lib/theme';
import { Body, Button, Card, ErrorText, Screen, Sub } from '../lib/ui';

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
type LastMatch = {
  match_id: string;
  pelada_name: string;
  crest_path: string | null;
  played_at: string;
  status: string;
  team_a_name: string;
  team_b_name: string;
  team_a_score: number;
  team_b_score: number;
  my_team: 'A' | 'B';
  result: 'win' | 'draw' | 'loss';
  goals: number;
  assists: number;
  official: boolean;
};
type Central = {
  me: { display_name: string; avatar_path: string | null; dominant_foot: string | null } | null;
  primary_pelada_id: string | null;
  peladas: Pelada[];
  last_match: LastMatch | null;
  next_rounds: { lineup_id: string; pelada_id: string; pelada_name: string; label: string; team_name: string; opponent_name: string }[];
  pending: {
    votes: { match_id: string; pelada_name: string; closes_at: string; team_a_name: string; team_b_name: string; team_a_score: number; team_b_score: number }[];
    positions: { pelada_id: string; pelada_name: string; membership_id: string }[];
    profile: { photo: boolean; foot: boolean };
  };
  guide: { dismissed: boolean; seen: { career?: boolean; cards?: boolean } };
};

// O convite guardado antes do login abre sozinho uma vez por sessão do app; depois fica como pendência até ser
// aceito (ou se mostrar inválido) na tela do convite, que o apaga.
let inviteOpened = false;

const ROLE = (r: string) => (r === 'admin' ? 'Administrador' : r === 'assistant' ? 'Assistente' : 'Jogador');
const RESULT = { win: 'Vitória', draw: 'Empate', loss: 'Derrota' } as const;

// Central do Jogador (V4.4): a tela inicial de todo mundo, administradores incluídos (o admin também é jogador; as
// funções de administração continuam dentro de cada pelada). Duas leituras independentes, cada uma com o seu estado:
// get_player_central (peladas, pendências, último jogo, próxima rodada, guia) e get_player_career_summary (Card,
// resumo e troféus). Nada aqui recalcula histórico; nada financeiro aparece aqui.
export default function Home() {
  const { session } = useAuth();
  const router = useRouter();
  const uid = session?.user.id ?? '';
  const [data, setData] = useState<Central | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [career, setCareer] = useState<CareerSummary | null>(null);
  const [careerErr, setCareerErr] = useState<string | null>(null);
  const [purgeAfter, setPurgeAfter] = useState<string | null>(null);
  const [pendingInvite, setPendingInvite] = useState<string | null>(null);
  const [reload, setReload] = useState(0); // incrementar = buscar de novo

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
        const [{ data: st }, central] = await Promise.all([supabase.rpc('get_account_status'), supabase.rpc('get_player_central')]);
        if (!alive) return;
        setPurgeAfter((st as { purge_after: string | null } | null)?.purge_after ?? null);
        // Falha de rede não vira "nenhuma pelada".
        if (central.error || !central.data) return setErr('Não foi possível carregar a sua Central. Verifique a internet e tente de novo.');
        setErr(null);
        setData(central.data as Central);
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

  // Pendências se atualizam ao voltar para o app e quando o prazo da próxima votação vence.
  useEffect(() => {
    const sub = AppState.addEventListener('change', (s) => s === 'active' && setReload((n) => n + 1));
    return () => sub.remove();
  }, []);
  const pendingVotes = data?.pending.votes;
  useEffect(() => {
    const next = (pendingVotes ?? []).map((p) => new Date(p.closes_at).getTime()).filter((t) => t > Date.now()).sort((a, b) => a - b)[0];
    if (!next) return;
    const timer = setTimeout(() => setReload((n) => n + 1), Math.min(next - Date.now() + 1000, 2 ** 31 - 1));
    return () => clearTimeout(timer);
  }, [pendingVotes]);

  async function principal(p: Pelada) {
    const { error } = await supabase.rpc('set_primary_pelada', { p_pelada: p.is_primary ? null : p.id });
    if (error) return setErr(friendly(error.message));
    setReload((n) => n + 1);
  }

  async function dispensarGuia() {
    await markGuide('dismiss').catch(() => {});
    setReload((n) => n + 1);
  }

  const peladas = data?.peladas ?? [];
  const me = data?.me;
  const visibleCareer = career?.visible ? career : null;
  const ref = visibleCareer ? referencePelada(visibleCareer.peladas, data?.primary_pelada_id ?? null) : null;
  const card = ref ? latestCard(ref) : null;
  const votes = pendingVotes ?? [];
  const steps = data ? guideSteps(data, (h) => router.push(h)) : [];
  const showGuide = !!data && !data.guide.dismissed && steps.some((s) => !s.done);

  return (
    <Screen>
      <Pressable
        onPress={() => router.push('/perfil')}
        accessibilityRole="button"
        accessibilityLabel="Abrir meu perfil"
        style={{ flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 4 }}>
        <Avatar path={me?.avatar_path} name={me?.display_name ?? ' '} size={48} />
        <View style={{ flex: 1 }}>
          <Text style={{ fontSize: 20, fontWeight: '800', color: colors.deepBlue }} numberOfLines={1}>
            {me ? `Olá, ${me.display_name}` : ' '}
          </Text>
          <Sub>Meu perfil ›</Sub>
        </View>
      </Pressable>

      <ErrorText>{err}</ErrorText>
      {err && <Button title="Tentar de novo" kind="secondary" onPress={() => setReload((n) => n + 1)} />}
      {!data && !err && <Sub>Carregando...</Sub>}
      {purgeAfter && (
        <Pressable onPress={() => router.push('/conta')}>
          <Card>
            <Body>Sua conta será apagada em {new Date(purgeAfter).toLocaleDateString('pt-BR')}.</Body>
            <Sub>Toque aqui para recuperar a conta e o seu histórico.</Sub>
          </Card>
        </Pressable>
      )}

      {/* Pendências: só o que pede uma ação. */}
      {votes.length > 0 && (
        <>
          <Text style={section}>Falta o seu voto</Text>
          {votes.map((p) => (
            <Pressable key={p.match_id} onPress={() => router.push({ pathname: '/partida/[id]', params: { id: p.match_id } })} accessibilityRole="button">
              <View style={{ ...cardBox, borderColor: colors.blue, borderWidth: 1.5 }}>
                <Body>
                  {p.team_a_name} {p.team_a_score} x {p.team_b_score} {p.team_b_name}
                </Body>
                <Sub>
                  {p.pelada_name} · votação até {fmtDate(p.closes_at)}, {fmtTime(p.closes_at)}
                </Sub>
                <Text style={{ color: colors.blue, fontWeight: '700' }}>Votar ›</Text>
              </View>
            </Pressable>
          ))}
        </>
      )}
      {pendingInvite && (
        <Pressable accessibilityRole="button" onPress={() => router.push({ pathname: '/convite/[token]', params: { token: pendingInvite } })}>
          <Card>
            <Body>Você tem um convite para aceitar</Body>
            <Sub>Toque para ver a pelada e entrar.</Sub>
          </Card>
        </Pressable>
      )}
      {data && (data.pending.positions.length > 0 || data.pending.profile.photo) && (
        <View style={{ gap: 6 }}>
          {data.pending.positions.map((p) => (
            <Pressable
              key={p.membership_id}
              accessibilityRole="button"
              onPress={() => router.push({ pathname: '/jogador/[id]', params: { id: p.membership_id } })}
              style={pendingRow}>
              <Text style={{ color: colors.darkGold, fontWeight: '700' }}>Atualize sua posição em {p.pelada_name} ›</Text>
            </Pressable>
          ))}
          {data.pending.profile.photo && peladas.length > 0 && (
            <Pressable accessibilityRole="button" onPress={() => router.push('/perfil')} style={pendingRow}>
              <Text style={{ color: colors.darkGold, fontWeight: '700' }}>Complete seu perfil: coloque uma foto ›</Text>
            </Pressable>
          )}
        </View>
      )}

      {showGuide && (
        <Card>
          <View style={{ flexDirection: 'row', alignItems: 'center' }}>
            <Text style={{ flex: 1, fontWeight: '800', color: colors.deepBlue }}>Primeiros passos</Text>
            <Pressable accessibilityRole="button" accessibilityLabel="Dispensar o guia" onPress={dispensarGuia} style={{ minHeight: 40, justifyContent: 'center' }}>
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
              style={{ flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 40 }}>
              <Text style={{ fontSize: 16, color: s.done ? colors.blue : colors.line, width: 20 }}>{s.done ? '✓' : '○'}</Text>
              <Text style={{ flex: 1, color: s.done ? colors.muted : colors.ink, textDecorationLine: s.done ? 'line-through' : 'none' }}>{s.label}</Text>
              {!s.done && <Text style={{ color: colors.blue }}>›</Text>}
            </Pressable>
          ))}
        </Card>
      )}

      {/* Minha Carreira (prévia) e Resumo da Carreira */}
      {peladas.length > 0 && (
        <>
          <Text style={section}>Minha Carreira</Text>
          <Pressable accessibilityRole="button" accessibilityLabel="Abrir Minha Carreira" onPress={() => router.push('/carreira')}>
            <View style={{ ...cardBox, borderWidth: 1, borderColor: colors.line }}>
              {careerErr && <Sub>Não foi possível carregar a carreira agora.</Sub>}
              {!career && !careerErr && <Sub>Carregando...</Sub>}
              {visibleCareer && (
                <>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
                    <Avatar path={me?.avatar_path} name={me?.display_name ?? ' '} size={56} />
                    <View style={{ flex: 1, gap: 2 }}>
                      <Text style={{ fontWeight: '800', color: colors.ink, fontSize: 16 }} numberOfLines={1}>
                        {me?.display_name}
                      </Text>
                      <Sub>{ref ? positionLabel(ref.position_code ?? ref.position) : ''}</Sub>
                      {card && ref && (
                        <Text style={{ color: TIER[card.card.tier].color, fontWeight: '800' }}>
                          Overall {Math.round(Number(card.card.overall))} · {TIER[card.card.tier].label}
                          <Text style={{ color: colors.muted, fontWeight: '400' }}>
                            {' '}
                            · {ref.name}, {card.season.name}
                          </Text>
                        </Text>
                      )}
                    </View>
                  </View>
                  <View style={{ flexDirection: 'row' }}>
                    <MiniStat value={visibleCareer.totals.matches_played} label="Jogos" />
                    <MiniStat value={visibleCareer.totals.goals} label="Gols" />
                    <MiniStat value={visibleCareer.totals.assists} label="Assist." />
                    <MiniStat value={trophyTotal(visibleCareer.trophies)} label="Premiações" />
                  </View>
                  <Sub>
                    {visibleCareer.peladas.length > 1 ? 'Somando todas as suas peladas' : 'Na sua pelada'}
                    {visibleCareer.partial ? ' (temporadas disponíveis)' : ''}. O overall é de cada pelada.
                  </Sub>
                  <Text style={{ color: colors.blue, fontWeight: '700' }}>Ver Minha Carreira ›</Text>
                </>
              )}
            </View>
          </Pressable>
        </>
      )}

      {data?.last_match && (
        <>
          <Text style={section}>Último jogo</Text>
          <Pressable accessibilityRole="button" onPress={() => router.push({ pathname: '/partida/[id]', params: { id: data.last_match!.match_id } })}>
            <View style={{ ...cardBox, borderWidth: 1, borderColor: colors.line }}>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                <Crest path={data.last_match.crest_path} name={data.last_match.pelada_name} size={28} />
                <Sub>
                  {data.last_match.pelada_name} · {fmtDate(data.last_match.played_at)}
                </Sub>
              </View>
              <Body>
                {data.last_match.team_a_name} {data.last_match.team_a_score} x {data.last_match.team_b_score} {data.last_match.team_b_name}
              </Body>
              <Text style={{ fontWeight: '700', color: data.last_match.result === 'win' ? colors.blue : data.last_match.result === 'loss' ? colors.danger : colors.darkGold }}>
                {RESULT[data.last_match.result]} do seu time
                <Text style={{ color: colors.muted, fontWeight: '400' }}>
                  {data.last_match.goals ? ` · ${data.last_match.goals} ${data.last_match.goals === 1 ? 'gol' : 'gols'}` : ''}
                  {data.last_match.assists
                    ? ` · ${data.last_match.assists} ${data.last_match.assists === 1 ? 'assistência' : 'assistências'}`
                    : ''}
                </Text>
              </Text>
              {!data.last_match.official && <Sub>{STATUS_LABEL[data.last_match.status] ?? 'Em andamento'}: o resultado ainda não é oficial.</Sub>}
            </View>
          </Pressable>
        </>
      )}

      {data && data.next_rounds.length > 0 && (
        <>
          <Text style={section}>Próxima rodada</Text>
          {data.next_rounds.slice(0, 3).map((r) => (
            <Pressable
              key={r.lineup_id}
              accessibilityRole="button"
              onPress={() => router.push({ pathname: '/pelada/[id]/escalacoes', params: { id: r.pelada_id } })}>
              <View style={{ ...cardBox, borderWidth: 1, borderColor: colors.line }}>
                <Body>
                  {r.team_name} x {r.opponent_name}
                </Body>
                <Sub>
                  {r.pelada_name} · {r.label} · você está no {r.team_name}
                </Sub>
              </View>
            </Pressable>
          ))}
        </>
      )}

      {data && peladas.length > 0 && <PushPrompt />}

      <Text style={section}>Minhas peladas</Text>
      {data && peladas.length === 0 && (
        <Card>
          <Body>Você ainda não está em nenhuma pelada.</Body>
          <Sub>Crie a pelada da sua turma ou entre com o convite que recebeu.</Sub>
          <Button title="Criar pelada" onPress={() => router.push('/criar-pelada')} />
          <Button title="Entrar com convite" kind="secondary" onPress={() => router.push('/entrar')} />
        </Card>
      )}
      {peladas.map((p) => (
        <Pressable key={p.id} accessibilityRole="button" onPress={() => router.push({ pathname: '/pelada/[id]', params: { id: p.id } })}>
          <Card>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
              <Crest path={p.crest_path} name={p.name} size={44} />
              <View style={{ flex: 1, gap: 2 }}>
                <Text style={{ fontSize: 17, fontWeight: '700', color: colors.deepBlue }} numberOfLines={1}>
                  {p.name}
                </Text>
                <Sub>
                  {ROLE(p.role)} · {positionLabel(p.position_code ?? p.position)}
                  {p.drafts > 0 ? ` · ${p.drafts === 1 ? '1 súmula em rascunho' : `${p.drafts} súmulas em rascunho`}` : ''}
                </Sub>
              </View>
              <Text style={{ color: colors.muted, fontSize: 18 }}>›</Text>
            </View>
            {peladas.length > 1 && (
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={p.is_primary ? `${p.name} é a pelada principal. Toque para desmarcar.` : `Tornar ${p.name} a pelada principal`}
                onPress={() => principal(p)}
                style={{ minHeight: 32, justifyContent: 'center', alignSelf: 'flex-start' }}>
                <Text style={{ fontSize: 12, fontWeight: '700', color: p.is_primary ? colors.darkGold : colors.muted }}>
                  {p.is_primary ? '★ Principal' : '☆ Tornar principal'}
                </Text>
              </Pressable>
            )}
          </Card>
        </Pressable>
      ))}

      {peladas.length > 0 && (
        <View style={{ flexDirection: 'row', gap: 8, marginTop: 4 }}>
          <View style={{ flex: 1 }}>
            <Button title="Criar pelada" kind="secondary" onPress={() => router.push('/criar-pelada')} />
          </View>
          <View style={{ flex: 1 }}>
            <Button title="Entrar em outra pelada" kind="secondary" onPress={() => router.push('/entrar')} />
          </View>
        </View>
      )}
    </Screen>
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

function MiniStat({ value, label }: { value: number; label: string }) {
  return (
    <View style={{ flex: 1, alignItems: 'center' }} accessibilityLabel={`${label}: ${value}`}>
      <Text style={{ fontSize: 20, fontWeight: '800', color: colors.deepBlue, fontVariant: ['tabular-nums'] }}>{value}</Text>
      <Text style={{ fontSize: 12, color: colors.muted }}>{label}</Text>
    </View>
  );
}

const section = { fontSize: 13, fontWeight: '800' as const, color: colors.deepBlue, letterSpacing: 0.5, marginTop: 6 };
const cardBox = { backgroundColor: colors.white, borderRadius: 12, padding: 14, gap: 6 };
const pendingRow = { minHeight: 40, justifyContent: 'center' as const, borderLeftWidth: 3, borderLeftColor: colors.gold, paddingLeft: 10 };
