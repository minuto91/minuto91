// V4.6: navegação com quatro abas (protótipo aprovado em 23/10/2026). Início é a Central do Jogador, igual para
// todos; as funções de administração continuam dentro de cada pelada. As rotas não mudaram ("/", "/carreira",
// "/perfil"; "/peladas" é nova): links diretos, avisos e o botão voltar seguem funcionando. Telas de dentro (pelada,
// partida, card...) abrem por cima das abas, na pilha principal.
import { Tabs } from 'expo-router/js-tabs';
import { Icon } from '../../lib/icons';
import { emitHomeTabRepress } from '../../lib/tabevents';
import { colors } from '../../lib/theme';

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
        options={{ title: 'Início', headerShown: false, tabBarIcon: ({ color }) => <Icon name="inicio" size={22} color={String(color)} strokeWidth={1.9} /> }}
        // E09: toque na aba já ativa — a tela decide (topo da página ou atualização de leitura).
        listeners={{ tabPress: () => emitHomeTabRepress() }}
      />
      <Tabs.Screen
        name="peladas"
        options={{ title: 'Peladas', headerTitle: 'Minhas peladas', tabBarIcon: ({ color }) => <Icon name="peladas" size={22} color={String(color)} strokeWidth={1.9} /> }}
      />
      <Tabs.Screen
        name="carreira"
        options={{ title: 'Carreira', headerTitle: 'Minha Carreira', tabBarIcon: ({ color }) => <Icon name="carreira" size={22} color={String(color)} strokeWidth={1.9} /> }}
      />
      <Tabs.Screen
        name="perfil"
        options={{ title: 'Perfil', headerTitle: 'Meu perfil', tabBarIcon: ({ color }) => <Icon name="perfil" size={22} color={String(color)} strokeWidth={1.9} /> }}
      />
    </Tabs>
  );
}
