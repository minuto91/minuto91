import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Alert, Pressable, Share, Text, View } from 'react-native';
import * as Linking from 'expo-linking';

import { friendly } from '../../lib/errors';
import { fmtDate, Match, MATCH_COLUMNS, STATUS_LABEL } from '../../lib/match';
import { useAuth } from '../../lib/session';
import { supabase } from '../../lib/supabase';
import { colors, positionLabel } from '../../lib/theme';
import { Body, Button, Card, ErrorText, Screen, Sub, Title } from '../../lib/ui';

type Member = {
  id: string;
  user_id: string | null;
  player_name: string;
  role: string;
  preferred_position: string;
};

export default function Pelada() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const router = useRouter();
  const [nome, setNome] = useState('');
  const [status, setStatus] = useState('');
  const [successor, setSuccessor] = useState<string | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [matches, setMatches] = useState<Match[]>([]);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const { data: p } = await supabase
      .from('peladas')
      .select('name, status, successor_membership_id')
      .eq('id', id)
      .maybeSingle();
    if (p) {
      setNome(p.name);
      setStatus(p.status);
      setSuccessor(p.successor_membership_id);
    }
    const { data: ms, error } = await supabase
      .from('pelada_memberships')
      .select('id, user_id, player_name, role, preferred_position')
      .eq('pelada_id', id)
      .eq('status', 'active')
      .order('joined_at', { ascending: true });
    if (error) setMsg(error.message);
    else setMembers((ms ?? []) as Member[]);
    // Rascunhos só aparecem para admin e assistentes (regra do banco).
    const { data: xs } = await supabase
      .from('matches')
      .select(MATCH_COLUMNS)
      .eq('pelada_id', id)
      .order('played_at', { ascending: false })
      .limit(20);
    setMatches((xs ?? []) as Match[]);
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
    Alert.alert(
      'Sair da pelada?',
      isAdmin
        ? 'Você é o administrador. A administração passa automaticamente: primeiro o sucessor indicado, depois o assistente mais antigo, depois o jogador mais antigo.'
        : 'Seu histórico fica guardado e você pode voltar por um novo convite.',
      [
        { text: 'Cancelar', style: 'cancel' },
        {
          text: 'Sair',
          style: 'destructive',
          onPress: async () => {
            const r = await rpc('leave_pelada', { p_pelada: id });
            if (r) router.replace('/');
          },
        },
      ],
    );
  }

  const roleName = (r: string) => (r === 'admin' ? 'Administrador' : r === 'assistant' ? 'Assistente' : 'Jogador');

  return (
    <Screen>
      <Title>{nome || 'Pelada'}</Title>
      {status === 'restricted' && <Sub>Pelada restrita: sem administrador elegível.</Sub>}
      <ErrorText>{msg}</ErrorText>
      {isAdmin && <Button title="Convidar" onPress={convidar} loading={busy} />}
      <Text style={{ fontWeight: '700', color: colors.deepBlue, marginTop: 8 }}>Partidas</Text>
      {isStaff && <Button title="Lançar partida" kind="secondary" onPress={lancarPartida} loading={busy} />}
      {matches.length === 0 && <Sub>Nenhuma partida ainda.</Sub>}
      {matches.map((x) => (
        <Pressable key={x.id} onPress={() => router.push({ pathname: '/partida/[id]', params: { id: x.id } })}>
          <Card>
            <Body>
              {x.team_a_name} {x.team_a_score} x {x.team_b_score} {x.team_b_name}
            </Body>
            <Sub>
              {fmtDate(x.played_at)} · {STATUS_LABEL[x.status] ?? x.status}
            </Sub>
          </Card>
        </Pressable>
      ))}
      <Text style={{ fontWeight: '700', color: colors.deepBlue, marginTop: 8 }}>
        Jogadores ({members.length})
      </Text>
      {members.map((m) => (
        <Card key={m.id}>
          <Body>
            {m.player_name}
            {m.user_id === session?.user.id ? ' (você)' : ''}
          </Body>
          <Sub>
            {roleName(m.role)} · {positionLabel(m.preferred_position)}
            {m.id === successor ? ' · sucessor indicado' : ''}
          </Sub>
          {isAdmin && m.role !== 'admin' && m.user_id && (
            <View style={{ gap: 8, marginTop: 6 }}>
              <Button
                kind="secondary"
                title={m.role === 'assistant' ? 'Remover assistente' : 'Tornar assistente'}
                onPress={() =>
                  rpc('set_assistant', { p_pelada: id, p_membership: m.id, p_is_assistant: m.role !== 'assistant' })
                }
              />
              <Button
                kind="secondary"
                title={m.id === successor ? 'Remover sucessor' : 'Indicar como sucessor'}
                onPress={() =>
                  rpc('set_successor', { p_pelada: id, p_membership: m.id === successor ? null : m.id })
                }
              />
            </View>
          )}
        </Card>
      ))}
      <View style={{ height: 8 }} />
      <Button title="Sair da pelada" kind="danger" onPress={sair} />
    </Screen>
  );
}
