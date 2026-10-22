import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { SharePanel } from '../../../lib/arts';
import { Avatar } from '../../../lib/avatar';
import { loadReadableSeasons, Season } from '../../../lib/career';
import { Duel, DuelArt, DuelView } from '../../../lib/duel';
import { friendly } from '../../../lib/errors';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, memberPosition, positionLabel } from '../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Screen, Sub, Title } from '../../../lib/ui';

type Member = { id: string; user_id: string | null; player_name: string; preferred_position: string; position_code?: string | null; avatar_path: string | null };

// Duelo de Jogadores (Pelada Premium): escolher dois jogadores da pelada e comparar na temporada.
// O servidor confere tudo (membro, Pelada Premium, mesma pelada, temporada liberada, jogadores diferentes).
export default function Duelo() {
  const { id, a } = useLocalSearchParams<{ id: string; a?: string }>();
  const { session } = useAuth();
  const router = useRouter();
  const [premium, setPremium] = useState<boolean | null>(null);
  const [pelada, setPelada] = useState<{ name: string; crest_path: string | null } | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [seasons, setSeasons] = useState<Season[]>([]);
  const [seasonId, setSeasonId] = useState<string | null>(null);
  const [pick, setPick] = useState<{ a: string | null; b: string | null }>({ a: a ?? null, b: null });
  const [duel, setDuel] = useState<{ key: string; data: Duel } | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const [{ data: ent, error }, ss, { data: p }, { data: ms, error: e2 }] = await Promise.all([
          supabase.rpc('get_pelada_entitlement', { p_pelada: id }),
          loadReadableSeasons(id),
          supabase.from('peladas').select('name, crest_path').eq('id', id).maybeSingle(),
          supabase.from('pelada_memberships').select('id, user_id, player_name, preferred_position, position_code').eq('pelada_id', id).eq('status', 'active').order('player_name'),
        ]);
        if (error || e2) throw error ?? e2;
        const ids = (ms ?? []).map((m) => m.user_id).filter(Boolean) as string[];
        const { data: pr } = ids.length ? await supabase.from('profiles').select('id, avatar_path').in('id', ids) : { data: [] };
        if (!alive) return;
        const photo = new Map((pr ?? []).map((x) => [x.id as string, x.avatar_path as string | null]));
        setPremium(!!(ent as { is_premium: boolean }).is_premium);
        setSeasons(ss);
        setSeasonId(ss[0]?.id ?? null);
        setPelada(p);
        setMembers((ms ?? []).map((m) => ({ ...(m as Omit<Member, 'avatar_path'>), avatar_path: m.user_id ? (photo.get(m.user_id) ?? null) : null })));
        // Sem escolha: começa por mim.
        const mine = (ms ?? []).find((m) => m.user_id === session?.user.id);
        if (!a && mine) setPick((x) => ({ ...x, a: mine.id as string }));
      } catch (e) {
        if (alive) setMsg(friendly((e as Error).message));
      }
    })();
    return () => {
      alive = false;
    };
  }, [id, a, session]);

  const key = `${seasonId}:${pick.a}:${pick.b}`;
  useEffect(() => {
    if (!premium || !seasonId || !pick.a || !pick.b) return;
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc('get_player_duel', { p_season: seasonId, p_a: pick.a, p_b: pick.b });
      if (!alive) return;
      if (error) return setMsg(friendly(error.message));
      setMsg(null);
      setDuel({ key: `${seasonId}:${pick.a}:${pick.b}`, data: data as Duel });
    })();
    return () => {
      alive = false;
    };
  }, [premium, seasonId, pick.a, pick.b]);

  const choose = (mid: string) =>
    setPick((x) => (x.a === mid ? { a: x.b, b: null } : x.b === mid ? { ...x, b: null } : !x.a ? { ...x, a: mid } : { ...x, b: mid }));
  const current = duel?.key === key ? duel.data : null;

  if (premium === null) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }

  if (!premium) {
    return (
      <Screen>
        <Title>Duelo de Jogadores</Title>
        <Card>
          <Body>Compare dois jogadores lado a lado: Card, atributos, gols, assistências, nota média e Craques.</Body>
          <Sub>Recurso da Pelada Premium. O administrador assina uma vez e vale para todos da pelada.</Sub>
          <Button title="Conhecer a Pelada Premium" onPress={() => router.push({ pathname: '/pelada/[id]/premium', params: { id } })} />
        </Card>
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>Duelo de Jogadores</Title>
      {seasons.length > 1 && <Chips options={seasons.map((s) => ({ value: s.id, label: s.name }))} value={seasonId} onChange={setSeasonId} />}
      <ErrorText>{msg}</ErrorText>

      {current ? (
        <>
          <Card>
            <DuelView duel={current} />
          </Card>
          <SharePanel label="Compartilhar o Duelo" fileName="minuto91-duelo" title="Duelo de Jogadores">
            <DuelArt duel={current} peladaName={pelada?.name ?? ''} crestPath={pelada?.crest_path} />
          </SharePanel>
        </>
      ) : (
        <Sub>{pick.a && pick.b ? 'Carregando o Duelo...' : 'Escolha dois jogadores.'}</Sub>
      )}

      <Text style={section}>Jogadores</Text>
      <Sub>Toque para escolher ou trocar. Azul = primeiro jogador; dourado = segundo.</Sub>
      {members.map((m) => {
        const side = pick.a === m.id ? 'a' : pick.b === m.id ? 'b' : null;
        return (
          <Pressable
            key={m.id}
            accessibilityRole="button"
            accessibilityState={{ selected: !!side }}
            accessibilityLabel={`${m.player_name}${side ? ', escolhido' : ''}`}
            onPress={() => choose(m.id)}
            style={{
              flexDirection: 'row',
              alignItems: 'center',
              gap: 10,
              minHeight: 48,
              paddingHorizontal: 10,
              borderRadius: 10,
              borderWidth: side ? 2 : 1,
              borderColor: side === 'a' ? colors.blue : side === 'b' ? colors.gold : colors.line,
            }}>
            <Avatar path={m.avatar_path} name={m.player_name} size={32} />
            <View style={{ flex: 1 }}>
              <Text style={{ color: colors.ink, fontWeight: '600' }}>{m.player_name}</Text>
              <Text style={{ color: colors.muted, fontSize: 12 }}>{positionLabel(memberPosition(m))}</Text>
            </View>
          </Pressable>
        );
      })}
    </Screen>
  );
}

const section = { fontSize: 13, fontWeight: '800' as const, color: colors.deepBlue, letterSpacing: 0.5, marginTop: 10 };
