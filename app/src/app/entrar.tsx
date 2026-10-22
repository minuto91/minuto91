import { useRouter } from 'expo-router';
import { useState } from 'react';

import { extractInviteToken } from '../lib/invite';
import { Button, Input, Screen, Sub } from '../lib/ui';

export default function Entrar() {
  const router = useRouter();
  const [text, setText] = useState('');
  // Aceita o código, o link ou a mensagem inteira colada do WhatsApp.
  const token = extractInviteToken(text);
  return (
    <Screen>
      <Sub>Cole o código ou o link do convite que você recebeu.</Sub>
      <Input placeholder="código ou link do convite" value={text} onChangeText={setText} multiline />
      {text.trim().length > 0 && !token && <Sub>Não encontramos um código de convite nesse texto.</Sub>}
      <Button
        title="Continuar"
        disabled={!token}
        onPress={() => token && router.replace({ pathname: '/convite/[token]', params: { token } })}
      />
    </Screen>
  );
}
