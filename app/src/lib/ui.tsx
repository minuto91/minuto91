import { ReactNode } from 'react';
import { ActivityIndicator, FlatList, Pressable, ScrollView, StyleSheet, TextInputProps, View } from 'react-native';
import { Text, TextInput } from './text';

import { Icon, IconName } from './icons';
import { colors, POSITIONS, Position, radius, Sector, SECTORS, shadow, space, touch, type } from './theme';

export function Screen({ children }: { children: ReactNode }) {
  return (
    <ScrollView
      style={{ backgroundColor: colors.white }}
      contentContainerStyle={{ padding: space.xl, paddingBottom: space.xxxl, gap: space.md, flexGrow: 1 }}
      // V6.0: formulários utilizáveis com o teclado aberto (iOS ajusta a área rolável).
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
      contentContainerStyle={{ padding: space.xl, paddingBottom: space.xxxl, flexGrow: 1 }}
      keyboardShouldPersistTaps="handled"
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

/** Estado vazio: o que falta e, quando houver, o próximo passo. */
export function EmptyState({ title, hint, children }: { title: string; hint?: string; children?: ReactNode }) {
  return (
    <View style={{ alignItems: 'center', gap: 6, paddingVertical: 24, paddingHorizontal: 12 }}>
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
  return (
    <View style={{ gap: 10 }}>
      {SECTORS.filter((s) => !sector || s.value === sector).map((s) => (
        <View key={s.value} style={{ gap: 6 }}>
          {!sector && <Text style={type.meta}>{s.label}</Text>}
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

// ---------------------------------------------------------------------------------------------------------------
// V6.0 — componentes consolidados do Design System (docs/v6_design_system.md). Substituem as versões locais
// repetidas em cada tela (grupos de atalhos, linhas, placar, selos de estado, avisos e estados de erro).
// ---------------------------------------------------------------------------------------------------------------

export type Tone = 'neutral' | 'info' | 'success' | 'warning' | 'danger' | 'gold';
const TONE: Record<Tone, { fg: string; bg: string }> = {
  neutral: { fg: colors.muted, bg: colors.bg },
  info: { fg: colors.blue, bg: colors.blueSoft },
  success: { fg: colors.success, bg: colors.successSoft },
  warning: { fg: colors.warning, bg: colors.warningSoft },
  danger: { fg: colors.danger, bg: colors.dangerSoft },
  gold: { fg: colors.darkGold, bg: colors.goldSoft },
};

/** Selo curto com texto (o estado nunca depende só da cor). */
export function Badge({ label, tone = 'neutral' }: { label: string; tone?: Tone }) {
  const t = TONE[tone];
  return (
    <View style={{ alignSelf: 'flex-start', flexDirection: 'row', alignItems: 'center', gap: 5, paddingHorizontal: 8, paddingVertical: 3, borderRadius: radius.pill, backgroundColor: t.bg }}>
      <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: t.fg }} />
      <Text style={{ fontSize: 12, lineHeight: 16, fontWeight: '700', color: t.fg }} numberOfLines={1}>
        {label}
      </Text>
    </View>
  );
}

// Estados da partida (só apresentação; as transições continuam no servidor).
const MATCH_STATUS: Record<string, { label: string; tone: Tone }> = {
  draft: { label: 'Em preparação', tone: 'neutral' },
  voting_open: { label: 'Votação aberta', tone: 'info' },
  finalizing: { label: 'Aguardando publicação', tone: 'warning' },
  finalized: { label: 'Resultado publicado', tone: 'success' },
  annulled: { label: 'Anulada', tone: 'danger' },
};
export function MatchStatusBadge({ status }: { status: string }) {
  const s = MATCH_STATUS[status] ?? { label: status, tone: 'neutral' as Tone };
  return <Badge label={s.label} tone={s.tone} />;
}

/** Título de seção com ação opcional à direita ("Ver todas"). */
export function SectionHeader({ title, action, onAction, first }: { title: string; action?: string; onAction?: () => void; first?: boolean }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', marginTop: first ? 0 : space.sm, gap: space.sm }}>
      <Text style={[type.section, { flex: 1 }]} accessibilityRole="header">
        {title}
      </Text>
      {action && onAction ? (
        <Pressable onPress={onAction} accessibilityRole="button" hitSlop={8} style={{ minHeight: touch.min, justifyContent: 'center' }}>
          <Text style={{ color: colors.blue, fontWeight: '700', fontSize: 15 }}>{action} ›</Text>
        </Pressable>
      ) : null}
    </View>
  );
}

export type ListItemProps = {
  title: string;
  sub?: string;
  icon?: IconName;
  leading?: ReactNode;
  trailing?: ReactNode;
  badge?: string;
  danger?: boolean;
  onPress?: () => void;
  a11yLabel?: string;
};

/** Linha de lista: ícone ou foto, título, apoio e seta. Toque mínimo de 56 px. */
export function ListItem({ title, sub, icon, leading, trailing, badge, danger, onPress, a11yLabel, first }: ListItemProps & { first?: boolean }) {
  return (
    <Pressable
      disabled={!onPress}
      accessibilityRole={onPress ? 'button' : undefined}
      accessibilityLabel={a11yLabel ?? (badge ? `${title}, ${badge}` : title)}
      accessibilityHint={sub}
      onPress={onPress}
      style={({ pressed }) => ({
        flexDirection: 'row',
        alignItems: 'center',
        gap: space.md,
        minHeight: 56,
        paddingHorizontal: 14,
        borderTopWidth: first ? 0 : 1,
        borderTopColor: colors.divider,
        backgroundColor: pressed ? colors.bg : colors.white,
      })}>
      {leading ?? (icon ? <Icon name={icon} size={22} color={danger ? colors.danger : undefined} /> : null)}
      <View style={{ flex: 1, minWidth: 0, paddingVertical: 9 }}>
        <Text style={{ fontSize: 16, fontWeight: '600', color: danger ? colors.danger : colors.ink }} numberOfLines={1}>
          {title}
        </Text>
        {sub ? (
          <Text style={{ fontSize: 13, color: colors.muted }} numberOfLines={1}>
            {sub}
          </Text>
        ) : null}
      </View>
      {badge ? <Text style={{ fontSize: 12, fontWeight: '700', color: colors.darkGold }}>{badge}</Text> : null}
      {trailing}
      {onPress && !danger ? <Text style={{ color: colors.muted, fontSize: 20 }}>›</Text> : null}
    </Pressable>
  );
}

/** Grupo de linhas sob um título: uma só moldura, divisores finos (sem cartão dentro de cartão). */
export function ListGroup({ title, items, children }: { title?: string; items?: ListItemProps[]; children?: ReactNode }) {
  return (
    <View style={{ gap: space.sm, marginTop: title ? space.sm : 0 }}>
      {title ? (
        <Text style={type.section} accessibilityRole="header">
          {title}
        </Text>
      ) : null}
      <View style={{ borderRadius: radius.card, borderWidth: 1, borderColor: colors.line, backgroundColor: colors.white, overflow: 'hidden' }}>
        {items?.map((it, n) => <ListItem key={it.title} {...it} first={n === 0} />)}
        {children}
      </View>
    </View>
  );
}

/** Placar: o protagonista visual da partida. Vencedor em negrito (não só por cor). */
export function Scoreboard({
  teamA,
  teamB,
  scoreA,
  scoreB,
  size = 'md',
  colorA,
  colorB,
}: {
  teamA: string;
  teamB: string;
  scoreA: number;
  scoreB: number;
  size?: 'md' | 'lg';
  colorA?: string;
  colorB?: string;
}) {
  const aWon = scoreA > scoreB;
  const bWon = scoreB > scoreA;
  const big = size === 'lg';
  const side = (name: string, won: boolean, align: 'left' | 'right', dot?: string) => (
    <View style={{ flex: 1, minWidth: 0, flexDirection: align === 'left' ? 'row' : 'row-reverse', alignItems: 'center', gap: 6 }}>
      {dot ? <View style={{ width: 10, height: 10, borderRadius: 5, backgroundColor: dot, borderWidth: 1, borderColor: colors.line }} /> : null}
      <Text style={{ flexShrink: 1, textAlign: align, fontSize: big ? 16 : 15, fontWeight: won ? '800' : '500', color: colors.ink }} numberOfLines={2}>
        {name}
      </Text>
    </View>
  );
  return (
    <View
      accessible
      accessibilityLabel={`${teamA} ${scoreA}, ${teamB} ${scoreB}`}
      style={{ flexDirection: 'row', alignItems: 'center', gap: space.md, paddingVertical: big ? space.sm : space.xs }}>
      {side(teamA, aWon, 'left', colorA)}
      <Text style={[big ? type.display : { ...type.number, fontSize: 30, lineHeight: 36 }, { textAlign: 'center' }]}>
        {scoreA}
        <Text style={{ color: colors.muted, fontWeight: '500' }}> x </Text>
        {scoreB}
      </Text>
      {side(teamB, bWon, 'right', colorB)}
    </View>
  );
}

/** Número esportivo com rótulo (estatísticas em linha, sem caixa própria). */
export function StatItem({ value, label }: { value: number | string; label: string }) {
  return (
    <View style={{ flex: 1, minWidth: 0 }} accessible accessibilityLabel={`${label}: ${value}`}>
      <Text style={type.numberSm} numberOfLines={1}>
        {value}
      </Text>
      <Text style={type.label} numberOfLines={1}>
        {label}
      </Text>
    </View>
  );
}

export function StatRow({ items }: { items: { value: number | string; label: string }[] }) {
  return (
    <View style={{ flexDirection: 'row', gap: space.sm }}>
      {items.map((i) => (
        <StatItem key={i.label} {...i} />
      ))}
    </View>
  );
}

export const Divider = () => <View style={{ height: 1, backgroundColor: colors.divider }} />;

/** Aviso em faixa: informação, alerta, sucesso (só após confirmação do servidor) ou erro. */
export function Notice({ tone = 'info', title, children, action, onAction }: { tone?: Tone; title?: string; children?: ReactNode; action?: string; onAction?: () => void }) {
  const t = TONE[tone];
  return (
    <View
      accessibilityRole={tone === 'danger' || tone === 'warning' ? 'alert' : undefined}
      accessibilityLiveRegion="polite"
      style={{ backgroundColor: t.bg, borderRadius: radius.md, padding: 14, gap: 4, borderLeftWidth: 3, borderLeftColor: t.fg }}>
      {title ? <Text style={{ fontSize: 15, fontWeight: '700', color: t.fg }}>{title}</Text> : null}
      {typeof children === 'string' ? <Text style={{ ...type.caption, color: colors.ink }}>{children}</Text> : children}
      {action && onAction ? (
        <Pressable onPress={onAction} accessibilityRole="button" hitSlop={8} style={{ minHeight: touch.min, justifyContent: 'center', alignSelf: 'flex-start' }}>
          <Text style={{ color: t.fg, fontWeight: '700', fontSize: 15 }}>{action} ›</Text>
        </Pressable>
      ) : null}
    </View>
  );
}

/** Erro de carregamento com "Tentar de novo" (erro de rede nunca vira "sem dados"). */
export function ErrorState({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <View style={{ gap: space.md, paddingVertical: space.lg }} accessibilityRole="alert">
      <Text style={type.cardTitle}>Não foi possível carregar</Text>
      <Text style={type.caption}>{message}</Text>
      {onRetry ? <Button title="Tentar de novo" kind="secondary" onPress={onRetry} /> : null}
    </View>
  );
}

/** Sem permissão: explica quem pode fazer, sem esconder que a tela existe. */
export const NoPermission = ({ who = 'o administrador da pelada' }: { who?: string }) => (
  <EmptyState title="Acesso restrito" hint={`Somente ${who} pode ver e usar esta área.`} />
);

/** Bloco de espera do tamanho do conteúdo (evita salto de layout). */
export const Skeleton = ({ height = 72 }: { height?: number }) => (
  <View
    accessibilityLabel="Carregando"
    accessibilityLiveRegion="polite"
    style={{ height, borderRadius: radius.card, backgroundColor: colors.bg }}
  />
);

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
  card: {
    backgroundColor: colors.white,
    borderRadius: radius.card,
    borderWidth: 1,
    borderColor: colors.line,
    padding: space.lg,
    gap: 6,
    ...shadow.card,
  },
});
