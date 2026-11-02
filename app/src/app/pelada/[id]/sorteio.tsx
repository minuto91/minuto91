// V8.5 — Sorteio de times (Pelada Premium; administrador e assistentes).
// Preparação → prévia (sorteio exato no servidor: melhor equilíbrio por posição e chance igual entre todas as
// divisões ideais; nada de OVR) → confirmação → escalação oficial. A prévia não substitui a escalação oficial
// enquanto não for confirmada; qualquer mudança na preparação invalida a prévia (o servidor confere tudo de novo).
import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useMemo, useRef, useState } from 'react';
import { Pressable, View } from 'react-native';

import { confirm, notify } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import { requestId } from '../../../lib/ids';
import { LineupBoard, type LineupPlayer } from '../../../lib/lineup';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { Text } from '../../../lib/text';
import { colors, memberPosition, positionLabel, positionRank } from '../../../lib/theme';
import { Toggle } from '../../../lib/toggle';
import { Body, Button, Card, Chips, ErrorText, Input, LoadingBlock, PositionPicker, Screen, Stepper, Sub, Title } from '../../../lib/ui';
import {
  countLabel,
  createGate,
  goalkeeperWarning,
  idempotent,
  nameHints,
  type Preparation,
  type PreviewRound,
  summaryText,
  type Team,
} from '../../../lib/v85';

type Member = { id: string; user_id: string | null; player_name: string; preferred_position: string; position_code?: string | null; role: string };

const MODES = [
  { value: 'single', label: 'Mesmos times' },
  { value: 'independent', label: 'Um por rodada' },
] as const;

