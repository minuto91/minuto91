// V8.5 — Lista inteligente de partidas (Etapas 8, 22, 23), dentro da pelada (sem Central do Administrador).
// Cronológica (mais recente primeiro), com status, pendência e próxima ação para quem administra; busca por
// rodada/data e filtros discretos; carregamento progressivo por cursor; canceladas continuam acessíveis.
// Rascunho manual só aparece para a administração; rodada pré-cadastrada aparece para todos, sem placar.
import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useRef, useState } from 'react';
import { Pressable, View } from 'react-native';

import { AnnulledBadge } from '../../../lib/annul';
import { friendly } from '../../../lib/errors';
import { fmtDate } from '../../../lib/match';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { Text } from '../../../lib/text';
import { colors } from '../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Input, LoadingBlock, Screen, Sub, Title } from '../../../lib/ui';
import { createGate, MATCH_PENDING, MATCH_STATUS, NEXT_ACTION } from '../../../lib/v85';

type Item = {
  id: string;
  played_at: string;
  status: string;
  team_a_name: string;
  team_b_name: string;
  team_a_score: number | null;
  team_b_score: number | null;
  rescheduled: boolean;
  round_label: string | null;
  pending: string | null;
  next_action: string | null;
};
const FILTERS = [
  { value: 'all', label: 'Todas' },
  { value: 'open', label: 'Pendentes' },
  { value: 'done', label: 'Publicadas' },
  { value: 'cancelled', label: 'Canceladas' },
] as const;
type Filter = (typeof FILTERS)[number]['value'];
const STATUS_FOR: Record<Filter, string[] | null> = {
  all: null,
  open: ['draft', 'voting_open', 'finalizing'],
  done: ['finalized', 'annulled'],
  cancelled: ['cancelled'],
};

export default function Partidas() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const router = useRouter();
  const gate = useRef(createGate()).current;
  const [items, setItems] = useState<Item[] | null>(null);
  const [cursor, setCursor] = useState<string | null>(null);
  const [filter, setFilter] = useState<Filter>('all');
  const [q, setQ] = useState('');
  const [isStaff, setIsStaff] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  const fetchPage = useCallback(
    async (after: string | null, f: Filter, text: string) => {
      const ok = gate.next('list'); // troca de filtro durante o carregamento: só a última resposta vale
      const { data, error } = await supabase.rpc('get_pelada_matches_v85', {
        p_pelada: id,
        p_filters: { ...(STATUS_FOR[f] ? { status: STATUS_FOR[f] } : {}), ...(text.trim() ? { q: text.trim() } : {}) },
        p_cursor: after,
        p_limit: 30,
      });
      if (!ok()) return;
      if (error) return setMsg(friendly(error.message));
      setMsg(null);
      const r = data as { items: Item[]; next_cursor: string | null };
      setItems((prev) => (after ? [...(prev ?? []), ...r.items] : r.items));
      setCursor(r.next_cursor);
    },
    [id, gate],
  );

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        const { data: me } = await supabase
          .from('pelada_memberships')
          .select('role')
          .eq('pelada_id', id)
          .eq('user_id', session?.user.id ?? '')
          .eq('status', 'active')
          .maybeSingle();
        if (!alive) return;
        setIsStaff(me?.role === 'admin' || me?.role === 'assistant');
        await fetchPage(null, filter, q);
      })();
      return () => {
        alive = false;
      };
      // q entra só ao buscar (não a cada letra)
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [id, session, filter, fetchPage]),
  );

  // Etapa 16: partida manual; a data sugerida é agora (o admin ajusta na súmula). Não inicia estatística nem votação.
  async function lancarPartida() {
    setBusy('new');
    setMsg(null);
    const { data, error } = await supabase.rpc('create_match', { p_pelada: id, p_played_at: new Date().toISOString() });
    setBusy(null);
    if (error) return setMsg(friendly(error.message));
    router.push({ pathname: '/partida/[id]/sumula', params: { id: String(data) } });
  }

  const open = (x: Item) => {
    if (isStaff && x.status === 'draft' && (x.next_action === 'CONFIRM_PARTICIPATION' || x.next_action === 'RESUME_SHEET'))
      return router.push({ pathname: '/partida/[id]/sumula', params: { id: x.id } });
    router.push({ pathname: '/partida/[id]', params: { id: x.id } });
  };

  return (
    <Screen>
      <Title>Partidas</Title>
      <ErrorText>{msg}</ErrorText>
      {isStaff && <Button title="Lançar partida" onPress={lancarPartida} loading={busy === 'new'} />}
      <Chips options={FILTERS} value={filter} onChange={setFilter} />
      <Input placeholder="Buscar por data (dd/mm) ou rodada" value={q} onChangeText={setQ} onSubmitEditing={() => fetchPage(null, filter, q)} returnKeyType="search" />
      {items === null ? (
        !msg && <LoadingBlock />
      ) : items.length === 0 ? (
        <Sub>{q || filter !== 'all' ? 'Nenhuma partida com esse filtro.' : isStaff ? 'Nenhuma partida ainda. Lance a primeira depois do jogo.' : 'Nenhuma partida ainda.'}</Sub>
      ) : (
        items.map((x) => (
          <Pressable key={x.id} accessibilityRole="button" onPress={() => open(x)}>
            <Card>
              <Body>
                {x.team_a_score != null && x.status !== 'annulled' && x.status !== 'cancelled'
                  ? `${x.team_a_name} ${x.team_a_score} x ${x.team_b_score} ${x.team_b_name}`
                  : `${x.team_a_name} x ${x.team_b_name}`}
              </Body>
              {x.status === 'annulled' && <AnnulledBadge />}
              <Text style={{ color: x.status === 'voting_open' ? colors.blue : x.status === 'cancelled' ? colors.danger : colors.muted, fontWeight: x.status === 'voting_open' ? '700' : '400' }}>
                {[fmtDate(x.played_at), x.round_label, MATCH_STATUS[x.status] ?? x.status, x.rescheduled ? 'remarcada' : null].filter(Boolean).join(' · ')}
              </Text>
              {x.pending && (
                <View style={{ flexDirection: 'row', justifyContent: 'space-between', marginTop: 4 }}>
                  <Text style={{ color: colors.darkGold, fontSize: 13, fontWeight: '600' }}>{MATCH_PENDING[x.pending] ?? x.pending}</Text>
                  {x.next_action && x.next_action !== 'VIEW' && <Text style={{ color: colors.blue, fontSize: 13, fontWeight: '700' }}>{NEXT_ACTION[x.next_action]} ›</Text>}
                </View>
              )}
            </Card>
          </Pressable>
        ))
      )}
      {cursor && <Button title="Carregar mais" kind="secondary" onPress={() => fetchPage(cursor, filter, q)} />}
    </Screen>
  );
}
