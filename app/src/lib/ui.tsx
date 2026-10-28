import { ReactNode } from 'react';
import { ActivityIndicator, FlatList, Pressable, ScrollView, StyleSheet, TextInputProps, View } from 'react-native';
import { Text, TextInput } from './text';

import { colors, POSITIONS, Position, radius, Sector, type } from './theme';

export function Screen({ children }: { children: ReactNode }) {
  return (
    <ScrollView
      style={{ backgroundColor: colors.white }}
      contentContainerStyle={{ padding: 20, gap: 12, flexGrow: 1 }}
      // REV-043: o teclado não cobre o campo (iOS ajusta o recuo; Android já redimensiona) e some ao rolar.
      automaticallyAdjustKeyboardInsets
      keyboardDismissMode="interactive"
      keyboardShouldPersistTaps="handled">
      {children}
    </ScrollView>
  );
}

/**
 * Tela com lista longa (V4.4): FlatList (virtualizada, desenha só o que está perto da tela) no lugar do ScrollView
 * com .map(). O cabeçalho (título, filtros, botões) rola junto. onEndReached pede a próxima página do servidor.
 */
export function ListScreen<T>({
  header,
  data,
  renderItem,
  keyExtractor,
  empty,
  loadingMore,
  onEndReached,
  footer,
}: {
  header: ReactNode;
  data: readonly T[] | null;
  renderItem: (item: T) => ReactNode;
  keyExtractor: (item: T) => string;
  empty?: ReactNode;
  loadingMore?: boolean;
  onEndReached?: () => void;
  footer?: ReactNode;
}) {
  return (
    <FlatList
      style={{ backgroundColor: colors.white }}
      contentContainerStyle={{ padding: 20, flexGrow: 1 }}
      keyboardShouldPersistTaps="handled"
      automaticallyAdjustKeyboardInsets
      keyboardDismissMode="interactive"
      data={data ?? []}
      keyExtractor={keyExtractor}
      renderItem={({ item }) => <>{renderItem(item)}</>}
      ItemSeparatorComponent={ListGap}
      ListHeaderComponent={<View style={{ gap: 12, marginBottom: 12 }}>{header}</View>}
      ListEmptyComponent={data ? <>{empty}</> : null}
      ListFooterComponent={
        <View style={{ gap: 12, marginTop: 12 }}>
          {loadingMore && <ActivityIndicator color={colors.blue} />}
          {footer}
        </View>
      }
      onEndReached={onEndReached}
      onEndReachedThreshold={0.5}
      initialNumToRender={12}
      windowSize={9}
      removeClippedSubviews={false}
    />
  );
}
const ListGap = () => <View style={{ height: 12 }} />;

// V4.6: escala única (theme.type). Título da tela 26, seção 19, texto 16, legenda 14.
export const Title = ({ children }: { children: ReactNode }) => (
  <Text style={type.title} accessibilityRole="header">
    {children}
  </Text>
);

/** Título de seção dentro da tela (19). */
export const Section = ({ children, first }: { children: ReactNode; first?: boolean }) => (
  <Text style={[type.section, { marginTop: first ? 0 : 10 }]} accessibilityRole="header">
    {children}
  </Text>
);

export const Sub = ({ children }: { children: ReactNode }) => <Text style={type.caption}>{children}</Text>;

export const Body = ({ children }: { children: ReactNode }) => <Text style={type.body}>{children}</Text>;

/**
 * Estado vazio (REV-027): ícone simples, mensagem breve e, só quando útil e permitido, a ação (children).
 */
export function EmptyState({ title, hint, children }: { title: string; hint?: string; children?: ReactNode }) {
  return (
    <View style={{ alignItems: 'center', gap: 6, paddingVertical: 24, paddingHorizontal: 12 }}>
      <View style={{ width: 36, height: 36, borderRadius: 18, borderWidth: 2, borderColor: colors.line, marginBottom: 4 }} />
      <Text style={[type.cardTitle, { textAlign: 'center' }]}>{title}</Text>
      {hint ? <Text style={[type.caption, { textAlign: 'center' }]}>{hint}</Text> : null}
      {children ? <View style={{ alignSelf: 'stretch', gap: 8, marginTop: 8 }}>{children}</View> : null}
    </View>
  );
}

/** Carregando (indicador e texto curto, lido pelo leitor de tela). */
export function Loading({ label = 'Carregando...' }: { label?: string }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 8 }} accessibilityLiveRegion="polite">
      <ActivityIndicator color={colors.blue} />
      <Text style={type.caption}>{label}</Text>
    </View>
  );
}

