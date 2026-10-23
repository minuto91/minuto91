// V5: avaliação pós-partida, um jogador por vez (Prompt Master v2.0, Etapa 12).
// O servidor guarda a ordem, as notas e o progresso: cada "Confirmar e próximo" só avança depois que o
// servidor confirma; sem confirmação a nota escolhida continua na tela para tentar de novo. A nota inicial
// 7,0 não vale como voto até ser confirmada. Pular não registra nota; o pulado volta uma vez no fim e
// depois fica na revisão. Ninguém vê as notas que recebeu. Votações abertas antes da V5 seguem o fluxo antigo.
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { Pressable, View } from 'react-native';

import { Avatar } from '../../../lib/avatar';
import { friendly } from '../../../lib/errors';
import { LegacyVotar } from '../../../lib/legacyvote';
import { loadMatch, Match } from '../../../lib/match';
import { fmtScore, RatingSlider, RatingTarget, RatingVote, useServerCountdown } from '../../../lib/ratingvote';
import { supabase } from '../../../lib/supabase';
import { Text } from '../../../lib/text';
import { colors, positionLabel } from '../../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Loading, Screen, Sub, Title } from '../../../lib/ui';

const START = 7;

export default function Votar() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [v, setV] = useState<RatingVote | null>(null);
  const [legacy, setLegacy] = useState(false);
  const [match, setMatch] = useState<Match | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [{ data, error }, m] = await Promise.all([supabase.rpc('get_rating_vote', { p_match: id }), loadMatch(id).catch(() => null)]);
      if (!alive) return;
      if (error) return setErr(friendly(error.message));
      const r = data as RatingVote;
      if (r.state === 'legacy' || (r.state === 'unavailable' && m?.status === 'voting_open')) return setLegacy(true);
      setMatch(m);
      setV(r);
    })();
    return () => {
      alive = false;
    };
  }, [id]);

  if (legacy) return <LegacyVotar />;
  if (!v) return <Screen>{err ? <ErrorText>{err}</ErrorText> : <Loading />}</Screen>;
  return <Flow initial={v} match={match} />;
}

function Flow({ initial, match }: { initial: RatingVote; match: Match | null }) {
  const router = useRouter();
  const [v, setV] = useState(initial);
  const [editing, setEditing] = useState<string | null>(null);
  // Nota escolhida por jogador (ainda não confirmada); sem escolha vale a já dada ou 7,0.
  const [picked, setPicked] = useState<Record<string, number>>({});
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const left = useServerCountdown(v.closes_at, v.server_now);
  const targets = v.targets ?? [];
  const current = targets.find((t) => t.membership_id === v.current) ?? null;
  const teamName = (t: 'A' | 'B') => (t === 'A' ? match?.team_a_name : match?.team_b_name) ?? `Time ${t}`;

  const focusId = editing ?? v.current ?? null;
  const focus = targets.find((x) => x.membership_id === focusId);
  const value = focusId ? (picked[focusId] ?? (focus?.my_rating != null ? Number(focus.my_rating) : START)) : START;
  const setValue = useCallback((n: number) => {
    if (focusId) setPicked((p) => ({ ...p, [focusId]: n }));
  }, [focusId]);

  const call = useCallback(
    async (fn: string, args: Record<string, unknown>) => {
      setBusy(true);
      setErr(null);
      const { data, error } = await supabase.rpc(fn, args);
      setBusy(false);
      if (error) {
        // Sem confirmação do servidor nada avança: a nota escolhida continua na tela.
        setErr(error.message.includes('VOTING_CLOSED') ? 'A votação já foi encerrada. Esta nota não foi registrada.' : 'O envio não foi confirmado. Verifique a internet e tente de novo.');
        return false;
      }
      setV(data as RatingVote);
      return true;
    },
    [],
  );

  if (v.state !== 'open') {
    return (
      <Screen>
        <Title>Avaliação dos jogadores</Title>
        <Body>
          {v.state === 'published'
            ? 'As notas desta partida já foram publicadas.'
            : v.state === 'awaiting_publication'
              ? 'O prazo terminou. As notas aparecem depois que o administrador publicar.'
              : v.state === 'ready'
                ? 'A votação desta partida ainda não foi aberta.'
                : 'A votação não está disponível.'}
        </Body>
        <Button title="Voltar para a partida" kind="secondary" onPress={() => router.back()} />
      </Screen>
    );
  }
  if (!v.is_voter) {
    return (
      <Screen>
        <Title>Avaliação dos jogadores</Title>
        <Body>Só quem jogou esta partida avalia os jogadores.</Body>
      </Screen>
    );
  }

  const header = (
    <View style={{ gap: 2 }}>
      {match && (
        <Sub>
          {match.team_a_name} {match.team_a_score} x {match.team_b_score} {match.team_b_name}
        </Sub>
      )}
      <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
        <Sub>
          {v.rated} de {targets.length} avaliados
        </Sub>
        <Sub>{left}</Sub>
      </View>
      <View style={{ height: 4, borderRadius: 2, backgroundColor: colors.line }}>
        <View style={{ width: `${targets.length ? ((v.rated ?? 0) / targets.length) * 100 : 0}%`, height: 4, borderRadius: 2, backgroundColor: colors.blue }} />
      </View>
    </View>
  );

  // Edição na revisão.
  if (editing) {
    const t = targets.find((x) => x.membership_id === editing)!;
    return (
      <Screen>
        {header}
        <PlayerBox t={t} team={teamName(t.team)} />
        <RatingSlider value={value} onChange={setValue} disabled={busy} />
        <ErrorText>{err}</ErrorText>
        <Button
          title="Salvar nota"
          loading={busy}
          disabled={busy}
          onPress={async () => {
            if (await call('cast_rating_vote', { p_session: v.session_id, p_target: t.membership_id, p_rating: value })) setEditing(null);
          }}
        />
        <Button title="Cancelar" kind="ghost" onPress={() => setEditing(null)} />
      </Screen>
    );
  }

  if (current) {
    return (
      <Screen>
        {header}
        {v.phase === 'second' && <Sub>Você pulou este jogador. Quer avaliar agora?</Sub>}
        <PlayerBox t={current} team={teamName(current.team)} />
        <RatingSlider value={value} onChange={setValue} disabled={busy} />
        <ErrorText>{err}</ErrorText>
        <Button
          title="Confirmar e próximo"
          loading={busy}
          disabled={busy}
          onPress={() => call('cast_rating_vote', { p_session: v.session_id, p_target: current.membership_id, p_rating: value })}
        />
        <Button title="Pular jogador" kind="ghost" disabled={busy} onPress={() => call('skip_rating_vote', { p_session: v.session_id, p_target: current.membership_id })} />
      </Screen>
    );
  }

  if (done) {
    return (
      <Screen>
        <Title>Avaliação concluída</Title>
        <Body>
          Você avaliou {v.rated} de {targets.length} jogadores. Dá para mudar suas notas até o fim do prazo.
        </Body>
        <Sub>As notas aparecem para todos só depois que o administrador publicar. Ninguém vê quem deu cada nota.</Sub>
        <Button title="Revisar notas" kind="secondary" onPress={() => setDone(false)} />
        <Button title="Voltar para a partida" onPress={() => router.back()} />
      </Screen>
    );
  }

  return (
    <Screen>
      <Title>Revisão</Title>
      {header}
      <Card>
        {targets.map((t) => (
          <View key={t.membership_id} style={{ flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 48 }}>
            <Avatar path={t.avatar_path} name={t.name} size={32} />
            <View style={{ flex: 1 }}>
              <Text style={{ fontWeight: '600', color: colors.ink }} numberOfLines={1}>
                {t.name}
              </Text>
              <Sub>{teamName(t.team)}</Sub>
            </View>
            <Text style={{ fontWeight: '800', color: t.my_rating === null ? colors.muted : colors.deepBlue }}>
              {t.my_rating === null ? 'Sem nota' : fmtScore(Number(t.my_rating))}
            </Text>
            <Pressable onPress={() => setEditing(t.membership_id)} accessibilityRole="button" accessibilityLabel={`Editar nota de ${t.name}`} style={{ padding: 8 }}>
              <Text style={{ color: colors.blue, fontWeight: '700' }}>Editar</Text>
            </Pressable>
          </View>
        ))}
      </Card>
      <Awards v={v} onSaved={(r) => setV(r)} />
      <ErrorText>{err}</ErrorText>
      <Button title="Concluir" onPress={() => setDone(true)} />
    </Screen>
  );
}

