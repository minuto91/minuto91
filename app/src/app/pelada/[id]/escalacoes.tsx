import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { SharePanel } from '../../../lib/arts';
import { confirm } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { autoAssign, Formation, FORMATION_SIZE, FORMATIONS, swapSlots } from '../../../lib/formation';
import { FormationField, LineupArt, LineupBoard, LineupPlayer, positionCounts } from '../../../lib/lineup';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, memberPosition, positionLabel, positionShort } from '../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Input, Screen, Sub, Title } from '../../../lib/ui';

type Lineup = {
  id: string;
  label: string;
  source: 'manual' | 'draw';
  team_a_name: string;
  team_b_name: string;
  team_a_formation: Formation | null;
  team_b_formation: Formation | null;
  version: number;
  rounds_total: number;
  rounds_used: number;
  needs_review: boolean;
  review_reason: 'MEMBER_INACTIVE' | 'POSITION_CHANGED' | null;
  players: {
    membership_id: string;
    team: 'A' | 'B';
    name: string;
    position: string;
    position_at_creation: string | null;
    slot: string | null;
    active: boolean;
    avatar_path: string | null;
  }[];
};
type Member = { id: string; user_id: string | null; player_name: string; preferred_position: string; position_code?: string | null; role: string };
type Side = 'A' | 'B' | '-';
type FormationChoice = Formation | 'lista';

const SIDES = [
  { value: 'A', label: 'A' },
  { value: 'B', label: 'B' },
  { value: '-', label: 'Fora' },
] as const;
const FORMATION_OPTIONS: { value: FormationChoice; label: string }[] = [{ value: 'lista', label: 'Lista' }, ...FORMATIONS.map((f) => ({ value: f, label: f }))];

