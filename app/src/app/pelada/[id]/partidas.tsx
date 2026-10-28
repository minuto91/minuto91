import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable } from 'react-native';
import { Text } from '../../../lib/text';

import { friendly } from '../../../lib/errors';
import { AnnulledBadge } from '../../../lib/annul';
import { fmtDate, Match, MATCH_COLUMNS, scoreLine, STATUS_LABEL } from '../../../lib/match';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors } from '../../../lib/theme';
import { Body, Button, Card, ErrorText, LoadingBlock, Screen, Sub, Title } from '../../../lib/ui';

const PAGE = 30;

// Todas as partidas da pelada, da mais recente para a mais antiga, em páginas de 30.
// Rascunhos só chegam para admin e assistentes (RLS); anuladas continuam na lista, com selo e sem placar.
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
        !msg && <LoadingBlock />
      ) : matches.length === 0 ? (
        <Sub>{isStaff ? 'Nenhuma partida ainda. Lance a primeira depois do jogo.' : 'Nenhuma partida ainda.'}</Sub>
      ) : (
        matches.map((x) => (
          <Pressable key={x.id} accessibilityRole="button" onPress={() => router.push({ pathname: '/partida/[id]', params: { id: x.id } })}>
            <Card>
              {/* V7.7: anulada fica na ordem cronológica, com selo e sem placar. */}
              <Body>{scoreLine(x)}</Body>
              {x.status === 'annulled' && <AnnulledBadge />}
              <Text
                style={{
                  color: x.status === 'voting_open' ? colors.blue : colors.muted,
                  fontWeight: x.status === 'voting_open' ? '700' : '400',
                }}>
                {fmtDate(x.played_at)} · {STATUS_LABEL[x.status] ?? x.status}
              </Text>
            </Card>
          </Pressable>
        ))
      )}
      {more && <Button title="Carregar mais" kind="secondary" onPress={() => setLimit(limit + PAGE)} />}
    </Screen>
  );
}
