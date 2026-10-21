// Anulação de partida (RN-117): só o admin, até 7 dias após finalizar, com motivo e confirmação.
// Mostra antes o que muda (preview_match_annulment) e só então chama annul_match.
import { useState } from 'react';

import { AWARD_LABEL } from './career';
import { confirm } from './dialog';
import { friendly } from './errors';
import { fmtDate, fmtTime } from './match';
import { supabase } from './supabase';
import { Body, Button, Card, Chips, ErrorText, Input, Sub } from './ui';

export const ANNUL_REASONS = [
  { value: 'sheet_error', label: 'Erro na súmula' },
  { value: 'duplicate_match', label: 'Partida duplicada' },
  { value: 'match_not_played', label: 'Partida não aconteceu' },
  { value: 'other', label: 'Outro' },
] as const;
type Reason = (typeof ANNUL_REASONS)[number]['value'];

type Preview = {
  can_annul: boolean;
  deadline: string;
  players_affected: number;
  goals: number;
  awards_revoked: { award_type: string; membership_id: string }[];
  has_round_selection: boolean;
  month_awards_recomputed: boolean;
};

export function AnnulMatch({
  matchId,
  nameOf,
  onDone,
}: {
  matchId: string;
  nameOf: (membershipId: string) => string;
  onDone: () => void;
}) {
  const [preview, setPreview] = useState<Preview | null>(null);
  const [reason, setReason] = useState<Reason | null>(null);
  const [description, setDescription] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  async function abrir() {
    setBusy(true);
    setMsg(null);
    const { data, error } = await supabase.rpc('preview_match_annulment', { p_match: matchId });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    setPreview(data as Preview);
  }

  async function anular() {
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc('annul_match', {
      p_match: matchId,
      p_reason_category: reason,
      p_description: description,
      p_confirm: true,
    });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    setPreview(null);
    onDone();
  }

  if (!preview) {
    return (
      <>
        <ErrorText>{msg}</ErrorText>
        <Button title="Anular partida" kind="danger" onPress={abrir} loading={busy} />
      </>
    );
  }

  if (!preview.can_annul) {
    return (
      <Card>
        <Sub>O prazo para anular (7 dias após finalizar) acabou em {fmtDate(preview.deadline)}.</Sub>
        <Button title="Fechar" kind="secondary" onPress={() => setPreview(null)} />
      </Card>
    );
  }

  const ok = !!reason && description.trim().length >= 10;
  return (
    <Card>
      <Body>Anular esta partida</Body>
      <Sub>
        Ela não é apagada, mas deixa de contar. Rankings, cartas, prêmios e figurinhas são recalculados. Os votos não
        voltam e não dá para desfazer: se preciso, registre a partida de novo.
      </Sub>
      <Sub>
        Afeta {preview.players_affected} jogador{preview.players_affected === 1 ? '' : 'es'} e {preview.goals} gol
        {preview.goals === 1 ? '' : 's'}.
      </Sub>
      {preview.awards_revoked.length > 0 && (
        <Sub>
          Prêmios removidos:{' '}
          {preview.awards_revoked.map((a) => `${AWARD_LABEL[a.award_type] ?? a.award_type} (${nameOf(a.membership_id)})`).join(', ')}.
        </Sub>
      )}
      {preview.has_round_selection && <Sub>A Seleção da Rodada desta partida será retirada.</Sub>}
      {preview.month_awards_recomputed && <Sub>Os prêmios do mês desta partida serão recalculados.</Sub>}
      <Sub>
        Prazo para anular: até {fmtTime(preview.deadline)} de {fmtDate(preview.deadline)}.
      </Sub>
      <Sub>Motivo</Sub>
      <Chips options={ANNUL_REASONS} value={reason} onChange={setReason} />
      <Input
        autoCapitalize="sentences"
        placeholder="explique o que aconteceu (10 caracteres ou mais)"
        value={description}
        onChangeText={setDescription}
        multiline
      />
      <ErrorText>{msg}</ErrorText>
      <Button
        title="Anular partida"
        kind="danger"
        loading={busy}
        disabled={!ok}
        onPress={() =>
          confirm(
            'Anular partida?',
            'Todos da pelada serão avisados. Não dá para desfazer.',
            'Anular',
            anular,
          )
        }
      />
      <Button title="Cancelar" kind="secondary" onPress={() => setPreview(null)} />
    </Card>
  );
}
