import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { confirm, notify } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { LineupBoard, LineupPlayer } from '../../../lib/lineup';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, memberPosition, positionLabel, positionRank } from '../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Input, Screen, Stepper, Sub, Title } from '../../../lib/ui';

type DrawPlayer = { membership_id: string; name: string; position: string | null; overall: number; active: boolean };
type DrawRound = {
  round: number;
  overall_a: number;
  overall_b: number;
  team_a: DrawPlayer[];
  team_b: DrawPlayer[];
  by_position: { position: string; a: number; b: number }[];
};
type Draw = { id: string; mode: 'single' | 'independent'; rounds_total: number; status: string; seed: string; warnings: string[]; rounds: DrawRound[];
  diversity?: { rounds: number; distinct: number; limited: boolean } | null;
};
type Member = { id: string; user_id: string | null; player_name: string; preferred_position: string; position_code?: string | null; role: string };

const MODES = [
  { value: 'single', label: 'Sorteio único' },
  { value: 'independent', label: 'Um por rodada' },
] as const;

const WARNING: Record<string, string> = {
  ONE_GOALKEEPER: 'Só 1 goleiro selecionado: ele fica num time e o outro joga sem goleiro de posição. Nenhum jogador teve a posição trocada.',
  ODD_GOALKEEPERS: 'Número ímpar de goleiros: um time fica com 1 goleiro a mais (inevitável com os selecionados).',
  NO_POSITION: 'Há jogadores sem posição informada: eles foram divididos entre si, com a mesma regra.',
  PROVISIONAL_OVERALL: 'Alguns jogadores ainda não têm Card definitivo: foi usado o overall provisório oficial.',
  MEMBER_LEFT: 'Alguém deste sorteio saiu da pelada: revise antes de usar.',
  POSITION_CHANGED: 'Alguém mudou de posição depois do sorteio: revise antes de usar.',
  LEGACY_POSITIONS:
    'Há jogadores com a posição antiga (Defensor, Meio-campista ou Atacante): eles formam grupos próprios. Quando cada um escolher a posição específica, o sorteio fica mais preciso.',
  LIMITED_DIVERSITY:
    'Com estes jogadores não há divisões válidas diferentes para todas as rodadas: algumas rodadas repetem times. O equilíbrio por posição foi mantido.',
};
const posName = (p: string) => (p === 'none' ? 'Posição não informada' : positionLabel(p));

