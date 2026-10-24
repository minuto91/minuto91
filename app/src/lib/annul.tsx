// Anulação e restauração de partida (V7.7, migração 054). Só o administrador, a qualquer tempo, com motivo,
// prévia resumida e confirmação reforçada. A prévia traz um token: se algo mudar antes de confirmar, o servidor
// recusa (PREVIEW_OUTDATED) e esta tela busca a prévia nova para confirmar de novo. Cada operação leva um id de
// pedido: tocar duas vezes ou repetir depois de queda de rede não repete a operação.
// Para jogadores, só a linha do tempo resumida (data, tipo e motivo geral), sem descrição e sem quem administrou.
import { useCallback, useEffect, useState } from 'react';
import { View } from 'react-native';

import { confirm } from './dialog';
import { friendly } from './errors';
import { requestId } from './ids';
import { fmtDate, fmtTime } from './match';
import { supabase } from './supabase';
import { Text } from './text';
import { colors } from './theme';
import { Body, Button, Card, Chips, ErrorText, Input, Sub } from './ui';

export const ANNUL_REASONS = [
  { value: 'sheet_error', label: 'Erro na súmula' },
  { value: 'duplicate_match', label: 'Partida duplicada' },
  { value: 'match_not_played', label: 'Partida não aconteceu' },
  { value: 'other', label: 'Outro' },
] as const;
type Reason = (typeof ANNUL_REASONS)[number]['value'];
export const reasonLabel = (r: string | null | undefined) => ANNUL_REASONS.find((x) => x.value === r)?.label ?? 'Outro';

type Preview = {
  kind: 'annulment' | 'restoration';
  preview_token: string;
  players_affected: number;
  goals: number;
  assists: number;
  cards: number;
  ratings: number;
  awards: number;
  has_round_selection: boolean;
  month: string;
  month_closed: boolean;
  season_closed: boolean;
  voting: string;
  conflicts: string[];
  cycles: number;
  can_annul?: boolean;
  can_restore?: boolean;
};

const VOTING_TEXT: Record<string, string> = {
  suspend_open: 'A votação em andamento fica suspensa, com os votos guardados. Ela não reabre sozinha se a partida for restaurada.',
  suspend_awaiting: 'A votação encerrada e ainda não publicada fica suspensa, com os votos guardados.',
  suspend_published: 'O resultado publicado da votação sai do ar (notas, Craque e Bola Murcha) e volta igual se a partida for restaurada.',
  keep_suspended: 'A votação desta partida continua suspensa.',
  restore_publication: 'O resultado publicado da votação volta igual, sem nova votação.',
  publication_suspended: 'A súmula não bate com a votação publicada: o resultado da votação fica suspenso até a correção.',
  admin_decision: 'A votação foi interrompida antes de publicar. Depois de restaurar, você decide: retomar, publicar os votos guardados ou reabrir por um novo prazo.',
  none: '',
};

function PreviewSummary({ p }: { p: Preview }) {
  const back = p.kind === 'restoration';
  const n = (v: number, one: string, many: string) => `${v} ${v === 1 ? one : many}`;
  return (
    <View style={{ gap: 4 }}>
      <Sub>
        {back ? 'Volta a contar' : 'Deixa de contar'}: {n(p.players_affected, 'jogador', 'jogadores')}, {n(p.goals, 'gol', 'gols')},{' '}
        {n(p.assists, 'assistência', 'assistências')}, {n(p.cards, 'cartão', 'cartões')}, {n(p.ratings, 'nota', 'notas')} e{' '}
        {n(p.awards, 'prêmio', 'prêmios')}.
      </Sub>
      <Sub>
        Rankings, OVR, Seleção da Rodada, troféus e figurinhas são recalculados
        {p.month_closed || p.season_closed ? ', inclusive no mês ou na temporada já fechados' : ''}. Fechamentos do Financeiro não mudam.
      </Sub>
      {!!VOTING_TEXT[p.voting] && <Sub>{VOTING_TEXT[p.voting]}</Sub>}
      <Sub>Os integrantes atuais recebem um aviso quando a operação terminar.</Sub>
    </View>
  );
}

// Fluxo comum: abrir prévia -> preencher -> confirmar; prévia vencida recarrega e pede nova confirmação.
function useStatusOperation(matchId: string, kind: 'annulment' | 'restoration', onDone: () => void) {
  const [preview, setPreview] = useState<Preview | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [req, setReq] = useState<string | null>(null);

  const load = useCallback(async () => {
    setBusy(true);
    setMsg(null);
    const { data, error } = await supabase.rpc(kind === 'annulment' ? 'preview_match_annulment' : 'preview_match_restoration', {
      p_match: matchId,
    });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    setPreview(data as Preview);
    setReq(requestId()); // um pedido por prévia confirmada
  }, [kind, matchId]);

  async function run(args: Record<string, unknown>) {
    if (!preview || !req || busy) return;
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc(kind === 'annulment' ? 'annul_match' : 'restore_match', {
      p_match: matchId,
      p_confirm: true,
      p_preview_token: preview.preview_token,
      p_request_id: req,
      ...args,
    });
    setBusy(false);
    if (error) {
      if (error.message.includes('PREVIEW_OUTDATED')) {
        await load();
        return setMsg(friendly(error.message));
      }
      return setMsg(friendly(error.message)); // o mesmo id de pedido vale no próximo toque (retry seguro)
    }
    setPreview(null);
    onDone();
  }
  return { preview, setPreview, busy, msg, load, run };
}

