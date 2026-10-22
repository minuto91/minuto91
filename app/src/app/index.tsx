import AsyncStorage from '@react-native-async-storage/async-storage';
import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { Avatar } from '../lib/avatar';
import { fmtDate, fmtTime, STATUS_LABEL } from '../lib/match';
import { useAuth } from '../lib/session';
import { supabase } from '../lib/supabase';
import { colors } from '../lib/theme';
import { Body, Button, Card, ErrorText, Screen, Sub } from '../lib/ui';

type LastMatch = {
  id: string;
  played_at: string;
  status: string;
  team_a_name: string;
  team_b_name: string;
  team_a_score: number;
  team_b_score: number;
};
type Row = { id: string; name: string; role: string; last: LastMatch | null; drafts: number };
type Pending = { matchId: string; pelada: string; closesAt: string; match: LastMatch | null };
type Me = { display_name: string; avatar_path: string | null };

const ROLE = (r: string) => (r === 'admin' ? 'Administrador' : r === 'assistant' ? 'Assistente' : 'Jogador');

// Início: só dados reais (peladas, votações abertas em que falta o meu voto, última partida de cada pelada).
export default function Home() {
  const { session } = useAuth();
  const router = useRouter();
  const [me, setMe] = useState<Me | null>(null);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [pending, setPending] = useState<Pending[]>([]);
  const [err, setErr] = useState<string | null>(null);
  const [purgeAfter, setPurgeAfter] = useState<string | null>(null);

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        // Convite recebido antes do login: continua de onde parou.
        const invite = await AsyncStorage.getItem('pending_invite');
        if (invite) {
          await AsyncStorage.removeItem('pending_invite');
          router.push({ pathname: '/convite/[token]', params: { token: invite } });
          return;
        }
        if (!session) return;
        const uid = session.user.id;
        const [{ data: st }, { data: pr }, { data: ms, error }] = await Promise.all([
          supabase.rpc('get_account_status'),
          supabase.from('profiles').select('display_name, avatar_path').eq('id', uid).maybeSingle(),
          supabase.from('pelada_memberships').select('id, role, pelada_id').eq('user_id', uid).eq('status', 'active'),
        ]);
        if (!alive) return;
        setPurgeAfter((st as { purge_after: string | null } | null)?.purge_after ?? null);
        setMe(pr as Me | null);
        if (error) return setErr('Não foi possível carregar suas peladas. Verifique a internet e abra a tela de novo.');
        const mine = ms ?? [];
        const ids = mine.map((m) => m.pelada_id as string);
        if (!ids.length) {
          setPending([]);
          return setRows([]);
        }
        const myMemberships = mine.map((m) => m.id as string);
        const [{ data: ps }, { data: xs }, { data: vs }, { data: el }, { data: rc }] = await Promise.all([
          supabase.from('peladas').select('id, name').in('id', ids),
          supabase
            .from('matches')
            .select('id, pelada_id, played_at, status, team_a_name, team_b_name, team_a_score, team_b_score')
            .in('pelada_id', ids)
            .order('played_at', { ascending: false })
            .limit(100),
          supabase.from('voting_sessions').select('id, match_id, pelada_id, closes_at').in('pelada_id', ids).eq('status', 'open'),
          supabase.from('voting_eligible_members').select('session_id').in('membership_id', myMemberships),
          supabase.from('vote_receipts').select('session_id').in('membership_id', myMemberships),
        ]);
        if (!alive) return;
        const matches = (xs ?? []) as (LastMatch & { pelada_id: string })[];
        const nameOf = (pid: string) => ps?.find((p) => p.id === pid)?.name ?? 'Pelada';
        setErr(null);
        setRows(
          ids
            .map((pid) => ({
              id: pid,
              name: nameOf(pid),
              role: mine.find((m) => m.pelada_id === pid)?.role ?? 'player',
              last: matches.find((x) => x.pelada_id === pid && x.status !== 'draft') ?? null,
              drafts: matches.filter((x) => x.pelada_id === pid && x.status === 'draft').length,
            }))
            .sort((a, b) => (b.last?.played_at ?? '').localeCompare(a.last?.played_at ?? '') || a.name.localeCompare(b.name)),
        );
        const eligible = new Set((el ?? []).map((e) => e.session_id as string));
        const voted = new Set((rc ?? []).map((r) => r.session_id as string));
        setPending(
          (vs ?? [])
            .filter((v) => eligible.has(v.id) && !voted.has(v.id))
            .map((v) => ({
              matchId: v.match_id,
              pelada: nameOf(v.pelada_id),
              closesAt: v.closes_at,
              match: matches.find((x) => x.id === v.match_id) ?? null,
            })),
        );
      })();
      return () => {
        alive = false;
      };
    }, [session, router]),
  );

  const openMatch = (id: string) => router.push({ pathname: '/partida/[id]', params: { id } });

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
      {purgeAfter && (
        <Pressable onPress={() => router.push('/conta')}>
          <Card>
            <Body>Sua conta será apagada em {new Date(purgeAfter).toLocaleDateString('pt-BR')}.</Body>
            <Sub>Toque aqui para recuperar a conta e o seu histórico.</Sub>
          </Card>
        </Pressable>
      )}

      {pending.length > 0 && (
        <>
          <Text style={section}>Falta o seu voto</Text>
          {pending.map((p) => (
            <Pressable key={p.matchId} onPress={() => openMatch(p.matchId)} accessibilityRole="button">
              <View style={{ ...cardBox, borderColor: colors.blue, borderWidth: 1.5 }}>
                <Body>
                  {p.match
                    ? `${p.match.team_a_name} ${p.match.team_a_score} x ${p.match.team_b_score} ${p.match.team_b_name}`
                    : 'Partida'}
                </Body>
                <Sub>
                  {p.pelada} · votação até {fmtDate(p.closesAt)}, {fmtTime(p.closesAt)}
                </Sub>
                <Text style={{ color: colors.blue, fontWeight: '700' }}>Votar ›</Text>
              </View>
            </Pressable>
          ))}
        </>
      )}

      <Text style={section}>Minhas peladas</Text>
      {rows === null ? (
        <Sub>Carregando...</Sub>
      ) : rows.length === 0 ? (
        <Card>
          <Body>Você ainda não está em nenhuma pelada.</Body>
          <Sub>Crie a pelada da sua turma ou entre com o convite que recebeu.</Sub>
          <Button title="Criar pelada" onPress={() => router.push('/criar-pelada')} />
          <Button title="Entrar com convite" kind="secondary" onPress={() => router.push('/entrar')} />
        </Card>
      ) : (
        rows.map((r) => (
          <Pressable
            key={r.id}
            accessibilityRole="button"
            onPress={() => router.push({ pathname: '/pelada/[id]', params: { id: r.id } })}>
            <Card>
              <Text style={{ fontSize: 18, fontWeight: '700', color: colors.deepBlue }}>{r.name}</Text>
              <Sub>{ROLE(r.role)}</Sub>
              {r.last ? (
                <Pressable onPress={() => openMatch(r.last!.id)} accessibilityRole="button">
                  <Text style={{ color: colors.ink, marginTop: 4 }}>
                    Última: {r.last.team_a_name} {r.last.team_a_score} x {r.last.team_b_score} {r.last.team_b_name}
                  </Text>
                  <Sub>
                    {fmtDate(r.last.played_at)} · {STATUS_LABEL[r.last.status] ?? r.last.status}
                  </Sub>
                </Pressable>
              ) : (
                <Sub>Nenhuma partida ainda.</Sub>
              )}
              {r.drafts > 0 && <Sub>{r.drafts === 1 ? '1 súmula em rascunho' : `${r.drafts} súmulas em rascunho`}</Sub>}
            </Card>
          </Pressable>
        ))
      )}

      {rows !== null && rows.length > 0 && (
        <View style={{ flexDirection: 'row', gap: 8, marginTop: 4 }}>
          <View style={{ flex: 1 }}>
            <Button title="Criar pelada" kind="secondary" onPress={() => router.push('/criar-pelada')} />
          </View>
          <View style={{ flex: 1 }}>
            <Button title="Entrar com convite" kind="secondary" onPress={() => router.push('/entrar')} />
          </View>
        </View>
      )}
    </Screen>
  );
}

const section = { fontSize: 13, fontWeight: '800' as const, color: colors.deepBlue, letterSpacing: 0.5, marginTop: 6 };
const cardBox = { backgroundColor: colors.white, borderRadius: 12, padding: 14, gap: 6 };