// Escalação antes do jogo (Pelada Premium): montada à mão ou vinda de um sorteio confirmado. Todos da
// pelada veem; admin e assistentes montam, escolhem a formação de cada time (4-3-3 ou 4-4-2, só com 11
// jogadores), usam na súmula (vira só rascunho) e cancelam. Não registra partida, não pede confirmação de
// presença e não depende de calendário. A formação nunca muda quem está em cada time nem o cadastro.
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
  // Editor de formação (de uma escalação já salva).
  const [fEdit, setFEdit] = useState<{ lineup: Lineup; fa: FormationChoice; fb: FormationChoice; slots: Record<string, string> } | null>(null);
  const [picked, setPicked] = useState<string | null>(null);

  useFocusEffect(
    useCallback(() => {
      let alive = true;
      (async () => {
        void reload;
        const [{ data: ls, error }, { data: ent }, { data: ms }, { data: p }] = await Promise.all([
          supabase.rpc('get_lineups', { p_pelada: id }),
          supabase.rpc('get_pelada_entitlement', { p_pelada: id }),
          supabase.from('pelada_memberships').select('id, user_id, player_name, preferred_position, position_code, role').eq('pelada_id', id).eq('status', 'active').order('player_name'),
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
  const toBoard = (l: Lineup, slots?: Record<string, string>): LineupPlayer[] =>
    l.players.map((p) => ({
      key: p.membership_id,
      team: p.team,
      name: p.name,
      position: p.position,
      avatar_path: p.avatar_path,
      slot: slots ? (slots[p.membership_id] ?? null) : p.slot,
    }));
  const formationsOf = (l: Lineup) => ({ A: l.team_a_formation, B: l.team_b_formation });

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

  function revisar(l: Lineup) {
    const changed = l.players.filter((p) => p.position_at_creation && p.position_at_creation !== p.position);
    confirm(
      'Manter esta escalação?',
      `Mudaram de posição: ${changed.map((p) => `${p.name} (${positionShort(p.position_at_creation)} para ${positionShort(p.position)})`).join(', ') || 'jogadores da escalação'}. Os times continuam iguais.`,
      'Manter escalação',
      async () => {
        if (await run(`revisar-${l.id}`, 'revalidate_lineup', { p_lineup: l.id })) setReload((n) => n + 1);
      },
    );
  }

  // ---------- Formação ----------
  const teamOf = (l: Lineup, t: 'A' | 'B') => l.players.filter((p) => p.team === t);
  function abrirFormacao(l: Lineup) {
    const keep = Object.fromEntries(l.players.map((p) => [p.membership_id, p.slot]));
    const slots: Record<string, string> = {};
    for (const t of ['A', 'B'] as const) {
      const f = t === 'A' ? l.team_a_formation : l.team_b_formation;
      if (f) Object.assign(slots, autoAssign(teamOf(l, t).map((p) => ({ key: p.membership_id, position: p.position })), f, keep));
    }
    setPicked(null);
    setFEdit({ lineup: l, fa: l.team_a_formation ?? 'lista', fb: l.team_b_formation ?? 'lista', slots });
  }
  function escolherFormacao(t: 'A' | 'B', v: FormationChoice) {
    if (!fEdit) return;
    const team = teamOf(fEdit.lineup, t);
    const slots = Object.fromEntries(Object.entries(fEdit.slots).filter(([k]) => !team.some((p) => p.membership_id === k)));
    if (v !== 'lista') Object.assign(slots, autoAssign(team.map((p) => ({ key: p.membership_id, position: p.position })), v));
    setPicked(null);
    setFEdit({ ...fEdit, [t === 'A' ? 'fa' : 'fb']: v, slots });
  }
  function tocar(key: string) {
    if (!fEdit) return;
    if (!picked) return setPicked(key);
    if (picked === key) return setPicked(null);
    const team = (k: string) => fEdit.lineup.players.find((p) => p.membership_id === k)?.team;
    // Só troca dentro do mesmo time: a formação não muda o time de ninguém.
    if (team(picked) !== team(key)) return setPicked(key);
    setFEdit({ ...fEdit, slots: swapSlots(fEdit.slots, picked, key) });
    setPicked(null);
  }
  async function salvarFormacao() {
    if (!fEdit) return;
    const fa = fEdit.fa === 'lista' ? null : fEdit.fa;
    const fb = fEdit.fb === 'lista' ? null : fEdit.fb;
    const slots = fEdit.lineup.players
      .filter((p) => (p.team === 'A' ? fa : fb) && fEdit.slots[p.membership_id])
      .map((p) => ({ membership_id: p.membership_id, slot: fEdit.slots[p.membership_id] }));
    const ok = await run('formacao', 'set_lineup_formation', {
      p_lineup: fEdit.lineup.id,
      p_team_a_formation: fa,
      p_team_b_formation: fb,
      p_slots: slots,
      p_expected_version: fEdit.lineup.version,
    });
    if (!ok) return;
    setFEdit(null);
    setReload((n) => n + 1);
  }

  // ---------- Montagem manual: equilíbrio por posição só como alerta (V4.2 11.12) ----------
  const draft: LineupPlayer[] = members
    .filter((m) => sides[m.id] === 'A' || sides[m.id] === 'B')
    .map((m) => ({ key: m.id, team: sides[m.id] as 'A' | 'B', name: m.player_name, position: memberPosition(m) }));
  const unbalanced = positionCounts(draft).filter((c) => Math.abs(c.a - c.b) > 1);
  const sizeA = draft.filter((p) => p.team === 'A').length;
  const sizeB = draft.length - sizeA;

  async function salvar() {
    const saved = (await run('salvar', 'save_lineup', {
      p_pelada: id,
      p_lineup: null,
      p_label: label.trim() || 'Escalação',
      p_team_a: draft.filter((p) => p.team === 'A').map((p) => p.key),
      p_team_b: draft.filter((p) => p.team === 'B').map((p) => p.key),
      p_team_a_name: nameA.trim() || null,
      p_team_b_name: nameB.trim() || null,
    })) as Lineup | null;
    if (!saved) return;
    setEditing(false);
    setSides({});
    setLabel('');
    setReload((n) => n + 1);
    // Time com 11: já abre a escolha da formação (o admin pode voltar sem salvar).
    if (teamOf(saved, 'A').length === FORMATION_SIZE || teamOf(saved, 'B').length === FORMATION_SIZE) abrirFormacao(saved);
  }

  if (fEdit) {
    const l = fEdit.lineup;
    const board = toBoard(l, fEdit.slots);
    const teamCard = (t: 'A' | 'B') => {
      const n = teamOf(l, t).length;
      const choice = t === 'A' ? fEdit.fa : fEdit.fb;
      const name = t === 'A' ? l.team_a_name : l.team_b_name;
      return (
        <Card key={t}>
          <Body>{name}</Body>
          {n === FORMATION_SIZE ? (
            <Chips options={FORMATION_OPTIONS} value={choice} onChange={(v) => escolherFormacao(t, v)} />
          ) : (
            <Sub>{n} jogadores: as formações 4-3-3 e 4-4-2 são para times com 11 (goleiro incluído). Este time aparece na lista por posição.</Sub>
          )}
          {choice !== 'lista' && (
            <FormationField
              name={name}
              formation={choice}
              players={board.filter((p) => p.team === t)}
              accent={t === 'A' ? colors.blue : colors.gold}
              selected={picked}
              onPressPlayer={tocar}
            />
          )}
        </Card>
      );
    };
    return (
      <Screen>
        <Title>Formação</Title>
        <Sub>{l.label}</Sub>
        <Sub>
          Toque num jogador e depois em outro do mesmo time para trocar os dois de lugar. A sigla em dourado indica quem está fora da
          posição sugerida (é permitido). O cadastro dos jogadores e os times não mudam.
        </Sub>
        <ErrorText>{msg}</ErrorText>
        {teamCard('A')}
        {teamCard('B')}
        <Button title="Salvar formação" onPress={salvarFormacao} loading={busy === 'formacao'} />
        <Pressable onPress={() => setFEdit(null)} accessibilityRole="button" style={{ minHeight: 44, justifyContent: 'center', alignSelf: 'center' }}>
          <Text style={{ color: colors.muted }}>Voltar sem salvar</Text>
        </Pressable>
      </Screen>
    );
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
            {l.version > 1 ? ` · versão ${l.version}` : ''}
          </Sub>
          {l.review_reason === 'MEMBER_INACTIVE' && (
            <Text style={{ color: colors.danger, fontWeight: '600' }}>
              Alguém desta escalação não está mais ativo na pelada. Ela não pode ser usada: cancele e monte de novo. Nada foi mudado sozinho.
            </Text>
          )}
          {l.review_reason === 'POSITION_CHANGED' && (
            <Text style={{ color: colors.danger, fontWeight: '600' }}>
              Alguém mudou de posição depois de montada. Revise antes de usar na súmula. Nada foi mudado sozinho.
            </Text>
          )}
          <LineupBoard teamA={l.team_a_name} teamB={l.team_b_name} players={toBoard(l)} formations={formationsOf(l)} />
          <SharePanel label="Compartilhar escalação" fileName="minuto91-escalacao" title="Escalação">
            <LineupArt
              peladaName={pelada?.name ?? ''}
              crestPath={pelada?.crest_path}
              subtitle={l.label}
              teamA={l.team_a_name}
              teamB={l.team_b_name}
              players={toBoard(l)}
              formations={formationsOf(l)}
            />
          </SharePanel>
          {isStaff && premium && (
            <>
              {l.review_reason === 'POSITION_CHANGED' && <Button title="Revisar e manter" onPress={() => revisar(l)} loading={busy === `revisar-${l.id}`} />}
              <Button title="Usar na súmula de hoje" onPress={() => usar(l)} loading={busy === `usar-${l.id}`} disabled={l.needs_review} />
              <Button title="Formação tática" kind="secondary" onPress={() => abrirFormacao(l)} />
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
                <Text style={{ color: colors.muted, fontSize: 12 }}>{positionLabel(memberPosition(m))}</Text>
              </View>
              <Chips options={SIDES} value={sides[m.id] ?? '-'} onChange={(v) => setSides((s) => ({ ...s, [m.id]: v }))} />
            </View>
          ))}
          <Sub>
            Time A: {sizeA} · Time B: {sizeB}
            {sizeA === FORMATION_SIZE || sizeB === FORMATION_SIZE ? ' · com 11, dá para escolher 4-3-3 ou 4-4-2 ao salvar' : ''}
          </Sub>
          {(unbalanced.length > 0 || Math.abs(sizeA - sizeB) > 1) && (
            <Text style={{ color: colors.darkGold, fontWeight: '600' }}>
              Atenção: times desequilibrados
              {unbalanced.length > 0 ? ` em ${unbalanced.map((u) => `${u.position === 'none' ? 'sem posição' : positionShort(u.position)} (${u.a} x ${u.b})`).join(', ')}` : ''}
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
