import * as Linking from 'expo-linking';
import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Platform } from 'react-native';

import { friendly } from '../lib/errors';
import { supabase } from '../lib/supabase';
import { Body, Button, ErrorText, Input, Screen, Sub, Title } from '../lib/ui';

// A17: o link do e-mail "Esqueci minha senha" abre esta tela. O Supabase manda a sessão de recuperação
// no fragmento (#access_token=...&type=recovery) ou um código (?code=..., fluxo PKCE); link vencido ou
// já usado chega como #error_code=otp_expired. Depois de trocar a senha, a pessoa segue logada.
type Phase = 'checking' | 'ready' | 'invalid' | 'done';

function params(url: string) {
  const out = new URLSearchParams(url.split('?')[1]?.split('#')[0] ?? '');
  new URLSearchParams(url.split('#')[1] ?? '').forEach((v, k) => out.set(k, v));
  return out;
}

export default function RedefinirSenha() {
  const router = useRouter();
  const linkUrl = Linking.useLinkingURL();
  const [phase, setPhase] = useState<Phase>('checking');
  const [senha, setSenha] = useState('');
  const [repetir, setRepetir] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const url = Platform.OS === 'web' && typeof window !== 'undefined' ? window.location.href : (linkUrl ?? '');
      const p = params(url);
      let ok = false;
      let err: string | null = null;
      if (p.get('error_code') || p.get('error')) {
        err = p.get('error_code') === 'otp_expired' ? 'O link venceu ou já foi usado. Peça um novo na tela de entrada.' : 'Link inválido. Peça um novo na tela de entrada.';
      } else if (p.get('access_token') && p.get('refresh_token')) {
        const { error } = await supabase.auth.setSession({ access_token: p.get('access_token')!, refresh_token: p.get('refresh_token')! });
        ok = !error;
        if (error) err = 'O link venceu ou já foi usado. Peça um novo na tela de entrada.';
      } else if (p.get('code')) {
        const { error } = await supabase.auth.exchangeCodeForSession(p.get('code')!);
        ok = !error;
        if (error) err = 'O link venceu ou já foi usado. Peça um novo na tela de entrada.';
      } else {
        // Sem parâmetros: pode ser a sessão de recuperação já aplicada (voltou para a tela).
        const { data } = await supabase.auth.getSession();
        ok = !!data.session;
        if (!ok && linkUrl === null) return; // a URL do link ainda está chegando
        if (!ok) err = 'Abra esta tela pelo link que enviamos por e-mail.';
      }
      if (!alive) return;
      setMsg(err);
      setPhase(ok ? 'ready' : 'invalid');
    })();
    return () => {
      alive = false;
    };
  }, [linkUrl]);

  async function salvar() {
    if (senha.length < 6) return setMsg('A senha precisa ter 6 ou mais caracteres.');
    if (senha !== repetir) return setMsg('As duas senhas não são iguais.');
    setBusy(true);
    setMsg(null);
    const { error } = await supabase.auth.updateUser({ password: senha });
    setBusy(false);
    if (error) return setMsg(/same|different/i.test(error.message) ? 'Escolha uma senha diferente da anterior.' : friendly(error.message));
    setPhase('done');
  }

  return (
    <Screen>
      <Title>Nova senha</Title>
      {phase === 'checking' && <Sub>Conferindo o link...</Sub>}
      {phase === 'invalid' && (
        <>
          <ErrorText>{msg}</ErrorText>
          <Button title="Ir para a entrada" onPress={() => router.replace('/login')} />
        </>
      )}
      {phase === 'ready' && (
        <>
          <Sub>Escolha a nova senha da sua conta.</Sub>
          <Input placeholder="nova senha (6 ou mais caracteres)" secureTextEntry value={senha} onChangeText={setSenha} autoComplete="new-password" />
          <Input placeholder="repita a nova senha" secureTextEntry value={repetir} onChangeText={setRepetir} autoComplete="new-password" />
          <ErrorText>{msg}</ErrorText>
          <Button title="Salvar nova senha" onPress={salvar} loading={busy} />
        </>
      )}
      {phase === 'done' && (
        <>
          <Body>Senha alterada. Você já está dentro do app.</Body>
          <Button title="Continuar" onPress={() => router.replace('/')} />
        </>
      )}
    </Screen>
  );
}