function PlayerBox({ t, team }: { t: RatingTarget; team: string }) {
  return (
    <Card>
      <View style={{ alignItems: 'center', gap: 6 }}>
        <Avatar path={t.avatar_path} name={t.name} size={88} />
        <Text style={{ fontSize: 20, fontWeight: '800', color: colors.deepBlue, textAlign: 'center' }}>{t.name}</Text>
        <Sub>
          {positionLabel(t.position)} · {team} · {t.is_teammate ? 'seu time' : 'adversário'}
        </Sub>
        <Body>
          {t.goals} {t.goals === 1 ? 'gol' : 'gols'} · {t.assists} {t.assists === 1 ? 'assistência' : 'assistências'}
        </Body>
      </View>
    </Card>
  );
}

// Craque e Bola Murcha: opcionais, uma escolha cada.
function Awards({ v, onSaved }: { v: RatingVote; onSaved: (r: RatingVote) => void }) {
  const [craque, setCraque] = useState<string | null>(v.my_awards?.craque ?? null);
  const [bola, setBola] = useState<string | null>(v.my_awards?.bola_murcha ?? null);
  const [msg, setMsg] = useState<string | null>(null);
  const options = (v.targets ?? []).map((t) => ({ value: t.membership_id, label: t.name }));
  async function save(c: string | null, b: string | null) {
    setMsg(null);
    const { error } = await supabase.rpc('set_rating_vote_awards', { p_session: v.session_id, p_craque: c, p_bola_murcha: b });
    if (error) return setMsg('Não foi possível salvar. Tente de novo.');
    onSaved({ ...v, my_awards: { craque: c ?? undefined, bola_murcha: b ?? undefined } });
  }
  return (
    <Card>
      <Text style={{ fontWeight: '700', color: colors.deepBlue }}>Craque da partida (opcional)</Text>
      <Chips options={options} value={craque} onChange={(x) => { const n = x === craque ? null : x; setCraque(n); void save(n, bola); }} />
      {v.bola_murcha_enabled && (
        <>
          <Text style={{ fontWeight: '700', color: colors.deepBlue, marginTop: 8 }}>Bola Murcha (opcional)</Text>
          <Chips options={options} value={bola} onChange={(x) => { const n = x === bola ? null : x; setBola(n); void save(craque, n); }} />
        </>
      )}
      <ErrorText>{msg}</ErrorText>
    </Card>
  );
}