export function AnnulMatch({ matchId, onDone }: { matchId: string; onDone: () => void }) {
  const op = useStatusOperation(matchId, 'annulment', onDone);
  const [reason, setReason] = useState<Reason | null>(null);
  const [description, setDescription] = useState('');

  if (!op.preview) {
    return (
      <>
        <ErrorText>{op.msg}</ErrorText>
        <Button title="Anular partida" kind="danger" onPress={op.load} loading={op.busy} />
      </>
    );
  }
  const ok = !!reason && description.trim().length >= 10 && op.preview.can_annul !== false;
  return (
    <Card>
      <Body>Anular esta partida</Body>
      <Sub>Ela continua no histórico com o selo “Anulada”, mas deixa de contar. Dá para restaurar depois, com justificativa.</Sub>
      <PreviewSummary p={op.preview} />
      <Sub>Motivo</Sub>
      <Chips options={ANNUL_REASONS} value={reason} onChange={setReason} />
      <Input
        autoCapitalize="sentences"
        placeholder="explique o que aconteceu (10 caracteres ou mais)"
        value={description}
        onChangeText={setDescription}
        multiline
        accessibilityLabel="Justificativa da anulação"
      />
      <Sub>Só a administração vê esta justificativa. Os jogadores veem a data e o motivo geral.</Sub>
      <ErrorText>{op.msg}</ErrorText>
      <Button
        title="Anular partida"
        kind="danger"
        loading={op.busy}
        disabled={!ok}
        onPress={() =>
          confirm(
            'Confirmar anulação?',
            `${reasonLabel(reason)}. A partida deixa de contar em todos os resultados e a votação fica suspensa.`,
            'Anular',
            () => op.run({ p_reason_category: reason, p_description: description }),
          )
        }
      />
      <Button title="Cancelar" kind="secondary" onPress={() => op.setPreview(null)} />
    </Card>
  );
}

export function RestoreMatch({ matchId, onDone }: { matchId: string; onDone: () => void }) {
  const op = useStatusOperation(matchId, 'restoration', onDone);
  const [justification, setJustification] = useState('');

  if (!op.preview) {
    return (
      <>
        <ErrorText>{op.msg}</ErrorText>
        <Button title="Restaurar partida" kind="secondary" onPress={op.load} loading={op.busy} />
      </>
    );
  }
  const ok = justification.trim().length >= 10 && op.preview.can_restore !== false;
  return (
    <Card>
      <Body>Restaurar esta partida</Body>
      <Sub>Use só em caso excepcional: a partida volta a contar com os dados válidos que tinha.</Sub>
      <PreviewSummary p={op.preview} />
      <Input
        autoCapitalize="sentences"
        placeholder="justificativa (10 caracteres ou mais)"
        value={justification}
        onChangeText={setJustification}
        multiline
        accessibilityLabel="Justificativa da restauração"
      />
      <ErrorText>{op.msg}</ErrorText>
      <Button
        title="Restaurar partida"
        loading={op.busy}
        disabled={!ok}
        onPress={() =>
          confirm('Confirmar restauração?', 'A partida volta a contar em todos os resultados.', 'Restaurar', () =>
            op.run({ p_justification: justification }),
          )
        }
      />
      <Button title="Cancelar" kind="secondary" onPress={() => op.setPreview(null)} />
    </Card>
  );
}

type TimelineEvent = { kind: 'annulment' | 'restoration'; at: string; reason_category: string | null; description?: string; actor_name?: string | null };

// Linha do tempo resumida (todos com acesso) ou detalhada (administração).
export function MatchStatusTimeline({ matchId, admin, refreshKey }: { matchId: string; admin: boolean; refreshKey?: unknown }) {
  const [events, setEvents] = useState<TimelineEvent[] | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc(admin ? 'get_match_status_history_admin' : 'get_match_status_history', { p_match: matchId });
      if (!alive) return;
      if (error) return setMsg(friendly(error.message));
      setEvents(((data as { events: TimelineEvent[] } | null)?.events ?? []) as TimelineEvent[]);
    })();
    return () => {
      alive = false;
    };
  }, [matchId, admin, refreshKey]);

  if (msg) return <ErrorText>{msg}</ErrorText>;
  if (!events || events.length === 0) return null;
  return (
    <View style={{ gap: 6 }} accessibilityLabel="Histórico de anulação e restauração">
      {events.map((e, i) => (
        <View key={`${e.at}-${i}`} style={{ flexDirection: 'row', gap: 10, alignItems: 'flex-start' }}>
          <View
            style={{ width: 8, height: 8, borderRadius: 4, marginTop: 6, backgroundColor: e.kind === 'annulment' ? colors.danger : colors.blue }}
          />
          <View style={{ flex: 1, gap: 2 }}>
            <Text style={{ color: colors.ink, fontWeight: '600' }}>
              {e.kind === 'annulment' ? `Anulada · ${reasonLabel(e.reason_category)}` : 'Restaurada'}
            </Text>
            <Sub>
              {fmtDate(e.at)} às {fmtTime(e.at)}
              {admin && e.actor_name ? ` · por ${e.actor_name}` : ''}
            </Sub>
            {admin && !!e.description && <Sub>{e.description}</Sub>}
          </View>
        </View>
      ))}
    </View>
  );
}

// Selo discreto para listas e cabeçalhos.
export function AnnulledBadge() {
  return (
    <View
      accessibilityLabel="Partida anulada"
      style={{ alignSelf: 'flex-start', borderRadius: 999, borderWidth: 1, borderColor: colors.danger, paddingHorizontal: 8, paddingVertical: 2 }}>
      <Text style={{ fontSize: 12, fontWeight: '700', color: colors.danger, letterSpacing: 0.4 }}>ANULADA</Text>
    </View>
  );
}
