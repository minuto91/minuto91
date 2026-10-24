// V5: votação pós-partida (Prompt Master v2.0). Tudo que é regra fica no servidor (migração 052):
// prazo, elegibilidade, ordem, progresso e sigilo. Aqui só a apresentação.
// - RatingSlider: controle de 0 a 10 em passos de 0,5 (arrastar ou -/+).
// - RatingVotePanel: bloco da partida (estado da votação, ação do jogador e, para a gestão, abrir, prorrogar,
//   acompanhar só por números e publicar com confirmação).
import { useRouter } from 'expo-router';
import { useEffect, useMemo, useState } from 'react';
import { PanResponder, Pressable, View } from 'react-native';

import { confirm } from './dialog';
import { friendly } from './errors';
import { fmtDate, fmtTime } from './match';
import { supabase } from './supabase';
import { Text } from './text';
import { colors } from './theme';
import { Body, Button, Card, Chips, ErrorText, Sub } from './ui';

export type RatingTarget = {
  membership_id: string;
  name: string;
  avatar_path: string | null;
  position: string | null;
  team: 'A' | 'B';
  is_teammate: boolean;
  goals: number;
  assists: number;
  my_rating: number | null;
  skipped: boolean;
};
export type RatingVote = {
  state: 'unavailable' | 'ready' | 'legacy' | 'open' | 'awaiting_publication' | 'published' | 'cancelled';
  session_id?: string;
  opened_at?: string;
  closes_at?: string;
  server_now: string;
  can_manage: boolean;
  is_voter?: boolean;
  my_team?: 'A' | 'B' | null;
  phase?: 'first' | 'second' | 'review' | null;
  current?: string | null;
  targets?: RatingTarget[];
  rated?: number;
  bola_murcha_enabled?: boolean;
  my_awards?: { craque?: string; bola_murcha?: string };
  published_at?: string | null;
  /** V7.7 (054): pergunta da resenha. my_resenha null = ainda não respondeu; [] = "ninguém ficou". */
  resenha_enabled?: boolean;
  my_resenha?: string[] | null;
  resenha_answers?: number | null;
};
type AdminSummary = {
  participants: number;
  voters_participated: number;
  votes: number;
  coverage: number;
  players_valid: number;
  players_insufficient: number;
  average_rating: number | null;
  players: { membership_id: string; name: string; team: 'A' | 'B'; valid: boolean }[];
};

export const fmtScore = (v: number) => v.toFixed(1).replace('.', ',');

// Diferença entre o relógio do servidor e o do aparelho: o tempo restante mostrado segue o servidor.
export function useServerCountdown(closesAt?: string, serverNow?: string) {
  const [text, setText] = useState<string | null>(null);
  useEffect(() => {
    if (!closesAt) return;
    const offset = serverNow ? new Date(serverNow).getTime() - Date.now() : 0;
    const update = () => {
      const ms = new Date(closesAt).getTime() - (Date.now() + offset);
      const h = Math.floor(ms / 3600000);
      const m = Math.floor((ms % 3600000) / 60000);
      setText(ms <= 0 ? 'Prazo encerrado' : h > 0 ? `Faltam ${h}h${String(m).padStart(2, '0')}` : `Faltam ${m} min`);
    };
    const first = setTimeout(update, 0);
    const t = setInterval(update, 30000);
    return () => {
      clearTimeout(first);
      clearInterval(t);
    };
  }, [closesAt, serverNow]);
  return closesAt ? text : null;
}

