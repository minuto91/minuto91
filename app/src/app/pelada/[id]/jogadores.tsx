import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, View } from 'react-native';
import { Text } from '../../../lib/text';

import { Avatar, prefetchAvatars } from '../../../lib/avatar';
import { BillingPrompt } from '../../../lib/billing';
import { friendly } from '../../../lib/errors';

import { disambiguators, matchesName, showSearch } from '../../../lib/search';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, memberPosition, positionLabel } from '../../../lib/theme';
import { Body, Button, Card, ErrorText, Input, LoadingBlock, Screen, Sub, Title } from '../../../lib/ui';

type Member = {
  id: string;
  user_id: string | null;
  player_name: string;
  role: string;
  preferred_position: string;
  position_code?: string | null;
  billing_class?: string | null;
};

const roleName = (r: string) => (r === 'admin' ? 'Administrador' : r === 'assistant' ? 'Assistente' : 'Jogador');

// Lista de jogadores ativos (com ou sem Card) e, para o admin, a gestão de assistente e sucessor.
// Antes ficava no fim da página da pelada; as RPCs e as regras são as mesmas (005).
export default function Jogadores() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const router = useRouter();
  const [members, setMembers] = useState<Member[] | null>(null);
  const [successor, setSuccessor] = useState<string | null>(null);
  const [photos, setPhotos] = useState<Record<string, string | null>>({});
  const [managing, setManaging] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [reload, setReload] = useState(0);
  const [q, setQ] = useState('');
  const [defaultCents, setDefaultCents] = useState<number | null>(null);

  useEffect(() => {
    supabase
      .from('pelada_settings')
      .select('default_monthly_cents')
      .eq('pelada_id', id)
      .maybeSingle()
      .then(({ data }) => setDefaultCents((data?.default_monthly_cents as number | null) ?? null));
  }, [id]);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [{ data: p }, { data: ms, error }] = await Promise.all([
        supabase.from('peladas').select('successor_membership_id').eq('id', id).maybeSingle(),
        supabase
          .from('pelada_memberships')
          .select('id, user_id, player_name, role, preferred_position, position_code, billing_class')
          .eq('pelada_id', id)
          .eq('status', 'active')
          .order('joined_at', { ascending: true }),
      ]);
      if (error) {
        if (alive) setMsg(friendly(error.message));
        return;
      }
      // Fotos só de quem o RLS deixa ver (pelada em comum, sem bloqueio nos dois sentidos).
      const uids = (ms ?? []).map((m) => m.user_id).filter((u): u is string => !!u);
      const { data: pr } = uids.length ? await supabase.from('profiles').select('id, avatar_path').in('id', uids) : { data: [] };
      await prefetchAvatars((pr ?? []).map((p) => p.avatar_path as string | null)); // V4.4: fotos assinadas em lote
      if (!alive) return;
      setSuccessor(p?.successor_membership_id ?? null);
      setMembers((ms ?? []) as Member[]);
      setPhotos(Object.fromEntries((pr ?? []).map((x) => [x.id as string, x.avatar_path as string | null])));
    })();
    return () => {
      alive = false;
    };
  }, [id, reload]);

  const me = members?.find((m) => m.user_id === session?.user.id);
  const isAdmin = me?.role === 'admin';
  const tags = isAdmin
    ? disambiguators(
        (members ?? []).map((m) => ({ id: m.id, name: m.player_name, position: memberPosition(m), hasPhoto: !!(m.user_id && photos[m.user_id]) })),
      )
    : {};

  async function rpc(name: string, args: Record<string, unknown>) {
    setMsg(null);
    const { error } = await supabase.rpc(name, args);
    if (error) return setMsg(friendly(error.message));
    setManaging(null);
    setReload((n) => n + 1);
  }

  return (
    <Screen>
      <Title>Jogadores{members ? ` (${members.length})` : ''}</Title>
      <ErrorText>{msg}</ErrorText>
      {isAdmin && (
        <Button title="Convidar jogadores" kind="secondary" onPress={() => router.push({ pathname: '/pelada/[id]/convidar', params: { id } })} />
      )}
      {members === null && !msg && <LoadingBlock />}
      {showSearch(members?.length ?? 0) && <Input placeholder="Buscar jogador" value={q} onChangeText={setQ} />}
      {(members ?? []).filter((m) => matchesName(m.player_name, q)).map((m) => (
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
                {tags[m.id] ? <Text style={{ color: colors.muted, fontSize: 13 }}>{` ${tags[m.id]}`}</Text> : null}
              </Body>
              <Sub>
                {roleName(m.role)} · {positionLabel(memberPosition(m))}
                {m.id === successor ? ' · sucessor indicado' : ''}
              </Sub>
            </View>
            <Text style={{ color: colors.muted, fontSize: 18 }}>›</Text>
          </Pressable>
          {isAdmin && m.billing_class === 'pending' && (
            <BillingPrompt membershipId={m.id} name={m.player_name} defaultCents={defaultCents} onDone={() => setReload((n) => n + 1)} />
          )}
          {isAdmin &&
            m.role !== 'admin' &&
            m.user_id &&
            (managing === m.id ? (
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
            ))}
        </Card>
      ))}
    </Screen>
  );
}
