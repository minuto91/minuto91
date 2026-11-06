import { ReactNode, useEffect, useState } from 'react';
import { ActivityIndicator, Animated, FlatList, Platform, Pressable, ScrollView, StyleSheet, TextInputProps, type TextStyle, View } from 'react-native';
import { Text, TextInput } from './text';

import { Icon, type IconName } from './icons';
import { useReducedMotion } from './motion';
import { colors, layout, POSITIONS, Position, radius, Sector, SECTORS, shadow, type } from './theme';

export function Screen({ children }: { children: ReactNode }) {
  return (
    <ScrollView
      style={{ backgroundColor: colors.screen }}
      // V8.4 (E10): conteúdo centralizado com largura máxima, margens de 20 e espaço de 16 entre blocos.
      contentContainerStyle={{ alignSelf: 'center', width: '100%', maxWidth: layout.maxWidth, padding: layout.gutter, gap: layout.gap, flexGrow: 1 }}
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
      style={{ backgroundColor: colors.screen }}
      contentContainerStyle={{ alignSelf: 'center', width: '100%', maxWidth: layout.maxWidth, padding: layout.gutter, flexGrow: 1 }}
      keyboardShouldPersistTaps="handled"
      automaticallyAdjustKeyboardInsets
      keyboardDismissMode="interactive"
      data={data ?? []}
      keyExtractor={keyExtractor}
      renderItem={({ item }) => <>{renderItem(item)}</>}
      ItemSeparatorComponent={ListGap}
      ListHeaderComponent={<View style={{ gap: 12, marginBottom: 12 }}>{header}</View>}
      ListEmptyComponent={data ? <>{empty}</> : undefined}
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
  <Text style={[type.section, { marginTop: first ? 0 : 8 }]} accessibilityRole="header">
    {children}
  </Text>
);

export const Sub = ({ children }: { children: ReactNode }) => <Text style={type.caption}>{children}</Text>;

export const Body = ({ children }: { children: ReactNode }) => <Text style={type.body}>{children}</Text>;

/**
 * Estado vazio (REV-027): ícone, mensagem breve e, só quando útil e permitido, a ação (children).
 */
export function EmptyState({ title, hint, children }: { title: string; hint?: string; children?: ReactNode }) {
  return (
    <View style={{ alignItems: 'center', gap: 4, paddingVertical: 24, paddingHorizontal: 12 }}>
      <View style={{ width: 40, height: 40, borderRadius: radius.pill, backgroundColor: colors.bg, alignItems: 'center', justifyContent: 'center', marginBottom: 8 }}>
        <Icon name="pendente" size={22} color={colors.muted} />
      </View>
      <Text style={[type.cardTitle, { textAlign: 'center' }]}>{title}</Text>
      {hint ? <Text style={[type.caption, { textAlign: 'center' }]}>{hint}</Text> : null}
      {children ? <View style={{ alignItems: 'center', gap: 8, marginTop: 12 }}>{children}</View> : null}
    </View>
  );
}

/** Carregando (indicador e texto curto, lido pelo leitor de tela). */
export function Loading({ label = 'Carregando...' }: { label?: string }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, paddingVertical: 8 }} accessibilityLiveRegion="polite">
      <ActivityIndicator color={colors.blue} />
      <Text style={type.caption}>{label}</Text>
    </View>
  );
}

/** Erro com ação de tentar de novo: o par do EmptyState e do LoadingBlock. */
export function ErrorState({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <View
      accessibilityRole="alert"
      style={{ alignItems: 'center', gap: 4, paddingVertical: 20, paddingHorizontal: 12, borderRadius: radius.card, backgroundColor: colors.dangerSoft }}>
      <Text style={[type.cardTitle, { color: colors.danger, textAlign: 'center' }]}>Algo deu errado</Text>
      <Text style={[type.caption, { textAlign: 'center', color: colors.danger }]}>{message}</Text>
      {onRetry ? (
        <View style={{ marginTop: 8 }}>
          <Button title="Tentar de novo" kind="secondary" size="sm" onPress={onRetry} />
        </View>
      ) : null}
    </View>
  );
}

/** Transição de 200 ms (transition-all duration-200 ease-in-out) nos elementos tocáveis; só a web interpreta. */
const smooth = (Platform.OS === 'web' ? { transitionProperty: 'all', transitionDuration: '200ms', transitionTimingFunction: 'ease-in-out' } : {}) as object;
/** Micro-interação ao tocar: leve redução de escala. */
const press = (pressed: boolean) => ({ transform: [{ scale: pressed ? 0.97 : 1 }] });

