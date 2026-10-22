import { ReactNode } from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TextInputProps,
  View,
} from 'react-native';

import { colors, POSITIONS, Position, Sector, SECTORS } from './theme';

export function Screen({ children }: { children: ReactNode }) {
  return (
    <ScrollView
      style={{ backgroundColor: colors.white }}
      contentContainerStyle={{ padding: 20, gap: 12, flexGrow: 1 }}
      keyboardShouldPersistTaps="handled">
      {children}
    </ScrollView>
  );
}

export const Title = ({ children }: { children: ReactNode }) => (
  <Text style={{ fontSize: 26, fontWeight: '800', color: colors.deepBlue }}>{children}</Text>
);

export const Sub = ({ children }: { children: ReactNode }) => (
  <Text style={{ fontSize: 15, color: colors.muted }}>{children}</Text>
);

export const Body = ({ children }: { children: ReactNode }) => (
  <Text style={{ fontSize: 16, color: colors.ink }}>{children}</Text>
);

export function Button({
  title,
  onPress,
  kind = 'primary',
  disabled,
  loading,
}: {
  title: string;
  onPress: () => void;
  kind?: 'primary' | 'secondary' | 'danger';
  disabled?: boolean;
  loading?: boolean;
}) {
  const bg = kind === 'primary' ? colors.blue : colors.white;
  const fg = kind === 'primary' ? colors.white : kind === 'danger' ? colors.danger : colors.blue;
  const border = kind === 'primary' ? colors.blue : kind === 'danger' ? colors.danger : colors.line;
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled || loading}
      style={{
        backgroundColor: bg,
        borderColor: border,
        borderWidth: 1,
        borderRadius: 10,
        paddingVertical: 14,
        alignItems: 'center',
        opacity: disabled ? 0.5 : 1,
      }}>
      {loading ? (
        <ActivityIndicator color={fg} />
      ) : (
        <Text style={{ color: fg, fontSize: 16, fontWeight: '700' }}>{title}</Text>
      )}
    </Pressable>
  );
}

export function Input(props: TextInputProps) {
  return (
    <TextInput
      placeholderTextColor={colors.muted}
      autoCapitalize="none"
      {...props}
      style={[styles.input, props.style]}
    />
  );
}

export function Card({ children }: { children: ReactNode }) {
  return <View style={styles.card}>{children}</View>;
}

// As dez posições oficiais, agrupadas por setor. `sector` limita a escolha a um setor (atualização de um
// cadastro antigo: Defensor escolhe entre ZAG, LD e LE, e assim por diante).
export function PositionPicker({
  value,
  onChange,
  sector,
}: {
  value: string | null;
  onChange: (p: Position) => void;
  sector?: Sector | null;
}) {
  return (
    <View style={{ gap: 10 }}>
      {SECTORS.filter((s) => !sector || s.value === sector).map((s) => (
        <View key={s.value} style={{ gap: 6 }}>
          {!sector && <Text style={{ fontSize: 12, fontWeight: '700', color: colors.muted, letterSpacing: 0.5 }}>{s.label.toUpperCase()}</Text>}
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
            {POSITIONS.filter((p) => p.sector === s.value).map((p) => {
              const on = value === p.value;
              return (
                <Pressable
                  key={p.value}
                  onPress={() => onChange(p.value)}
                  accessibilityRole="button"
                  accessibilityState={{ selected: on }}
                  accessibilityLabel={p.label}
                  style={{
                    minHeight: 44,
                    justifyContent: 'center',
                    paddingHorizontal: 14,
                    borderRadius: 22,
                    borderWidth: 1,
                    borderColor: on ? colors.blue : colors.line,
                    backgroundColor: on ? colors.blue : colors.white,
                  }}>
                  <Text style={{ color: on ? colors.white : colors.ink, fontWeight: '600' }}>
                    <Text style={{ fontWeight: '800', color: on ? colors.white : colors.blue }}>{p.value}</Text> {p.label}
                  </Text>
                </Pressable>
              );
            })}
          </View>
        </View>
      ))}
    </View>
  );
}

