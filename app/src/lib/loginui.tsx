// V8.2 — visual da tela de entrada (exceção cinematográfica escura; o resto do app segue o branding V8.1).
import { Image } from 'expo-image';
import { ReactNode, useState } from 'react';
import { ActivityIndicator, Dimensions, Platform, Pressable, StyleSheet, TextInputProps, View } from 'react-native';
import Svg, { Defs, G, LinearGradient, Path, Rect, Stop } from 'react-native-svg';

import { Text, TextInput } from './text';

export const L = {
  navy: '#06152B',
  navy2: '#081C35',
  night: '#030B18',
  black: '#020813',
  gold1: '#FFE184',
  gold2: '#F4C85B',
  gold3: '#D79A32',
  gold: '#F4C85B',
  text: '#F2F5FA',
  soft: '#B7C2D4',
  line: 'rgba(150,170,200,0.45)',
  field: 'rgba(8,24,48,0.72)',
  danger: '#FF8A80',
};

/** Fundo oficial (asset original, sem edição) + gradiente sobreposto só para legibilidade. */
export function LoginBackground() {
  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="none">
      <Image
        source={require('../../assets/login/fundo-login.jpg')}
        style={StyleSheet.absoluteFill}
        contentFit="cover"
        contentPosition="top center"
        accessibilityIgnoresInvertColors
      />
      <Svg width="100%" height="100%" preserveAspectRatio="none" style={StyleSheet.absoluteFill}>
        <Defs>
          <LinearGradient id="g" x1="0" y1="0" x2="0" y2="1">
            <Stop offset="0" stopColor={L.navy} stopOpacity="0.55" />
            <Stop offset="0.25" stopColor={L.navy2} stopOpacity="0.1" />
            <Stop offset="0.5" stopColor={L.navy2} stopOpacity="0" />
            <Stop offset="0.62" stopColor={L.night} stopOpacity="0.45" />
            <Stop offset="0.8" stopColor={L.night} stopOpacity="0.8" />
            <Stop offset="1" stopColor={L.black} stopOpacity="0.95" />
          </LinearGradient>
        </Defs>
        <Rect x="0" y="0" width="100%" height="100%" fill="url(#g)" />
      </Svg>
    </View>
  );
}

const Mail = () => (
  <Svg width={20} height={20} viewBox="0 0 24 24" fill="none" stroke={L.text} strokeWidth={1.6} strokeLinecap="round" strokeLinejoin="round">
    <Rect x="3" y="5" width="18" height="14" rx="2.5" />
    <Path d="M3.5 7l8.5 6 8.5-6" />
  </Svg>
);
const Lock = () => (
  <Svg width={20} height={20} viewBox="0 0 24 24" fill="none" stroke={L.text} strokeWidth={1.6} strokeLinecap="round" strokeLinejoin="round">
    <Rect x="4.5" y="10.5" width="15" height="10" rx="2.5" />
    <Path d="M8 10.5V8a4 4 0 018 0v2.5" />
    <Path d="M12 14.5v2" />
  </Svg>
);
const Eye = ({ off }: { off: boolean }) => (
  <Svg width={20} height={20} viewBox="0 0 24 24" fill="none" stroke={L.text} strokeWidth={1.6} strokeLinecap="round" strokeLinejoin="round">
    <Path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z" />
    <Path d="M12 9.5a2.5 2.5 0 100 5 2.5 2.5 0 000-5z" />
    {off && <Path d="M4 4l16 16" strokeWidth={2.2} />}
  </Svg>
);
const GoogleG = () => (
  <Svg width={24} height={24} viewBox="0 0 48 48">
    <G>
      <Path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9.1 3.6l6.8-6.8C35.8 2.4 30.3 0 24 0 14.6 0 6.5 5.4 2.6 13.2l7.9 6.1C12.4 13.6 17.7 9.5 24 9.5z" />
      <Path fill="#4285F4" d="M46.5 24.5c0-1.6-.1-3.1-.4-4.5H24v9h12.7c-.6 3-2.3 5.5-4.8 7.2l7.5 5.8c4.4-4.1 7.1-10.1 7.1-17.5z" />
      <Path fill="#FBBC05" d="M10.5 28.7A14.5 14.5 0 019.5 24c0-1.6.3-3.2.8-4.7l-7.9-6.1A24 24 0 000 24c0 3.9.9 7.5 2.6 10.8l7.9-6.1z" />
      <Path fill="#34A853" d="M24 48c6.5 0 11.9-2.1 15.9-5.8l-7.5-5.8c-2.1 1.4-4.9 2.3-8.4 2.3-6.3 0-11.6-4.1-13.5-9.9l-7.9 6.1C6.5 42.6 14.6 48 24 48z" />
    </G>
  </Svg>
);

