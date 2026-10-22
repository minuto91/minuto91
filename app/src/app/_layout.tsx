import { Stack, useRouter, useSegments } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import { ActivityIndicator, View } from 'react-native';

import { AuthProvider, useAuth } from '../lib/session';
import { colors } from '../lib/theme';

function Gate() {
  const { session, loading, onboarded } = useAuth();
  const segments = useSegments();
  const router = useRouter();

  useEffect(() => {
    if (loading) return;
    const first = segments[0] as string | undefined;
    if (!session) {
      if (first !== 'login' && first !== 'convite') router.replace('/login');
      return;
    }
    if (onboarded === null) return;
    if (!onboarded) {
      if (first !== 'onboarding') router.replace('/onboarding');
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
      <Stack.Screen name="pelada/[id]/premium" options={{ title: 'Premium' }} />
      <Stack.Screen name="pelada/[id]/configuracoes" options={{ title: 'Configurações' }} />
      <Stack.Screen name="conta" options={{ title: 'Minha conta' }} />
      <Stack.Screen name="perfil" options={{ title: 'Meu perfil' }} />
      <Stack.Screen name="atleta/[id]" options={{ title: 'Perfil do jogador' }} />
      <Stack.Screen name="jogador/[id]/index" options={{ title: 'Carta' }} />
      <Stack.Screen name="jogador/[id]/album" options={{ title: 'Álbum' }} />
      <Stack.Screen name="partida/[id]/index" options={{ title: 'Partida' }} />
      <Stack.Screen name="partida/[id]/sumula" options={{ title: 'Súmula' }} />
      <Stack.Screen name="partida/[id]/votar" options={{ title: 'Votação' }} />
    </Stack>
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
