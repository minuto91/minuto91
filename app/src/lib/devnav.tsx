// Barra de navegação das vitrines dev-* (só em desenvolvimento): permite pular entre elas sem digitar a URL.
import { usePathname, useRouter } from 'expo-router';
import { Pressable, ScrollView, Text, View } from 'react-native';

import { colors } from './theme';

const SHOWCASES = ['dev-central', 'dev-cards', 'dev-v42', 'dev-v43', 'dev-v44', 'dev-v45', 'dev-v46', 'dev-v5', 'dev-v85', 'dev-v86', 'dev-v87'];

export function DevNav() {
  const router = useRouter();
  const path = usePathname().replace(/^\//, '');
  if (!__DEV__ || !path.startsWith('dev-')) return null;
  return (
    <View style={{ position: 'absolute', left: 0, right: 0, bottom: 0, zIndex: 20, backgroundColor: colors.deepBlue, paddingVertical: 6 }}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ paddingHorizontal: 8, gap: 6 }}>
        {SHOWCASES.map((name) => {
          const active = name === path;
          return (
            <Pressable
              key={name}
              accessibilityRole="button"
              onPress={() => router.replace(`/${name}` as never)}
              style={{ paddingHorizontal: 10, paddingVertical: 6, borderRadius: 14, backgroundColor: active ? colors.white : 'transparent' }}>
              <Text style={{ color: active ? colors.deepBlue : colors.white, fontSize: 13, fontWeight: '600' }}>{name.replace('dev-', '')}</Text>
            </Pressable>
          );
        })}
      </ScrollView>
    </View>
  );
}
