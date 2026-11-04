// REV-141 (V10.0): barra deslizante de passos fixos (o prazo da votação). Arrastar ou tocar escolhe o passo mais próximo;
// o texto do valor escolhido muda na hora. Os passos são exatamente os que o servidor aceita (nada novo).
import { useMemo, useState } from 'react';
import { PanResponder, View } from 'react-native';

import { Text } from './text';
import { colors } from './theme';

export function StepSlider<T extends string>({
  options,
  value,
  onChange,
  disabled,
  label,
}: {
  options: readonly { value: T; label: string }[];
  value: T;
  onChange: (v: T) => void;
  disabled?: boolean;
  label: string;
}) {
  const [width, setWidth] = useState(1);
  const last = options.length - 1;
  const index = Math.max(0, options.findIndex((o) => o.value === value));
  const pan = useMemo(() => {
    const set = (x: number) => {
      const i = Math.min(last, Math.max(0, Math.round((x / width) * last)));
      onChange(options[i].value);
    };
    return PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: () => true,
      onPanResponderGrant: (e) => set(e.nativeEvent.locationX),
      onPanResponderMove: (e) => set(e.nativeEvent.locationX),
      onPanResponderTerminationRequest: () => false,
    });
  }, [width, last, options, onChange]);
  const pct = last === 0 ? 0 : (index / last) * 100;
  const step = (d: number) => onChange(options[Math.min(last, Math.max(0, index + d))].value);
  return (
    <View style={{ gap: 6, opacity: disabled ? 0.5 : 1 }} pointerEvents={disabled ? 'none' : 'auto'}>
      <Text style={{ fontSize: 22, fontWeight: '800', color: colors.ink, textAlign: 'center' }}>{options[index].label}</Text>
      <View
        style={{ height: 44, justifyContent: 'center', marginHorizontal: 13 }}
        onLayout={(e) => setWidth(Math.max(1, e.nativeEvent.layout.width))}
        accessible
        accessibilityRole="adjustable"
        accessibilityLabel={label}
        accessibilityValue={{ min: 0, max: last, now: index, text: options[index].label }}
        accessibilityActions={[{ name: 'increment' }, { name: 'decrement' }]}
        onAccessibilityAction={(e) => step(e.nativeEvent.actionName === 'increment' ? 1 : -1)}
        {...pan.panHandlers}>
        <View pointerEvents="none" style={{ height: 6, borderRadius: 3, backgroundColor: colors.line }}>
          <View style={{ width: `${pct}%`, height: 6, borderRadius: 3, backgroundColor: colors.blue }} />
        </View>
        {options.map((_, i) => (
          <View
            key={i}
            pointerEvents="none"
            style={{ position: 'absolute', left: `${last === 0 ? 0 : (i / last) * 100}%`, marginLeft: -3, width: 6, height: 6, borderRadius: 3, backgroundColor: i <= index ? colors.blue : colors.line }}
          />
        ))}
        <View
          pointerEvents="none"
          style={{ position: 'absolute', left: `${pct}%`, marginLeft: -13, width: 26, height: 26, borderRadius: 13, backgroundColor: colors.white, borderWidth: 3, borderColor: colors.blue }}
        />
      </View>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
        <Text style={{ color: colors.muted, fontSize: 12 }}>{options[0].label}</Text>
        <Text style={{ color: colors.muted, fontSize: 12 }}>{options[last].label}</Text>
      </View>
    </View>
  );
}
