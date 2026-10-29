import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { View } from 'react-native';

import { loadReadableSeasons, Season } from '../../../lib/career';
import { friendly } from '../../../lib/errors';
import { supabase } from '../../../lib/supabase';
import { Text } from '../../../lib/text';
import { colors, type } from '../../../lib/theme';
import { Button, Chips, EmptyState, ErrorText, Screen, Section, Sub, Title } from '../../../lib/ui';
import { candidateReason, CraqueCandidate, CraqueStatus, remaining, statusTitle } from '../../../lib/v86logic';

// V8.6: Craque da Temporada, por votação. O servidor decide tudo (elegibilidade, turnos, quórum, desempate);
// aqui só se mostra o estado e se enviam o voto e as ações do administrador. Sem parciais (V10).
type State = {
  season_id: string;
  status: CraqueStatus;
  is_admin: boolean;
  round: number | null;
  candidates?: CraqueCandidate[];
  closes_at?: string | null;
  extended?: boolean | null;
  i_am_elector?: boolean;
  my_vote?: string | null;
  can_open?: boolean;
  blocked?: string | null;
  no_winner_reason?: string | null;
  winner_membership_id?: string | null;
  rectification_pending?: boolean;
};

export default function CraqueTemporada() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [seasons, setSeasons] = useState<Season[]>([]);
  const [seasonId, setSeasonId] = useState<string | null>(null);
  const [state, setState] = useState<State | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    loadReadableSeasons(id)
      .then((ss) => {
        setSeasons(ss);
        setSeasonId((cur) => cur ?? ss.find((s) => s.status === 'closed')?.id ?? ss[0]?.id ?? null);
      })
      .catch((e) => setMsg(friendly((e as Error).message)));
  }, [id]);

  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true;
    (async () => {
      if (!seasonId) return;
      const { data, error } = await supabase.rpc('get_season_craque', { p_season: seasonId });
      if (!alive) return;
      if (error) setMsg(friendly(error.message));
      else {
        setMsg(null);
        setState(data as State);
      }
    })();
    const t = setInterval(() => setNow(Date.now()), 30000);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [seasonId, tick]);
  const load = async () => setTick((n) => n + 1);

  const run = async (fn: 'open_season_craque_poll' | 'confirm_season_craque' | 'cast_season_craque_vote', candidate?: string) => {
    if (!seasonId) return;
    setBusy(true);
    const { error } = await supabase.rpc(fn, candidate ? { p_season: seasonId, p_candidate: candidate } : { p_season: seasonId });
    setBusy(false);
    if (error) setMsg(friendly(error.message));
    await load();
  };

  const name = (mid?: string | null) => state?.candidates?.find((c) => c.membership_id === mid)?.name ?? 'Jogador';
  const open = state?.status === 'round1' || state?.status === 'round2';

  return (
    <Screen>
      <Title>Craque da Temporada</Title>
      {seasons.length > 1 && <Chips options={seasons.map((s) => ({ value: s.id, label: s.name }))} value={seasonId} onChange={(v) => { setState(null); setSeasonId(v); }} />}
      <ErrorText>{msg}</ErrorText>
      {!state ? (
        <Sub>Carregando…</Sub>
      ) : (
        <>
          <Section first>{statusTitle(state.status, state.round, state.no_winner_reason)}</Section>
          {state.status === 'not_started' && (
            <EmptyState
              title={state.can_open ? 'A temporada terminou.' : 'Ainda não é hora.'}
              hint={state.can_open ? 'Abra a votação para quem disputou partidas.' : 'A votação só abre depois do encerramento oficial da temporada.'}
            >
              {state.is_admin && state.can_open ? <Button title="Abrir votação (72 h)" loading={busy} onPress={() => run('open_season_craque_poll')} /> : null}
              {state.blocked ? <ErrorText>Empate de OVR na escolha dos candidatos: aguardando decisão do produto.</ErrorText> : null}
            </EmptyState>
          )}
          {state.status === 'awaiting_open' && state.is_admin && (
            <Button title="Reabrir votação com os candidatos corrigidos" loading={busy} onPress={() => run('open_season_craque_poll')} />
          )}
          {open && (
            <>
              <Sub>
                Encerra em {remaining(state.closes_at, now)}
                {state.extended ? ' (prorrogada por falta de quórum)' : ''}. Voto secreto; você pode trocar até o encerramento.
              </Sub>
              {!state.i_am_elector && <Sub>Você não vota neste turno.</Sub>}
              {(state.candidates ?? [])
                .filter((c) => state.round !== 2 || c.finalist)
                .map((c) => (
                  <View key={c.membership_id} style={{ gap: 6, paddingVertical: 8 }}>
                    <Text style={type.cardTitle}>{c.name ?? 'Jogador'}</Text>
                    <Sub>
                      {candidateReason(c)} · OVR {c.ovr == null ? '—' : Math.round(Number(c.ovr))}
                    </Sub>
                    {state.i_am_elector && (
                      <Button
                        title={state.my_vote === c.membership_id ? 'Seu voto' : 'Votar'}
                        kind={state.my_vote === c.membership_id ? 'secondary' : 'primary'}
                        loading={busy}
                        onPress={() => run('cast_season_craque_vote', c.membership_id)}
                      />
                    )}
                  </View>
                ))}
            </>
          )}
          {state.status === 'awaiting_admin' && state.is_admin && (
            <>
              <Text style={[type.body, { color: colors.deepBlue }]}>Vencedor: {name(state.winner_membership_id)}</Text>
              <Button title="Confirmar e publicar" loading={busy} onPress={() => run('confirm_season_craque')} />
            </>
          )}
          {state.status === 'published' && <Text style={type.cardTitle}>{name(state.winner_membership_id)}</Text>}
          {state.rectification_pending && <ErrorText>Uma correção mudou os candidatos depois da publicação: retificação pendente.</ErrorText>}
        </>
      )}
    </Screen>
  );
}
