import * as AppleAuthentication from 'expo-apple-authentication';
import * as Linking from 'expo-linking';
import * as WebBrowser from 'expo-web-browser';
import { useEffect, useState } from 'react';
import { useRouter } from 'expo-router';
import { Platform, Pressable, View } from 'react-native';
import { Text } from '../lib/text';

import { friendly } from '../lib/errors';
import { supabase } from '../lib/supabase';
import { colors } from '../lib/theme';
import { BrandSymbol } from '../lib/brand';
import { Button, ErrorText, Input, Notice, Screen, Sub, Title } from '../lib/ui';

WebBrowser.maybeCompleteAuthSession();

export default function Login() {
  const router = useRouter();
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
      const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: senha });
      return error ? 'E-mail ou senha incorretos.' : null;
    });

  const cadastrar = () =>
    run('cadastrar', async () => {
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
    <Screen>
      {/* V6.0: marca no topo, formulário com rótulos visíveis e provedores separados por "ou". */}
      <View style={{ width: '100%', maxWidth: 440, alignSelf: 'center', gap: 12 }}>
      <View style={{ alignItems: 'center', gap: 10, paddingTop: 36, paddingBottom: 16 }}>
        <BrandSymbol size={56} />
        <Title>Minuto 91</Title>
        <Sub>O jogo acaba. A resenha começa.</Sub>
      </View>
      <Text style={fieldLabel}>E-mail</Text>
      <Input
        placeholder="voce@exemplo.com"
        keyboardType="email-address"
        autoComplete="email"
        textContentType="emailAddress"
        accessibilityLabel="E-mail"
        value={email}
        onChangeText={setEmail}
      />
      {forgot ? (
        <>
          <Sub>Digite o e-mail da conta. Vamos mandar um link para criar uma senha nova.</Sub>
          <ErrorText>{msg}</ErrorText>
          {info && <Notice tone="success">{info}</Notice>}
          <Button title="Enviar link" onPress={recuperar} loading={busy === 'recuperar'} />
          <Button title="Voltar para entrar" kind="secondary" onPress={() => { setForgot(false); setMsg(null); setInfo(null); }} />
        </>
      ) : (
        <>
          <Text style={fieldLabel}>Senha</Text>
          <Input
            placeholder="6 ou mais caracteres"
            secureTextEntry
            autoComplete="password"
            textContentType="password"
            accessibilityLabel="Senha"
            value={senha}
            onChangeText={setSenha}
          />
          <ErrorText>{msg}</ErrorText>
          <Button title="Entrar" onPress={entrar} loading={busy === 'entrar'} />
          <Button title="Criar conta" kind="secondary" onPress={cadastrar} loading={busy === 'cadastrar'} />
          <Pressable accessibilityRole="button" onPress={() => { setForgot(true); setMsg(null); }} style={{ minHeight: 44, justifyContent: 'center', alignSelf: 'center' }}>
            <Text style={{ color: colors.blue, fontWeight: '600' }}>Esqueci minha senha</Text>
          </Pressable>
        </>
      )}
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10, marginVertical: 4 }} importantForAccessibility="no-hide-descendants">
        <View style={{ flex: 1, height: 1, backgroundColor: colors.line }} />
        <Text style={{ color: colors.muted, fontSize: 13 }}>ou</Text>
        <View style={{ flex: 1, height: 1, backgroundColor: colors.line }} />
      </View>
      <Button title="Continuar com Google" kind="secondary" onPress={google} loading={busy === 'google'} />
      <Text style={{ color: colors.muted, fontSize: 13, textAlign: 'center' }}>
        Ao continuar você poderá ler os{' '}
        <Text style={{ color: colors.blue }} onPress={() => router.push('/termos')}>Termos de Uso</Text> e a{' '}
        <Text style={{ color: colors.blue }} onPress={() => router.push('/privacidade')}>Política de Privacidade</Text> antes de aceitar.
      </Text>
      {appleOk && (
        <Button title="Continuar com Apple" kind="secondary" onPress={apple} loading={busy === 'apple'} />
      )}
      </View>
    </Screen>
  );
}

const fieldLabel = { fontSize: 13, fontWeight: '600' as const, color: colors.ink, marginBottom: -6 };
