import { useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { View } from 'react-native';

import { Avatar } from '../../lib/avatar';
import { friendly } from '../../lib/errors';
import {
  AchievementsList,
  CardsList,
  Career,
  CareerByPelada,
  CareerSummary,
  loadPlayer,
  PeladasList,
  PlayerProfile,
} from '../../lib/profile';
import { footLabel } from '../../lib/theme';
import { Card, Chips, ErrorText, Screen, Sub, Title } from '../../lib/ui';

const TABS = [
  { value: 'carreira', label: 'Carreira' },
  { value: 'peladas', label: 'Peladas' },
  { value: 'conquistas', label: 'Conquistas' },
  { value: 'cartas', label: 'Cards' },
] as const;
type Tab = (typeof TABS)[number]['value'];

// Perfil global de outro jogador (id da conta). O servidor decide o que aparece: privacidade do
// perfil e da carreira, bloqueios e conta em exclusão (029/030).
export default function Atleta() {
  const { id, name } = useLocalSearchParams<{ id: string; name?: string }>();
  const [tab, setTab] = useState<Tab>('carreira');
  const [profile, setProfile] = useState<PlayerProfile | null>(null);
  const [career, setCareer] = useState<Career | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    loadPlayer(id)
      .then((r) => {
        if (!alive) return;
        setProfile(r.profile);
        setCareer(r.career);
      })
      .catch((e) => alive && setMsg(friendly((e as Error).message)));
    return () => {
      alive = false;
    };
  }, [id]);

  if (!profile || !career) {
    return (
      <Screen>
        <ErrorText>{msg}</ErrorText>
        {!msg && <Sub>Carregando...</Sub>}
      </Screen>
    );
  }

  const displayName = profile.visible ? profile.display_name : (name ?? 'Jogador');
  const photo = profile.visible ? profile.avatar_path : null;

  if (!profile.visible && !career.visible) {
    return (
      <Screen>
        <Title>{displayName}</Title>
        <Card>
          <Sub>Este jogador deixou o perfil e a carreira privados. O Card dele continua na pelada de vocês.</Sub>
        </Card>
      </Screen>
    );
  }

  const tabs = TABS.filter((t) => (t.value === 'peladas' ? profile.visible : career.visible));
  const current = tabs.some((t) => t.value === tab) ? tab : tabs[0].value;

  return (
    <Screen>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
        <Avatar path={photo} name={displayName} size={72} />
        <View style={{ flex: 1, gap: 2 }}>
          <Title>{displayName}</Title>
          {profile.visible && profile.dominant_foot && <Sub>{footLabel(profile.dominant_foot)}</Sub>}
        </View>
      </View>
      {tabs.length > 1 && <Chips options={tabs} value={current} onChange={setTab} />}
      {!career.visible && <Sub>A carreira deste jogador é privada.</Sub>}

      {current === 'carreira' && career.visible && (
        <>
          <CareerSummary career={career} />
          <CareerByPelada career={career} />
        </>
      )}
      {current === 'peladas' && profile.visible && <PeladasList peladas={profile.peladas} isMe={false} />}
      {current === 'conquistas' && career.visible && <AchievementsList items={career.achievements} />}
      {current === 'cartas' && career.visible && <CardsList career={career} playerName={displayName} photoPath={photo} />}
    </Screen>
  );
}