export function RatingSlider({ value, onChange, disabled }: { value: number; onChange: (v: number) => void; disabled?: boolean }) {
  const [width, setWidth] = useState(1);
  const pan = useMemo(() => {
    const set = (x: number) => onChange(Math.min(10, Math.max(0, Math.round((x / width) * 20) / 2)));
    return PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: () => true,
      onPanResponderGrant: (e) => set(e.nativeEvent.locationX),
      onPanResponderMove: (e) => set(e.nativeEvent.locationX),
      onPanResponderTerminationRequest: () => false,
    });
  }, [width, onChange]);
  const step = (d: number) => onChange(Math.min(10, Math.max(0, value + d)));
  return (
    <View style={{ gap: 10, opacity: disabled ? 0.5 : 1 }} pointerEvents={disabled ? 'none' : 'auto'}>
      <Text style={{ fontSize: 44, fontWeight: '900', color: colors.deepBlue, textAlign: 'center' }}>{fmtScore(value)}</Text>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        <Pressable onPress={() => step(-0.5)} accessibilityRole="button" accessibilityLabel="Diminuir meio ponto" style={stepBtn}>
          <Text style={stepTxt}>−</Text>
        </Pressable>
        <View
          style={{ flex: 1, height: 44, justifyContent: 'center' }}
          onLayout={(e) => setWidth(Math.max(1, e.nativeEvent.layout.width))}
          accessible
          accessibilityRole="adjustable"
          accessibilityLabel="Nota"
          accessibilityValue={{ min: 0, max: 10, now: value, text: fmtScore(value) }}
          accessibilityActions={[{ name: 'increment' }, { name: 'decrement' }]}
          onAccessibilityAction={(e) => step(e.nativeEvent.actionName === 'increment' ? 0.5 : -0.5)}
          {...pan.panHandlers}>
          <View pointerEvents="none" style={{ height: 6, borderRadius: 3, backgroundColor: colors.line }}>
            <View style={{ width: `${value * 10}%`, height: 6, borderRadius: 3, backgroundColor: colors.blue }} />
          </View>
          <View
            pointerEvents="none"
            style={{
              position: 'absolute',
              left: `${value * 10}%`,
              marginLeft: -13,
              width: 26,
              height: 26,
              borderRadius: 13,
              backgroundColor: colors.white,
              borderWidth: 3,
              borderColor: colors.blue,
            }}
          />
        </View>
        <Pressable onPress={() => step(0.5)} accessibilityRole="button" accessibilityLabel="Aumentar meio ponto" style={stepBtn}>
          <Text style={stepTxt}>+</Text>
        </Pressable>
      </View>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', paddingHorizontal: 56 }}>
        <Sub>0</Sub>
        <Sub>5</Sub>
        <Sub>10</Sub>
      </View>
    </View>
  );
}
const stepBtn = { width: 44, height: 44, borderRadius: 22, borderWidth: 1, borderColor: colors.line, alignItems: 'center' as const, justifyContent: 'center' as const };
const stepTxt = { fontSize: 22, fontWeight: '800' as const, color: colors.deepBlue };

const STATE_LABEL: Record<string, string> = {
  unavailable: 'Indisponível: a partida ainda não é oficial.',
  ready: 'Pronta para abrir.',
  legacy: 'Esta partida usou a votação antiga.',
  open: 'Aberta.',
  awaiting_publication: 'Prazo encerrado. Aguardando a publicação pelo administrador.',
  published: 'Notas publicadas.',
  cancelled: 'Cancelada (partida anulada).',
};