/** V10.1: logo (imagem provisória até o arquivo oficial chegar) + slogan, centralizados. */
export function LoginBrand() {
  return (
    <View style={{ alignItems: 'center', gap: 10 }}>
      <View accessible accessibilityRole="header" accessibilityLabel="Minuto 91">
        <Image source={require('../../assets/images/logo-minuto91-provisoria.png')} style={{ width: 96, height: 86 }} contentFit="contain" accessibilityIgnoresInvertColors />
      </View>
      <Text style={{ fontSize: 15, color: L.soft, fontWeight: '400', textAlign: 'center' }} adjustsFontSizeToFit numberOfLines={1}>
        O jogo acaba. A resenha começa.
      </Text>
    </View>
  );
}

export function LoginField({
  icon,
  secure,
  ...props
}: TextInputProps & { icon: 'mail' | 'lock'; secure?: boolean }) {
  const [focus, setFocus] = useState(false);
  const [hide, setHide] = useState(true);
  return (
    <View style={[s.field, { borderColor: focus ? L.gold : L.line }]}>
      <View style={{ width: 20, height: 20 }}>{icon === 'mail' ? <Mail /> : <Lock />}</View>
      <TextInput
        placeholderTextColor={L.soft}
        autoCapitalize="none"
        autoCorrect={false}
        selectionColor={L.gold}
        {...props}
        secureTextEntry={secure ? hide : props.secureTextEntry}
        onFocus={(e) => {
          setFocus(true);
          props.onFocus?.(e);
        }}
        onBlur={(e) => {
          setFocus(false);
          props.onBlur?.(e);
        }}
        style={[s.fieldInput, props.style]}
      />
      {secure && (
        <Pressable
          onPress={() => setHide((h) => !h)}
          hitSlop={10}
          accessibilityRole="button"
          accessibilityLabel={hide ? 'Mostrar senha' : 'Ocultar senha'}>
          <Eye off={hide} />
        </Pressable>
      )}
    </View>
  );
}

export type LoginButtonKind = 'primary' | 'outline' | 'google';

export function LoginButton({
  title,
  onPress,
  kind,
  loading,
  disabled,
}: {
  title: string;
  onPress: () => void;
  kind: LoginButtonKind;
  loading?: boolean;
  disabled?: boolean;
}) {
  const off = !!(disabled || loading);
  const base = {
    height: 44,
    borderRadius: 12,
    borderWidth: kind === 'primary' ? 0 : 1,
    borderColor: kind === 'outline' ? L.gold : L.line,
    backgroundColor: kind === 'primary' ? L.gold2 : kind === 'outline' ? 'rgba(3,11,24,0.55)' : L.field,
    overflow: 'hidden' as const,
    ...(Platform.OS === 'web' ? ({ transitionProperty: 'all', transitionDuration: '200ms', transitionTimingFunction: 'ease-in-out' } as object) : {}),
  };
  const color = kind === 'primary' ? L.black : kind === 'outline' ? L.gold : '#FFFFFF';
  return (
    <Pressable
      onPress={onPress}
      disabled={off}
      accessibilityRole="button"
      accessibilityLabel={title}
      accessibilityState={{ disabled: off, busy: !!loading }}
      style={({ pressed }) => [base, { opacity: disabled ? 0.5 : pressed ? 0.85 : 1, transform: [{ scale: pressed ? 0.98 : 1 }] }]}>
      <View style={s.btnRow}>
        {loading ? (
          <ActivityIndicator color={color} size="small" />
        ) : (
          <>
            {kind === 'google' && <GoogleG />}
            <Text style={{ color, fontSize: 15, fontWeight: '600', marginLeft: kind === 'google' ? 10 : 0 }}>{title}</Text>
          </>
        )}
      </View>
    </Pressable>
  );
}

export function LoginDivider({ children }: { children: ReactNode }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
      <View style={s.rule} />
      <Text style={{ color: L.soft, fontSize: 13 }}>{children}</Text>
      <View style={s.rule} />
    </View>
  );
}

const s = StyleSheet.create({
  field: {
    flexDirection: 'row',
    alignItems: 'center',
    height: 44,
    borderRadius: 12,
    borderWidth: 1,
    backgroundColor: L.field,
    paddingHorizontal: 14,
    gap: 12,
  },
  fieldInput: { flex: 1, minWidth: 0, outlineStyle: 'none' as never, color: L.text, fontSize: Dimensions.get('window').width < 360 ? 12 : 15, paddingVertical: 8 },
  btnRow: { flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', paddingHorizontal: 16 },
  shadow: { shadowColor: L.gold3, shadowOpacity: 0.35, shadowRadius: 8, shadowOffset: { width: 0, height: 3 }, elevation: 4 },
  rule: { flex: 1, height: StyleSheet.hairlineWidth * 2, backgroundColor: L.line },
});
