import { useRouter } from 'expo-router';
import { useState } from 'react';

import { Button, Input, Screen, Sub } from '../lib/ui';

export default function Entrar() {
  const router = useRouter();
  const [token, setToken] = useState('');
  return (
    <Screen>
      <Sub>Cole o código de convite que você recebeu.</Sub>
      <Input placeholder="código do convite" value={token} onChangeText={setToken} />
      <Button
        title="Continuar"
        disabled={token.trim().length < 10}
        onPress={() => router.replace({ pathname: '/convite/[token]', params: { token: token.trim() } })}
      />
    </Screen>
  );
}
