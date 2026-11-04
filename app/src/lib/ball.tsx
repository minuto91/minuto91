// REV-139 (V10.0): bola de futebol simples, na cor oficial do time, usada para associar o jogador ao time.
import Svg, { Circle, Line, Polygon } from 'react-native-svg';

export function Ball({ color, size = 28 }: { color: string; size?: number }) {
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" accessibilityElementsHidden importantForAccessibility="no-hide-descendants">
      <Circle cx="12" cy="12" r="10.5" fill={color} stroke="#0F172A" strokeWidth="1" />
      <Polygon points="12,7.2 16.2,10.2 14.6,15 9.4,15 7.8,10.2" fill="#FFFFFF" stroke="#0F172A" strokeWidth="0.8" />
      <Line x1="12" y1="7.2" x2="12" y2="2" stroke="#0F172A" strokeWidth="0.8" />
      <Line x1="16.2" y1="10.2" x2="21.2" y2="8.6" stroke="#0F172A" strokeWidth="0.8" />
      <Line x1="14.6" y1="15" x2="17.6" y2="19.4" stroke="#0F172A" strokeWidth="0.8" />
      <Line x1="9.4" y1="15" x2="6.4" y2="19.4" stroke="#0F172A" strokeWidth="0.8" />
      <Line x1="7.8" y1="10.2" x2="2.8" y2="8.6" stroke="#0F172A" strokeWidth="0.8" />
    </Svg>
  );
}