// Bloco da votação na tela da partida.
export function RatingVotePanel({ matchId, onChanged }: { matchId: string; onChanged?: () => void }) {
  const router = useRouter();
  const [v, setV] = useState<RatingVote | null>(null);
  const [admin, setAdmin] = useState<AdminSummary | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [extra, setExtra] = useState<'30' | '60' | '120'>('60');
  const [reload, setReload] = useState(0);
  const left = useServerCountdown(v?.state === 'open' ? v.closes_at : undefined, v?.server_now);

  useEffect(() => {
    let alive = true;
    (async () => {
      void reload;
      const { data, error } = await supabase.rpc('get_rating_vote', { p_match: matchId });
      if (!alive) return;
      if (error) return setErr(friendly(error.message));
      const r = data as RatingVote;
      setV(r);
      if (r.can_manage && r.session_id && r.state !== 'published') {
        const a = await supabase.rpc('get_rating_vote_admin', { p_session: r.session_id });
        if (alive) setAdmin((a.data as AdminSummary) ?? null);
      } else setAdmin(null);
    })();
    return () => {
      alive = false;
    };
  }, [matchId, reload]);

  async function run(fn: string, args: Record<string, unknown>) {
    setBusy(true);
    setErr(null);
    const { error } = await supabase.rpc(fn, args);
    setBusy(false);
    if (error) return setErr(friendly(error.message));
    setReload((n) => n + 1);
    onChanged?.();
  }

  if (!v || v.state === 'legacy') return err ? <ErrorText>{err}</ErrorText> : null;
  if (v.state === 'unavailable') return null;
  const total = v.targets?.length ?? 0;
  return (
    <Card>
      <Text style={{ fontWeight: '800', color: colors.deepBlue, fontSize: 16 }}>Avaliação dos jogadores</Text>
      <Sub>{STATE_LABEL[v.state]}</Sub>
      {v.state === 'open' && (
        <Sub>
          Até {fmtDate(v.closes_at!)}, {fmtTime(v.closes_at!)} · {left}
        </Sub>
      )}
      {v.state === 'open' && v.is_voter && (
        <Button
          title={v.phase === 'review' ? `Revisar minhas notas (${v.rated} de ${total})` : (v.rated ?? 0) > 0 ? `Continuar (${v.rated} de ${total})` : 'Avaliar jogadores'}
          onPress={() => router.push({ pathname: '/partida/[id]/votar', params: { id: matchId } })}
        />
      )}
      {v.can_manage && v.state === 'ready' && (
        <>
          <Body>Abra a votação para os participantes avaliarem companheiros e adversários por 6 horas.</Body>
          <Button
            title="Abrir votação"
            disabled={busy}
            onPress={() =>
              confirm('Abrir a votação?', 'Todos os participantes com conta poderão votar durante 6 horas.', 'Abrir', () =>
                run('open_rating_vote', { p_match: matchId }),
              )
            }
          />
        </>
      )}
      {admin && (
        <View style={{ gap: 4, marginTop: 6 }}>
          <Sub>
            {admin.voters_participated} de {admin.participants} participantes votaram · {admin.votes} notas registradas · cobertura{' '}
            {Math.round(admin.coverage * 100)}%
          </Sub>
          <Sub>
            Com avaliação válida: {admin.players_valid} · Avaliação insuficiente até agora: {admin.players_insufficient}
          </Sub>
          {v.resenha_answers !== null && v.resenha_answers !== undefined && (
            <Sub>
              Pergunta da resenha: {v.resenha_answers} de {admin.participants} responderam.
            </Sub>
          )}
          <Sub>Por sigilo, ninguém (nem o administrador) vê quem deu cada nota.</Sub>
        </View>
      )}
      {v.can_manage && v.state === 'open' && (
        <>
          <Chips
            options={[
              { value: '30', label: '+30 min' },
              { value: '60', label: '+1 h' },
              { value: '120', label: '+2 h' },
            ]}
            value={extra}
            onChange={(x) => setExtra(x)}
          />
          <Button title="Prorrogar para todos" kind="secondary" disabled={busy} onPress={() => run('extend_rating_vote', { p_session: v.session_id, p_minutes: Number(extra) })} />
        </>
      )}
      {v.can_manage && v.state === 'awaiting_publication' && (
        <Button
          title="Publicar notas"
          disabled={busy}
          onPress={() =>
            confirm(
              'Publicar as notas?',
              `${admin?.players_valid ?? 0} jogadores com nota válida e ${admin?.players_insufficient ?? 0} com avaliação insuficiente. Depois de publicar não dá para desfazer.`,
              'Publicar',
              () => run('publish_rating_vote', { p_session: v.session_id }),
            )
          }
        />
      )}
      <ErrorText>{err}</ErrorText>
    </Card>
  );
}
