// Denúncia de conteúdo (RF-014): apelido, perfil, pelada ou convidado.
import { useState } from 'react';
import { Pressable, Text } from 'react-native';

import { friendly } from './errors';
import { supabase } from './supabase';
import { colors } from './theme';
import { Button, Card, Chips, ErrorText, Input, Sub } from './ui';

const REASONS = [
  { value: 'offensive', label: 'Ofensivo' },
  { value: 'inappropriate_image', label: 'Imagem imprópria' },
  { value: 'impersonation', label: 'Se passando por outro' },
  { value: 'spam', label: 'Spam' },
  { value: 'other', label: 'Outro' },
] as const;
type Reason = (typeof REASONS)[number]['value'];

export function ReportLink({
  peladaId,
  targetType,
  targetId,
  label,
}: {
  peladaId: string;
  targetType: 'profile' | 'member_name' | 'pelada' | 'guest';
  targetId: string;
  label: string;
}) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState<Reason | null>(null);
  const [details, setDetails] = useState('');
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  async function enviar() {
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc('report_content', {
      p_pelada: peladaId,
      p_target_type: targetType,
      p_target_id: targetId,
      p_reason: reason,
      p_details: details,
    });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    setSent(true);
    setOpen(false);
  }

  if (sent) return <Sub>Denúncia enviada. Nossa equipe vai analisar.</Sub>;
  if (!open) {
    return (
      <Pressable onPress={() => setOpen(true)}>
        <Text style={{ color: colors.danger, fontWeight: '600' }}>{label}</Text>
      </Pressable>
    );
  }
  return (
    <Card>
      <Sub>Por que você está denunciando?</Sub>
      <Chips options={REASONS} value={reason} onChange={setReason} />
      <Input autoCapitalize="sentences" placeholder="detalhes (opcional)" value={details} onChangeText={setDetails} />
      <ErrorText>{msg}</ErrorText>
      <Button title="Enviar denúncia" kind="danger" onPress={enviar} loading={busy} disabled={!reason} />
      <Button title="Cancelar" kind="secondary" onPress={() => setOpen(false)} />
    </Card>
  );
}
