import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useMemo, useState } from 'react';
import { Pressable, Switch, View } from 'react-native';
import { Text } from '../../../lib/text';

import { confirm, notify } from '../../../lib/dialog';
import { DraftBanner } from '../../../lib/draftbanner';
import { clearDraft, draftKey, loadDraft, saveDraft } from '../../../lib/drafts';
import { SheetReview } from '../../../lib/sheetreview';
import { friendly } from '../../../lib/errors';
import {
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
  Team,
  TeamExtras,
} from '../../../lib/match';
import { useAuth } from '../../../lib/session';
import { supabase } from '../../../lib/supabase';
import { colors, memberPosition, Position, positionLabel } from '../../../lib/theme';
import { teamHex, TeamColorPicker } from '../../../lib/selection';
import { Ball } from '../../../lib/ball';
import { MatchRoles } from '../../../lib/matchroles';
import { Collapsible } from '../../../lib/collapsible';
import { StepSlider } from '../../../lib/stepslider';
import {
  filledLost,
  goalProblems,
  GoalRec,
  goalsFromSheet,
  goalsToSheet,
  resizeGoals,
  scoreOf,
} from '../../../lib/goals';
import { requestId } from '../../../lib/ids';
import { idempotent, REVIEW_CODE } from '../../../lib/v85';
import { Body, Button, Card, Chips, ErrorText, Input, LoadingBlock, PositionPicker, Screen, Stepper, Sub, Title } from '../../../lib/ui';

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
  // REV-138: o placar é a quantidade de gols; cada gol tem autor (ou gol contra) e assistência opcional.
  const [goals, setGoals] = useState<GoalRec[]>([]);
  const [colorsAB, setColorsAB] = useState<{ A: string | null; B: string | null }>({ A: null, B: null });
  const [reason, setReason] = useState('');
  const [duration, setDuration] = useState<'120' | '240' | '360'>('240');
  const [guestName, setGuestName] = useState('');
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
  // REV-041: revisão antes de publicar/corrigir; REV-044: rascunho local das mudanças ainda não salvas.
  const [review, setReview] = useState<'publish' | 'correct' | null>(null);
  const [original, setOriginal] = useState<SheetPlayer[] | null>(null);
  const [originalGoals, setOriginalGoals] = useState('[]');
  const [localDraft, setLocalDraft] = useState<{ players: SheetPlayer[]; goals: GoalRec[] } | null>(null);
  const dKey = session ? draftKey(session.user.id, `sumula:${id}`) : null;
  // V8.5: versão do rascunho no servidor (salvamento sem sobrescrita obsoleta), escalação prevista e
  // confirmação coletiva de quem jogou (Etapas 2, 14, 21) e revisão do servidor (Etapa 15).
  type Planned = { pid: string; membership_id: string | null; guest_id: string | null; guest: boolean; name: string; team: Team; position: string | null; eligible: boolean };
  const [draftVersion, setDraftVersion] = useState<number | null>(null);
  const [planned, setPlanned] = useState<Planned[]>([]);
  const [confirmed, setConfirmed] = useState(true);
  const [present, setPresent] = useState<Record<string, { on: boolean; team: Team; position: string | null }>>({});
  const [serverReview, setServerReview] = useState<{ blocking: string[]; warnings: { code: string; count?: number }[] } | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const m = await loadMatch(id);
        if (!alive) return;
        if (!m) return setMsg('Partida não encontrada.');
        const [ms, gs, sheet, { data: st }, { data: ent }, { data: cols }] = await Promise.all([
          loadMembers(m.pelada_id),
          loadGuests(m.pelada_id),
          loadSheet(id),
          supabase.from('pelada_settings').select('voting_duration_minutes').eq('pelada_id', m.pelada_id).maybeSingle(),
          supabase.rpc('get_pelada_entitlement', { p_pelada: m.pelada_id }),
          supabase.from('matches').select('team_a_color, team_b_color').eq('id', id).maybeSingle(),
        ]);
        if (!alive) return;
        setColorsAB({ A: cols?.team_a_color ?? null, B: cols?.team_b_color ?? null });
        // Prazo padrão escolhido nas configurações da pelada.
        if (st) setDuration(String(st.voting_duration_minutes) as '120' | '240' | '360');
        setPremium(!!(ent as { is_premium?: boolean } | null)?.is_premium);
        setTeamA(m.team_a_name);
        setTeamB(m.team_b_name);
        setMatch(m);
        if (m.status === 'draft') {
          const { data: det } = await supabase.rpc('get_match_detail_v85', { p_match: id });
          if (!alive) return;
          const d = det as { draft_version: number; planned: Planned[] | null; participation_confirmed: boolean } | null;
          setDraftVersion(d?.draft_version ?? null);
          setPlanned(d?.planned ?? []);
          setConfirmed(!d?.planned?.length || d.participation_confirmed);
          setPresent(Object.fromEntries((d?.planned ?? []).map((x) => [x.pid, { on: x.eligible, team: x.team, position: x.position }])));
        }
        setMembers(ms);
        setGuests(gs);
        const teamByKey = new Map(sheet.players.map((p) => [p.key, p.team]));
        const loaded = goalsFromSheet(sheet.players, sheet.extras, sheet.ownCulprits, (k) => teamByKey.get(k));
        setPlayers(sheet.players);
        setGoals(loaded);
        setOriginal(sheet.players);
        setOriginalGoals(JSON.stringify(loaded.map(({ id: _id, ...g }) => g)));
        if (dKey) {
          const d = await loadDraft<{ players: SheetPlayer[]; goals?: GoalRec[] }>(dKey);
          const same = d && JSON.stringify(d.players) === JSON.stringify(sheet.players) && JSON.stringify(d.goals ?? []) === JSON.stringify(loaded);
          if (alive && d && d.goals && !same) setLocalDraft({ players: d.players, goals: d.goals });
        }
      } catch (e) {
        if (alive) setMsg(friendly((e as Error).message));
      }
    })();
    return () => {
      alive = false;
    };
  }, [id, reload, dKey]);

  // Grava o rascunho local a cada mudança (só no aparelho; nunca publica nada).
  const goalsKey = JSON.stringify(goals.map(({ id: _id, ...g }) => g));
  useEffect(() => {
    if (!dKey || !original || localDraft) return;
    if (JSON.stringify(players) === JSON.stringify(original) && goalsKey === originalGoals) return;
    const t = setTimeout(() => saveDraft(dKey, { players, goals }), 500);
    return () => clearTimeout(t);
  }, [dKey, players, goals, goalsKey, originalGoals, original, localDraft]);

  const isDraft = match?.status === 'draft';
  const isCorrection = match?.status === 'voting_open';
  const editable = isDraft || isCorrection;
  const score = scoreOf(goals);
  // Gols e assistências por jogador saem dos registros de gol (REV-138); o resto da súmula (cartões, times) vem de `players`.
  const sheet = useMemo(() => {
    const g = goalsToSheet(goals);
    const ps = players.map((p) => ({ ...p, goals: g.goalsBy[p.key] ?? 0, assists: g.assistsBy[p.key] ?? 0 }));
    const ex: TeamExtras = { unattributed: g.unattributed, ownGoals: g.ownLoose };
    return { players: ps, extras: ex, culprits: g.culprits };
  }, [goals, players]);
  const problems = goalProblems(goals);
  const memberById = useMemo(() => new Map(members.map((m) => [m.id, m])), [members]);
  const guestById = useMemo(() => new Map(guests.map((g) => [g.id, g])), [guests]);
  const nameOf = (p: SheetPlayer) =>
    p.membership_id ? (memberById.get(p.membership_id)?.player_name ?? 'Jogador') : (guestById.get(p.guest_id!)?.display_name ?? 'Convidado');
  // REV-146: o goleiro temporário é definido aqui, no fluxo da súmula, só entre quem já está gravado nela.
  const keeperPlayers = useMemo(
    () =>
      players
        .filter((p) => p.participant_id)
        .map((p) => ({ participant_id: p.participant_id!, membership_id: p.membership_id ?? null, team: p.team, position: p.position, name: nameOf(p) })),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [players, members, guests],
  );
  const inSheet = new Set(players.map((p) => p.key));
  const benchMembers = members.filter((m) => m.status === 'active' && !inSheet.has(`m:${m.id}`));
  const benchGuests = guests.filter((g) => !inSheet.has(`g:${g.id}`));

  const update = (key: string, patch: Partial<SheetPlayer>) =>
    setPlayers((ps) => ps.map((p) => (p.key === key ? { ...p, ...patch } : p)));
  // Quem sai da súmula também sai dos gols que citavam essa pessoa (o registro do gol continua, sem autor).
  const remove = (key: string) => {
    setPlayers((ps) => ps.filter((p) => p.key !== key));
    setGoals((gs) =>
      gs.map((g) => ({
        ...g,
        author: g.author === key ? null : g.author,
        assist: g.assist === key ? null : g.assist,
        culprit: g.culprit === key ? null : g.culprit,
      })),
    );
  };
  const changeGoal = (id: string, patch: Partial<GoalRec>) => setGoals((gs) => gs.map((g) => (g.id === id ? { ...g, ...patch } : g)));
  // Trocar o time de um jogador desfaz as ligações dele com gols do time antigo.
  const changeTeam = (key: string, team: Team) => {
    update(key, { team });
    setGoals((gs) =>
      gs.map((g) => ({
        ...g,
        author: g.author === key && g.team !== team ? null : g.author,
        assist: g.assist === key && g.team !== team ? null : g.assist,
        culprit: g.culprit === key && g.team === team ? null : g.culprit,
      })),
    );
  };
  function changeScore(team: Team, n: number) {
    const v = Math.max(0, Math.min(30, n));
    const lost = filledLost(goals, team, v);
    const apply = () => setGoals((gs) => resizeGoals(gs, team, v));
    if (lost > 0) confirm('Diminuir o placar?', `${lost === 1 ? '1 gol preenchido será removido' : `${lost} gols preenchidos serão removidos`}.`, 'Diminuir', apply);
    else apply();
  }
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
    // REV-140: a maioridade do convidado é declarada pelo administrador/assistente no aceite dos Termos (cláusula 4.7);
    // aqui o app apenas registra essa declaração (p_adult_declared) por convidado, sem pedir confirmação na súmula.
    const { ok, data: gid } = await call<string>('create_guest', {
      p_pelada: match!.pelada_id,
      p_name: guestName,
      p_adult_declared: true,
    });
    if (!ok) return;
    const g = { id: gid, display_name: guestName.trim() };
    setGuests((gs) => [...gs, g]);
    setGuestName('');
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

  // Etapa 21: salva com a versão vista e request_id; se a resposta se perder, recupera o resultado gravado.
  const salvarRascunho = async () => {
    if (!isDraft) return call('save_match_sheet', { p_match: id, ...asArgs() });
    const rid = requestId();
    setBusy(true);
    setMsg(null);
    const r = await idempotent(
      async () => await supabase.rpc('save_match_sheet_v85', { p_match: id, p_expected: draftVersion, ...asArgs(), p_request: rid }),
      async () => (await supabase.rpc('get_v85_operation', { p_request: rid })) as never,
    );
    setBusy(false);
    if (r.error) {
      setMsg(friendly(r.error.message));
      // Versão antiga: o rascunho local fica guardado no aparelho; a tela busca a versão atual.
      if (/VERSION_CONFLICT/.test(r.error.message)) setReload((n) => n + 1);
      return { ok: false, data: null };
    }
    setDraftVersion((r.data as { draft_version: number }).draft_version);
    return { ok: true, data: r.data };
  };

  async function confirmarParticipacao() {
    const list = planned
      .filter((x) => present[x.pid]?.on)
      .map((x) =>
        x.guest_id
          ? { guest_id: x.guest_id, team: present[x.pid].team, position: present[x.pid].position }
          : { membership_id: x.membership_id, team: present[x.pid].team },
      );
    const rid = requestId();
    setBusy(true);
    setMsg(null);
    const r = await idempotent(
      async () => await supabase.rpc('confirm_match_participation', { p_match: id, p_expected: draftVersion, p_present: list, p_request: rid }),
      async () => (await supabase.rpc('get_v85_operation', { p_request: rid })) as never,
    );
    setBusy(false);
    if (r.error) return setMsg(friendly(r.error.message));
    notify('Participação confirmada', 'Agora complete placar, gols e assistências. Confirmar não publica nem abre votação.');
    setReload((n) => n + 1);
  }

  async function revisarNoServidor() {
    const { data, error } = await supabase.rpc('get_match_sheet_review', { p_match: id });
    if (error) return setMsg(friendly(error.message));
    setServerReview(data as { blocking: string[]; warnings: { code: string; count?: number }[] });
  }
  const asArgs = () => {
    const { participants, events } = sheetPayload(sheet.players, sheet.extras, sheet.culprits);
    return { p_participants: participants, p_events: events };
  };

  async function salvar() {
    if ((await salvarRascunho()).ok) {
      if (dKey) await clearDraft(dKey);
      setOriginal(players);
      setOriginalGoals(goalsKey);
      notify('Súmula salva');
    }
  }

  async function publicar() {
    // REV-138: nenhum gol sem autor; o servidor também bloqueia (get_match_sheet_review).
    if (problems.length) return setMsg(problems[0]);
    if (!(await salvarRascunho()).ok) return;
    const { data: rv } = await supabase.rpc('get_match_sheet_review', { p_match: id });
    const blocking = ((rv as { blocking?: string[] } | null)?.blocking ?? []) as string[];
    if (blocking.length) {
      setServerReview(rv as { blocking: string[]; warnings: { code: string }[] });
      return setMsg(blocking.map((b) => REVIEW_CODE[b] ?? b).join(' '));
    }
    const { ok, data: r } = await call<{ status: string; eligible_voter_count: number }>(
      'publish_match',
      closeMode === 'fixed'
        ? { p_match: id, p_closes_at: new Date(Date.now() + fixedHours * 3600_000).toISOString() }
        : { p_match: id, p_duration_minutes: Number(duration) },
    );
    if (!ok) return;
    if (dKey) await clearDraft(dKey);
    if (r.status === 'finalized')
      notify(
        'Partida finalizada sem votação',
        `Só ${r.eligible_voter_count} jogadores podem votar (mínimo 6). Contam só gols, assistências e presença.`,
      );
    router.replace({ pathname: '/partida/[id]', params: { id } });
  }

  async function corrigir() {
    if (problems.length) return setMsg(problems[0]);
    const { ok, data: r } = await call<{ sheet_version: number; eligible_voters_changed: boolean }>('correct_match_sheet', {
      p_match: id,
      ...asArgs(),
      p_reason: reason,
    });
    if (!ok) return;
    if (dKey) await clearDraft(dKey);
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
        {!msg && <LoadingBlock />}
      </Screen>
    );
  }

  const teamOpts = [
    { value: 'A', label: match.team_a_name },
    { value: 'B', label: match.team_b_name },
  ] as const;
  const bench = { A: teamHex(colorsAB.A) ?? colors.blue, B: teamHex(colorsAB.B) ?? colors.gold };
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
      {isDraft && !confirmed && (
        <Card>
          <Body>Quem jogou?</Body>
          <Sub>Escalação prevista não é presença. Desmarque quem não entrou em campo; quem não entrou não conta. Para incluir substitutos, confirme e adicione na súmula.</Sub>
          {planned.map((x) => {
            const st = present[x.pid] ?? { on: false, team: x.team, position: x.position };
            return (
              <View key={x.pid} style={{ gap: 4 }}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                  <Switch value={st.on} disabled={!x.eligible} onValueChange={(on) => setPresent((p) => ({ ...p, [x.pid]: { ...st, on } }))} />
                  <Text style={{ flex: 1, color: x.eligible ? colors.ink : colors.danger }} numberOfLines={1}>
                    {x.name}
                    {x.guest ? ' (convidado)' : ''}
                    {!x.eligible ? ' · não faz mais parte' : ''}
                  </Text>
                  <Chips options={teamOpts} value={st.team} onChange={(team) => setPresent((p) => ({ ...p, [x.pid]: { ...st, team } }))} />
                </View>
                {x.guest && st.on && !x.position && (
                  <>
                    <Sub>Posição em que o convidado jogou</Sub>
                    <PositionPicker value={st.position} onChange={(pos) => setPresent((p) => ({ ...p, [x.pid]: { ...st, position: pos } }))} />
                  </>
                )}
              </View>
            );
          })}
          <Button title="Confirmar quem jogou" onPress={confirmarParticipacao} loading={busy} />
        </Card>
      )}
      {serverReview && (
        <Card>
          <Body>Revisão</Body>
          {serverReview.blocking.map((b) => (
            <Text key={b} style={{ color: colors.danger }}>
              • {REVIEW_CODE[b] ?? b}
            </Text>
          ))}
          {serverReview.warnings.map((w) => (
            <Text key={w.code} style={{ color: colors.darkGold }}>
              • {REVIEW_CODE[w.code] ?? w.code}
              {w.count ? ` (${w.count})` : ''}
            </Text>
          ))}
          {!serverReview.blocking.length && !serverReview.warnings.length && <Sub>Tudo certo para publicar.</Sub>}
        </Card>
      )}
      {isDraft && confirmed && <Button title="Revisar antes de publicar" kind="ghost" onPress={revisarNoServidor} />}
      {localDraft && (
        <DraftBanner
          onResume={() => {
            setPlayers(localDraft.players);
            setGoals(localDraft.goals);
            setLocalDraft(null);
          }}
          onDiscard={async () => {
            setLocalDraft(null);
            if (dKey) await clearDraft(dKey);
          }}
        />
      )}
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
        <TeamColorPicker matchId={id} teamA={match.team_a_name} teamB={match.team_b_name} onSaved={setColorsAB} />
      </Card>
      <Card>
        <Body>Placar</Body>
        <View style={{ flexDirection: 'row', gap: 16, justifyContent: 'space-between' }}>
          {(['A', 'B'] as Team[]).map((t) => (
            <View key={t} style={{ flex: 1, alignItems: 'center', gap: 6 }}>
              <Text style={{ fontWeight: '700', color: colors.ink }} numberOfLines={1}>
                {t === 'A' ? match.team_a_name : match.team_b_name}
              </Text>
              <Stepper label="Gols" value={score[t]} onChange={(v) => changeScore(t, v)} min={0} max={30} />
            </View>
          ))}
        </View>
      </Card>

      {goals.map((g, i) => {
        const mine = sheet.players.filter((p) => p.team === g.team);
        const rivals = sheet.players.filter((p) => p.team !== g.team);
        const opts = (list: SheetPlayer[]) => list.map((p) => ({ value: p.key, label: nameOf(p) }));
        return (
          <Card key={g.id}>
            <Body>{'Gol ' + (i + 1) + ' · ' + (g.team === 'A' ? match.team_a_name : match.team_b_name)}</Body>
            <Sub>Quem fez</Sub>
            <Chips
              options={[...opts(mine), { value: 'OWN', label: 'Gol contra' }]}
              value={g.own ? 'OWN' : g.author}
              onChange={(v) =>
                changeGoal(g.id, v === 'OWN' ? { own: true, author: null, assist: null } : { own: false, author: v, culprit: null, assist: g.assist === v ? null : g.assist })
              }
            />
            {g.own ? (
              <>
                <Sub>Jogador adversário responsável</Sub>
                <Chips options={opts(rivals)} value={g.culprit} onChange={(v) => changeGoal(g.id, { culprit: v })} />
              </>
            ) : (
              <>
                <Sub>Assistência (opcional)</Sub>
                <Chips
                  options={[...opts(mine.filter((p) => p.key !== g.author)), { value: 'NONE', label: 'Sem assistência' }]}
                  value={g.assist ?? 'NONE'}
                  onChange={(v) => changeGoal(g.id, { assist: v === 'NONE' ? null : v })}
                />
              </>
            )}
          </Card>
        );
      })}

      {(['A', 'B'] as Team[]).map((t) => (
        <View key={t} style={{ gap: 8 }}>
          <Text style={{ fontWeight: '800', color: colors.ink, marginTop: 8 }}>
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
                  <Pressable
                    onPress={() => remove(p.key)}
                    accessibilityRole="button"
                    accessibilityLabel={`Tirar ${nameOf(p)} da súmula`}
                    hitSlop={8}
                    style={{ minHeight: 44, minWidth: 44, alignItems: 'flex-end', justifyContent: 'center' }}>
                    <Text style={{ color: colors.danger, fontWeight: '600' }}>Tirar</Text>
                  </Pressable>
                </View>
                <Sub>{positionLabel(p.position)}</Sub>
                <Chips options={teamOpts} value={p.team} onChange={(v) => changeTeam(p.key, v)} />
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 12, marginTop: 4 }}>
                  <Stepper label="Amarelo" value={p.yellows ?? 0} max={1} onChange={(v) => update(p.key, { yellows: v })} />
                  {/* V5: expulsão por segundo amarelo = uma penalidade de vermelho (não lance os dois amarelos). */}
                  <Stepper label="2º amarelo" value={p.secondYellow ?? 0} max={1} onChange={(v) => update(p.key, { secondYellow: v })} />
                  <Stepper label="Vermelho" value={p.reds} max={5} onChange={(v) => update(p.key, { reds: v })} />
                </View>
              </Card>
            ))}
        </View>
      ))}

      {isDraft && confirmed && keeperPlayers.length > 0 && (
        <MatchRoles mode="sheet" matchId={id} staff myMembershipId={null} players={keeperPlayers} teamNames={{ A: match.team_a_name, B: match.team_b_name }} />
      )}

      <Text style={{ fontWeight: '800', color: colors.ink, marginTop: 12 }}>Adicionar quem jogou</Text>
      {benchMembers.length === 0 && <Sub>Todos os jogadores da pelada já estão na súmula.</Sub>}
      {benchMembers.map((m) => (
        <BenchRow key={m.id} name={m.player_name} sub={positionLabel(memberPosition(m))} onAdd={(t) => addMember(m, t)} hex={bench} names={[match.team_a_name, match.team_b_name]} />
      ))}

      {/* REV-140: recolhida a cada abertura da súmula; recolher não apaga nada. */}
      <Collapsible title="Incluir Convidados">
        <View style={{ gap: 8, paddingBottom: 8 }}>
          <Sub>Posição do convidado ao adicionar:</Sub>
          <PositionPicker value={guestPos} onChange={setGuestPos} />
          {benchGuests.map((g) => (
            <BenchRow key={g.id} name={g.display_name} sub="Convidado" onAdd={(t) => addGuest(g, t)} hex={bench} names={[match.team_a_name, match.team_b_name]} />
          ))}
          <Input autoCapitalize="words" placeholder="nome do novo convidado" value={guestName} onChangeText={setGuestName} />
          <Button title="Adicionar convidado" kind="secondary" onPress={novoConvidado} disabled={guestName.trim().length < 1} loading={busy} />
        </View>
      </Collapsible>

      <View style={{ height: 12 }} />
      {problems.length > 0 && <Sub>{problems[0] + (problems.length > 1 ? ` (+${problems.length - 1})` : '')}</Sub>}
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
            <StepSlider label="Prazo da votação" options={DURATIONS} value={duration} onChange={setDuration} />
          ) : (
            <>
              <Stepper label="Encerra em (horas)" value={fixedHours} onChange={setFixedHours} min={1} max={24} />
              <Sub>A votação fecha {fixedHours === 1 ? '1 hora' : `${fixedHours} horas`} depois de publicar, no horário exato.</Sub>
            </>
          )}
          {review === 'publish' ? (
            <SheetReview teamA={match.team_a_name} teamB={match.team_b_name} score={score} players={sheet.players} before={null} nameOf={nameOf}
              correction={false} busy={busy} onConfirm={publicar} onBack={() => setReview(null)} />
          ) : (
            <Button title="Revisar e publicar" onPress={() => setReview('publish')} loading={busy} />
          )}
          <Button title="Excluir rascunho" kind="danger" onPress={descartar} />
        </>
      ) : (
        <>
          <Input autoCapitalize="sentences" placeholder="motivo da correção (obrigatório)" value={reason} onChangeText={setReason} />
          {review === 'correct' ? (
            <SheetReview teamA={match.team_a_name} teamB={match.team_b_name} score={score} players={sheet.players} before={original} nameOf={nameOf}
              correction busy={busy} onConfirm={corrigir} onBack={() => setReview(null)} />
          ) : (
            <Button title="Revisar correção" onPress={() => setReview('correct')} loading={busy} disabled={reason.trim().length < 3} />
          )}
        </>
      )}
    </Screen>
  );
}

function BenchRow({ name, sub, onAdd, hex, names }: { name: string; sub: string; onAdd: (t: Team) => void; hex: { A: string; B: string }; names: [string, string] }) {
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
              accessibilityRole="button"
              accessibilityLabel={`Escalar ${name} no time ${t === 'A' ? names[0] : names[1]}`}
              style={{ minHeight: 44, minWidth: 44, alignItems: 'center', justifyContent: 'center' }}>
              <Ball color={hex[t]} />
            </Pressable>
          ))}
        </View>
      </View>
    </Card>
  );
}
