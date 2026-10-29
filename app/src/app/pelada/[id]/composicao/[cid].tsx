// V8.5 — Escalação oficial (composição versionada).
// Jogadores: só a versão vigente (Etapa 36 A) e as imagens. Administração: ajustes manuais atômicos (incluir,
// remover, substituir, transferir, trocar, capitães) sem redistribuição nem alerta de equilíbrio (Etapa 32 A),
// pré-cadastro das partidas, cópia como ponto de partida, campo ilustrativo (rascunho → publicação) e histórico.
// O campo e as imagens nunca mudam equipe, posição oficial, presença ou estatística.
import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useMemo, useRef, useState } from 'react';
import { Pressable, View } from 'react-native';

import { SharePanel } from '../../../../lib/arts';
import { Collapsible } from '../../../../lib/collapsible';
import { confirm, notify } from '../../../../lib/dialog';
import { friendly } from '../../../../lib/errors';
import { requestId } from '../../../../lib/ids';
import { LineupBoard } from '../../../../lib/lineup';
import { supabase } from '../../../../lib/supabase';
import { Text } from '../../../../lib/text';
import { colors, positionLabel } from '../../../../lib/theme';
import { Body, Button, Card, ErrorText, Input, LoadingBlock, Screen, Sub, Title } from '../../../../lib/ui';
import {
  autoPositions,
  checkPages,
  clampPoint,
  type Composition,
  createGate,
  displayNames,
  idempotent,
  nameHints,
  overlaps,
  paginateField,
  paginateList,
  type Positions,
  type SharePayload,
  summaryText,
} from '../../../../lib/v85';
import { FieldArt, FieldDrawing, ListArt } from '../../../../lib/v85art';

type Layout = { version: number; published_seq: number | null; needs_review: boolean; positions: Positions; missing: string[] } | null;
type FieldState = { composition_version: number; published: Layout; draft: Layout };
type Member = { id: string; player_name: string; position_code: string | null; preferred_position: string };
type HistoryOp = { version: number; op_type: string; created_at: string; actor_name: string | null };

const OP_LABEL: Record<string, string> = { created: 'Escalação criada', manual_ops: 'Ajuste manual' };

/** "dd/mm/aaaa hh:mm" → ISO (horário local do aparelho). */
function parseLocal(s: string): string | null {
  const m = s.trim().match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2})$/);
  if (!m) return null;
  const d = new Date(Number(m[3]), Number(m[2]) - 1, Number(m[1]), Number(m[4]), Number(m[5]));
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

