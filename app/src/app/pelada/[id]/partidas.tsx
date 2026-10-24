import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, View } from 'react-native';
import { Text } from '../../../lib/text';

import { friendly } from '../../../lib/errors';
import { fmtDate, Match, MATCH_COLUMNS, STATUS_LABEL } from '../../../lib/match';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors } from '../../../lib/theme';
import { Button, EmptyState, ErrorText, ListGroup, Loading, MatchStatusBadge, Scoreboard, Screen, Title } from '../../../lib/ui';

const PAGE = 30;

// Todas as partidas da pelada, da mais recente para a mais antiga, em páginas de 30.
// Rascunhos só chegam para admin e assistentes (RLS); anuladas continuam listadas como anuladas.
export default function Partidas() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const router = useRouter();
  const [matches, setMatches] = useState<Match[] | null>(null);
  const [limit, setLimit] = useState(PAGE);
  const [more, setMore] = useState(false);
  const [isStaff, setIsStaff] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        const [{ data: xs, error }, { data: me }] = await Promise.all([
          supabase
            .from('matches')
            .select(MATCH_COLUMNS)
            .eq('pelada_id', id)
            .order('played_at', { ascending: false })
            .range(0, limit), // um a mais para saber se há outra página
          supabase
            .from('pelada_memberships')
            .select('role')
            .eq('pelada_id', id)
            .eq('user_id', session?.user.id ?? '')
            .eq('status', 'active')
            .maybeSingle(),
        ]);
        if (!alive) return;
        if (error) return setMsg(friendly(error.message));
        setMore((xs ?? []).length > limit);
        setMatches(((xs ?? []) as Match[]).slice(0, limit));
        setIsStaff(me?.role === 'admin' || me?.role === 'assistant');
      })();
      return () => {
        alive = false;
      };
    }, [id, limit, session]),
  );

  async function lancarPartida() {
    setBusy(true);
    setMsg(null);
    const { data, error } = await supabase.rpc('create_match', { p_pelada: id, p_played_at: new Date().toISOString() });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    router.push({ pathname: '/partida/[id]/sumula', params: { id: String(data) } });
  }

  return (
    <Screen>
      <Title>Partidas</Title>
      <ErrorText>{msg}</ErrorText>
      {isStaff && <Button title="Lançar partida" onPress={lancarPartida} loading={busy} />}
      {matches === null ? (
        !msg && <Loading label="Carregando partidas..." />
      ) : matches.length === 0 ? (
        <EmptyState
          title="Nenhuma partida ainda"
          hint={isStaff ? 'Lance a primeira depois do jogo: times, placar, gols e assistências.' : 'Quando a súmula for lançada, a partida aparece aqui.'}
        />
      ) : (
        <ListGroup>
          {matches.map((x, n) => (
            <Pressable
              key={x.id}
              accessibilityRole="button"
              accessibilityLabel={`${x.team_a_name} ${x.team_a_score} x ${x.team_b_score} ${x.team_b_name}, ${fmtDate(x.played_at)}, ${STATUS_LABEL[x.status] ?? x.status}`}
              onPress={() => router.push({ pathname: '/partida/[id]', params: { id: x.id } })}
              style={({ pressed }) => ({
                paddingHorizontal: 14,
                paddingVertical: 12,
                gap: 6,
                borderTopWidth: n ? 1 : 0,
                borderTopColor: colors.divider,
                backgroundColor: pressed ? colors.bg : colors.white,
              })}>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                <Text style={{ flex: 1, fontSize: 13, color: colors.muted }}>{fmtDate(x.played_at)}</Text>
                <MatchStatusBadge status={x.status} />
              </View>
              <Scoreboard teamA={x.team_a_name} teamB={x.team_b_name} scoreA={x.team_a_score} scoreB={x.team_b_score} />
            </Pressable>
          ))}
        </ListGroup>
      )}
      {more && <Button title="Carregar mais" kind="secondary" onPress={() => setLimit(limit + PAGE)} />}
    </Screen>
  );
}
