// V4.6: navegação com quatro abas (protótipo aprovado em 23/10/2026). Início é a Central do Jogador, igual para
// todos; as funções de administração continuam dentro de cada pelada. As rotas não mudaram ("/", "/carreira",
// "/perfil"; "/peladas" é nova): links diretos, avisos e o botão voltar seguem funcionando. Telas de dentro (pelada,
// partida, card...) abrem por cima das abas, na pilha principal.
import { Tabs } from 'expo-router/js-tabs';
import Svg, { Circle, Path } from 'react-native-svg';

import { emitHomeTabRepress } from '../../lib/tabevents';
import { colors } from '../../lib/theme';

type TabIcon = 'inicio' | 'peladas' | 'carreira' | 'perfil';

function Icon({ name, color }: { name: TabIcon; color: string }) {
  const p = { stroke: color, strokeWidth: 1.9, fill: 'none', strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const };
  return (
    <Svg width={22} height={22} viewBox="0 0 24 24">
      {name === 'inicio' && <Path d="M3 11 L12 4 L21 11 V20 H14 V14 H10 V20 H3 Z" {...p} />}
      {name === 'peladas' && (
        <>
          <Circle cx={12} cy={12} r={9} {...p} />
          <Path d="M12 7.5 L16 10.5 L14.5 15 H9.5 L8 10.5 Z" {...p} />
        </>
      )}
      {name === 'carreira' && <Path d="M5 20 V13 M10 20 V9 M15 20 V12 M20 20 V5" {...p} />}
      {name === 'perfil' && (
        <>
          <Circle cx={12} cy={8} r={4} {...p} />
          <Path d="M4.5 20.5 C5.5 16.5 8.5 14.5 12 14.5 C15.5 14.5 18.5 16.5 19.5 20.5" {...p} />
        </>
      )}
    </Svg>
  );
}

export default function TabsLayout() {
  return (
    <Tabs
      // E15: o "voltar" do sistema devolve à aba de onde a pessoa veio (ex.: Carta → Carreira → voltar à Central).
      backBehavior="history"
      screenOptions={{
        headerTintColor: colors.ink,
        headerTitleStyle: { color: colors.ink, fontFamily: 'Inter_700Bold', fontSize: 17 },
        headerStyle: { backgroundColor: colors.screen },
        headerShadowVisible: false,
        tabBarActiveTintColor: colors.blue,
        tabBarInactiveTintColor: colors.muted,
        tabBarLabelStyle: { fontFamily: 'Inter_600SemiBold', fontSize: 11 },
        tabBarStyle: { borderTopColor: colors.line, backgroundColor: colors.white, height: 60, paddingTop: 6, paddingBottom: 6 },
        sceneStyle: { backgroundColor: colors.screen },
      }}>
      <Tabs.Screen
        name="index"
        // Central 2.0: cabeçalho próprio (foto, saudação, "Central do Jogador" e avisos), com a área segura do topo.
        options={{ title: 'Início', headerShown: false, tabBarIcon: ({ color }) => <Icon name="inicio" color={String(color)} /> }}
        // E09: toque na aba já ativa — a tela decide (topo da página ou atualização de leitura).
        listeners={{ tabPress: () => emitHomeTabRepress() }}
      />
      <Tabs.Screen
        name="peladas"
        options={{ title: 'Peladas', headerTitle: 'Minhas peladas', tabBarIcon: ({ color }) => <Icon name="peladas" color={String(color)} /> }}
      />
      <Tabs.Screen
        name="carreira"
        options={{ title: 'Carreira', headerTitle: 'Minha Carreira', tabBarIcon: ({ color }) => <Icon name="carreira" color={String(color)} /> }}
      />
      <Tabs.Screen
        name="perfil"
        options={{ title: 'Perfil', headerTitle: 'Meu perfil', tabBarIcon: ({ color }) => <Icon name="perfil" color={String(color)} /> }}
      />
    </Tabs>
  );
}
