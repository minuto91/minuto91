import { useFonts } from 'expo-font';
import { Stack, useGlobalSearchParams, useRouter, useSegments } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import { ActivityIndicator, View } from 'react-native';
import { HOME , colors } from '../lib/theme';

import { PushHandler, pushSupported } from '../lib/push';
import { AuthProvider, useAuth } from '../lib/session';
import { validParam } from '../lib/navguard';
import { INTER_FONTS } from '../lib/text';
import { Button, EmptyState } from '../lib/ui';

function Gate() {
  const { session, loading, onboarded } = useAuth();
  const segments = useSegments();
  const router = useRouter();
  const params = useGlobalSearchParams<{ id?: string }>();
  // E15-32: rota com [id] cujo parâmetro não é um UUID válido nunca abre conteúdo (nem de outra pelada ou partida).
  const invalidLink = !!session && !!onboarded && (segments as string[]).includes('[id]') && !validParam(params.id);

  useEffect(() => {
    if (loading) return;
    const first = segments[0] as string | undefined;
    // Telas abertas sem login e sem cadastro completo: documentos legais (A18) e nova senha (A17).
    const open = first === 'termos' || first === 'privacidade' || first === 'redefinir-senha';
    if (!session) {
      // A vitrine de Cards (só em desenvolvimento) abre sem login, para conferir o desenho.
      if (first !== 'login' && first !== 'convite' && !open && !(__DEV__ && (first === 'dev-cards' || first === 'dev-v42' || first === 'dev-v43' || first === 'dev-v44' || first === 'dev-v45' || first === 'dev-v46' || first === 'dev-v5' || first === 'dev-central'))) router.replace('/login');
      return;
    }
    if (onboarded === null) return;
    if (!onboarded) {
      if (first !== 'onboarding' && !open) router.replace('/onboarding');
      return;
    }
    if (first === 'login' || first === 'onboarding') router.replace(HOME);
  }, [loading, session, onboarded, segments, router]);

  if (loading) {
    return (
      <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
        <ActivityIndicator color={colors.blue} />
      </View>
    );
  }

  return (
    <>
      {/* Toque no aviso abre a tela dele; só no app instalado, com login. */}
      {pushSupported && session && onboarded && <PushHandler />}
      {invalidLink && (
        <View
          accessibilityViewIsModal
          style={{ position: 'absolute', top: 0, bottom: 0, left: 0, right: 0, zIndex: 10, backgroundColor: colors.white, justifyContent: 'center', padding: 20 }}>
          <EmptyState title="Este link não é válido" hint="O endereço está incompleto ou foi alterado. Nenhum conteúdo foi aberto.">
            <Button title="Ir para a Central" onPress={() => router.replace(HOME)} />
          </EmptyState>
        </View>
      )}
      <Stack
        screenOptions={{
          headerTintColor: colors.blue,
          headerTitleStyle: { color: colors.deepBlue, fontFamily: 'Inter_700Bold', fontSize: 17 },
          headerBackTitleStyle: { fontFamily: 'Inter_500Medium' },
          headerShadowVisible: false,
          contentStyle: { backgroundColor: colors.white },
        }}>
        {/* V4.6: Início, Peladas, Carreira e Perfil ficam nas abas ((tabs)/_layout.tsx); o resto abre por cima. */}
        <Stack.Screen name="(tabs)" options={{ headerShown: false, title: 'Início' }} />
        <Stack.Screen name="login" options={{ headerShown: false }} />
        <Stack.Screen name="onboarding" options={{ title: 'Seu cadastro', headerBackVisible: false }} />
        <Stack.Screen name="criar-pelada" options={{ title: 'Criar pelada' }} />
        <Stack.Screen name="entrar" options={{ title: 'Entrar com convite' }} />
        <Stack.Screen name="convite/[token]" options={{ title: 'Convite' }} />
        <Stack.Screen name="pelada/[id]/index" options={{ title: 'Pelada' }} />
        <Stack.Screen name="pelada/[id]/rankings" options={{ title: 'Rankings' }} />
        <Stack.Screen name="pelada/[id]/elenco" options={{ title: 'Elenco' }} />
        <Stack.Screen name="pelada/[id]/partidas" options={{ title: 'Partidas' }} />
        <Stack.Screen name="pelada/[id]/jogadores" options={{ title: 'Jogadores' }} />
        <Stack.Screen name="pelada/[id]/convidar" options={{ title: 'Convidar' }} />
        <Stack.Screen name="pelada/[id]/retrospectiva" options={{ title: 'Retrospectiva' }} />
        <Stack.Screen name="pelada/[id]/configuracoes" options={{ title: 'Configurações' }} />
        <Stack.Screen name="pelada/[id]/temporadas" options={{ title: 'Temporadas' }} />
        <Stack.Screen name="pelada/[id]/duelo" options={{ title: 'Duelo' }} />
        <Stack.Screen name="pelada/[id]/escalacoes" options={{ title: 'Escalações' }} />
        <Stack.Screen name="pelada/[id]/sorteio" options={{ title: 'Sorteio' }} />
        <Stack.Screen name="pelada/[id]/premium" options={{ title: 'Pelada Premium' }} />
        <Stack.Screen name="pelada/[id]/financeiro/index" options={{ title: 'Financeiro' }} />
        <Stack.Screen name="pelada/[id]/financeiro/cobrancas" options={{ title: 'Cobranças' }} />
        <Stack.Screen name="pelada/[id]/financeiro/mensalistas" options={{ title: 'Mensalistas' }} />
        <Stack.Screen name="pelada/[id]/financeiro/lancamentos" options={{ title: 'Receitas e despesas' }} />
        <Stack.Screen name="pelada/[id]/financeiro/relatorio" options={{ title: 'Relatórios' }} />
        <Stack.Screen name="conta" options={{ title: 'Minha conta' }} />
        <Stack.Screen name="notificacoes" options={{ title: 'Notificações' }} />
        <Stack.Screen name="personalizar-central" options={{ title: 'Personalizar Central' }} />
        <Stack.Screen name="termos" options={{ title: 'Termos de Uso' }} />
        <Stack.Screen name="privacidade" options={{ title: 'Política de Privacidade' }} />
        <Stack.Screen name="redefinir-senha" options={{ title: 'Nova senha' }} />
        <Stack.Screen name="guia-cards" options={{ title: 'Cards e premiações' }} />
        <Stack.Screen name="atleta/[id]" options={{ title: 'Perfil do jogador' }} />
        <Stack.Screen name="jogador/[id]/index" options={{ title: 'Card' }} />
        <Stack.Screen name="jogador/[id]/album" options={{ title: 'Álbum' }} />
        <Stack.Screen name="partida/[id]/index" options={{ title: 'Partida' }} />
        <Stack.Screen name="partida/[id]/sumula" options={{ title: 'Súmula' }} />
        <Stack.Screen name="partida/[id]/votar" options={{ title: 'Votação' }} />
      </Stack>
    </>
  );
}

export default function RootLayout() {
  // V4.6: Inter (fonte única da marca). Enquanto carrega, a tela de abertura; se falhar, segue com a fonte do sistema.
  const [fontsLoaded, fontError] = useFonts(INTER_FONTS);
  if (!fontsLoaded && !fontError) {
    return (
      <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.white }}>
        <ActivityIndicator color={colors.blue} />
      </View>
    );
  }
  return (
    <AuthProvider>
      <StatusBar style="dark" />
      <Gate />
    </AuthProvider>
  );
}
