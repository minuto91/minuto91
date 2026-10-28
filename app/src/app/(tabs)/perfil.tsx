import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { View } from 'react-native';
import { Text } from '../../lib/text';

import { Avatar, pickAndUploadAvatar, removeAvatar } from '../../lib/avatar';
import { confirm } from '../../lib/dialog';
import { friendly } from '../../lib/errors';
import {
  AchievementsList,
  CardsList,
  Career,
  CareerByPelada,
  CareerSummary,
  loadMyProfile,
  loadPlayer,
  MyProfile,
  PeladasList,
  PlayerProfile,
  VISIBILITY,
  Visibility,
} from '../../lib/profile';
import { useAuth } from '../../lib/session';
import { supabase } from '../../lib/supabase';
import { colors, FEET, Foot, footLabel } from '../../lib/theme';
import { Body, Button, Card, Chips, ErrorText, Input, Screen, Sub, Title } from '../../lib/ui';

const TABS = [
  { value: 'geral', label: 'Visão geral' },
  { value: 'carreira', label: 'Carreira' },
  { value: 'peladas', label: 'Peladas' },
  { value: 'conquistas', label: 'Conquistas' },
  { value: 'cartas', label: 'Cards' },
  { value: 'privacidade', label: 'Privacidade' },
] as const;
type Tab = (typeof TABS)[number]['value'];

