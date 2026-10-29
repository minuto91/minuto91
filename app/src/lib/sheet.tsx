// V8.4 — Bottom Sheet compartilhado (E02 seletor de pelada, E07 pendências). Um só padrão para todo o app.
import { type ReactNode } from 'react';
import { KeyboardAvoidingView, Modal, Platform, Pressable, ScrollView, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useReducedMotion } from './motion';
import { Text } from './text';
import { colors, layout, radius, type } from './theme';

export function BottomSheet({
  visible,
  onClose,
  title,
  children,
}: {
  visible: boolean;
  onClose: () => void;
  title: string;
  children: ReactNode;
}) {
  const reduced = useReducedMotion();
  const { bottom } = useSafeAreaInsets();
  return (
    <Modal
      visible={visible}
      transparent
      animationType={reduced ? 'none' : 'slide'}
      onRequestClose={onClose}
      statusBarTranslucent
      accessibilityViewIsModal>
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={{ flex: 1, justifyContent: 'flex-end' }}>
        {/* Toque fora fecha (E15-36: o gesto tem controle equivalente, o botão Fechar). */}
        <Pressable
          style={{ position: 'absolute', top: 0, bottom: 0, left: 0, right: 0, backgroundColor: 'rgba(16,54,117,0.35)' }}
          onPress={onClose}
          accessibilityLabel="Fechar"
          accessibilityRole="button"
        />
        <View
          style={{
            alignSelf: 'center',
            width: '100%',
            maxWidth: layout.maxWidth,
            maxHeight: '82%',
            backgroundColor: colors.white,
            borderTopLeftRadius: radius.lg,
            borderTopRightRadius: radius.lg,
            paddingTop: 8,
            paddingBottom: Math.max(bottom, 12),
          }}>
          <View style={{ alignSelf: 'center', width: 40, height: 4, borderRadius: 2, backgroundColor: colors.line, marginBottom: 6 }} />
          <View style={{ flexDirection: 'row', alignItems: 'center', paddingHorizontal: layout.gutter }}>
            <Text style={{ ...type.section, flex: 1 }} accessibilityRole="header">
              {title}
            </Text>
            <Pressable
              onPress={onClose}
              accessibilityRole="button"
              accessibilityLabel="Fechar"
              style={{ minHeight: 44, minWidth: 44, alignItems: 'center', justifyContent: 'center' }}>
              <Text style={{ color: colors.blue, fontWeight: '700', fontSize: 15 }}>Fechar</Text>
            </Pressable>
          </View>
          <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={{ paddingHorizontal: layout.gutter, paddingBottom: 8, gap: 4 }}>
            {children}
          </ScrollView>
        </View>
      </KeyboardAvoidingView>
    </Modal>
  );
}