export function Button({
  title,
  onPress,
  kind = 'primary',
  size = 'md',
  block,
  disabled,
  loading,
}: {
  title: string;
  onPress: () => void;
  /** primary: ação principal; secondary: contorno claro; ghost: discreto, só texto; danger: destrutivo. */
  kind?: 'primary' | 'secondary' | 'ghost' | 'danger' | 'gold';
  /** md 40 px (padrão), sm 32 px (área de toque ampliada por hitSlop). */
  size?: 'md' | 'sm';
  /** Largura toda: padrão só na ação principal (primary); os demais são compactos. Passe block={false} para compactar um primary. */
  block?: boolean;
  disabled?: boolean;
  loading?: boolean;
}) {
  // gold (V10.0, REV-133): dourado chapado da marca, sem gradiente nem sombra; texto escuro para manter o contraste.
  const bg = kind === 'primary' ? colors.blue : kind === 'gold' ? colors.gold : kind === 'secondary' ? colors.white : kind === 'danger' ? colors.dangerSoft : 'transparent';
  const fg = kind === 'primary' ? colors.white : kind === 'gold' ? colors.ink : kind === 'danger' ? colors.danger : kind === 'secondary' ? colors.ink : colors.blue;
  const border = kind === 'secondary' ? colors.line : 'transparent';
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled || loading}
      hitSlop={size === 'sm' ? 6 : 2}
      accessibilityRole="button"
      accessibilityLabel={title}
      accessibilityState={{ disabled: !!(disabled || loading), busy: !!loading }}
      style={({ pressed }) => ({
        backgroundColor: bg,
        borderColor: border,
        borderWidth: kind === 'secondary' ? 1 : 0,
        borderRadius: radius.md,
        height: size === 'sm' ? 32 : 40,
        paddingHorizontal: size === 'sm' ? 12 : 16,
        justifyContent: 'center',
        alignItems: 'center',
        alignSelf: (block ?? kind === 'primary') ? 'stretch' : 'flex-start',
        opacity: disabled ? 0.45 : pressed ? 0.85 : 1,
        ...press(pressed),
        ...smooth,
      })}>
      {loading ? <ActivityIndicator color={fg} size="small" /> : <Text style={[size === 'sm' ? type.buttonSm : type.button, { color: fg }]}>{title}</Text>}
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

/** V10.1: bloco de conteúdo sem moldura de card, separado do seguinte por uma linha fina (substitui Card em seções de tela). */
export function Block({ children }: { children: ReactNode }) {
  return <View style={{ gap: 8, paddingBottom: 16, borderBottomWidth: 1, borderBottomColor: colors.line }}>{children}</View>;
}

/** V10.1: texto de ação com seta (ícone) no fim, no lugar do "›" em texto. A cor da seta acompanha a do texto. */
export function LinkLabel({ children, style }: { children: ReactNode; style?: TextStyle | TextStyle[] }) {
  const flat = StyleSheet.flatten(style) ?? {};
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 2 }}>
      <Text style={[{ flexShrink: 1 }, style]}>{children}</Text>
      <Icon name="chevron" size={16} color={String(flat.color ?? colors.blue)} />
    </View>
  );
}

/** V10.1: linha fina de separação (colors.line), usada no lugar de molduras de card. */
export const Divider = () => <View style={{ height: 1, backgroundColor: colors.line, alignSelf: 'stretch' }} />;

/**
 * V10.1: linha de lista (Figma "Linha de lista"): ícone opcional, título, subtítulo, valor à direita e seta.
 * Substitui os Group/Row locais das telas. Alvo de toque de pelo menos 44 px. `danger` pinta o título de vermelho.
 */
