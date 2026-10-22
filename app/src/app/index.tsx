import AsyncStorage from '@react-native-async-storage/async-storage';
import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { AppState, Pressable, Text, View } from 'react-native';

import { Avatar } from '../lib/avatar';
import { fmtDate, fmtTime, STATUS_LABEL } from '../lib/match';
import { PushPrompt } from '../lib/push';
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
type HomeData = {
  peladas: { id: string; name: string; role: string; last: LastMatch | null; drafts: number }[];
  pending: { match_id: string; pelada_name: string; closes_at: string; team_a_name: string; team_b_name: string; team_a_score: number; team_b_score: number }[];
};

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
  const [reload, setReload] = useState(0); // incrementar = buscar de novo

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
        void reload; // recarregar (AppState, prazo, Tentar de novo)
        const uid = session.user.id;
        // A12: o servidor devolve a última partida e os rascunhos de CADA pelada (sem limite global) e as
        // votações em que falta o meu voto, já sem as vencidas (A13).
        const [{ data: st }, { data: pr }, { data: home, error }] = await Promise.all([
          supabase.rpc('get_account_status'),
          supabase.from('profiles').select('display_name, avatar_path').eq('id', uid).maybeSingle(),
          supabase.rpc('get_my_home'),
        ]);
        if (!alive) return;
        setPurgeAfter((st as { purge_after: string | null } | null)?.purge_after ?? null);
        setMe(pr as Me | null);
        // A21: falha de rede não vira "nenhuma pelada".
        if (error || !home) return setErr('Não foi possível carregar suas peladas. Verifique a internet e tente de novo.');
        const h = home as HomeData;
        setErr(null);
        setRows(
          h.peladas
            .map((p) => ({ id: p.id, name: p.name, role: p.role, last: p.last, drafts: p.drafts }))
            .sort((a, b) => (b.last?.played_at ?? '').localeCompare(a.last?.played_at ?? '') || a.name.localeCompare(b.name)),
        );
        setPending(
          h.pending.map((v) => ({
            matchId: v.match_id,
            pelada: v.pelada_name,
            closesAt: v.closes_at,
            match: { id: v.match_id, played_at: '', status: 'voting_open', team_a_name: v.team_a_name, team_b_name: v.team_b_name,
              team_a_score: v.team_a_score, team_b_score: v.team_b_score },
          })),
        );
      })();
      return () => {
        alive = false;
      };
    }, [session, router, reload]),
  );

  // A13: pendências se atualizam ao voltar para o app e quando o prazo da próxima votação vence.
  useEffect(() => {
    const sub = AppState.addEventListener('change', (s) => s === 'active' && setReload((n) => n + 1));
    return () => sub.remove();
  }, []);
  useEffect(() => {
    const next = pending.map((p) => new Date(p.closesAt).getTime()).filter((t) => t > Date.now()).sort((a, b) => a - b)[0];
    if (!next) return;
    const timer = setTimeout(() => setReload((n) => n + 1), Math.min(next - Date.now() + 1000, 2 ** 31 - 1));
    return () => clearTimeout(timer);
  }, [pending]);

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
      {err && <Button title="Tentar de novo" kind="secondary" onPress={() => setReload((n) => n + 1)} />}
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

      {rows !== null && rows.length > 0 && <PushPrompt />}

      <Text style={section}>Minhas peladas</Text>
      {rows === null ? (
        !err && <Sub>Carregando...</Sub>
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
                <View>
                  <Text style={{ color: colors.ink, marginTop: 4 }}>
                    Última: {r.last.team_a_name} {r.last.team_a_score} x {r.last.team_b_score} {r.last.team_b_name}
                  </Text>
                  <Sub>
                    {fmtDate(r.last.played_at)} · {STATUS_LABEL[r.last.status] ?? r.last.status}
                  </Sub>
                </View>
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