export default function Sorteio() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const router = useRouter();
  const gate = useRef(createGate()).current;
  const [members, setMembers] = useState<Member[] | null>(null);
  const [premium, setPremium] = useState(false);
  const [prep, setPrep] = useState<Preparation | null>(null);
  const [lastDraw, setLastDraw] = useState<string[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [search, setSearch] = useState('');
  const [guestName, setGuestName] = useState('');
  const [guestPos, setGuestPos] = useState<string | null>(null);
  const [guestAdult, setGuestAdult] = useState(false);
  const [nameA, setNameA] = useState('');
  const [nameB, setNameB] = useState('');
  const [swapPick, setSwapPick] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  const applyPrep = useCallback((p: Preparation | null) => {
    setPrep(p);
    if (p) setSelected(new Set(p.participants.filter((x) => x.membership_id).map((x) => x.membership_id!)));
  }, []);

  const load = useCallback(async () => {
    const ok = gate.next('load');
    const [{ data: ms, error }, { data: ent }, { data: p, error: pe }, { data: comps }] = await Promise.all([
      supabase.from('pelada_memberships').select('id, user_id, player_name, preferred_position, position_code, role').eq('pelada_id', id).eq('status', 'active').order('player_name'),
      supabase.rpc('get_pelada_entitlement', { p_pelada: id }),
      supabase.rpc('get_draw_preparation', { p_pelada: id }),
      supabase.rpc('get_team_compositions', { p_pelada: id }),
    ]);
    if (!ok()) return; // resposta obsoleta
    if (error) return setMsg(friendly(error.message));
    setMembers((ms ?? []) as Member[]);
    setPremium(!!(ent as { is_premium?: boolean } | null)?.is_premium);
    if (!pe) applyPrep((p ?? null) as Preparation | null);
    const latest = ((comps ?? []) as { members: { membership_id: string | null }[] }[])[0];
    setLastDraw(latest ? latest.members.filter((m) => m.membership_id).map((m) => m.membership_id!) : []);
  }, [id, gate, applyPrep]);

  // Ao voltar para a tela, recupera a preparação e a prévia salvas no servidor (REV-37).
  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  // Toda escrita: versão esperada + request_id; conflito recarrega a versão atual sem sobrescrever.
  async function run(key: string, fn: () => PromiseLike<{ data: unknown; error: { message: string } | null }>, rid?: string) {
    setBusy(key);
    setMsg(null);
    const r = rid
      ? await idempotent(
          async () => await fn(),
          async () => (await supabase.rpc('get_v85_operation', { p_request: rid })) as never,
        )
      : await fn();
    setBusy(null);
    if (r.error) {
      setMsg(friendly(r.error.message));
      if (/VERSION_CONFLICT|PREP_CLOSED|DRAW_STALE/.test(r.error.message)) await load();
      return null;
    }
    return r.data;
  }

  const me = members?.find((m) => m.user_id === session?.user.id);
  const isStaff = me?.role === 'admin' || me?.role === 'assistant';
  const memberIds = useMemo(() => new Set((members ?? []).map((m) => m.id)), [members]);
  const prepMembers = useMemo(() => new Set(prep?.participants.filter((x) => x.membership_id).map((x) => x.membership_id!) ?? []), [prep]);
  const selectionDirty = prep != null && (selected.size !== prepMembers.size || [...selected].some((x) => !prepMembers.has(x)));

  if (!members) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <LoadingBlock />}
      </Screen>
    );
  }
  if (!isStaff || !premium) {
    return (
      <Screen>
        <Title>Sorteio de times</Title>
        <Sub>
          {!isStaff
            ? 'Só o administrador e os assistentes sorteiam os times. A escalação confirmada aparece em Escalações.'
            : 'O sorteio automático é da Pelada Premium. Você continua podendo montar os times à mão na súmula.'}
        </Sub>
        {isStaff && <Button title="Conhecer a Pelada Premium" onPress={() => router.push({ pathname: '/pelada/[id]/premium', params: { id } })} />}
      </Screen>
    );
  }

  // ----- sem preparação aberta -----
  if (!prep) {
    return (
      <Screen>
        <Title>Sorteio de times</Title>
        <Sub>Divide por posição com o melhor equilíbrio possível. Nota e overall não entram.</Sub>
        <ErrorText>{msg}</ErrorText>
        <Button
          title="Começar sorteio"
          loading={busy === 'open'}
          onPress={async () => {
            const d = await run('open', () => supabase.rpc('open_draw_preparation', { p_pelada: id, p_mode: 'single', p_rounds: 1 }));
            if (d) applyPrep(d as Preparation);
          }}
        />
      </Screen>
    );
  }

  const v = prep.version;
  const hints = nameHints(prep.participants);
  const q = search.trim().toLocaleLowerCase('pt-BR');
  const list = [...members]
    .filter((m) => !q || m.player_name.toLocaleLowerCase('pt-BR').includes(q))
    .sort((a, b) => positionRank(memberPosition(a)) - positionRank(memberPosition(b)) || a.player_name.localeCompare(b.player_name, 'pt-BR'));
  const guests = prep.participants.filter((p) => p.guest);
  const gkWarning = goalkeeperWarning([
    ...members.filter((m) => selected.has(m.id)).map((m) => m.position_code ?? m.preferred_position),
    ...guests.map((g) => g.position),
  ]);
  const captainOf = (pid: string) => prep.participants.find((p) => p.pid === pid)?.captain_team ?? null;
  const capA = prep.participants.find((p) => p.captain_team === 'A')?.pid ?? null;
  const capB = prep.participants.find((p) => p.captain_team === 'B')?.pid ?? null;
  const ineligible = new Set(prep.problems.map((p) => p.pid));

  async function syncMembers() {
    if (!selectionDirty || !prep) return prep;
    const d = (await run('members', () => supabase.rpc('set_draw_members', { p_prep: prep.id, p_expected: prep.version, p_members: [...selected].filter((x) => memberIds.has(x)) }))) as Preparation | null;
    if (d) applyPrep(d);
    if (d?.notice === 'DUPLICATES_MERGED') notify('Seleção ajustada', 'Um participante aparecia duas vezes e ficou só uma.');
    return d;
  }

  async function setCaptain(pid: string, team: Team) {
    if (!prep) return;
    const a = team === 'A' ? (capA === pid ? null : pid) : capA === pid ? null : capA;
    const b = team === 'B' ? (capB === pid ? null : pid) : capB === pid ? null : capB;
    const d = await run('captain', () => supabase.rpc('set_draw_captains', { p_prep: prep.id, p_expected: v, p_captain_a: a, p_captain_b: b }));
    if (d) applyPrep(d as Preparation);
  }

  async function gerar() {
    const p = await syncMembers();
    if (!p) return;
    const rid = requestId();
    const d = await run('preview', () => supabase.rpc('generate_draw_preview', { p_prep: p.id, p_expected: p.version, p_request: rid }), rid);
    if (d) applyPrep(d as Preparation);
  }

  // Etapa 12: ajuste rápido na prévia (troca de dois jogadores de times diferentes), salvo como prévia manual.
  async function trocar(round: PreviewRound, a: string, b: string) {
    if (!prep?.preview) return;
    const assign = prep.preview.rounds.flatMap((r) =>
      r.players.map((pl) => ({
        round: r.round,
        pid: pl.pid,
        team: r.round === round.round && (pl.pid === a || pl.pid === b) ? (pl.team === 'A' ? 'B' : 'A') : pl.team,
      })),
    );
    const rid = requestId();
    const d = await run('swap', () => supabase.rpc('save_manual_preview', { p_prep: prep.id, p_expected: v, p_assign: assign, p_request: rid }), rid);
    if (d) applyPrep(d as Preparation);
  }

  async function confirmar() {
    if (!prep?.preview) return;
    const rid = requestId();
    const d = (await run(
      'confirm',
      () => supabase.rpc('confirm_draw_preview', { p_preview: prep.preview!.id, p_expected: v, p_team_a_name: nameA.trim() || null, p_team_b_name: nameB.trim() || null, p_request: rid }),
      rid,
    )) as { compositions: { id: string }[] } | null;
    if (!d) return;
    // REV-55: sucesso só depois da confirmação do servidor; as duas imagens ficam na escalação.
    notify('Escalação confirmada', 'Já está disponível para a pelada. Compartilhe a lista ou o campo na escalação.');
    router.replace({ pathname: '/pelada/[id]/escalacoes', params: { id } });
  }

  const preview = prep.preview;
  const board = (r: PreviewRound): LineupPlayer[] =>
    r.players.map((p) => ({ key: p.pid, team: p.team, name: `${p.name}${p.captain ? ' (C)' : ''}${hints[p.pid] ? ` · ${hints[p.pid]}` : ''}`, position: p.position, guest: p.guest }));

  return (
    <Screen>
      <Title>Sorteio de times</Title>
      <Sub>Divide por posição com o melhor equilíbrio possível. Nota e overall não entram.</Sub>

      <Text style={section}>Rodadas</Text>
      <Chips
        options={MODES}
        value={prep.mode}
        onChange={async (mode) => {
          const d = await run('opts', () => supabase.rpc('set_draw_preparation_options', { p_prep: prep.id, p_expected: v, p_mode: mode, p_rounds: prep.rounds_total, p_round_dates: null, p_captains: prep.captains_enabled }));
          if (d) applyPrep(d as Preparation);
        }}
      />
      <Stepper
        label="Quantidade de rodadas"
        value={prep.rounds_total}
        min={1}
        max={12}
        onChange={async (n) => {
          const d = await run('opts', () => supabase.rpc('set_draw_preparation_options', { p_prep: prep.id, p_expected: v, p_mode: prep.mode, p_rounds: n, p_round_dates: null, p_captains: prep.captains_enabled }));
          if (d) applyPrep(d as Preparation);
        }}
      />
      <Sub>{prep.mode === 'single' ? 'Um sorteio: os mesmos times valem para as rodadas escolhidas.' : 'Um sorteio diferente para cada rodada.'}</Sub>

      <Text style={section}>Quem vai jogar ({selected.size + guests.length})</Text>
      <View style={{ flexDirection: 'row', gap: 8 }}>
        <View style={{ flex: 1 }}>
          <Button title="Último sorteio" kind="secondary" disabled={!lastDraw.length} onPress={() => setSelected(new Set(lastDraw.filter((x) => memberIds.has(x))))} />
        </View>
        <View style={{ flex: 1 }}>
          <Button title="Todos" kind="secondary" onPress={() => setSelected(new Set(members.map((m) => m.id)))} />
        </View>
        <View style={{ flex: 1 }}>
          <Button title="Limpar" kind="ghost" onPress={() => setSelected(new Set())} />
        </View>
      </View>
      <Sub>Selecionar não confirma presença: quem jogou de fato é confirmado na súmula.</Sub>
      {members.length > 12 && <Input placeholder="Buscar jogador" value={search} onChangeText={setSearch} autoCapitalize="none" />}
      {list.map((m) => {
        const on = selected.has(m.id);
        const cap = on && prepMembers.has(m.id) ? captainOf(m.id) : null;
        return (
          <View key={m.id} style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
            <Pressable
              onPress={() =>
                setSelected((s) => {
                  const n = new Set(s);
                  if (n.has(m.id)) n.delete(m.id);
                  else n.add(m.id);
                  return n;
                })
              }
              accessibilityRole="checkbox"
              accessibilityState={{ checked: on }}
              style={{ flex: 1, flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 44, paddingHorizontal: 8, borderRadius: 8, backgroundColor: on ? colors.bg : colors.white }}>
              <View style={{ width: 22, height: 22, borderRadius: 6, borderWidth: 2, borderColor: on ? colors.blue : colors.line, backgroundColor: on ? colors.blue : colors.white }} />
              <Text style={{ flex: 1, color: ineligible.has(m.id) ? colors.danger : colors.ink }} numberOfLines={1}>
                {m.player_name}
                {hints[m.id] ? <Text style={{ color: colors.muted, fontSize: 12 }}>{` · ${hints[m.id]}`}</Text> : null}
              </Text>
              <Text style={{ color: colors.muted, fontSize: 12 }}>{positionLabel(memberPosition(m))}</Text>
            </Pressable>
            {prep.captains_enabled && on && prepMembers.has(m.id) && <CaptainButtons value={cap} onPick={(t) => setCaptain(m.id, t)} />}
          </View>
        );
      })}

      {guests.map((g) => (
        <View key={g.pid} style={{ flexDirection: 'row', alignItems: 'center', gap: 6, minHeight: 44, paddingHorizontal: 8 }}>
          <Text style={{ flex: 1, color: colors.ink }} numberOfLines={1}>
            {g.name} <Text style={{ color: colors.muted, fontSize: 12 }}>convidado{g.position ? ` · ${positionLabel(g.position)}` : ' · sem posição'}</Text>
          </Text>
          {prep.captains_enabled && <CaptainButtons value={g.captain_team} onPick={(t) => setCaptain(g.pid, t)} />}
          <Button
            title="Tirar"
            kind="ghost"
            onPress={async () => {
              const d = await run('rm', () => supabase.rpc('remove_draw_participant', { p_prep: prep.id, p_expected: v, p_pid: g.pid }));
              if (d) applyPrep(d as Preparation);
            }}
          />
        </View>
      ))}

      <Card>
        <Body>Adicionar convidado</Body>
        <Input placeholder="Nome do convidado" value={guestName} onChangeText={setGuestName} maxLength={80} autoCapitalize="words" />
        <Sub>Posição (opcional)</Sub>
        <PositionPicker value={guestPos} onChange={(p) => setGuestPos(guestPos === p ? null : p)} />
        <Toggle label="Declaro que o convidado tem 18 anos ou mais" value={guestAdult} onChange={setGuestAdult} />
        <Button
          title="Adicionar convidado"
          kind="secondary"
          loading={busy === 'guest'}
          disabled={!guestName.trim() || !guestAdult}
          onPress={async () => {
            const p = await syncMembers();
            if (!p) return;
            const d = await run('guest', () => supabase.rpc('add_draw_guest', { p_prep: p.id, p_expected: p.version, p_guest: null, p_name: guestName.trim(), p_position: guestPos, p_adult_declared: guestAdult }));
            if (d) {
              applyPrep(d as Preparation);
              setGuestName('');
              setGuestPos(null);
              setGuestAdult(false);
            }
          }}
        />
      </Card>

      <Toggle
        label="Capitães (um por time, ficam fixos no sorteio)"
        value={prep.captains_enabled}
        onChange={async (on) => {
          const p = await syncMembers();
          if (!p) return;
          const d = await run('opts', () => supabase.rpc('set_draw_preparation_options', { p_prep: p.id, p_expected: p.version, p_mode: p.mode, p_rounds: p.rounds_total, p_round_dates: null, p_captains: on }));
          if (d) applyPrep(d as Preparation);
        }}
      />
      {selectionDirty && <Sub>Seleção alterada: será aplicada ao gerar a prévia.</Sub>}
      {gkWarning && <Sub>⚠ {gkWarning}</Sub>}
      {prep.problems.length > 0 && <ErrorText>Há participante que não pode mais jogar (em vermelho). Remova-o para continuar.</ErrorText>}
      <ErrorText>{msg}</ErrorText>
      <Button title={preview ? 'Sortear de novo' : 'Sortear'} onPress={gerar} loading={busy === 'preview' || busy === 'members'} disabled={selected.size + guests.length < 2} />

      {preview && (
        <>
          <Text style={section}>Prévia {preview.source === 'draw' ? '' : '(ajustada à mão)'}</Text>
          {preview.stale && <ErrorText>Algo mudou depois desta prévia (posição ou participante). Sorteie de novo antes de confirmar.</ErrorText>}
          {preview.rounds.map((r) => {
            const s = summaryText(r.summary, r.optimal?.cost);
            return (
              <Card key={r.round}>
                {prep.mode === 'independent' && <Body>Rodada {r.round}</Body>}
                <LineupBoard teamA={nameA.trim() || 'Time A'} teamB={nameB.trim() || 'Time B'} players={board(r)} />
                <Text style={{ color: colors.ink, fontWeight: '700', marginTop: 6 }}>{s.headline}</Text>
                {r.optimal && <Sub>{countLabel(r.optimal.count)}</Sub>}
                {s.unavoidable && <Sub>Com essas posições, uma diferença pequena é inevitável.</Sub>}
                <View style={{ gap: 2 }}>
                  {s.lines.map((l) => (
                    <Text key={l} style={{ color: colors.muted, fontSize: 13 }}>
                      {l}
                    </Text>
                  ))}
                </View>
                <Sub>Toque em dois jogadores de times diferentes para trocá-los.</Sub>
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
                  {r.players
                    .filter((p) => !p.captain)
                    .map((p) => (
                      <Pressable
                        key={p.pid}
                        onPress={() => {
                          if (!swapPick) return setSwapPick(p.pid);
                          const other = r.players.find((x) => x.pid === swapPick);
                          setSwapPick(null);
                          if (other && other.team !== p.team) trocar(r, other.pid, p.pid);
                        }}
                        style={{ paddingHorizontal: 10, paddingVertical: 6, borderRadius: 14, borderWidth: 1, borderColor: swapPick === p.pid ? colors.blue : colors.line, backgroundColor: p.team === 'A' ? colors.bg : colors.white }}>
                        <Text style={{ fontSize: 12, color: colors.ink }}>
                          {p.team} · {p.name}
                        </Text>
                      </Pressable>
                    ))}
                </View>
              </Card>
            );
          })}
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Input placeholder="nome do Time A" value={nameA} onChangeText={setNameA} maxLength={40} autoCapitalize="words" />
            </View>
            <View style={{ flex: 1 }}>
              <Input placeholder="nome do Time B" value={nameB} onChangeText={setNameB} maxLength={40} autoCapitalize="words" />
            </View>
          </View>
          <Button title="Confirmar escalação" onPress={confirmar} loading={busy === 'confirm'} disabled={preview.stale || selectionDirty} />
        </>
      )}
      <Button
        title="Descartar preparação"
        kind="danger"
        onPress={() =>
          confirm('Descartar preparação?', 'A escalação oficial anterior continua valendo.', 'Descartar', async () => {
            const r = await run('discard', () => supabase.rpc('discard_draw_preparation', { p_prep: prep.id, p_expected: v, p_confirm: true }));
            if (r !== null) applyPrep(null);
          })
        }
      />
    </Screen>
  );
}

function CaptainButtons({ value, onPick }: { value: Team | null; onPick: (t: Team) => void }) {
  return (
    <View style={{ flexDirection: 'row', gap: 4 }}>
      {(['A', 'B'] as Team[]).map((t) => (
        <Pressable
          key={t}
          onPress={() => onPick(t)}
          accessibilityRole="button"
          accessibilityLabel={`Capitão do time ${t}`}
          accessibilityState={{ selected: value === t }}
          style={{ minWidth: 36, minHeight: 32, alignItems: 'center', justifyContent: 'center', borderRadius: 8, borderWidth: 1, borderColor: value === t ? colors.gold : colors.line, backgroundColor: value === t ? colors.deepBlue : colors.white }}>
          <Text style={{ fontSize: 12, fontWeight: '700', color: value === t ? colors.white : colors.muted }}>C{t}</Text>
        </Pressable>
      ))}
    </View>
  );
}

const section = { fontSize: 19, lineHeight: 25, fontWeight: '700' as const, color: colors.ink, marginTop: 10 };
