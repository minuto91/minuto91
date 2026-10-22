import { useState } from 'react';
import { Switch, Text, View } from 'react-native';

import { friendly } from '../lib/errors';
import { useAuth } from '../lib/session';
import { supabase } from '../lib/supabase';
import { colors } from '../lib/theme';
import { Button, ErrorText, Input, Screen, Sub, Title } from '../lib/ui';

export default function Onboarding() {
  const { session, refresh } = useAuth();
  const [nome, setNome] = useState('');
  const [adulto, setAdulto] = useState(false);
  const [termos, setTermos] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  async function concluir() {
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.rpc('complete_onboarding', {
      p_display_name: nome.trim() || (session?.user.email ?? 'Jogador').split('@')[0],
      p_adult: adulto,
      p_terms: termos,
    });
    if (error) {
      setMsg(friendly(error.message));
    } else {
      await refresh();
    }
    setBusy(false);
  }

  return (
    <Screen>
      <Title>Como te chamam na pelada?</Title>
      <Sub>Esse apelido aparece nos seus Cards e rankings.</Sub>
      <Input autoCapitalize="words" placeholder="seu apelido" value={nome} onChangeText={setNome} />
      <Row value={adulto} onChange={setAdulto} label="Declaro que tenho 18 anos ou mais." />
      <Row value={termos} onChange={setTermos} label="Li e aceito os Termos de Uso e a Política de Privacidade." />
      <ErrorText>{msg}</ErrorText>
      <Button title="Continuar" onPress={concluir} loading={busy} disabled={!adulto || !termos} />
      <Button title="Sair" kind="secondary" onPress={() => supabase.auth.signOut()} />
    </Screen>
  );
}

function Row({ value, onChange, label }: { value: boolean; onChange: (v: boolean) => void; label: string }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
      <Switch value={value} onValueChange={onChange} trackColor={{ true: colors.blue }} />
      <Text style={{ flex: 1, color: colors.ink }}>{label}</Text>
    </View>
  );
}