export default function ComposicaoScreen() {
  const { id, cid } = useLocalSearchParams<{ id: string; cid: string }>();
  const router = useRouter();
  const gate = useRef(createGate()).current;
  const [comp, setComp] = useState<Composition | null>(null);
  const [staff, setStaff] = useState(false);
  const [field, setField] = useState<FieldState | null>(null);
  const [pelada, setPelada] = useState<{ name: string; crest_path: string | null } | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [history, setHistory] = useState<HistoryOp[] | null>(null);
  const [pick, setPick] = useState<string | null>(null);
  const [subFor, setSubFor] = useState<string | null>(null);
  const [positions, setPositions] = useState<Positions | null>(null);
  const [fieldPick, setFieldPick] = useState<string | null>(null);
  const [dates, setDates] = useState<Record<number, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  const load = useCallback(async () => {
    const ok = gate.next('load');
    const [{ data: cs, error }, { data: f }, { data: p }, { data: ms }] = await Promise.all([
      supabase.rpc('get_team_compositions', { p_pelada: id }),
      supabase.rpc('get_field_layout', { p_comp: cid }),
      supabase.from('peladas').select('name, crest_path').eq('id', id).maybeSingle(),
      supabase.from('pelada_memberships').select('id, player_name, position_code, preferred_position').eq('pelada_id', id).eq('status', 'active').order('player_name'),
    ]);
    if (!ok()) return;
    if (error) return setMsg(friendly(error.message));
    const c = ((cs ?? []) as Composition[]).find((x) => x.id === cid) ?? null;
    setComp(c);
    setStaff(!!c?.summary); // o resumo só vem para quem administra
    setField((f ?? null) as FieldState | null);
    setPelada(p);
    setMembers((ms ?? []) as Member[]);
    setPositions(null);
    if (c?.summary) {
      const { data: h } = await supabase.rpc('get_composition_history', { p_comp: cid });
      if (ok()) setHistory(((h as { operations: HistoryOp[] } | null)?.operations ?? []) as HistoryOp[]);
    }
  }, [id, cid, gate]);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  const hints = useMemo(() => (comp ? nameHints(comp.members) : {}), [comp]);
  const names = useMemo(() => (comp ? displayNames(comp.members) : {}), [comp]);

  if (!comp) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <LoadingBlock />}
      </Screen>
    );
  }

  async function ops(key: string, list: Record<string, unknown>[]) {
    if (!comp) return;
    const rid = requestId();
    setBusy(key);
    setMsg(null);
    const r = await idempotent(
      async () => await supabase.rpc('apply_composition_ops', { p_comp: comp.id, p_expected: comp.version, p_ops: list, p_request: rid }),
      async () => (await supabase.rpc('get_v85_operation', { p_request: rid })) as never,
    );
    setBusy(null);
    setPick(null);
    setSubFor(null);
    if (r.error) {
      setMsg(friendly(r.error.message));
      if (/VERSION_CONFLICT/.test(r.error.message)) load();
      return;
    }
    const c = r.data as Composition;
    if (c.notices?.some((n) => n.notice === 'ALREADY_IN_COMPOSITION')) notify('Já estava na escalação', 'A mesma pessoa foi mantida uma vez só.');
    await load();
  }

  const sel = comp.members.find((m) => m.pid === pick) ?? null;
  const inComp = new Set(comp.members.map((m) => m.membership_id).filter(Boolean));
  const free = members.filter((m) => !inComp.has(m.id));
  const s = comp.summary ? summaryText(comp.summary) : null;
  const versionLabel = `${comp.label} · versão ${comp.version}`;
  const dateLabel = comp.round_date ? new Date(comp.round_date).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : null;

  // ----- campo -----
  const base = field?.draft ?? field?.published ?? null;
  const shownPositions = positions ?? autoPositions(comp.members, base?.positions ?? {});
  const flagged = new Set(overlaps(shownPositions).flat());

  async function saveDraft(publish: boolean) {
    if (!comp || !field) return;
    setBusy(publish ? 'publish' : 'draft');
    setMsg(null);
    const { data: d, error } = await supabase.rpc('save_field_draft', { p_comp: comp.id, p_expected: field.draft?.version ?? null, p_positions: shownPositions });
    if (error) {
      setBusy(null);
      setMsg(friendly(error.message));
      if (/VERSION_CONFLICT/.test(error.message)) load();
      return;
    }
    if (publish) {
      const rid = requestId();
      const { error: pe } = await supabase.rpc('publish_field_layout', {
        p_comp: comp.id,
        p_expected_draft: (d as { version: number }).version,
        p_expected_seq: field.published?.published_seq ?? null,
        p_request: rid,
      });
      if (pe) {
        setBusy(null);
        setMsg(friendly(pe.message));
        await load();
        return;
      }
      notify('Campo publicado', 'A pelada já vê esta disposição. Times e posições oficiais não mudaram.');
    }
    setBusy(null);
    await load();
  }

  // ----- imagens: conferência antes de liberar cada arquivo -----
  const listPages = paginateList(comp.members);
  const fieldPages = paginateField(comp.members);
  const fieldPositions = field?.published?.positions ?? autoPositions(comp.members);
  async function validate(pageMembers: { pid: string; team: 'A' | 'B'; captain: boolean }[][]) {
    const { data, error } = await supabase.rpc('get_share_payload', { p_comp: comp!.id });
    if (error) return friendly(error.message);
    const payload = data as SharePayload;
    const issues = checkPages(
      payload,
      pageMembers.map((m) => ({ members: m, version: comp!.version, stamp: payload.stamp })),
    );
    if (payload.composition_version !== comp!.version || issues.length) {
      load();
      return 'A escalação mudou ou a imagem ficou incompleta. Atualizamos a tela: gere a imagem de novo.';
    }
    return null;
  }
  const allListMembers = listPages.map((p) => [...p.A, ...p.B]);

  return (
    <Screen>
      <Title>{comp.label}</Title>
      <Sub>
        {[dateLabel, comp.source === 'draw' ? 'sorteio' : comp.source === 'copy' ? 'cópia de escalação anterior' : 'montada à mão', `versão ${comp.version}`]
          .filter(Boolean)
          .join(' · ')}
      </Sub>
      <Card>
        <LineupBoard
          teamA={comp.team_a_name}
          teamB={comp.team_b_name}
          players={comp.members.map((m) => ({
            key: m.pid,
            team: m.team,
            name: `${m.name}${m.captain ? ' (C)' : ''}${hints[m.pid] ? ` · ${hints[m.pid]}` : ''}`,
            position: m.position,
            avatar_path: m.avatar_path,
            guest: m.guest,
          }))}
        />
        {s && (
          <>
            <Text style={{ color: colors.deepBlue, fontWeight: '700' }}>{s.headline.replace(' · posições equilibradas', '')}</Text>
            <Collapsible title="Posições por time">
              {s.lines.map((l) => (
                <Text key={l} style={{ color: colors.muted, fontSize: 13 }}>
                  {l}
                </Text>
              ))}
            </Collapsible>
          </>
        )}
        <Sub>Escalação prevista: quem jogou de fato é confirmado na súmula.</Sub>
      </Card>

      {staff && (
        <>
          <Text style={section}>Ajustar</Text>
          <Sub>Toque num jogador para escolher o que fazer.</Sub>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
            {comp.members.map((m) => (
              <Pressable
                key={m.pid}
                onPress={() => setPick(pick === m.pid ? null : m.pid)}
                style={{ paddingHorizontal: 10, paddingVertical: 6, borderRadius: 14, borderWidth: 1, borderColor: pick === m.pid ? colors.blue : colors.line, backgroundColor: m.team === 'A' ? colors.bg : colors.white }}>
                <Text style={{ fontSize: 12, color: m.eligible ? colors.ink : colors.danger }}>
                  {m.team} · {m.name}
                  {m.captain ? ' (C)' : ''}
                </Text>
              </Pressable>
            ))}
          </View>
          {sel && (
            <Card>
              <Body>
                {sel.name} · {sel.team === 'A' ? comp.team_a_name : comp.team_b_name}
              </Body>
              {!sel.captain && <Button title="Passar para o outro time" kind="secondary" loading={busy === 'transfer'} onPress={() => ops('transfer', [{ op: 'transfer', pid: sel.pid }])} />}
              {!sel.captain && (
                <Sub>Trocar com alguém do outro time: toque nele abaixo.</Sub>
              )}
              {!sel.captain && (
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
                  {comp.members
                    .filter((m) => m.team !== sel.team && !m.captain)
                    .map((m) => (
                      <Button key={m.pid} title={`Trocar com ${m.name}`} kind="ghost" onPress={() => ops('swap', [{ op: 'swap', a: sel.pid, b: m.pid }])} />
                    ))}
                </View>
              )}
              <Button title="Substituir por outro jogador" kind="secondary" onPress={() => setSubFor(sel.pid)} />
              {comp.captains_enabled && !sel.captain && (
                <Button
                  title={`Tornar capitão do ${sel.team === 'A' ? comp.team_a_name : comp.team_b_name}`}
                  kind="secondary"
                  onPress={() => {
                    const other = comp.members.find((m) => m.captain && m.team !== sel.team);
                    ops('cap', [{ op: 'captains', a: sel.team === 'A' ? sel.pid : (other?.pid ?? null), b: sel.team === 'B' ? sel.pid : (other?.pid ?? null) }]);
                  }}
                />
              )}
              {comp.captains_enabled && <Button title="Desativar capitães" kind="ghost" onPress={() => ops('cap', [{ op: 'captains', a: null, b: null }])} />}
              {!sel.captain && (
                <Button
                  title="Remover da escalação"
                  kind="danger"
                  onPress={() => confirm('Remover da escalação?', 'Ninguém é redistribuído automaticamente. O histórico fica guardado.', 'Remover', () => ops('remove', [{ op: 'remove', pid: sel.pid }]))}
                />
              )}
            </Card>
          )}
          {subFor && (
            <Card>
              <Body>Substituto (mesmo time)</Body>
              {free.map((m) => (
                <Button key={m.id} title={`${m.player_name} · ${positionLabel(m.position_code ?? m.preferred_position)}`} kind="ghost" onPress={() => ops('sub', [{ op: 'substitute', out: subFor, membership_id: m.id }])} />
              ))}
              <Button title="Cancelar" kind="secondary" onPress={() => setSubFor(null)} />
            </Card>
          )}
          {!sel && !subFor && free.length > 0 && (
            <Collapsible title={`Incluir jogador (${free.length} fora)`}>
              <Sub>Sem time escolhido, vai para o time com menos jogadores.</Sub>
              {free.map((m) => (
                <Button key={m.id} title={`${m.player_name} · ${positionLabel(m.position_code ?? m.preferred_position)}`} kind="ghost" loading={busy === `add-${m.id}`} onPress={() => ops(`add-${m.id}`, [{ op: 'add', membership_id: m.id }])} />
              ))}
            </Collapsible>
          )}

          <Text style={section}>Partidas</Text>
          <Sub>Cria a partida de cada rodada em rascunho, com esta escalação prevista. Não registra presença.</Sub>
          {Array.from({ length: comp.rounds_total }, (_, i) => i + 1).map((r) => (
            <Input key={r} placeholder={`Rodada ${r}: dd/mm/aaaa hh:mm`} value={dates[r] ?? ''} onChangeText={(t) => setDates((d) => ({ ...d, [r]: t }))} />
          ))}
          <Button
            title="Criar partidas"
            loading={busy === 'pre'}
            onPress={async () => {
              const items = Object.entries(dates)
                .filter(([, t]) => t.trim())
                .map(([r, t]) => ({ composition_id: comp.id, round: Number(r), played_at: parseLocal(t) }));
              if (!items.length || items.some((x) => !x.played_at)) return setMsg('Use o formato dd/mm/aaaa hh:mm em cada rodada preenchida.');
              const send = async (update: boolean, reinforced: boolean) => {
                const rid = requestId();
                setBusy('pre');
                const r = await idempotent(
                  async () => await supabase.rpc('pre_register_matches', { p_pelada: id, p_items: items, p_update: update, p_reinforced: reinforced, p_request: rid }),
                  async () => (await supabase.rpc('get_v85_operation', { p_request: rid })) as never,
                );
                setBusy(null);
                if (r.error) return setMsg(friendly(r.error.message));
                const res = (r.data as { items: { result: string }[] }).items;
                const exists = res.some((x) => x.result === 'EXISTS');
                const reinforcedNeeded = res.some((x) => x.result === 'NEEDS_REINFORCED_REVIEW');
                if (exists && !update)
                  return confirm('Já existe partida nessa rodada', 'Atualizar a partida em rascunho com esta escalação e data? Partidas publicadas ou canceladas não mudam.', 'Atualizar', () => send(true, false));
                if (reinforcedNeeded)
                  return confirm('Partida com dados registrados', 'Ela já tem presença confirmada ou eventos na súmula. A escalação prevista será substituída; a súmula não é apagada. Confirmar?', 'Confirmar', () => send(true, true));
                notify('Partidas prontas', `${res.filter((x) => x.result === 'CREATED' || x.result === 'UPDATED').length} partida(s) em rascunho.`);
                router.push({ pathname: '/pelada/[id]/partidas', params: { id } });
              };
              send(false, false);
            }}
          />
          <Button
            title="Usar como ponto de partida de um novo sorteio"
            kind="secondary"
            onPress={async () => {
              const { error } = await supabase.rpc('copy_composition_to_preparation', { p_comp: comp.id, p_mode: 'single', p_rounds: 1 });
              if (error) return setMsg(friendly(error.message));
              router.push({ pathname: '/pelada/[id]/sorteio', params: { id } });
            }}
          />
        </>
      )}
      <ErrorText>{msg}</ErrorText>

      <Text style={section}>Campo ilustrativo</Text>
      <Sub>Só ilustração: mudar alguém de lugar no desenho não muda time, posição, presença nem estatística. Fora do campo não é reserva.</Sub>
      {staff && field?.draft?.needs_review && <ErrorText>A escalação mudou depois do seu rascunho. Revise as posições antes de publicar.</ErrorText>}
      {staff && field?.published?.needs_review && !field.draft && <Sub>O campo publicado é de uma versão anterior da escalação.</Sub>}
      <FieldDrawing
        members={comp.members}
        positions={staff ? shownPositions : fieldPositions}
        names={names}
        selected={fieldPick}
        flagged={staff ? flagged : undefined}
        onPressPlayer={staff ? (pid) => setFieldPick(fieldPick === pid ? null : pid) : undefined}
        onPressPoint={
          staff
            ? (p) => {
                if (!fieldPick) return;
                setPositions({ ...shownPositions, [fieldPick]: clampPoint(p) });
                setFieldPick(null);
              }
            : undefined
        }
      />
      {staff && (
        <>
          <Sub>{fieldPick ? 'Agora toque no lugar do campo (ou fora dele).' : 'Toque num jogador e depois no lugar do campo.'}</Sub>
          {flagged.size > 0 && <Sub>Há nomes sobrepostos (destacados): afaste-os para ficar legível.</Sub>}
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Button title="Salvar rascunho" kind="secondary" loading={busy === 'draft'} onPress={() => saveDraft(false)} />
            </View>
            <View style={{ flex: 1 }}>
              <Button title="Publicar campo" loading={busy === 'publish'} onPress={() => saveDraft(true)} />
            </View>
          </View>
          <Button title="Reorganizar automaticamente" kind="ghost" onPress={() => setPositions(autoPositions(comp.members))} />
        </>
      )}

      <Text style={section}>Compartilhar</Text>
      <Sub>As duas imagens saem desta mesma versão. Se a escalação mudar, gere imagens novas: as já enviadas não mudam.</Sub>
      {listPages.map((p) => (
        <SharePanel
          key={`l${p.page}`}
          label={listPages.length > 1 ? `Lista dos times (imagem ${p.page} de ${p.pages})` : 'Lista dos times'}
          fileName={`escalacao-lista-v${comp.version}-${p.page}`}
          title="Escalação"
          validate={() => validate(allListMembers)}>
          <ListArt
            title={pelada?.name ?? 'Escalação'}
            subtitle={[comp.label, dateLabel].filter(Boolean).join(' · ')}
            crestPath={pelada?.crest_path}
            teamA={comp.team_a_name}
            teamB={comp.team_b_name}
            A={p.A}
            B={p.B}
            page={p.page}
            pages={p.pages}
            names={names}
            hints={hints}
            versionLabel={versionLabel}
          />
        </SharePanel>
      ))}
      {fieldPages.map((ms, i) => (
        <SharePanel
          key={`f${i}`}
          label={fieldPages.length > 1 ? `Campo (imagem ${i + 1} de ${fieldPages.length})` : 'Campo ilustrativo'}
          fileName={`escalacao-campo-v${comp.version}-${i + 1}`}
          title="Escalação"
          validate={() => validate(fieldPages)}>
          <FieldArt
            title={pelada?.name ?? 'Escalação'}
            subtitle={[comp.label, dateLabel].filter(Boolean).join(' · ')}
            crestPath={pelada?.crest_path}
            members={ms}
            positions={fieldPositions}
            names={names}
            teamA={comp.team_a_name}
            teamB={comp.team_b_name}
            page={i + 1}
            pages={fieldPages.length}
            versionLabel={versionLabel}
          />
        </SharePanel>
      ))}

      {staff && history && (
        <Collapsible title="Histórico da escalação">
          {history.map((h, i) => (
            <Text key={i} style={{ color: colors.muted, fontSize: 13 }}>
              v{h.version} · {OP_LABEL[h.op_type] ?? h.op_type} · {new Date(h.created_at).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}
              {h.actor_name ? ` · ${h.actor_name}` : ''}
            </Text>
          ))}
        </Collapsible>
      )}
    </Screen>
  );
}

const section = { fontSize: 19, lineHeight: 25, fontWeight: '700' as const, color: colors.deepBlue, marginTop: 10 };
