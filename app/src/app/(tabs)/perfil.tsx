import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { View } from 'react-native';

import { Avatar } from '../../lib/avatar';
import { friendly } from '../../lib/errors';
import {
  AchievementsList,
  CardsList,
  Career,
  loadMyProfile,
  loadPlayer,
  MyProfile,
  PlayerProfile,
} from '../../lib/profile';
import { useAuth } from '../../lib/session';
import { positionLabel } from '../../lib/theme';
import { Button, Chips, ErrorText, LoadingBlock, Screen, Sub, Title } from '../../lib/ui';

const TABS = [
  { value: 'conquistas', label: 'Conquistas' },
  { value: 'cartas', label: 'Cards' },
] as const;
type Tab = (typeof TABS)[number]['value'];

// Meu Perfil: a identidade da pessoa no Minuto 91 (igual em todas as peladas). A carta é o
// desempenho em cada pelada; a posição também é de cada pelada.
export default function Perfil() {
  const router = useRouter();
  const { session } = useAuth();
  const [tab, setTab] = useState<Tab>('conquistas');
  const [me, setMe] = useState<MyProfile | null>(null);
  const [player, setPlayer] = useState<PlayerProfile | null>(null);
  const [career, setCareer] = useState<Career | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const mainPosition = career?.visible ? (career.peladas.find((p) => p.status === 'active')?.position ?? null) : null;

  useEffect(() => {
    if (!session) return;
    let alive = true;
    (async () => {
      try {
        const [mine, other] = await Promise.all([loadMyProfile(), loadPlayer(session.user.id)]);
        if (!alive) return;
        if (!mine) return setMsg('Perfil não encontrado.');
        setMe(mine);
        setPlayer(other.profile);
        setCareer(other.career);
      } catch (e) {
        if (alive) setMsg(friendly((e as Error).message));
      }
    })();
    return () => {
      alive = false;
    };
  }, [session]);

  if (!me || !career || !player) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <LoadingBlock />}
      </Screen>
    );
  }

  return (
    <Screen>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
        <Avatar path={me.avatar_path} name={me.display_name} size={72} />
        <View style={{ flex: 1, gap: 2 }}>
          <Title>{me.display_name}</Title>
          {/* REV-022: só a posição (da pelada atual), sem complemento com o nome da pelada. */}
          {mainPosition ? <Sub>{positionLabel(mainPosition)}</Sub> : null}
        </View>
      </View>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
        <Button title="Minha conta" kind="secondary" size="sm" onPress={() => router.push('/conta')} />
        <Button title="Personalizar Central" kind="secondary" size="sm" onPress={() => router.push('/personalizar-central')} />
        <Button title="Meu histórico de votos" kind="secondary" size="sm" onPress={() => router.push('/historico-votos')} />
      </View>
      <Chips options={TABS} value={tab} onChange={setTab} />
      <ErrorText>{msg}</ErrorText>

      {tab === 'conquistas' && career.visible && <AchievementsList items={career.achievements} />}

      {tab === 'cartas' && career.visible && <CardsList career={career} playerName={me.display_name} photoPath={me.avatar_path} />}
    </Screen>
  );
}