export function ListRow({
  title,
  subtitle,
  icon,
  onPress,
  danger,
  trailing,
  chevron = true,
  hint,
  accessibilityLabel,
}: {
  title: string;
  subtitle?: string;
  icon?: IconName;
  onPress?: () => void;
  danger?: boolean;
  trailing?: ReactNode;
  /** Seta à direita (padrão: só quando há onPress e a linha não é de perigo). */
  chevron?: boolean;
  hint?: string;
  accessibilityLabel?: string;
}) {
  const showChevron = chevron && !!onPress && !danger;
  const content = (
    <>
      {icon ? <Icon name={icon} size={22} /> : null}
      <View style={{ flex: 1, paddingVertical: 8, gap: 2 }}>
        <Text style={[danger ? type.body : type.cardTitle, danger ? { color: colors.danger, fontWeight: '500' } : null]}>{title}</Text>
        {subtitle ? (
          <Text style={type.caption} numberOfLines={1}>
            {subtitle}
          </Text>
        ) : null}
      </View>
      {trailing}
      {showChevron ? <Icon name="chevron" size={20} color={colors.muted} /> : null}
    </>
  );
  const base = { flexDirection: 'row' as const, alignItems: 'center' as const, gap: 12, minHeight: 56, paddingHorizontal: 4 };
  if (!onPress) return <View style={base}>{content}</View>;
  return (
    <Pressable accessibilityRole="button" accessibilityLabel={accessibilityLabel ?? title} accessibilityHint={hint ?? subtitle} onPress={onPress} style={({ pressed }) => [base, { opacity: pressed ? 0.6 : 1 }]}>
      {content}
    </Pressable>
  );
}

/** V10.1: grupo de linhas com título de seção opcional e divisores finos entre os itens (sem moldura). */
export function ListGroup({ title, children }: { title?: string; children: ReactNode }) {
  const items = (Array.isArray(children) ? children : [children]).flat().filter(Boolean) as ReactNode[];
  return (
    <View style={{ gap: 4 }}>
      {title ? (
        <Text style={type.section} accessibilityRole="header">
          {title}
        </Text>
      ) : null}
      <View>
        {items.map((c, i) => (
          <View key={i}>
            {i > 0 ? <Divider /> : null}
            {c}
          </View>
        ))}
      </View>
    </View>
  );
}

