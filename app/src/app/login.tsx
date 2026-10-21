import * as AppleAuthentication from 'expo-apple-authentication';
import * as Linking from 'expo-linking';
import * as WebBrowser from 'expo-web-browser';
import { useState } from 'react';
import { Platform, View } from 'react-native';

import { friendly } from '../lib/errors';
import { supabase } from '../lib/supabase';
import { Button, ErrorText, Input, Screen, Sub, Title } from '../lib/ui';

WebBrowser.maybeCompleteAuthSession();

export default function Login() {
  const [email, setEmail] = useState('');
  const [senha, setSenha] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  async function run(name: string, fn: () => Promise<string | null | void>) {
    setBusy(name);
    setMsg(null);
    try {
      const r = await fn();
      if (r) setMsg(r);
    } catch (e) {
      setMsg(friendly(e instanceof Error ? e.message : String(e)));
    } finally {
      setBusy(null);
    }
  }

  const entrar = () =>
    run('entrar', async () => {
      const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: senha });
      return error ? 'E-mail ou senha incorretos.' : null;
    });

  const cadastrar = () =>
    run('cadastrar', async () => {
      const { data, error } = await supabase.auth.signUp({ email: email.trim(), password: senha });
      if (error) return error.message;
      return data.session ? null : 'Enviamos um e-mail de confirmação. Confirme e depois entre.';
    });

  const google = () =>
    run('google', async () => {
      const redirectTo = Linking.createURL('auth-callback');
      const { data, error } = await supabase.auth.signInWithOAuth({
        provider: 'google',
        options: { redirectTo, skipBrowserRedirect: true },
      });
      if (error || !data.url) return error?.message ?? 'Não foi possível iniciar o login com Google.';
      // No Expo Go o retorno precisa do modo túnel (--tunnel): o Supabase recusa exp:// com IP numérico.
      const res = await WebBrowser.openAuthSessionAsync(data.url, redirectTo);
      if (res.type !== 'success') return null;
      const frag = res.url.split('#')[1] ?? '';
      const p = new URLSearchParams(frag);
      const access_token = p.get('access_token');
      const refresh_token = p.get('refresh_token');
      if (!access_token || !refresh_token) return 'Login com Google não concluiu. Tente de novo.';
      const { error: e2 } = await supabase.auth.setSession({ access_token, refresh_token });
      return e2 ? e2.message : null;
    });

  const apple = () =>
    run('apple', async () => {
      const cred = await AppleAuthentication.signInAsync({
        requestedScopes: [
          AppleAuthentication.AppleAuthenticationScope.FULL_NAME,
          AppleAuthentication.AppleAuthenticationScope.EMAIL,
        ],
      });
      if (!cred.identityToken) return 'A Apple não devolveu o token de login.';
      const { error } = await supabase.auth.signInWithIdToken({
        provider: 'apple',
        token: cred.identityToken,
      });
      return error ? error.message : null;
    });

  return (
    <Screen>
      <View style={{ height: 40 }} />
      <Title>Minuto 91</Title>
      <Sub>Mais que pelada. História.</Sub>
      <View style={{ height: 12 }} />
      <Input placeholder="e-mail" keyboardType="email-address" value={email} onChangeText={setEmail} />
      <Input placeholder="senha (6 ou mais caracteres)" secureTextEntry value={senha} onChangeText={setSenha} />
      <ErrorText>{msg}</ErrorText>
      <Button title="Entrar" onPress={entrar} loading={busy === 'entrar'} />
      <Button title="Criar conta" kind="secondary" onPress={cadastrar} loading={busy === 'cadastrar'} />
      <View style={{ height: 8 }} />
      <Button title="Continuar com Google" kind="secondary" onPress={google} loading={busy === 'google'} />
      {Platform.OS === 'ios' && (
        <Button title="Continuar com Apple" kind="secondary" onPress={apple} loading={busy === 'apple'} />
      )}
    </Screen>
  );
}
