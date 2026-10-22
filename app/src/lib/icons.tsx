// Ícones de traço simples (react-native-svg), na cor que a tela pedir. Sem biblioteca de ícones:
// são poucos e precisam sair iguais no iOS, Android e web.
import Svg, { Circle, Path, Rect } from 'react-native-svg';

import { colors } from './theme';

export type IconName = 'elenco' | 'rankings' | 'card' | 'partidas' | 'retro' | 'jogadores' | 'config' | 'convite';

export function Icon({ name, size = 24, color = colors.blue }: { name: IconName; size?: number; color?: string }) {
  const p = { stroke: color, strokeWidth: 1.8, fill: 'none', strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const };
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24">
      {name === 'elenco' && (
        <>
          <Rect x={3} y={4} width={8} height={11} rx={1.5} {...p} />
          <Rect x={13} y={4} width={8} height={11} rx={1.5} {...p} />
          <Path d="M5 19h14" {...p} />
        </>
      )}
      {name === 'rankings' && (
        <>
          <Rect x={9} y={6} width={6} height={14} rx={1} {...p} />
          <Rect x={3} y={11} width={6} height={9} rx={1} {...p} />
          <Rect x={15} y={14} width={6} height={6} rx={1} {...p} />
        </>
      )}
      {name === 'card' && (
        <>
          <Path d="M6 3h12v12.5L12 21l-6-5.5z" {...p} />
          <Circle cx={12} cy={9.5} r={2.5} {...p} />
        </>
      )}
      {name === 'partidas' && (
        <>
          <Circle cx={12} cy={12} r={8.5} {...p} />
          <Path d="M12 7.5l3.5 2.5-1.3 4h-4.4l-1.3-4z" {...p} />
        </>
      )}
      {name === 'retro' && (
        <>
          <Path d="M4 12a8 8 0 1 0 2.3-5.6" {...p} />
          <Path d="M4 4v4h4" {...p} />
          <Path d="M12 8v4l3 2" {...p} />
        </>
      )}
      {name === 'jogadores' && (
        <>
          <Circle cx={9} cy={8} r={3.2} {...p} />
          <Path d="M3 19c.6-3.4 3-5 6-5s5.4 1.6 6 5" {...p} />
          <Path d="M16 5.2a3 3 0 0 1 0 5.6M18 14.4c1.6.7 2.6 2.2 3 4.6" {...p} />
        </>
      )}
      {name === 'config' && (
        <>
          <Circle cx={12} cy={12} r={3} {...p} />
          <Path
            d="M12 2.8v2.4M12 18.8v2.4M2.8 12h2.4M18.8 12h2.4M5.5 5.5l1.7 1.7M16.8 16.8l1.7 1.7M5.5 18.5l1.7-1.7M16.8 7.2l1.7-1.7"
            {...p}
          />
        </>
      )}
      {name === 'convite' && (
        <>
          <Circle cx={10} cy={8} r={3.2} {...p} />
          <Path d="M4 19c.6-3.4 3-5 6-5 1.4 0 2.6.3 3.6 1" {...p} />
          <Path d="M18 13v6M15 16h6" {...p} />
        </>
      )}
    </Svg>
  );
}
