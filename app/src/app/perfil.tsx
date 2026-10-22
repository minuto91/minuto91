import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Text, View } from 'react-native';

import { Avatar, pickAndUploadAvatar, removeAvatar } from '../lib/avatar';
import { confirm } from '../lib/dialog';
import { friendly } from '../lib/errors';
import { useAuth } from '../lib/session';
import { supabase } from '../lib/supabase';
import { colors, FEET, Foot } from '../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Input, Screen, Sub, Title } from '../lib/ui';

type Profile = { display_name: string; avatar_path: string | null; dominant_foot: Foot | null };

// Meu perfil: dados da pessoa, iguais em todas as peladas (a posição fica em cada pelada, na carta).
export default function Perfil() {
  const router = useRouter();
  const { session } = useAuth();
  const [profile, setProfile] = useState<Profile | null>(null);
  const [name, setName] = useState('');
  const [foot, setFoot] = useState<Foot | null>(null);
  const [reload, setReload] = useState(0);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);

  useEffect(() => {
    if (!session) return;
    let alive = true;
    (async () => {
      const { data, error } = await supabase
        .from('profiles')
        .select('display_name, avatar_path, dominant_foot')
        .eq('id', session.user.id)
        .maybeSingle();
      if (!alive) return;
      if (error || !data) return setMsg(error ? friendly(error.message) : 'Perfil não encontrado.');
      setProfile(data as Profile);
      setName(data.display_name);
      setFoot((data.dominant_foot as Foot | null) ?? null);
    })();
    return () => {
      alive = false;
    };
  }, [session, reload]);

  async function trocarFoto() {
    if (!session) return;
    setBusy('foto');
    setMsg(null);
    setOk(null);
    try {
      if (await pickAndUploadAvatar(session.user.id)) {
        setOk('Foto atualizada.');
        setReload((n) => n + 1);
      }
    } catch (e) {
      setMsg(e instanceof Error ? e.message : 'Não foi possível usar essa foto.');
    }
    setBusy(null);
  }

  function tirarFoto() {
    confirm('Remover foto', 'Sua foto sai do perfil e das cartas. Você pode pôr outra depois.', 'Remover', async () => {
      setBusy('remover');
      setMsg(null);
      setOk(null);
      try {
        await removeAvatar();
        setOk('Foto removida.');
        setReload((n) => n + 1);
      } catch (e) {
        setMsg((e as Error).message);
      }
      setBusy(null);
    });
  }

  async function salvar() {
    setBusy('salvar');
    setMsg(null);
    setOk(null);
    const { error } = await supabase.rpc('update_my_profile', { p_display_name: name, p_dominant_foot: foot });
    setBusy(null);
    if (error) return setMsg(friendly(error.message));
    setOk('Perfil salvo.');
    setReload((n) => n + 1);
  }

  if (!profile) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }

  const changed = name.trim() !== profile.display_name || foot !== profile.dominant_foot;

  return (
    <Screen>
      <Title>Meu perfil</Title>
      <ErrorText>{msg}</ErrorText>
      {ok && <Text style={{ color: colors.deepBlue, fontWeight: '600' }}>{ok}</Text>}

      <Card>
        <View style={{ alignItems: 'center', gap: 10, paddingVertical: 6 }}>
          <Avatar path={profile.avatar_path} name={profile.display_name} size={120} />
          <Sub>Aparece no seu perfil e nas suas cartas, só para quem joga com você.</Sub>
        </View>
        <Button
          title={profile.avatar_path ? 'Trocar foto' : 'Escolher foto'}
          kind="secondary"
          onPress={trocarFoto}
          loading={busy === 'foto'}
          disabled={!!busy}
        />
        {profile.avatar_path && (
          <Button title="Remover foto" kind="danger" onPress={tirarFoto} loading={busy === 'remover'} disabled={!!busy} />
        )}
      </Card>

      <Card>
        <Body>Nome</Body>
        <Sub>É o nome que aparece nas suas peladas.</Sub>
        <Input value={name} onChangeText={setName} maxLength={80} autoCapitalize="words" placeholder="Seu apelido" />
        <Body>Pé dominante</Body>
        <Sub>Opcional. Só informativo: não muda nota nem carta.</Sub>
        <Chips options={FEET} value={foot} onChange={(v) => setFoot(v === foot ? null : v)} />
      </Card>

      <Button title="Salvar" onPress={salvar} loading={busy === 'salvar'} disabled={!changed || !name.trim() || !!busy} />
      <Sub>A posição é escolhida em cada pelada: abra a sua carta na pelada para mudar.</Sub>
      <Button title="Minha conta" kind="secondary" onPress={() => router.push('/conta')} />
    </Screen>
  );
}
