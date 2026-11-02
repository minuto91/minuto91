import { View } from 'react-native';

import { Text } from './text';
import { colors, type } from './theme';
import { Button, Chips, EmptyState, ErrorText, Screen, Section, Sub, Title } from './ui';
import { candidateReason, CraqueCandidate, CraqueStatus, remaining, statusTitle } from './v86logic';

// Parte visual do Craque da Temporada (sem rede): usada pela tela real e pela vitrine dev-v86.
export type State = {
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

export function CraqueView({ state, seasons, seasonId, onSeason, busy, msg, now, onOpen, onConfirm, onVote }: {
  state: State | null;
  seasons: { id: string; name: string }[];
  seasonId: string | null;
  onSeason: (id: string) => void;
  busy: boolean;
  msg: string | null;
  now: number;
  onOpen: () => void;
  onConfirm: () => void;
  onVote: (candidate: string) => void;
}) {
  const name = (mid?: string | null) => state?.candidates?.find((c) => c.membership_id === mid)?.name ?? 'Jogador';
  const open = state?.status === 'round1' || state?.status === 'round2';

  return (
    <Screen>
      <Title>Craque da Temporada</Title>
      {seasons.length > 1 && <Chips options={seasons.map((s) => ({ value: s.id, label: s.name }))} value={seasonId} onChange={(v) => onSeason(v)} />}
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
              {state.is_admin && state.can_open ? <Button title="Abrir votação (72 h)" loading={busy} onPress={() => onOpen()} /> : null}
              {state.blocked ? <ErrorText>Empate de OVR na escolha dos candidatos: aguardando decisão do produto.</ErrorText> : null}
            </EmptyState>
          )}
          {state.status === 'awaiting_open' && state.is_admin && (
            <Button title="Reabrir votação com os candidatos corrigidos" loading={busy} onPress={() => onOpen()} />
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
                        onPress={() => onVote(c.membership_id)}
                      />
                    )}
                  </View>
                ))}
            </>
          )}
          {state.status === 'awaiting_admin' && state.is_admin && (
            <>
              <Text style={[type.body, { color: colors.ink }]}>Vencedor: {name(state.winner_membership_id)}</Text>
              <Button title="Confirmar e publicar" loading={busy} onPress={() => onConfirm()} />
            </>
          )}
          {state.status === 'published' && <Text style={type.cardTitle}>{name(state.winner_membership_id)}</Text>}
          {state.rectification_pending && <ErrorText>Uma correção mudou os candidatos depois da publicação: retificação pendente.</ErrorText>}
        </>
      )}
    </Screen>
  );
}
