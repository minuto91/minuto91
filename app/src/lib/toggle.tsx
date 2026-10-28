import { Pressable, View } from 'react-native';

import { Text } from './text';
import { colors, radius, type } from './theme';

/** Interruptor com rótulo (linha inteira tocável, 48 pt). */
export function Toggle({ label, value, onChange, premium, disabled }: {
  label: string; value: boolean; onChange: (v: boolean) => void; premium?: boolean; disabled?: boolean;
}) {
  return (
    <Pressable
      onPress={() => !disabled && onChange(!value)}
      accessibilityRole="switch"
      accessibilityState={{ checked: value, disabled }}
      accessibilityLabel={label}
      style={{ minHeight: 48, flexDirection: 'row', alignItems: 'center', gap: 10, opacity: disabled ? 0.5 : 1 }}>
      <Text style={[type.body, { flex: 1 }]}>
        {label}
        {premium ? <Text style={{ color: colors.darkGold, fontWeight: '700' }}>{'  Premium'}</Text> : null}
      </Text>
      <View style={{ width: 46, height: 28, borderRadius: radius.pill, padding: 3, backgroundColor: value ? colors.blue : colors.line }}>
        <View style={{ width: 22, height: 22, borderRadius: 11, backgroundColor: colors.white, marginLeft: value ? 18 : 0 }} />
      </View>
    </Pressable>
  );
}