export function Button({
  title,
  onPress,
  kind = 'primary',
  disabled,
  loading,
}: {
  title: string;
  onPress: () => void;
  /** primary: ação principal; secondary: contorno azul; ghost: discreto, só texto; danger: destrutivo. */
  kind?: 'primary' | 'secondary' | 'ghost' | 'danger';
  disabled?: boolean;
  loading?: boolean;
}) {
  const bg = kind === 'primary' ? colors.blue : kind === 'ghost' ? 'transparent' : colors.white;
  const fg = kind === 'primary' ? colors.white : kind === 'danger' ? colors.danger : colors.blue;
  const border = kind === 'primary' ? colors.blue : kind === 'danger' ? colors.danger : kind === 'ghost' ? 'transparent' : colors.blue;
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled || loading}
      accessibilityRole="button"
      accessibilityLabel={title}
      accessibilityState={{ disabled: !!(disabled || loading), busy: !!loading }}
      style={({ pressed }) => ({
        backgroundColor: bg,
        borderColor: border,
        borderWidth: kind === 'ghost' ? 0 : 1.5,
        borderRadius: radius.md,
        minHeight: kind === 'ghost' ? 44 : 48,
        paddingHorizontal: 16,
        justifyContent: 'center',
        alignItems: 'center',
        opacity: disabled ? 0.45 : pressed ? 0.85 : 1,
      })}>
      {loading ? (
        <ActivityIndicator color={fg} />
      ) : (
        <Text style={{ color: fg, fontSize: kind === 'ghost' ? 15 : 16, fontWeight: '600' }}>{title}</Text>
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
  // REV-005: grade compacta de siglas (4 colunas), sem grupos por setor; o nome completo aparece abaixo.
  const current = POSITIONS.find((p) => p.value === value);
  return (
    <View style={{ gap: 6 }}>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', marginHorizontal: -4 }}>
        {POSITIONS.filter((p) => !sector || p.sector === sector).map((p) => {
          const on = value === p.value;
          return (
            <View key={p.value} style={{ width: '25%', padding: 4 }}>
              <Pressable
                onPress={() => onChange(p.value)}
                accessibilityRole="radio"
                accessibilityState={{ selected: on }}
                accessibilityLabel={p.label}
                style={{
                  minHeight: 44,
                  alignItems: 'center',
                  justifyContent: 'center',
                  borderRadius: 12,
                  borderWidth: 1,
                  borderColor: on ? colors.blue : colors.line,
                  backgroundColor: on ? colors.blue : colors.white,
                }}>
                <Text style={{ fontWeight: '800', color: on ? colors.white : colors.ink }}>{p.value}</Text>
              </Pressable>
            </View>
          );
        })}
      </View>
      {current && <Text style={type.meta}>{current.label}</Text>}
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
              // V4.5: área de toque mínima de 44 px (era 37 px)
              minHeight: 44,
              justifyContent: 'center',
              paddingVertical: 8,
              paddingHorizontal: 14,
              borderRadius: 22,
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
  children ? (
    <Text style={{ color: colors.danger, fontSize: 14, lineHeight: 20 }} accessibilityLiveRegion="polite" accessibilityRole="alert">
      {children}
    </Text>
  ) : null;

const styles = StyleSheet.create({
  input: {
    borderWidth: 1,
    borderColor: colors.line,
    backgroundColor: colors.white,
    borderRadius: radius.md,
    paddingHorizontal: 14,
    paddingVertical: 12,
    minHeight: 48,
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
  // V6.2: superfície cinza-clara sem borda nem sombra. Separa o conteúdo pelo tom, não por moldura; campos e botões
  // brancos por dentro ganham contraste. Destaques (placar, voto urgente) usam os componentes de lib/domain.tsx.
  card: {
    backgroundColor: colors.bg,
    borderRadius: radius.card,
    padding: 16,
    gap: 6,
  },
});

/**
 * REV-036: carregamento padrão — blocos neutros no formato de uma lista, sem animação; distinto de vazio
 * (EmptyState), erro (ErrorText + tentar de novo) e bloqueio (EmptyState com o plano).
 */
export function LoadingBlock({ rows = 3 }: { rows?: number }) {
  return (
    <View style={{ gap: 10 }} accessibilityLabel="Carregando" accessibilityLiveRegion="polite">
      {Array.from({ length: rows }, (_, i) => (
        <View key={i} style={{ height: i === 0 ? 28 : 56, width: i === 0 ? '55%' : '100%', borderRadius: radius.card, backgroundColor: colors.bg }} />
      ))}
    </View>
  );
}
