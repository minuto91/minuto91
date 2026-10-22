import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, Share, Text, View } from 'react-native';
import * as Linking from 'expo-linking';

import { Avatar } from '../../../lib/avatar';
import { Crest } from '../../../lib/crest';
import { confirm } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { fmtDate, Match, MATCH_COLUMNS, STATUS_LABEL } from '../../../lib/match';
import { AdminPending } from '../../../lib/pending';
import { ReportLink } from '../../../lib/report';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, positionLabel } from '../../../lib/theme';
import { Body, Button, Card, ErrorText, Screen, Sub, Title } from '../../../lib/ui';

type Member = {
  id: string;
  user_id: string | null;
  player_name: string;
  role: string;
  preferred_position: string;
};

type Highlight = { match_id: string; membership_id: string; highlight_type: string };

const HIGHLIGHT_LABEL: Record<string, string> = {
  craque: 'Craque da Partida',
  garcom_round: 'Garçom da rodada',
  bola_murcha: 'Bola Murcha',
};

export default function Pelada() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const router = useRouter();
  const [nome, setNome] = useState('');
  const [status, setStatus] = useState('');
  const [crest, setCrest] = useState<string | null>(null);
  const [successor, setSuccessor] = useState<string | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [matches, setMatches] = useState<Match[]>([]);
  const [highlights, setHighlights] = useState<Highlight[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [photos, setPhotos] = useState<Record<string, string | null>>({});
  const [allMatches, setAllMatches] = useState(false);
  const [managing, setManaging] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data: p } = await supabase
      .from('peladas')
      .select('name, status, successor_membership_id, crest_path')
      .eq('id', id)
      .maybeSingle();
    if (p) {
      setNome(p.name);
      setStatus(p.status);
      setCrest(p.crest_path);
      setSuccessor(p.successor_membership_id);
    }
    const { data: ms, error } = await supabase
      .from('pelada_memberships')
      .select('id, user_id, player_name, role, preferred_position')
      .eq('pelada_id', id)
      .eq('status', 'active')
      .order('joined_at', { ascending: true });
    if (error) setMsg(friendly(error.message));
    else {
      setMembers((ms ?? []) as Member[]);
      // Fotos só de quem o RLS deixa ver (pelada em comum, sem bloqueio).
      const uids = (ms ?? []).map((m) => m.user_id).filter((u): u is string => !!u);
      if (uids.length) {
        const { data: pr } = await supabase.from('profiles').select('id, avatar_path').in('id', uids);
        setPhotos(Object.fromEntries((pr ?? []).map((p) => [p.id as string, p.avatar_path as string | null])));
      }
    }
    // Rascunhos só aparecem para admin e assistentes (regra do banco).
    const { data: xs } = await supabase
      .from('matches')
      .select(MATCH_COLUMNS)
      .eq('pelada_id', id)
      .order('played_at', { ascending: false })
      .limit(20);
    setMatches((xs ?? []) as Match[]);
    // Destaques da última partida finalizada (somem quando a próxima é finalizada).
    const { data: hs } = await supabase
      .from('highlights')
      .select('match_id, membership_id, highlight_type')
      .eq('pelada_id', id)
      .is('expires_at', null);
    setHighlights((hs ?? []) as Highlight[]);
    setLoaded(true);
  }, [id]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  const me = members.find((m) => m.user_id === session?.user.id);
  const isAdmin = me?.role === 'admin';
  const isStaff = isAdmin || me?.role === 'assistant';

  async function lancarPartida() {
    const matchId = (await rpc('create_match', {
      p_pelada: id,
      p_played_at: new Date().toISOString(),
    })) as string | null;
    if (matchId) router.push({ pathname: '/partida/[id]/sumula', params: { id: matchId } });
  }

  async function rpc(name: string, args: Record<string, unknown>) {
    setBusy(true);
    setMsg(null);
    const { data, error } = await supabase.rpc(name, args);
    setBusy(false);
    if (error) {
      setMsg(friendly(error.message));
      return null;
    }
    await load();
    return data;
  }

  async function convidar() {
    const token = (await rpc('create_pelada_invite', { p_pelada: id })) as string | null;
    if (!token) return;
    const link = Linking.createURL(`convite/${token}`);
    await Share.share({
      message: `Entra na nossa pelada "${nome}" no Minuto 91:\n${link}\n\nOu cole este código no app: ${token}`,
    });
  }

  function sair() {
    confirm(
      'Sair da pelada?',
      isAdmin
        ? 'Você é o administrador. A administração passa automaticamente: primeiro o sucessor indicado, depois o assistente mais antigo, depois o jogador mais antigo.'
        : 'Seu histórico fica guardado e você pode voltar por um novo convite.',
      'Sair',
      async () => {
        const r = await rpc('leave_pelada', { p_pelada: id });
        if (r) router.replace('/');
      },
    );
  }

  const roleName = (r: string) => (r === 'admin' ? 'Administrador' : r === 'assistant' ? 'Assistente' : 'Jogador');

  const shown = allMatches ? matches : matches.slice(0, 5);
  const go = (pathname: '/pelada/[id]/rankings' | '/pelada/[id]/elenco' | '/pelada/[id]/configuracoes' | '/pelada/[id]/premium') =>
    router.push({ pathname, params: { id } });

  return (
    <Screen>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        {nome ? <Crest path={crest} name={nome} size={48} /> : null}
        <View style={{ flex: 1 }}>
          <Title>{nome || 'Pelada'}</Title>
        </View>
      </View>
      {status === 'restricted' && <Sub>Pelada restrita: sem administrador elegível.</Sub>}
      <ErrorText>{msg}</ErrorText>

      {me && <Button title="Meu Card" onPress={() => router.push({ pathname: '/jogador/[id]', params: { id: me.id } })} />}
      <View style={{ flexDirection: 'row', gap: 8 }}>
        <View style={{ flex: 1 }}>
          <Button title="Elenco" kind="secondary" onPress={() => go('/pelada/[id]/elenco')} />
        </View>
        <View style={{ flex: 1 }}>
          <Button title="Rankings" kind="secondary" onPress={() => go('/pelada/[id]/rankings')} />
        </View>
      </View>

      {isStaff && loaded && (
        <AdminPending matches={matches} members={members} successor={successor} isAdmin={isAdmin} onInvite={convidar} />
      )}

      {highlights.length > 0 && (
        <Pressable
          accessibilityRole="button"
          onPress={() => router.push({ pathname: '/partida/[id]', params: { id: highlights[0].match_id } })}>
          <View style={{ backgroundColor: colors.white, borderRadius: 12, borderWidth: 1.5, borderColor: colors.gold, padding: 14, gap: 6 }}>
            <Text style={{ fontSize: 12, fontWeight: '800', letterSpacing: 1, color: colors.darkGold }}>DESTAQUES DA ÚLTIMA RODADA</Text>
            {Object.keys(HIGHLIGHT_LABEL)
              .filter((t) => highlights.some((h) => h.highlight_type === t))
              .map((t) => (
                <Text key={t} style={{ color: colors.ink, fontWeight: t === 'craque' ? '700' : '500' }}>
                  {HIGHLIGHT_LABEL[t]}:{' '}
                  {highlights
                    .filter((h) => h.highlight_type === t)
                    .map((h) => members.find((m) => m.id === h.membership_id)?.player_name ?? 'Jogador')
                    .join(', ')}
                </Text>
              ))}
          </View>
        </Pressable>
      )}

      <Text style={section}>Partidas</Text>
      {isStaff && <Button title="Lançar partida" onPress={lancarPartida} loading={busy} />}
      {!loaded && <Sub>Carregando...</Sub>}
      {loaded && matches.length === 0 && (
        <Sub>{isStaff ? 'Nenhuma partida ainda. Lance a primeira depois do jogo.' : 'Nenhuma partida ainda.'}</Sub>
      )}
      {shown.map((x) => (
        <Pressable key={x.id} accessibilityRole="button" onPress={() => router.push({ pathname: '/partida/[id]', params: { id: x.id } })}>
          <Card>
            <Body>
              {x.team_a_name} {x.team_a_score} x {x.team_b_score} {x.team_b_name}
            </Body>
            <Text style={{ color: x.status === 'voting_open' ? colors.blue : colors.muted, fontWeight: x.status === 'voting_open' ? '700' : '400' }}>
              {fmtDate(x.played_at)} · {STATUS_LABEL[x.status] ?? x.status}
            </Text>
          </Card>
        </Pressable>
      ))}
      {matches.length > 5 && (
        <Button
          title={allMatches ? 'Mostrar menos' : `Ver todas (${matches.length})`}
          kind="secondary"
          onPress={() => setAllMatches(!allMatches)}
        />
      )}

      <Text style={section}>Jogadores{loaded ? ` (${members.length})` : ''}</Text>
      {isAdmin && <Button title="Convidar jogadores" kind="secondary" onPress={convidar} loading={busy} />}
      {members.map((m) => (
        <Card key={m.id}>
          <Pressable
            accessibilityRole="button"
            onPress={() => router.push({ pathname: '/jogador/[id]', params: { id: m.id } })}
            style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
            <Avatar path={m.user_id ? photos[m.user_id] : null} name={m.player_name} size={40} />
            <View style={{ flex: 1 }}>
              <Body>
                {m.player_name}
                {m.user_id === session?.user.id ? ' (você)' : ''}
              </Body>
              <Sub>
                {roleName(m.role)} · {positionLabel(m.preferred_position)}
                {m.id === successor ? ' · sucessor indicado' : ''}
              </Sub>
            </View>
            <Text style={{ color: colors.muted, fontSize: 18 }}>›</Text>
          </Pressable>
          {isAdmin && m.role !== 'admin' && m.user_id && (
            managing === m.id ? (
              <View style={{ gap: 8, marginTop: 6 }}>
                <Button
                  kind="secondary"
                  title={m.role === 'assistant' ? 'Remover assistente' : 'Tornar assistente'}
                  onPress={() => rpc('set_assistant', { p_pelada: id, p_membership: m.id, p_is_assistant: m.role !== 'assistant' })}
                />
                <Button
                  kind="secondary"
                  title={m.id === successor ? 'Remover sucessor' : 'Indicar como sucessor'}
                  onPress={() => rpc('set_successor', { p_pelada: id, p_membership: m.id === successor ? null : m.id })}
                />
                <Pressable onPress={() => setManaging(null)} accessibilityRole="button">
                  <Text style={{ color: colors.muted, textAlign: 'center', paddingVertical: 4 }}>Fechar</Text>
                </Pressable>
              </View>
            ) : (
              <Pressable onPress={() => setManaging(m.id)} accessibilityRole="button">
                <Text style={{ color: colors.blue, fontWeight: '600', marginTop: 4 }}>Gerenciar</Text>
              </Pressable>
            )
          )}
        </Card>
      ))}

      <Text style={section}>Pelada</Text>
      {isAdmin && <Button title="Configurações da pelada" kind="secondary" onPress={() => go('/pelada/[id]/configuracoes')} />}
      <Button title="Premium da pelada" kind="secondary" onPress={() => go('/pelada/[id]/premium')} />
      <Button title="Sair da pelada" kind="danger" onPress={sair} />
      {me && <ReportLink peladaId={id} targetType="pelada" targetId={id} label="Denunciar nome ou imagem da pelada" />}
    </Screen>
  );
}

const section = { fontSize: 13, fontWeight: '800' as const, color: colors.deepBlue, letterSpacing: 0.5, marginTop: 10 };