/** V10.1: número em destaque com rótulo (Figma "Número destaque"). `tone` troca a cor do número. */
export function Stat({ value, label, tone = 'ink' }: { value: string | number; label: string; tone?: 'ink' | 'blue' | 'danger' | 'gold' }) {
  const color = tone === 'blue' ? colors.blue : tone === 'danger' ? colors.danger : tone === 'gold' ? colors.darkGold : colors.ink;
  return (
    <View style={{ flex: 1, minWidth: 0, gap: 2 }} accessible accessibilityLabel={`${label}: ${value}`}>
      <Text style={[type.number, { color }]} numberOfLines={1} adjustsFontSizeToFit>
        {value}
      </Text>
      <Text style={type.meta} numberOfLines={2}>
        {label}
      </Text>
    </View>
  );
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
  // V10.0: a pessoa escolhe o SETOR e depois a POSIÇÃO (sigla); com `sector` fixo (troca dentro do setor) só a posição.
  // Grade compacta de siglas (4 colunas); o nome completo aparece abaixo.
  const current = POSITIONS.find((p) => p.value === value);
  const [picked, setPicked] = useState<Sector | null>(null);
  const shownSector = sector ?? picked ?? current?.sector ?? null;
  const askSector = !sector;
  return (
    <View style={{ gap: 6 }}>
      {askSector && (
        <>
          <Text style={type.meta}>Setor</Text>
          <Chips options={SECTORS.map((s) => ({ value: s.value, label: s.label }))} value={shownSector} onChange={(v) => setPicked(v)} />
          <Text style={type.meta}>Posição</Text>
        </>
      )}
      {askSector && !shownSector && <Text style={type.meta}>Escolha o setor para ver as posições.</Text>}
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', marginHorizontal: -4 }}>
        {POSITIONS.filter((p) => (askSector ? !!shownSector && p.sector === shownSector : !sector || p.sector === sector)).map((p) => {
          const on = value === p.value;
          return (
            <View key={p.value} style={{ width: '25%', padding: 4 }}>
              <Pressable
                onPress={() => onChange(p.value)}
                accessibilityRole="radio"
                accessibilityState={{ selected: on }}
                accessibilityLabel={p.label}
                style={{
                  height: 40,
                  alignItems: 'center',
                  justifyContent: 'center',
                  borderRadius: radius.md,
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
  small = false,
}: {
  options: readonly { value: T; label: string }[];
  value: T | null;
  onChange: (v: T) => void;
  /** V10.0 (REV-131): botões menores (filtro de temporada). */
  small?: boolean;
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
            hitSlop={4}
            style={({ pressed }) => ({
              // V9: pílula compacta de 36 px; o hitSlop leva a área de toque a 44 px.
              height: small ? 30 : 36,
              justifyContent: 'center',
              paddingHorizontal: small ? 11 : 14,
              borderRadius: radius.pill,
              borderWidth: 1,
              borderColor: on ? colors.blue : colors.line,
              backgroundColor: on ? colors.blue : colors.white,
              ...press(pressed),
              ...smooth,
            })}>
            <Text style={{ color: on ? colors.white : colors.body, fontWeight: '600', fontSize: small ? 13 : 14 }}>{o.label}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

/**
 * Filtro simples e minimalista (V9): trilho cinza com a opção ativa em branco (tabs do Shadcn). Para filtros e
 * alternâncias de visão; use Chips só quando a escolha for parte de um formulário.
 */
export function Segmented<T extends string>({
  options,
  value,
  onChange,
}: {
  options: readonly { value: T; label: string }[];
  value: T | null;
  onChange: (v: T) => void;
}) {
  return (
    <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ flexGrow: 0, alignSelf: 'flex-start', maxWidth: '100%' }}>
      <View style={{ flexDirection: 'row', backgroundColor: colors.bg, borderRadius: radius.md, padding: 2 }}>
        {options.map((o) => {
          const on = value === o.value;
          return (
            <Pressable
              key={o.value}
              accessibilityRole="button"
              accessibilityState={{ selected: on }}
              onPress={() => onChange(o.value)}
              hitSlop={{ top: 8, bottom: 8 }}
              style={{ height: 28, paddingHorizontal: 12, borderRadius: radius.sm, justifyContent: 'center', backgroundColor: on ? colors.white : 'transparent', ...(on ? shadow.card : {}), ...smooth }}>
              <Text style={{ fontSize: 13, fontWeight: on ? '600' : '500', color: on ? colors.ink : colors.muted }}>{o.label}</Text>
            </Pressable>
          );
        })}
      </View>
    </ScrollView>
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
      <Pressable onPress={() => bump(-step)} style={styles.stepBtn} hitSlop={6} accessibilityLabel={`Diminuir ${name}`}>
        <Text style={styles.stepTxt}>−</Text>
      </Pressable>
      <Text style={{ minWidth: 38, textAlign: 'center', fontWeight: '700', fontSize: 16, color: colors.ink }}>
        {value === null ? '–' : format(value)}
      </Text>
      <Pressable onPress={() => bump(step)} style={styles.stepBtn} hitSlop={6} accessibilityLabel={`Aumentar ${name}`}>
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
    paddingHorizontal: 12,
    paddingVertical: 8,
    minHeight: 40,
    fontSize: 15,
    color: colors.ink,
  },
  stepBtn: {
    width: 36,
    height: 36,
    borderRadius: radius.pill,
    borderWidth: 1,
    borderColor: colors.line,
    backgroundColor: colors.white,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stepTxt: { fontSize: 20, fontWeight: '700', color: colors.blue },
  // V6.2: superfície cinza-clara sem borda nem sombra. Separa o conteúdo pelo tom, não por moldura; campos e botões
  // brancos por dentro ganham contraste. Destaques (placar, voto urgente) usam os componentes de lib/domain.tsx.
  // V8.4 (E10): o cartão padrão do app passa a ser o da Central — branco, borda sutil, raio 16 e sombra leve.
  card: {
    backgroundColor: colors.white,
    borderRadius: radius.card,
    borderWidth: 1,
    borderColor: colors.line,
    padding: 16,
    gap: 8,
    ...shadow.card,
  },
});

/**
 * REV-036 / V9: carregamento padrão — esqueleto no formato de uma lista, com pulso suave (parado se o sistema pedir
 * menos movimento); distinto de vazio (EmptyState), erro (ErrorState) e bloqueio (EmptyState com o plano).
 */
export function LoadingBlock({ rows = 3 }: { rows?: number }) {
  const reduced = useReducedMotion();
  const [pulse] = useState(() => new Animated.Value(1));
  useEffect(() => {
    if (reduced) return;
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(pulse, { toValue: 0.5, duration: 800, useNativeDriver: true }),
        Animated.timing(pulse, { toValue: 1, duration: 800, useNativeDriver: true }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [reduced, pulse]);
  return (
    <Animated.View style={{ gap: 12, opacity: pulse }} accessibilityLabel="Carregando" accessibilityLiveRegion="polite">
      {Array.from({ length: rows }, (_, i) => (
        <View key={i} style={{ height: i === 0 ? 24 : 64, width: i === 0 ? '50%' : '100%', borderRadius: radius.card, backgroundColor: colors.line }} />
      ))}
    </Animated.View>
  );
}