// Sorteio automático de times (Pelada Premium, admin e assistentes). Feito no servidor (039; V4.3: 040, dez posições):
// 1º cada posição fica com diferença máxima de 1 entre os times (goleiros separados), 2º os totais com
// diferença máxima de 1, 3º só então o overall equilibra a força, trocando jogadores da mesma posição.
// A semente é sempre gerada pelo servidor; no modo um por rodada, as rodadas evitam repetir times.
export default function Sorteio() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const router = useRouter();
  const [members, setMembers] = useState<Member[] | null>(null);
  const [premium, setPremium] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [mode, setMode] = useState<'single' | 'independent'>('single');
  const [rounds, setRounds] = useState(4);
  const [draft, setDraft] = useState<Draw | null>(null);
  const [nameA, setNameA] = useState('');
  const [nameB, setNameB] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [{ data: ms, error }, { data: ent }, { data: draws }] = await Promise.all([
        supabase.from('pelada_memberships').select('id, user_id, player_name, preferred_position, position_code, role').eq('pelada_id', id).eq('status', 'active').order('player_name'),
        supabase.rpc('get_pelada_entitlement', { p_pelada: id }),
        supabase.rpc('get_team_draws', { p_pelada: id }),
      ]);
      if (!alive) return;
      if (error) return setMsg(friendly(error.message));
      setMembers((ms ?? []) as Member[]);
      setPremium(!!(ent as { is_premium?: boolean } | null)?.is_premium);
      // Rascunho aberto (sorteado e ainda não confirmado) continua de onde parou.
      const open = ((draws ?? []) as Draw[]).find((d) => d.status === 'draft');
      if (open) {
        setDraft(open);
        setMode(open.mode);
        setRounds(open.rounds_total);
        setSelected(new Set(open.rounds[0]?.team_a.concat(open.rounds[0].team_b).map((p) => p.membership_id)));
      }
    })();
    return () => {
      alive = false;
    };
  }, [id]);

  const me = members?.find((m) => m.user_id === session?.user.id);
  const isStaff = me?.role === 'admin' || me?.role === 'assistant';
  const toggle = (mid: string) =>
    setSelected((s) => {
      const n = new Set(s);
      if (n.has(mid)) n.delete(mid);
      else n.add(mid);
      return n;
    });

  async function sortear() {
    setBusy('sortear');
    setMsg(null);
    const { data, error } = await supabase.rpc('create_team_draw', { p_pelada: id, p_members: [...selected], p_mode: mode, p_rounds: rounds });
    setBusy(null);
    if (error) return setMsg(friendly(error.message));
    setDraft(data as Draw);
  }

  async function confirmar() {
    if (!draft) return;
    setBusy('confirmar');
    setMsg(null);
    const { error } = await supabase.rpc('confirm_team_draw', { p_draw: draft.id, p_team_a_name: nameA.trim() || null, p_team_b_name: nameB.trim() || null });
    setBusy(null);
    if (error) return setMsg(friendly(error.message));
    notify(
      'Sorteio confirmado',
      draft.mode === 'single' ? `Os mesmos times valem para ${draft.rounds_total} ${draft.rounds_total === 1 ? 'rodada' : 'rodadas'}.` : `${draft.rounds_total} escalações criadas, uma por rodada.`,
    );
    router.replace({ pathname: '/pelada/[id]/escalacoes', params: { id } });
  }

  function descartar() {
    if (!draft) return;
    confirm('Descartar sorteio?', 'Nada foi confirmado ainda.', 'Descartar', async () => {
      const { error } = await supabase.rpc('cancel_team_draw', { p_draw: draft.id });
      if (error) return setMsg(friendly(error.message));
      setDraft(null);
    });
  }

  if (!members) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }
  if (!isStaff || !premium) {
    return (
      <Screen>
        <Title>Sorteio de times</Title>
        <Sub>
          {!isStaff
            ? 'Só o administrador e os assistentes sorteiam os times. As escalações confirmadas aparecem em Escalações.'
            : 'O sorteio automático é da Pelada Premium. Você continua podendo montar os times à mão na súmula.'}
        </Sub>
        {isStaff && <Button title="Conhecer a Pelada Premium" onPress={() => router.push({ pathname: '/pelada/[id]/premium', params: { id } })} />}
      </Screen>
    );
  }

  const byPos = [...members].sort((a, b) => positionRank(memberPosition(a)) - positionRank(memberPosition(b)) || a.player_name.localeCompare(b.player_name, 'pt-BR'));
  const board = (r: DrawRound): LineupPlayer[] => [
    ...r.team_a.map((p) => ({ key: p.membership_id, team: 'A' as const, name: p.name, position: p.position })),
    ...r.team_b.map((p) => ({ key: p.membership_id, team: 'B' as const, name: p.name, position: p.position })),
  ];

  return (
    <Screen>
      <Title>Sorteio de times</Title>
      <Sub>Regras, nesta ordem: 1) em cada posição, no máximo 1 jogador de diferença entre os times (goleiros separados); 2) totais com no máximo 1 de diferença; 3) overall equilibrado sem quebrar 1 e 2.</Sub>

      {!draft && (
        <>
          <Text style={section}>Tipo de sorteio</Text>
          <Chips options={MODES} value={mode} onChange={setMode} />
          <Sub>
            {mode === 'single'
              ? 'Um sorteio só: os mesmos times valem para todas as rodadas escolhidas.'
              : 'Um sorteio diferente para cada rodada, todos feitos agora.'}
          </Sub>
          <Stepper label="Rodadas" value={rounds} onChange={setRounds} min={1} max={12} />

          <Text style={section}>Quem vai jogar ({selected.size})</Text>
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Button title="Todos" kind="secondary" onPress={() => setSelected(new Set(members.map((m) => m.id)))} />
            </View>
            <View style={{ flex: 1 }}>
              <Button title="Nenhum" kind="secondary" onPress={() => setSelected(new Set())} />
            </View>
          </View>
          {byPos.map((m) => {
            const on = selected.has(m.id);
            return (
              <Pressable
                key={m.id}
                onPress={() => toggle(m.id)}
                accessibilityRole="checkbox"
                accessibilityState={{ checked: on }}
                style={{ flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 44, paddingHorizontal: 8, borderRadius: 8, backgroundColor: on ? colors.bg : colors.white }}>
                <View style={{ width: 22, height: 22, borderRadius: 6, borderWidth: 2, borderColor: on ? colors.blue : colors.line, backgroundColor: on ? colors.blue : colors.white }} />
                <Text style={{ flex: 1, color: colors.ink }}>{m.player_name}</Text>
                <Text style={{ color: colors.muted, fontSize: 12 }}>{positionLabel(memberPosition(m))}</Text>
              </Pressable>
            );
          })}
          <ErrorText>{msg}</ErrorText>
          <Button title="Sortear" onPress={sortear} loading={busy === 'sortear'} disabled={selected.size < 2} />
        </>
      )}

      {draft && (
        <>
          <Card>
            <Body>
              {draft.mode === 'single'
                ? `Sorteio único · ${draft.rounds_total} ${draft.rounds_total === 1 ? 'rodada' : 'rodadas'}`
                : `${draft.rounds_total} sorteios independentes`}
            </Body>
            <Sub>Ainda não confirmado. Código do sorteio: {draft.seed.slice(0, 8)} (gerado pelo servidor; permite conferir depois).</Sub>
            {draft.mode === 'independent' && draft.diversity && (
              <Sub>
                {draft.diversity.distinct} {draft.diversity.distinct === 1 ? 'composição diferente' : 'composições diferentes'} em {draft.diversity.rounds}{' '}
                {draft.diversity.rounds === 1 ? 'rodada' : 'rodadas'} (times invertidos contam como a mesma).
              </Sub>
            )}
            {draft.warnings.map((w) => (
              <Text key={w} style={{ color: colors.darkGold, fontWeight: '600' }}>
                {WARNING[w] ?? w}
              </Text>
            ))}
          </Card>
          {draft.rounds.map((r) => (
            <Card key={r.round}>
              {draft.mode === 'independent' && <Body>Rodada {r.round}</Body>}
              <LineupBoard teamA={nameA.trim() || 'Time A'} teamB={nameB.trim() || 'Time B'} players={board(r)} />
              <View style={{ marginTop: 6, gap: 2 }}>
                {r.by_position.map((p) => (
                  <Text key={p.position} style={{ color: colors.muted, fontSize: 13 }}>
                    {posName(p.position)}: {p.a} x {p.b}
                  </Text>
                ))}
                <Text style={{ color: colors.muted, fontSize: 13 }}>
                  Total: {r.team_a.length} x {r.team_b.length} · Overall somado: {Math.round(r.overall_a)} x {Math.round(r.overall_b)}
                </Text>
              </View>
            </Card>
          ))}
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Input placeholder="nome do Time A" value={nameA} onChangeText={setNameA} maxLength={40} autoCapitalize="words" />
            </View>
            <View style={{ flex: 1 }}>
              <Input placeholder="nome do Time B" value={nameB} onChangeText={setNameB} maxLength={40} autoCapitalize="words" />
            </View>
          </View>
          <ErrorText>{msg}</ErrorText>
          <Button title="Confirmar e salvar" onPress={confirmar} loading={busy === 'confirmar'} />
          <Button title="Sortear de novo" kind="secondary" onPress={sortear} loading={busy === 'sortear'} />
          <Button title="Mudar jogadores ou tipo" kind="secondary" onPress={() => setDraft(null)} />
          <Button title="Descartar sorteio" kind="danger" onPress={descartar} />
        </>
      )}
    </Screen>
  );
}

const section = { fontSize: 13, fontWeight: '800' as const, color: colors.deepBlue, letterSpacing: 0.5, marginTop: 10 };
