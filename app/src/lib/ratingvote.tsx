// V5: votação pós-partida (Prompt Master v2.0). Tudo que é regra fica no servidor (migrações 052-054):
// prazo, elegibilidade, ordem, progresso, versões e sigilo. Aqui só a apresentação.
// V7.7: publicação automática no fechamento; uma prorrogação comum; votação suspensa (partida anulada) e
// interrompida (restaurada, aguardando a decisão da administração: retomar, publicar ou reabrir 1-24 h).
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
import { Body, Button, Card, Chips, ErrorText, Input, Sub } from './ui';

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
  state: 'unavailable' | 'ready' | 'legacy' | 'open' | 'awaiting_publication' | 'published' | 'cancelled' | 'suspended' | 'interrupted';
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
  original_closes_at?: string;
  is_former_member?: boolean;
  reopened?: boolean;
  extension_used?: boolean;
  interruption?: { previous_status: 'open' | 'awaiting_publication' | 'published'; divergent: boolean } | null;
  /** V7.7 (071): pergunta da resenha. my_resenha null = ainda não respondeu; [] = "ninguém ficou". */
  resenha_enabled?: boolean;
  my_resenha?: string[] | null;
  resenha_answers?: number | null;
};
// Só progresso operacional: nunca notas, médias ou resultado provisório (053).
type AdminSummary = {
  participants: number;
  voters_complete: number;
  voters_in_progress: number;
  voters_not_started: number;
  voters: { membership_id: string; name: string; team: 'A' | 'B'; progress: 'complete' | 'in_progress' | 'not_started' }[];
  extension_used: boolean;
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
      <Text style={{ fontSize: 44, fontWeight: '900', color: colors.ink, textAlign: 'center' }}>{fmtScore(value)}</Text>
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
const stepTxt = { fontSize: 22, fontWeight: '800' as const, color: colors.ink };

const STATE_LABEL: Record<string, string> = {
  unavailable: 'Indisponível: a partida ainda não é oficial.',
  ready: 'Pronta para abrir.',
  legacy: 'Esta partida usou a votação antiga.',
  open: 'Aberta.',
  awaiting_publication: 'Prazo encerrado. O resultado é publicado automaticamente em instantes.',
  published: 'Resultado publicado.',
  cancelled: 'Votação encerrada sem resultado.',
  suspended: 'Votação suspensa: a partida foi anulada. Os votos ficam guardados.',
  interrupted: 'Votação interrompida pela anulação. Aguardando a decisão da administração.',
};

// Bloco da votação na tela da partida.
export function RatingVotePanel({ matchId, onChanged }: { matchId: string; onChanged?: () => void }) {
  const router = useRouter();
  const [v, setV] = useState<RatingVote | null>(null);
  const [admin, setAdmin] = useState<AdminSummary | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [details, setDetails] = useState(false);
  const [hours, setHours] = useState<'1' | '3' | '6' | '12' | '24'>('3');
  const [reason, setReason] = useState('');
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
      if (r.can_manage && r.session_id && (r.state === 'open' || r.state === 'awaiting_publication')) {
        const a = await supabase.rpc('get_rating_vote_admin', { p_session: r.session_id });
        if (alive) setAdmin((a.data as AdminSummary) ?? null);
      } else setAdmin(null);
    })();
    return () => {
      alive = false;
    };
  }, [matchId, reload]);

  async function run(fn: string, args: Record<string, unknown>) {
    if (busy) return;
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
      {/* REV-012: só o essencial — status, prazo, progresso discreto e Avaliar. Detalhes ficam recolhidos. */}
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        <Text style={{ flex: 1, fontWeight: '800', color: colors.ink, fontSize: 16 }}>Votação</Text>
        {v.state === 'open' && v.is_voter && total > 0 && (
          <Text style={{ color: colors.muted, fontWeight: '700', fontVariant: ['tabular-nums'] }}>{`${v.rated ?? 0}/${total}`}</Text>
        )}
      </View>
      <Sub>{STATE_LABEL[v.state]}</Sub>
      {v.state === 'open' && (
        <Sub>
          Até {fmtDate(v.closes_at!)}, {fmtTime(v.closes_at!)} · {left}
          {v.reopened ? ' · reabertura excepcional' : ''}
        </Sub>
      )}
      {v.is_voter && v.session_id && (v.state === 'published' || (v.rated ?? 0) > 0) && (
        <Button title="Ver meu histórico de votos" kind="ghost" onPress={() => router.push({ pathname: '/partida/[id]/meus-votos', params: { id: matchId } })} />
      )}
      {v.state === 'open' && v.is_voter && (
        <Button
          title={v.phase === 'review' ? 'Revisar' : (v.rated ?? 0) > 0 ? 'Continuar' : 'Avaliar'}
          onPress={() => router.push({ pathname: '/partida/[id]/votar', params: { id: matchId } })}
        />
      )}
      {v.can_manage && v.state === 'ready' && (
        <>
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
      {v.can_manage && v.state === 'open' && !v.extension_used && (
        <View style={{ flexDirection: 'row', gap: 8 }}>
          {([
            ['30', '+30 min'],
            ['60', '+1 h'],
            ['120', '+2 h'],
          ] as const).map(([m, label]) => (
            <View key={m} style={{ flex: 1 }}>
              <Button
                title={label}
                kind="secondary"
                disabled={busy}
                onPress={() =>
                  confirm('Prorrogar a votação?', 'Só uma prorrogação por votação.', 'Prorrogar', () =>
                    run('extend_rating_vote', { p_session: v.session_id, p_minutes: Number(m) }),
                  )
                }
              />
            </View>
          ))}
        </View>
      )}
      {admin && (
        <Pressable
          onPress={() => setDetails((d) => !d)}
          accessibilityRole="button"
          accessibilityState={{ expanded: details }}
          style={{ minHeight: 44, justifyContent: 'center' }}>
          <Text style={{ color: colors.blue, fontWeight: '600' }}>{details ? 'Ocultar detalhes da votação' : 'Detalhes da votação'}</Text>
        </Pressable>
      )}
      {admin && details && (
        <View style={{ gap: 4 }}>
          <Sub>
            {admin.voters_complete} concluíram · {admin.voters_in_progress} em andamento · {admin.voters_not_started} não começaram (de{' '}
            {admin.participants})
          </Sub>
          {admin.voters.some((x) => x.progress !== 'complete') && (
            <Sub>Pendentes: {admin.voters.filter((x) => x.progress !== 'complete').map((x) => x.name).join(', ')}</Sub>
          )}
          {v.extension_used && <Sub>Prorrogação já usada.</Sub>}
          {v.resenha_answers !== null && v.resenha_answers !== undefined && (
            <Sub>
              Pergunta da resenha: {v.resenha_answers} de {admin.participants} responderam.
            </Sub>
          )}
          <Sub>Notas e escolhas ficam em sigilo até a publicação.</Sub>
        </View>
      )}
      {v.can_manage && v.state === 'awaiting_publication' && (
        // O servidor publica sozinho; o botão só adianta (mesma operação, idempotente).
        <Button title="Publicar agora" kind="secondary" disabled={busy} onPress={() => run('publish_rating_vote', { p_session: v.session_id })} />
      )}
      {v.can_manage && v.state === 'interrupted' && v.session_id && (
        <View style={{ gap: 8, marginTop: 6 }}>
          {v.interruption?.previous_status === 'published' ? (
            <>
              <Body>A súmula mudou desde a publicação: o resultado da votação está suspenso.</Body>
              <Sub>Corrija a súmula (sem mudar quem jogou) e recupere a publicação original.</Sub>
            </>
          ) : (
            <Body>A partida foi restaurada. A votação não reabre sozinha: escolha o que fazer.</Body>
          )}
          <Input placeholder="motivo (obrigatório)" value={reason} onChangeText={setReason} accessibilityLabel="Motivo da decisão" />
          {v.interruption?.previous_status === 'published' ? (
            <Button title="Recuperar publicação original" disabled={busy || reason.trim().length < 3} onPress={() => run('reactivate_rating_vote', { p_session: v.session_id, p_mode: 'restore_publication', p_hours: null, p_reason: reason })} />
          ) : (
            <>
              <Button title="Retomar no prazo original" kind="secondary" disabled={busy || reason.trim().length < 3} onPress={() => run('reactivate_rating_vote', { p_session: v.session_id, p_mode: 'resume', p_hours: null, p_reason: reason })} />
              <Button
                title="Publicar os votos guardados"
                kind="secondary"
                disabled={busy || reason.trim().length < 3}
                onPress={() =>
                  confirm('Publicar os votos guardados?', 'O resultado sai com os votos já registrados, sem nova votação.', 'Publicar', () =>
                    run('reactivate_rating_vote', { p_session: v.session_id, p_mode: 'publish', p_hours: null, p_reason: reason }),
                  )
                }
              />
              <Sub>Ou reabrir (uma vez; votos já dados continuam):</Sub>
              <Chips
                options={[
                  { value: '1', label: '1 h' },
                  { value: '3', label: '3 h' },
                  { value: '6', label: '6 h' },
                  { value: '12', label: '12 h' },
                  { value: '24', label: '24 h' },
                ]}
                value={hours}
                onChange={setHours}
              />
              <Button
                title={`Reabrir por ${hours} h`}
                disabled={busy || reason.trim().length < 3}
                onPress={() =>
                  confirm('Reabrir a votação?', `Novo prazo: ${hours} h a partir de agora. Só quem jogou a partida vota.`, 'Reabrir', () =>
                    run('reactivate_rating_vote', { p_session: v.session_id, p_mode: 'reopen', p_hours: Number(hours), p_reason: reason }),
                  )
                }
              />
            </>
          )}
        </View>
      )}
      <ErrorText>{err}</ErrorText>
    </Card>
  );
}
