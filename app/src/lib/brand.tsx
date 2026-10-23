// V4.6: assinatura da marca nas peças compartilháveis (Brand Book v2.1, 3 e 11.3): o símbolo 91’ — quadrado de cantos
// arredondados azul, 91 branco em negrito, o sinal de minuto ’ dourado colado ao 1 e uma referência mínima ao
// círculo central. PROVISÓRIO: desenho fiel à especificação até a arte final do fundador (Figma) entrar como arquivo.
import { View } from 'react-native';
import Svg, { Circle, Path, Rect, Text as SvgText } from 'react-native-svg';

import { Text } from './text';
import { colors } from './theme';

/** Símbolo 91’ (ícone). */
export function BrandSymbol({ size = 24, onDark = false }: { size?: number; onDark?: boolean }) {
  return (
    <Svg width={size} height={size} viewBox="0 0 48 48" accessibilityLabel="Minuto 91">
      <Rect x={0} y={0} width={48} height={48} rx={11} fill={colors.blue} stroke={onDark ? colors.white : 'none'} strokeWidth={onDark ? 1.5 : 0} />
      <Circle cx={24} cy={24} r={17} fill="none" stroke={colors.white} strokeOpacity={0.14} strokeWidth={1.4} />
      <SvgText x={21.5} y={32.5} textAnchor="middle" fontSize={23} fontWeight="800" fontFamily="Inter_800ExtraBold" fill={colors.white} letterSpacing={-1}>
        91
      </SvgText>
      <Path d="M35.6 12.8 L38.6 12.8 L35.9 20.6 L33.6 20.6 Z" fill={colors.gold} />
    </Svg>
  );
}

/** Versão horizontal: símbolo + "Minuto 91". Discreta, para o rodapé das artes. */
export function BrandSignature({ size = 18, onDark = false }: { size?: number; onDark?: boolean }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }} accessible accessibilityLabel="Minuto 91">
      <BrandSymbol size={size} onDark={onDark} />
      <Text style={{ fontSize: Math.round(size * 0.62), fontWeight: '800', color: onDark ? colors.white : colors.deepBlue, letterSpacing: 0.2 }}>
        Minuto 91
      </Text>
    </View>
  );
}
