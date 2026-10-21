import { useRouter } from 'expo-router';
import { useState } from 'react';

import { friendly } from '../lib/errors';
import { Position } from '../lib/theme';
import { supabase } from '../lib/supabase';
import { Button, ErrorText, Input, PositionPicker, Screen, Sub } from '../lib/ui';

export default function CriarPelada() {
  const router = useRouter();
  const [nome, setNome] = useState('');
  const [pos, setPos] = useState<Position | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  async function criar() {
    if (!pos) return setMsg('Escolha sua posição.');
    setBusy(true);
    setMsg(null);
    const { data, error } = await supabase.rpc('create_pelada', { p_name: nome, p_position: pos });
    setBusy(false);
    if (error) return setMsg(friendly(error.message));
    router.replace({ pathname: '/pelada/[id]', params: { id: String(data) } });
  }

  return (
    <Screen>
      <Input autoCapitalize="sentences" placeholder="nome da pelada" value={nome} onChangeText={setNome} />
      <Sub>Sua posição nessa pelada</Sub>
      <PositionPicker value={pos} onChange={setPos} />
      <ErrorText>{msg}</ErrorText>
      <Button title="Criar" onPress={criar} loading={busy} disabled={nome.trim().length < 2} />
    </Screen>
  );
}
