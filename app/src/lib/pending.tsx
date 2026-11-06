// Pendências da pelada para quem administra (admin e assistentes), dentro da tela da pelada.
// Só lê o que já existe: rascunhos, votações abertas (com quantos votaram e o prazo) e dois avisos de
// organização (poucos jogadores com conta; admin sem sucessor). Cada item leva à tela que resolve.
// Sem pendência, o cartão não aparece. O início do app não muda.
import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, View } from 'react-native';
import { Text } from './text';

import { fmtDate, fmtTime, Match, scoreLine } from './match';
import { supabase } from './supabase';
import { colors } from './theme';
import { LinkLabel } from './ui';

type Voting = { id: string; match_id: string; closes_at: string; eligible_voter_count: number; voted: number; expired: boolean };
type Item = { key: string; title: string; detail: string; action: string; urgent?: boolean; onPress?: () => void };

const MIN_VOTERS = 7; // V10.0 (REV-136): cada jogador avaliado precisa receber pelo menos 7 votos (antes: 3)

export function AdminPending({
  peladaId,
  matches,
  members,
  successor,
  isAdmin,
  onInvite,
}: {
  peladaId: string;
  matches: Match[];
  members: { user_id: string | null }[];
  successor: string | null;
  isAdmin: boolean;
  onInvite: () => void;
}) {
  const router = useRouter();
  const [votings, setVotings] = useState<Voting[]>([]);
  const openIds = matches
    .filter((m) => m.status === 'voting_open')
    .map((m) => m.id)
    .join(',');

  useEffect(() => {
    let alive = true;
    (async () => {
      const ids = openIds ? openIds.split(',') : [];
      if (!ids.length) {
        if (alive) setVotings([]);
        return;
      }
      const { data: ss } = await supabase
        .from('voting_sessions')
        .select('id, match_id, closes_at, eligible_voter_count')
        .in('match_id', ids)
        .eq('status', 'open');
      const sessions = ss ?? [];
      // Só quem já votou (sem notas nem horários), uma consulta para todas as votações.
      const { data: rc } = sessions.length
        ? await supabase.from('vote_receipts').select('session_id').in('session_id', sessions.map((s) => s.id))
        : { data: [] as { session_id: string }[] };
      if (!alive) return;
      const now = Date.now();
      setVotings(
        sessions.map((s) => ({
          ...(s as Omit<Voting, 'voted' | 'expired'>),
          voted: (rc ?? []).filter((r) => r.session_id === s.id).length,
          expired: new Date(s.closes_at).getTime() <= now, // a tela recarrega ao voltar para ela
        })),
      );
    })();
    return () => {
      alive = false;
    };
  }, [openIds]);

  const openMatch = (id: string) => router.push({ pathname: '/partida/[id]', params: { id } });
  const items: Item[] = [];

  for (const v of votings) {
    const m = matches.find((x) => x.id === v.match_id);
    if (!m) continue;
    const expired = v.expired;
    items.push({
      key: `v-${v.id}`,
      title: expired ? 'Prazo da votação acabou' : 'Votação aberta',
      detail: `${scoreLine(m)} · ${fmtDate(m.played_at)} · ${v.voted} de ${v.eligible_voter_count} votaram${
        expired ? '' : ` · fecha às ${fmtTime(v.closes_at)}`
      }`,
      action: expired ? 'Encerrar votação' : 'Ver quem falta votar',
      urgent: expired,
      onPress: () => openMatch(m.id),
    });
  }

  for (const m of matches.filter((x) => x.status === 'draft')) {
    items.push({
      key: `d-${m.id}`,
      title: 'Súmula em rascunho',
      detail: `${fmtDate(m.played_at)} · ainda não publicada, ninguém pode votar`,
      action: 'Terminar súmula',
      onPress: () => router.push({ pathname: '/partida/[id]/sumula', params: { id: m.id } }),
    });
  }

  const withAccount = members.filter((m) => m.user_id).length;
  if (withAccount < MIN_VOTERS + 1) {
    items.push({
      key: 'invite',
      title: 'Poucos jogadores no elenco',
      detail: `${withAccount} com conta no app. Cada jogador avaliado precisa de pelo menos ${MIN_VOTERS} votos para a nota valer.`,
      action: 'Convidar jogadores',
      onPress: onInvite,
    });
  }

  if (isAdmin && !successor && withAccount > 1) {
    items.push({
      key: 'successor',
      title: 'Sem sucessor indicado',
      detail: 'Se você sair, a administração passa para o assistente ou o jogador mais antigo.',
      action: 'Indicar em Jogadores > Gerenciar',
      onPress: () => router.push({ pathname: '/pelada/[id]/jogadores', params: { id: peladaId } }),
    });
  }

  if (!items.length) return null;
  return (
    <View
      accessibilityLabel={`Pendências: ${items.length}`}
      style={{ borderRadius: 12, borderWidth: 1.5, borderColor: colors.blue, backgroundColor: colors.white, padding: 14, gap: 10 }}>
      <Text style={{ fontSize: 12, fontWeight: '800', letterSpacing: 1, color: colors.blue }}>
        PENDÊNCIAS ({items.length})
      </Text>
      {items.map((it, i) => (
        <Pressable
          key={it.key}
          accessibilityRole={it.onPress ? 'button' : undefined}
          accessibilityHint={it.action}
          disabled={!it.onPress}
          onPress={it.onPress}
          style={{ gap: 2, paddingTop: i ? 10 : 0, borderTopWidth: i ? 1 : 0, borderTopColor: colors.line }}>
          <Text style={{ fontWeight: '700', color: it.urgent ? colors.danger : colors.ink }}>{it.title}</Text>
          <Text style={{ color: colors.muted, fontSize: 13 }}>{it.detail}</Text>
          {it.onPress ? (
            <LinkLabel style={{ color: colors.blue, fontWeight: '700', fontSize: 13 }}>{it.action}</LinkLabel>
          ) : (
            <Text style={{ color: colors.muted, fontWeight: '700', fontSize: 13 }}>{it.action}</Text>
          )}
        </Pressable>
      ))}
    </View>
  );
}
