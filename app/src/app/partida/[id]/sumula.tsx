import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useMemo, useState } from 'react';
import { Pressable, Switch, Text, View } from 'react-native';

import { confirm, notify } from '../../../lib/dialog';
import { friendly } from '../../../lib/errors';
import {
  emptyExtras,
  fmtDate,
  Guest,
  loadGuests,
  loadMatch,
  loadMembers,
  loadSheet,
  Match,
  Member,
  sheetPayload,
  SheetPlayer,
  sheetScore,
  Team,
  TeamExtras,
} from '../../../lib/match';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, memberPosition, Position, positionLabel } from '../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Input, PositionPicker, Screen, Stepper, Sub, Title } from '../../../lib/ui';

const TEAMS = [
  { value: 'A', label: 'Time A' },
  { value: 'B', label: 'Time B' },
] as const;

const DURATIONS = [
  { value: '120', label: '2 horas' },
  { value: '240', label: '4 horas' },
  { value: '360', label: '6 horas' },
] as const;

const DAYS = [
  { value: '0', label: 'Hoje' },
  { value: '1', label: 'Ontem' },
  { value: '2', label: 'Anteontem' },
] as const;

export default function Sumula() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const router = useRouter();
  const [match, setMatch] = useState<Match | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [guests, setGuests] = useState<Guest[]>([]);
  const [players, setPlayers] = useState<SheetPlayer[]>([]);
  const [extras, setExtras] = useState<TeamExtras>(emptyExtras());
  const [reason, setReason] = useState('');
  const [duration, setDuration] = useState<'120' | '240' | '360'>('240');
  const [guestName, setGuestName] = useState('');
  const [guestAdult, setGuestAdult] = useState(false);
  const [guestPos, setGuestPos] = useState<Position | null>('MEI');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [reload, setReload] = useState(0); // incrementar = buscar de novo
  // A19 (Pelada Premium): nomes dos times e horário fixo para encerrar a votação (1 a 24 h).
  const [premium, setPremium] = useState(false);
  const [teamA, setTeamA] = useState('');
  const [teamB, setTeamB] = useState('');
  const [closeMode, setCloseMode] = useState<'duration' | 'fixed'>('duration');
  const [fixedHours, setFixedHours] = useState(3);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const m = await loadMatch(id);
        if (!alive) return;
        if (!m) return setMsg('Partida não encontrada.');
        const [ms, gs, sheet, { data: st }, { data: ent }] = await Promise.all([
          loadMembers(m.pelada_id),
          loadGuests(m.pelada_id),
          loadSheet(id),
          supabase.from('pelada_settings').select('voting_duration_minutes').eq('pelada_id', m.pelada_id).maybeSingle(),
          supabase.rpc('get_pelada_entitlement', { p_pelada: m.pelada_id }),
        ]);
        if (!alive) return;
        // Prazo padrão escolhido nas configurações da pelada.
        if (st) setDuration(String(st.voting_duration_minutes) as '120' | '240' | '360');
        setPremium(!!(ent as { is_premium?: boolean } | null)?.is_premium);
        setTeamA(m.team_a_name);
        setTeamB(m.team_b_name);
        setMatch(m);
        setMembers(ms);
        setGuests(gs);
        setPlayers(sheet.players);
        setExtras(sheet.extras);
      } catch (e) {
        if (alive) setMsg(friendly((e as Error).message));
      }
    })();
    return () => {
      alive = false;
    };
  }, [id, reload]);

  const isDraft = match?.status === 'draft';
  const isCorrection = match?.status === 'voting_open';
  const editable = isDraft || isCorrection;
  const score = sheetScore(players, extras);
  const memberById = useMemo(() => new Map(members.map((m) => [m.id, m])), [members]);
  const guestById = useMemo(() => new Map(guests.map((g) => [g.id, g])), [guests]);
  const nameOf = (p: SheetPlayer) =>
    p.membership_id ? (memberById.get(p.membership_id)?.player_name ?? 'Jogador') : (guestById.get(p.guest_id!)?.display_name ?? 'Convidado');
  const inSheet = new Set(players.map((p) => p.key));
  const benchMembers = members.filter((m) => m.status === 'active' && !inSheet.has(`m:${m.id}`));
  const benchGuests = guests.filter((g) => !inSheet.has(`g:${g.id}`));

  const update = (key: string, patch: Partial<SheetPlayer>) =>
    setPlayers((ps) => ps.map((p) => (p.key === key ? { ...p, ...patch } : p)));
  const remove = (key: string) => setPlayers((ps) => ps.filter((p) => p.key !== key));
  const addMember = (m: Member, team: Team) =>
    setPlayers((ps) => [
      ...ps,
      { key: `m:${m.id}`, membership_id: m.id, team, position: memberPosition(m) ?? m.preferred_position, goals: 0, assists: 0, reds: 0 },
    ]);
  const addGuest = (g: Guest, team: Team) => {
    if (!guestPos) return setMsg('Escolha a posição do convidado.');
    setPlayers((ps) => [
      ...ps,
      { key: `g:${g.id}`, guest_id: g.id, team, position: guestPos, goals: 0, assists: 0, reds: 0 },
    ]);
  };
  const setExtra = (kind: keyof TeamExtras, team: Team, v: number) =>
    setExtras((e) => ({ ...e, [kind]: { ...e[kind], [team]: v } }));

  // ok = false quando o servidor recusou (a mensagem já aparece na tela).
  async function call<T = unknown>(fn: string, args: Record<string, unknown>): Promise<{ ok: boolean; data: T }> {
    setBusy(true);
    setMsg(null);
    const { data, error } = await supabase.rpc(fn, args);
    setBusy(false);
    if (error) setMsg(friendly(error.message));
    return { ok: !error, data: data as T };
  }

  async function novoConvidado() {
    if (!guestAdult) return setMsg('Confirme que o convidado tem 18 anos ou mais.');
    const { ok, data: gid } = await call<string>('create_guest', {
      p_pelada: match!.pelada_id,
      p_name: guestName,
      p_adult_declared: true,
    });
    if (!ok) return;
    const g = { id: gid, display_name: guestName.trim() };
    setGuests((gs) => [...gs, g]);
    setGuestName('');
    setGuestAdult(false);
    addGuest(g, 'A');
  }

  async function mudarData(daysAgo: string) {
    const d = new Date();
    d.setDate(d.getDate() - Number(daysAgo));
    if ((await call('update_match_draft', { p_match: id, p_played_at: d.toISOString(), p_team_a_name: match!.team_a_name, p_team_b_name: match!.team_b_name })).ok)
      setReload((n) => n + 1);
  }

  async function salvarNomes() {
    if ((await call('update_match_draft', { p_match: id, p_played_at: match!.played_at, p_team_a_name: teamA.trim() || null, p_team_b_name: teamB.trim() || null })).ok) {
      notify('Nomes dos times salvos');
      setReload((n) => n + 1);
    }
  }

  const salvarRascunho = () => call('save_match_sheet', { p_match: id, ...asArgs() });
  const asArgs = () => {
    const { participants, events } = sheetPayload(players, extras);
    return { p_participants: participants, p_events: events };
  };

  async function salvar() {
    if ((await salvarRascunho()).ok) notify('Súmula salva');
  }

  async function publicar() {
    if (!(await salvarRascunho()).ok) return;
    const { ok, data: r } = await call<{ status: string; eligible_voter_count: number }>(
      'publish_match',
      closeMode === 'fixed'
        ? { p_match: id, p_closes_at: new Date(Date.now() + fixedHours * 3600_000).toISOString() }
        : { p_match: id, p_duration_minutes: Number(duration) },
    );
    if (!ok) return;
    if (r.status === 'finalized')
      notify(
        'Partida finalizada sem votação',
        `Só ${r.eligible_voter_count} jogadores podem votar (mínimo 6). Contam só gols, assistências e presença.`,
      );
    router.replace({ pathname: '/partida/[id]', params: { id } });
  }

  async function corrigir() {
    const { ok, data: r } = await call<{ sheet_version: number; eligible_voters_changed: boolean }>('correct_match_sheet', {
      p_match: id,
      ...asArgs(),
      p_reason: reason,
    });
    if (!ok) return;
    notify(
      'Súmula corrigida',
      r.eligible_voters_changed
        ? 'A lista de quem vota mudou: a votação foi reiniciada.'
        : `Versão ${r.sheet_version}. Todos precisam conferir a súmula de novo.`,
    );
    router.replace({ pathname: '/partida/[id]', params: { id } });
  }

  function descartar() {
    confirm('Excluir rascunho?', 'A súmula será apagada. Isso não pode ser desfeito.', 'Excluir', async () => {
      if ((await call('discard_match_draft', { p_match: id })).ok)
        router.replace({ pathname: '/pelada/[id]', params: { id: match!.pelada_id } });
    });
  }

  if (!match) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }

  const me = members.find((m) => m.user_id === session?.user.id);
  if (!editable || !(me?.role === 'admin' || me?.role === 'assistant')) {
    return (
      <Screen>
        <Sub>Só admin ou assistentes editam a súmula, e só antes do resultado.</Sub>
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>{isCorrection ? 'Corrigir súmula' : 'Súmula'}</Title>
      <Sub>{fmtDate(match.played_at)}</Sub>
      {isDraft && <Chips options={DAYS} value={null} onChange={mudarData} />}
      {isDraft && premium && (
        <Card>
          <Body>Nomes dos times</Body>
          <Input autoCapitalize="words" placeholder="Time A" value={teamA} onChangeText={setTeamA} maxLength={40} />
          <Input autoCapitalize="words" placeholder="Time B" value={teamB} onChangeText={setTeamB} maxLength={40} />
          <Button title="Salvar nomes" kind="secondary" onPress={salvarNomes} loading={busy} disabled={teamA === match.team_a_name && teamB === match.team_b_name} />
        </Card>
      )}
      <Card>
        <Text style={{ fontSize: 22, fontWeight: '800', color: colors.deepBlue, textAlign: 'center' }}>
          {match.team_a_name} {score.A} x {score.B} {match.team_b_name}
        </Text>
        <Sub>O placar sai dos gols lançados abaixo.</Sub>
      </Card>

      {(['A', 'B'] as Team[]).map((t) => (
        <View key={t} style={{ gap: 8 }}>
          <Text style={{ fontWeight: '800', color: colors.deepBlue, marginTop: 8 }}>
            {t === 'A' ? match.team_a_name : match.team_b_name}
          </Text>
          {players
            .filter((p) => p.team === t)
            .map((p) => (
              <Card key={p.key}>
                <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
                  <Body>
                    {nameOf(p)}
                    {p.guest_id ? ' (convidado)' : ''}
                  </Body>
                  <Pressable onPress={() => remove(p.key)}>
                    <Text style={{ color: colors.danger, fontWeight: '600' }}>Tirar</Text>
                  </Pressable>
                </View>
                <Sub>{positionLabel(p.position)}</Sub>
                <Chips options={TEAMS} value={p.team} onChange={(v) => update(p.key, { team: v })} />
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 12, marginTop: 4 }}>
                  <Stepper label="Gols" value={p.goals} onChange={(v) => update(p.key, { goals: v })} />
                  <Stepper label="Assist." value={p.assists} onChange={(v) => update(p.key, { assists: v })} />
                  <Stepper label="Vermelho" value={p.reds} max={5} onChange={(v) => update(p.key, { reds: v })} />
                </View>
              </Card>
            ))}
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 12 }}>
            <Stepper label="Gol sem autor" value={extras.unattributed[t]} onChange={(v) => setExtra('unattributed', t, v)} />
            <Stepper label="Gol contra a favor" value={extras.ownGoals[t]} onChange={(v) => setExtra('ownGoals', t, v)} />
          </View>
        </View>
      ))}

      <Text style={{ fontWeight: '800', color: colors.deepBlue, marginTop: 12 }}>Adicionar quem jogou</Text>
      {benchMembers.length === 0 && <Sub>Todos os jogadores da pelada já estão na súmula.</Sub>}
      {benchMembers.map((m) => (
        <BenchRow key={m.id} name={m.player_name} sub={positionLabel(memberPosition(m))} onAdd={(t) => addMember(m, t)} />
      ))}

      <Text style={{ fontWeight: '800', color: colors.deepBlue, marginTop: 12 }}>Convidados</Text>
      <Sub>Posição do convidado ao adicionar:</Sub>
      <PositionPicker value={guestPos} onChange={setGuestPos} />
      {benchGuests.map((g) => (
        <BenchRow key={g.id} name={g.display_name} sub="Convidado" onAdd={(t) => addGuest(g, t)} />
      ))}
      <Input autoCapitalize="words" placeholder="nome do novo convidado" value={guestName} onChangeText={setGuestName} />
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
        <Switch value={guestAdult} onValueChange={setGuestAdult} trackColor={{ true: colors.blue }} />
        <Text style={{ flex: 1, color: colors.ink }}>Declaro que o convidado tem 18 anos ou mais.</Text>
      </View>
      <Button title="Adicionar convidado" kind="secondary" onPress={novoConvidado} disabled={guestName.trim().length < 1} loading={busy} />

      <View style={{ height: 12 }} />
      <ErrorText>{msg}</ErrorText>
      {isDraft ? (
        <>
          <Button title="Salvar rascunho" kind="secondary" onPress={salvar} loading={busy} />
          <Sub>Prazo da votação</Sub>
          {premium && (
            <Chips
              options={[
                { value: 'duration', label: 'Duração' },
                { value: 'fixed', label: 'Horário fixo' },
              ]}
              value={closeMode}
              onChange={setCloseMode}
            />
          )}
          {closeMode === 'duration' || !premium ? (
            <Chips options={DURATIONS} value={duration} onChange={setDuration} />
          ) : (
            <>
              <Stepper label="Encerra em (horas)" value={fixedHours} onChange={setFixedHours} min={1} max={24} />
              <Sub>A votação fecha {fixedHours === 1 ? '1 hora' : `${fixedHours} horas`} depois de publicar, no horário exato.</Sub>
            </>
          )}
          <Button title="Publicar e abrir votação" onPress={publicar} loading={busy} />
          <Button title="Excluir rascunho" kind="danger" onPress={descartar} />
        </>
      ) : (
        <>
          <Input autoCapitalize="sentences" placeholder="motivo da correção (obrigatório)" value={reason} onChangeText={setReason} />
          <Button title="Salvar correção" onPress={corrigir} loading={busy} disabled={reason.trim().length < 3} />
        </>
      )}
    </Screen>
  );
}

function BenchRow({ name, sub, onAdd }: { name: string; sub: string; onAdd: (t: Team) => void }) {
  return (
    <Card>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
        <View style={{ flex: 1 }}>
          <Body>{name}</Body>
          <Sub>{sub}</Sub>
        </View>
        <View style={{ flexDirection: 'row', gap: 8 }}>
          {(['A', 'B'] as Team[]).map((t) => (
            <Pressable
              key={t}
              onPress={() => onAdd(t)}
              style={{ paddingVertical: 8, paddingHorizontal: 12, borderRadius: 8, borderWidth: 1, borderColor: colors.blue }}>
              <Text style={{ color: colors.blue, fontWeight: '700' }}>+ {t}</Text>
            </Pressable>
          ))}
        </View>
      </View>
    </Card>
  );
}
