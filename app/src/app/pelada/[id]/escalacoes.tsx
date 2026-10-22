import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { SharePanel } from '../../../lib/arts';
import { confirm } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { LineupArt, LineupBoard, LineupPlayer, POS_SHORT, positionCounts } from '../../../lib/lineup';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, positionLabel } from '../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Input, Screen, Sub, Title } from '../../../lib/ui';

type Lineup = {
  id: string;
  label: string;
  source: 'manual' | 'draw';
  team_a_name: string;
  team_b_name: string;
  rounds_total: number;
  rounds_used: number;
  needs_review: boolean;
  players: { membership_id: string; team: 'A' | 'B'; name: string; position: string; active: boolean; avatar_path: string | null }[];
};
type Member = { id: string; user_id: string | null; player_name: string; preferred_position: string; role: string };
type Side = 'A' | 'B' | '-';

const SIDES = [
  { value: 'A', label: 'A' },
  { value: 'B', label: 'B' },
  { value: '-', label: 'Fora' },
] as const;

// Escalação antes do jogo (Pelada Premium): montada à mão ou vinda de um sorteio confirmado. Todos da
// pelada veem; admin e assistentes montam, usam na súmula (vira só rascunho) e cancelam. Não registra
// partida, não pede confirmação de presença e não depende de calendário.
export default function Escalacoes() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const router = useRouter();
  const [lineups, setLineups] = useState<Lineup[] | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [premium, setPremium] = useState(false);
  const [pelada, setPelada] = useState<{ name: string; crest_path: string | null } | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [reload, setReload] = useState(0);
  // Editor da escalação manual.
  const [editing, setEditing] = useState(false);
  const [sides, setSides] = useState<Record<string, Side>>({});
  const [label, setLabel] = useState('');
  const [nameA, setNameA] = useState('');
  const [nameB, setNameB] = useState('');

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        void reload;
        const [{ data: ls, error }, { data: ent }, { data: ms }, { data: p }] = await Promise.all([
          supabase.rpc('get_lineups', { p_pelada: id }),
          supabase.rpc('get_pelada_entitlement', { p_pelada: id }),
          supabase.from('pelada_memberships').select('id, user_id, player_name, preferred_position, role').eq('pelada_id', id).eq('status', 'active').order('player_name'),
          supabase.from('peladas').select('name, crest_path').eq('id', id).maybeSingle(),
        ]);
        if (!alive) return;
        if (error) return setMsg(friendly(error.message));
        setMsg(null);
        setLineups(ls as Lineup[]);
        setPremium(!!(ent as { is_premium?: boolean } | null)?.is_premium);
        setMembers((ms ?? []) as Member[]);
        setPelada(p);
      })();
      return () => {
        alive = false;
      };
    }, [id, reload]),
  );

  const me = members.find((m) => m.user_id === session?.user.id);
  const isStaff = me?.role === 'admin' || me?.role === 'assistant';
  const toBoard = (l: Lineup): LineupPlayer[] =>
    l.players.map((p) => ({ key: p.membership_id, team: p.team, name: p.name, position: p.position, avatar_path: p.avatar_path }));

  async function run(name: string, fn: string, args: Record<string, unknown>) {
    setBusy(name);
    setMsg(null);
    const { data, error } = await supabase.rpc(fn, args);
    setBusy(null);
    if (error) setMsg(friendly(error.message));
    return error ? null : (data ?? true);
  }

  async function usar(l: Lineup) {
    const match = await run(`usar-${l.id}`, 'use_lineup_in_match', { p_lineup: l.id, p_played_at: new Date().toISOString() });
    if (match) router.push({ pathname: '/partida/[id]/sumula', params: { id: String(match) } });
  }

  function cancelar(l: Lineup) {
    confirm('Cancelar escalação?', 'Ela some da lista. Partidas já lançadas não mudam.', 'Cancelar escalação', async () => {
      if (await run(`cancelar-${l.id}`, 'cancel_lineup', { p_lineup: l.id })) setReload((n) => n + 1);
    });
  }

  // Editor: equilíbrio por posição só como alerta (a montagem manual é livre, V4.2 11.12).
  const draft: LineupPlayer[] = members
    .filter((m) => sides[m.id] === 'A' || sides[m.id] === 'B')
    .map((m) => ({ key: m.id, team: sides[m.id] as 'A' | 'B', name: m.player_name, position: m.preferred_position }));
  const unbalanced = positionCounts(draft).filter((c) => Math.abs(c.a - c.b) > 1);
  const sizeA = draft.filter((p) => p.team === 'A').length;
  const sizeB = draft.length - sizeA;

  async function salvar() {
    const ok = await run('salvar', 'save_lineup', {
      p_pelada: id,
      p_lineup: null,
      p_label: label.trim() || 'Escalação',
      p_team_a: draft.filter((p) => p.team === 'A').map((p) => p.key),
      p_team_b: draft.filter((p) => p.team === 'B').map((p) => p.key),
      p_team_a_name: nameA.trim() || null,
      p_team_b_name: nameB.trim() || null,
    });
    if (!ok) return;
    setEditing(false);
    setSides({});
    setLabel('');
    setReload((n) => n + 1);
  }

  return (
    <Screen>
      <Title>Escalações</Title>
      <Sub>Times definidos antes do jogo. Gols e assistências continuam sendo lançados na súmula depois da partida.</Sub>
      <ErrorText>{msg}</ErrorText>
      {msg && !lineups && <Button title="Tentar de novo" kind="secondary" onPress={() => setReload((n) => n + 1)} />}
      {!lineups && !msg && <Sub>Carregando...</Sub>}

      {lineups?.length === 0 && !editing && <Sub>Nenhuma escalação ativa.</Sub>}
      {lineups?.map((l) => (
        <Card key={l.id}>
          <Body>{l.label}</Body>
          <Sub>
            {l.source === 'draw' ? 'Do sorteio' : 'Montada à mão'}
            {l.rounds_total > 1 ? ` · usada em ${l.rounds_used} de ${l.rounds_total} rodadas` : ''}
          </Sub>
          {l.needs_review && (
            <Text style={{ color: colors.danger, fontWeight: '600' }}>
              Precisa de revisão: alguém saiu da pelada ou mudou de posição depois de montada. Nada foi mudado sozinho.
            </Text>
          )}
          <LineupBoard teamA={l.team_a_name} teamB={l.team_b_name} players={toBoard(l)} />
          <SharePanel label="Compartilhar escalação" fileName="minuto91-escalacao" title="Escalação">
            <LineupArt peladaName={pelada?.name ?? ''} crestPath={pelada?.crest_path} subtitle={l.label} teamA={l.team_a_name} teamB={l.team_b_name} players={toBoard(l)} />
          </SharePanel>
          {isStaff && premium && (
            <>
              <Button title="Usar na súmula de hoje" onPress={() => usar(l)} loading={busy === `usar-${l.id}`} disabled={l.needs_review} />
              <Button title="Cancelar escalação" kind="secondary" onPress={() => cancelar(l)} loading={busy === `cancelar-${l.id}`} />
            </>
          )}
        </Card>
      ))}

      {isStaff && !premium && (
        <Card>
          <Body>Escalação antes do jogo e sorteio automático</Body>
          <Sub>Recursos da Pelada Premium. A escalação depois do jogo continua grátis, na tela de cada partida.</Sub>
          <Button title="Conhecer a Pelada Premium" kind="secondary" onPress={() => router.push({ pathname: '/pelada/[id]/premium', params: { id } })} />
        </Card>
      )}

      {isStaff && premium && !editing && (
        <>
          <Button title="Sortear times" onPress={() => router.push({ pathname: '/pelada/[id]/sorteio', params: { id } })} />
          <Button title="Montar escalação à mão" kind="secondary" onPress={() => setEditing(true)} />
        </>
      )}

      {editing && (
        <Card>
          <Body>Nova escalação</Body>
          <Input placeholder="nome (ex.: Quinta 21/10)" value={label} onChangeText={setLabel} maxLength={60} autoCapitalize="sentences" />
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Input placeholder="Time A" value={nameA} onChangeText={setNameA} maxLength={40} autoCapitalize="words" />
            </View>
            <View style={{ flex: 1 }}>
              <Input placeholder="Time B" value={nameB} onChangeText={setNameB} maxLength={40} autoCapitalize="words" />
            </View>
          </View>
          {members.map((m) => (
            <View key={m.id} style={{ flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 44 }}>
              <View style={{ flex: 1 }}>
                <Text style={{ color: colors.ink }}>{m.player_name}</Text>
                <Text style={{ color: colors.muted, fontSize: 12 }}>{positionLabel(m.preferred_position)}</Text>
              </View>
              <Chips options={SIDES} value={sides[m.id] ?? '-'} onChange={(v) => setSides((s) => ({ ...s, [m.id]: v }))} />
            </View>
          ))}
          <Sub>
            Time A: {sizeA} · Time B: {sizeB}
          </Sub>
          {(unbalanced.length > 0 || Math.abs(sizeA - sizeB) > 1) && (
            <Text style={{ color: colors.darkGold, fontWeight: '600' }}>
              Atenção: times desequilibrados
              {unbalanced.length > 0 ? ` em ${unbalanced.map((u) => `${POS_SHORT[u.position] ?? 'sem posição'} (${u.a} x ${u.b})`).join(', ')}` : ''}
              {Math.abs(sizeA - sizeB) > 1 ? ` e no total (${sizeA} x ${sizeB})` : ''}. Você pode salvar mesmo assim.
            </Text>
          )}
          <Button title="Salvar escalação" onPress={salvar} loading={busy === 'salvar'} disabled={sizeA < 1 || sizeB < 1} />
          <Pressable onPress={() => setEditing(false)} accessibilityRole="button" style={{ minHeight: 44, justifyContent: 'center', alignSelf: 'center' }}>
            <Text style={{ color: colors.muted }}>Cancelar</Text>
          </Pressable>
        </Card>
      )}
    </Screen>
  );
}
