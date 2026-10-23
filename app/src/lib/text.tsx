// V4.6: Inter, a fonte única do app (Brand Book v2.1, seção 4). Cada peso da Inter é uma família própria
// (@expo-google-fonts/inter), e o Android não escolhe o peso sozinho a partir de fontWeight. Estes Text e TextInput
// trocam fontWeight pela família do peso certo; o resto do estilo segue igual. Todo o app importa Text daqui.
import {
  Inter_400Regular,
  Inter_500Medium,
  Inter_600SemiBold,
  Inter_700Bold,
  Inter_800ExtraBold,
  Inter_900Black,
} from '@expo-google-fonts/inter';
import { forwardRef } from 'react';
import { Text as RNText, TextInput as RNTextInput, StyleSheet, type TextInputProps, type TextProps, type TextStyle } from 'react-native';

export const INTER_FONTS = { Inter_400Regular, Inter_500Medium, Inter_600SemiBold, Inter_700Bold, Inter_800ExtraBold, Inter_900Black };

const FAMILY: Record<string, string> = {
  '100': 'Inter_400Regular',
  '200': 'Inter_400Regular',
  '300': 'Inter_400Regular',
  '400': 'Inter_400Regular',
  normal: 'Inter_400Regular',
  '500': 'Inter_500Medium',
  '600': 'Inter_600SemiBold',
  '700': 'Inter_700Bold',
  bold: 'Inter_700Bold',
  '800': 'Inter_800ExtraBold',
  '900': 'Inter_900Black',
};

/** Família Inter do peso pedido (estilo sem fontFamily própria). */
export function interStyle(style: TextProps['style']): TextStyle | null {
  const flat = StyleSheet.flatten(style) as TextStyle | undefined;
  if (flat?.fontFamily) return null;
  return { fontFamily: FAMILY[String(flat?.fontWeight ?? '400')] ?? 'Inter_400Regular', fontWeight: 'normal' };
}

export const Text = forwardRef<RNText, TextProps>(function Text({ style, ...props }, ref) {
  return <RNText ref={ref} {...props} style={[style, interStyle(style)]} />;
});

export const TextInput = forwardRef<RNTextInput, TextInputProps>(function TextInput({ style, ...props }, ref) {
  return <RNTextInput ref={ref} {...props} style={[style, interStyle(style)]} />;
});
