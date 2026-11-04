import * as AppleAuthentication from 'expo-apple-authentication';
import * as Linking from 'expo-linking';
import * as WebBrowser from 'expo-web-browser';
import { useEffect, useState } from 'react';
import { useRouter } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { Dimensions, Platform, Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Text } from '../lib/text';

import { friendly } from '../lib/errors';
import { supabase } from '../lib/supabase';
import { APP_VERSION_LABEL } from '../lib/version';
import { L, LoginBackground, LoginBrand, LoginButton, LoginDivider, LoginField } from '../lib/loginui';

WebBrowser.maybeCompleteAuthSession();

export default function Login() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const [email, setEmail] = useState('');
  const [senha, setSenha] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [forgot, setForgot] = useState(false); // A17: modo "esqueci minha senha"
  // Login com Apple só existe no app nativo (development build ou lojas), não no Expo Go.
  const [appleOk, setAppleOk] = useState(false);

  useEffect(() => {
    if (Platform.OS !== 'ios') return;
    let alive = true;
    (async () => {
      let ok = false;
      try {
        ok = await AppleAuthentication.isAvailableAsync(); // no Expo Go o módulo nativo não existe e dá erro
      } catch {
        ok = false;
      }
      if (alive) setAppleOk(ok);
    })();
    return () => {
      alive = false;
    };
  }, []);

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
      if (!/^\S+@\S+\.\S+$/.test(email.trim())) return 'Digite um e-mail válido.';
      if (senha.length < 6) return 'A senha precisa ter 6 ou mais caracteres.';
      const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: senha });
      return error ? 'E-mail ou senha incorretos.' : null;
    });

  const cadastrar = () =>
    run('cadastrar', async () => {
      if (!/^\S+@\S+\.\S+$/.test(email.trim())) return 'Digite um e-mail válido.';
      if (senha.length < 6) return 'A senha precisa ter 6 ou mais caracteres.';
      const { data, error } = await supabase.auth.signUp({ email: email.trim(), password: senha });
      if (error) return error.message;
      return data.session ? null : 'Enviamos um e-mail de confirmação. Confirme e depois entre.';
    });

  // A17: o Supabase manda um link que abre /redefinir-senha (precisa estar nas Redirect URLs do Auth).
  // A resposta é a mesma exista ou não a conta, para não revelar quem tem cadastro.
  const recuperar = () =>
    run('recuperar', async () => {
      const mail = email.trim();
      if (!/^\S+@\S+\.\S+$/.test(mail)) return 'Digite o e-mail da sua conta.';
      const { error } = await supabase.auth.resetPasswordForEmail(mail, { redirectTo: Linking.createURL('redefinir-senha') });
      if (error && /rate|security purposes/i.test(error.message)) return 'Aguarde um minuto antes de pedir outro e-mail.';
      if (error) return friendly(error.message);
      setInfo('Se houver uma conta com esse e-mail, enviamos um link para criar uma nova senha. Ele vale por 1 hora; confira também o spam.');
      return null;
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
    <View style={{ flex: 1, backgroundColor: L.black }}>
      <StatusBar style="light" />
      <LoginBackground />
      <ScrollView
        contentContainerStyle={{ flexGrow: 1, justifyContent: 'space-between', paddingHorizontal: 20, paddingTop: Math.max(insets.top, 24) + Math.round(Dimensions.get('window').height * 0.07), paddingBottom: Math.max(insets.bottom, 16) + 8 }}
        automaticallyAdjustKeyboardInsets
        keyboardDismissMode="interactive"
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}>
        <LoginBrand />
        <View style={{ gap: 8, marginTop: 24 }}>
          <LoginField icon="mail" placeholder="e-mail" keyboardType="email-address" textContentType="emailAddress" autoComplete="email" value={email} onChangeText={setEmail} accessibilityLabel="e-mail" />
          {forgot ? (
            <>
              <Text style={{ color: L.soft, fontSize: 14, textAlign: 'center' }}>Digite o e-mail da conta. Vamos mandar um link para criar uma senha nova.</Text>
              {msg && <Text accessibilityRole="alert" style={s.err}>{msg}</Text>}
              {info && <Text style={{ color: L.text, fontSize: 14, textAlign: 'center' }}>{info}</Text>}
              <LoginButton kind="primary" title="Enviar link" onPress={recuperar} loading={busy === 'recuperar'} />
              <LoginButton kind="outline" title="Voltar para entrar" onPress={() => { setForgot(false); setMsg(null); setInfo(null); }} />
            </>
          ) : (
            <>
              <LoginField icon="lock" secure placeholder="senha (6 ou mais caracteres)" textContentType="password" autoComplete="password" value={senha} onChangeText={setSenha} accessibilityLabel="senha" />
              {msg && <Text accessibilityRole="alert" style={s.err}>{msg}</Text>}
              <LoginButton kind="primary" title="Entrar" onPress={entrar} loading={busy === 'entrar'} disabled={busy !== null && busy !== 'entrar'} />
              <LoginButton kind="outline" title="Criar conta" onPress={cadastrar} loading={busy === 'cadastrar'} disabled={busy !== null && busy !== 'cadastrar'} />
              <Pressable accessibilityRole="button" onPress={() => { setForgot(true); setMsg(null); }} style={{ minHeight: 36, justifyContent: 'center', alignSelf: 'center' }}>
                <Text style={{ color: L.gold, fontWeight: '500', fontSize: 14 }}>Esqueci minha senha</Text>
              </Pressable>
            </>
          )}
          <LoginDivider>ou</LoginDivider>
          <LoginButton kind="google" title="Continuar com Google" onPress={google} loading={busy === 'google'} disabled={busy !== null && busy !== 'google'} />
          {appleOk && <LoginButton kind="google" title="Continuar com Apple" onPress={apple} loading={busy === 'apple'} disabled={busy !== null && busy !== 'apple'} />}
          <Text style={{ color: L.soft, fontSize: 13, lineHeight: 19, textAlign: 'center' }}>
            Ao continuar você poderá ler os{' '}
            <Text style={{ color: L.gold }} accessibilityRole="link" onPress={() => router.push('/termos')}>Termos de Uso</Text> e a{' '}
            <Text style={{ color: L.gold }} accessibilityRole="link" onPress={() => router.push('/privacidade')}>Política de Privacidade</Text> antes de aceitar.
          </Text>
        </View>
      </ScrollView>
      <Text
        accessible={false}
        pointerEvents="none"
        style={{ position: 'absolute', right: Math.max(insets.right, 16), bottom: Math.max(insets.bottom, 8) + 2, color: L.soft, fontSize: 11, opacity: 0.7 }}>
        {APP_VERSION_LABEL}
      </Text>
    </View>
  );
}

const s = StyleSheet.create({ err: { color: L.danger, fontSize: 14, textAlign: 'center' } });
