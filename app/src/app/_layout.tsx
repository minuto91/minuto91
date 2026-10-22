import { Stack, useRouter, useSegments } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import { ActivityIndicator, View } from 'react-native';

import { PushHandler, pushSupported } from '../lib/push';
import { AuthProvider, useAuth } from '../lib/session';
import { colors } from '../lib/theme';

function Gate() {
  const { session, loading, onboarded } = useAuth();
  const segments = useSegments();
  const router = useRouter();

  useEffect(() => {
    if (loading) return;
    const first = segments[0] as string | undefined;
    // Telas abertas sem login e sem cadastro completo: documentos legais (A18) e nova senha (A17).
    const open = first === 'termos' || first === 'privacidade' || first === 'redefinir-senha';
    if (!session) {
      // A vitrine de Cards (só em desenvolvimento) abre sem login, para conferir o desenho.
      if (first !== 'login' && first !== 'convite' && !open && !(__DEV__ && (first === 'dev-cards' || first === 'dev-v42'))) router.replace('/login');
      return;
    }
    if (onboarded === null) return;
    if (!onboarded) {
      if (first !== 'onboarding' && !open) router.replace('/onboarding');
      return;
    }
    if (first === 'login' || first === 'onboarding') router.replace('/');
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
      <Stack
        screenOptions={{
          headerTintColor: colors.blue,
          headerTitleStyle: { color: colors.deepBlue },
          contentStyle: { backgroundColor: colors.white },
        }}>
        <Stack.Screen name="index" options={{ title: 'Minuto 91' }} />
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
        <Stack.Screen name="conta" options={{ title: 'Minha conta' }} />
        <Stack.Screen name="termos" options={{ title: 'Termos de Uso' }} />
        <Stack.Screen name="privacidade" options={{ title: 'Política de Privacidade' }} />
        <Stack.Screen name="redefinir-senha" options={{ title: 'Nova senha' }} />
        <Stack.Screen name="perfil" options={{ title: 'Meu perfil' }} />
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
  return (
    <AuthProvider>
      <StatusBar style="dark" />
      <Gate />
    </AuthProvider>
  );
}