// Meu Perfil: a identidade da pessoa no Minuto 91 (igual em todas as peladas). A carta é o
// desempenho em cada pelada; a posição também é de cada pelada.
export default function Perfil() {
  const router = useRouter();
  const { session } = useAuth();
  const [tab, setTab] = useState<Tab>('geral');
  const [me, setMe] = useState<MyProfile | null>(null);
  const [player, setPlayer] = useState<PlayerProfile | null>(null);
  const [career, setCareer] = useState<Career | null>(null);
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState('');
  const [foot, setFoot] = useState<Foot | null>(null);
  const [profileVis, setProfileVis] = useState<Visibility>('peladas');
  const [careerVis, setCareerVis] = useState<Visibility>('peladas');
  const [reload, setReload] = useState(0);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);

  useEffect(() => {
    if (!session) return;
    let alive = true;
    (async () => {
      try {
        const [mine, other] = await Promise.all([loadMyProfile(), loadPlayer(session.user.id)]);
        if (!alive) return;
        if (!mine) return setMsg('Perfil não encontrado.');
        setMe(mine);
        setName(mine.display_name);
        setFoot((mine.dominant_foot as Foot | null) ?? null);
        setProfileVis(mine.profile_visibility);
        setCareerVis(mine.career_visibility);
        setPlayer(other.profile);
        setCareer(other.career);
      } catch (e) {
        if (alive) setMsg(friendly((e as Error).message));
      }
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
    confirm('Remover foto', 'Sua foto sai do perfil e dos Cards. Você pode pôr outra depois.', 'Remover', async () => {
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
    setEditing(false);
    setReload((n) => n + 1);
  }

  async function salvarPrivacidade() {
    setBusy('privacidade');
    setMsg(null);
    setOk(null);
    const { error } = await supabase.rpc('set_my_privacy', { p_profile: profileVis, p_career: careerVis });
    setBusy(null);
    if (error) return setMsg(friendly(error.message));
    setOk('Privacidade salva. Vale na hora para o perfil e a carreira.');
    setReload((n) => n + 1);
  }

  if (!me || !career || !player) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }

  const changed = name.trim() !== me.display_name || foot !== me.dominant_foot;
  const privacyChanged = profileVis !== me.profile_visibility || careerVis !== me.career_visibility;
  const visLabel = (v: Visibility) => VISIBILITY.find((x) => x.value === v)?.label ?? v;

  return (
    <Screen>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
        <Avatar path={me.avatar_path} name={me.display_name} size={72} />
        <View style={{ flex: 1, gap: 2 }}>
          <Title>{me.display_name}</Title>
          <Sub>{me.dominant_foot ? footLabel(me.dominant_foot) : 'Meu perfil'}</Sub>
        </View>
      </View>
      <Chips options={TABS} value={tab} onChange={(v) => { setOk(null); setTab(v); }} />
      <ErrorText>{msg}</ErrorText>
      {ok && <Text style={{ color: colors.deepBlue, fontWeight: '600' }}>{ok}</Text>}

      {tab === 'geral' && (
        <>
          {career.visible && <CareerSummary career={career} />}
          {!editing ? (
            <Button title="Editar foto, nome e pé" kind="secondary" onPress={() => setEditing(true)} />
          ) : (
            <>
              <Card>
                <View style={{ alignItems: 'center', gap: 10, paddingVertical: 6 }}>
                  <Avatar path={me.avatar_path} name={me.display_name} size={120} />
                  <Sub>Aparece no seu perfil e nos seus Cards, para quem joga com você (e para todos, se o perfil for público).</Sub>
                </View>
                <Button
                  title={me.avatar_path ? 'Trocar foto' : 'Escolher foto'}
                  kind="secondary"
                  onPress={trocarFoto}
                  loading={busy === 'foto'}
                  disabled={!!busy}
                />
                {me.avatar_path && (
                  <Button title="Remover foto" kind="danger" onPress={tirarFoto} loading={busy === 'remover'} disabled={!!busy} />
                )}
              </Card>
              <Card>
                <Body>Nome</Body>
                <Sub>É o nome que aparece nas suas peladas.</Sub>
                <Input value={name} onChangeText={setName} maxLength={80} autoCapitalize="words" placeholder="Seu apelido" />
                <Body>Pé dominante</Body>
                <Sub>Opcional. Só informativo: não muda nota nem Card.</Sub>
                <Chips options={FEET} value={foot} onChange={(v) => setFoot(v === foot ? null : v)} />
              </Card>
              <Button title="Salvar" onPress={salvar} loading={busy === 'salvar'} disabled={!changed || !name.trim() || !!busy} />
              <Button title="Cancelar" kind="secondary" onPress={() => setEditing(false)} />
            </>
          )}
          <Sub>A posição é escolhida em cada pelada: abra o seu Card na pelada para mudar.</Sub>
          <Button title="Minha Carreira" onPress={() => router.push('/carreira')} />
          <Button title="Minha conta" kind="secondary" onPress={() => router.push('/conta')} />
        </>
      )}

      {tab === 'carreira' && career.visible && (
        <>
          <CareerSummary career={career} />
          <CareerByPelada career={career} />
        </>
      )}

      {tab === 'peladas' && player.visible && <PeladasList peladas={player.peladas} isMe />}

      {tab === 'conquistas' && career.visible && <AchievementsList items={career.achievements} />}

      {tab === 'cartas' && career.visible && <CardsList career={career} playerName={me.display_name} photoPath={me.avatar_path} />}

      {tab === 'privacidade' && (
        <>
          <Card>
            <Body>Quem vê meu perfil</Body>
            <Sub>Pé dominante, suas peladas e conquistas. Agora: {visLabel(me.profile_visibility)}.</Sub>
            <Chips options={VISIBILITY} value={profileVis} onChange={setProfileVis} />
            <Sub>{VISIBILITY.find((x) => x.value === profileVis)?.hint}</Sub>
          </Card>
          <Card>
            <Body>Quem vê minha carreira</Body>
            <Sub>Totais e histórico de todas as peladas. Agora: {visLabel(me.career_visibility)}.</Sub>
            <Chips options={VISIBILITY} value={careerVis} onChange={setCareerVis} />
            <Sub>{VISIBILITY.find((x) => x.value === careerVis)?.hint}</Sub>
          </Card>
          <Button title="Salvar privacidade" onPress={salvarPrivacidade} loading={busy === 'privacidade'} disabled={!privacyChanged || !!busy} />
          <Card>
            <Sub>
              Dentro de cada pelada, seu nome, foto, Card e estatísticas continuam visíveis para os colegas: a súmula, a votação e
              os rankings precisam deles. Quem você bloqueia (ou quem bloqueou você) não vê seu perfil nem sua carreira.
            </Sub>
            <Sub>
              Uma foto já aberta por alguém pode continuar na tela dele por até 15 minutos. Imagens que você compartilhou fora do
              app (Cards e artes) não podem ser apagadas ou recuperadas pelo Minuto 91 depois do envio.
            </Sub>
          </Card>
        </>
      )}
    </Screen>
  );
}