// Escolha única entre opções (times, prazos, pessoas).
export function Chips<T extends string>({
  options,
  value,
  onChange,
}: {
  options: readonly { value: T; label: string }[];
  value: T | null;
  onChange: (v: T) => void;
}) {
  return (
    <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
      {options.map((o) => {
        const on = value === o.value;
        return (
          <Pressable
            key={o.value}
            accessibilityRole="button"
            accessibilityState={{ selected: on }}
            onPress={() => onChange(o.value)}
            style={{
              paddingVertical: 8,
              paddingHorizontal: 14,
              borderRadius: 18,
              borderWidth: 1,
              borderColor: on ? colors.blue : colors.line,
              backgroundColor: on ? colors.blue : colors.white,
            }}>
            <Text style={{ color: on ? colors.white : colors.ink, fontWeight: '600' }}>{o.label}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

// Contador com − e +. value null = vazio (mostra "–").
export function Stepper({
  label,
  value,
  onChange,
  min = 0,
  max = 99,
  step = 1,
  start,
  format = (v: number) => String(v),
  a11yName,
}: {
  label?: string;
  /** Nome lido pelo leitor de tela (ex.: "Nota de João"); padrão = label. */
  a11yName?: string;
  value: number | null;
  onChange: (v: number) => void;
  min?: number;
  max?: number;
  step?: number;
  start?: number;
  format?: (v: number) => string;
}) {
  const bump = (d: number) => {
    const base = value ?? (start ?? min) - d;
    const next = Math.round((base + d) * 10) / 10;
    if (next >= min && next <= max) onChange(next);
  };
  const name = a11yName ?? label ?? 'Valor';
  const shown = value === null ? 'sem valor' : format(value);
  // A26: alvos de 44 px (diretriz de acessibilidade das lojas), nome e valor lidos pelo leitor de tela, e
  // o conjunto ajustável por gesto (deslizar para cima/baixo no VoiceOver/TalkBack).
  return (
    <View
      accessible
      accessibilityRole="adjustable"
      accessibilityLabel={name}
      accessibilityValue={{ text: shown }}
      accessibilityActions={[{ name: 'increment' }, { name: 'decrement' }]}
      onAccessibilityAction={(e) => bump(e.nativeEvent.actionName === 'increment' ? step : -step)}
      style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
      {label ? <Text style={{ color: colors.muted, fontSize: 13 }}>{label}</Text> : null}
      <Pressable onPress={() => bump(-step)} style={styles.stepBtn} hitSlop={4} accessibilityLabel={`Diminuir ${name}`}>
        <Text style={styles.stepTxt}>−</Text>
      </Pressable>
      <Text style={{ minWidth: 38, textAlign: 'center', fontWeight: '700', fontSize: 16, color: colors.ink }}>
        {value === null ? '–' : format(value)}
      </Text>
      <Pressable onPress={() => bump(step)} style={styles.stepBtn} hitSlop={4} accessibilityLabel={`Aumentar ${name}`}>
        <Text style={styles.stepTxt}>+</Text>
      </Pressable>
    </View>
  );
}

export const ErrorText = ({ children }: { children?: string | null }) =>
  children ? <Text style={{ color: colors.danger }}>{children}</Text> : null;

const styles = StyleSheet.create({
  input: {
    borderWidth: 1,
    borderColor: colors.line,
    backgroundColor: colors.white,
    borderRadius: 10,
    padding: 12,
    fontSize: 16,
    color: colors.ink,
  },
  stepBtn: {
    width: 44,
    height: 44,
    borderRadius: 22,
    borderWidth: 1,
    borderColor: colors.line,
    backgroundColor: colors.white,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stepTxt: { fontSize: 20, fontWeight: '700', color: colors.blue },
  card: {
    backgroundColor: colors.white,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: colors.line,
    padding: 14,
    gap: 6,
  },
});
