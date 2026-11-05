// Ícones de traço simples (react-native-svg), na cor que a tela pedir. Sem biblioteca de ícones:
// são poucos e precisam sair iguais no iOS, Android e web.
import Svg, { Circle, Path, Rect } from 'react-native-svg';

import { colors } from './theme';

export type IconName =
  | 'elenco'
  | 'rankings'
  | 'card'
  | 'partidas'
  | 'retro'
  | 'jogadores'
  | 'config'
  | 'convite'
  | 'duelo'
  | 'escalacao'
  | 'sorteio'
  | 'temporadas'
  | 'financeiro'
  // V10.1: abas, aviso e estados (substituem ✓ ○ ⚠ ✕ e › em texto)
  | 'inicio'
  | 'peladas'
  | 'carreira'
  | 'perfil'
  | 'sino'
  | 'chevron'
  | 'selecionado'
  | 'pendente'
  | 'alerta'
  | 'fechar';

export function Icon({ name, size = 24, color = colors.blue, strokeWidth = 1.8 }: { name: IconName; size?: number; color?: string; strokeWidth?: number }) {
  const p = { stroke: color, strokeWidth, fill: 'none', strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const };
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
      {/* REV-143: três linhas horizontais (menu); antes era um desenho parecido com um sol. */}
      {name === 'config' && <Path d="M4 6.5h16M4 12h16M4 17.5h16" {...p} strokeWidth={2.4} />}
      {name === 'convite' && (
        <>
          <Circle cx={10} cy={8} r={3.2} {...p} />
          <Path d="M4 19c.6-3.4 3-5 6-5 1.4 0 2.6.3 3.6 1" {...p} />
          <Path d="M18 13v6M15 16h6" {...p} />
        </>
      )}
      {name === 'duelo' && (
        <>
          <Path d="M4 4l7 7M4 4h4M4 4v4" {...p} />
          <Path d="M20 4l-7 7M20 4h-4M20 4v4" {...p} />
          <Path d="M7 17l3 3M14 20l3-3M9 15l-3 3M15 15l3 3" {...p} />
        </>
      )}
      {name === 'escalacao' && (
        <>
          <Rect x={3} y={4} width={18} height={16} rx={2} {...p} />
          <Path d="M12 4v16M3 12h3M18 12h3" {...p} />
          <Circle cx={12} cy={12} r={2.5} {...p} />
        </>
      )}
      {name === 'sorteio' && (
        <>
          <Rect x={4} y={4} width={16} height={16} rx={3} {...p} />
          <Circle cx={9} cy={9} r={1.2} {...p} />
          <Circle cx={15} cy={15} r={1.2} {...p} />
          <Circle cx={15} cy={9} r={1.2} {...p} />
          <Circle cx={9} cy={15} r={1.2} {...p} />
        </>
      )}
      {name === 'temporadas' && (
        <>
          <Rect x={4} y={5} width={16} height={15} rx={2} {...p} />
          <Path d="M4 10h16M8 3v4M16 3v4" {...p} />
        </>
      )}
      {name === 'financeiro' && (
        <>
          <Rect x={3} y={6} width={18} height={13} rx={2.5} {...p} />
          <Path d="M3 10h18M16 15h2" {...p} />
        </>
      )}
      {name === 'inicio' && <Path d="M3 11 L12 4 L21 11 V20 H14 V14 H10 V20 H3 Z" {...p} />}
      {name === 'peladas' && (
        <>
          <Circle cx={12} cy={12} r={9} {...p} />
          <Path d="M12 7.5 L16 10.5 L14.5 15 H9.5 L8 10.5 Z" {...p} />
        </>
      )}
      {name === 'carreira' && <Path d="M5 20 V13 M10 20 V9 M15 20 V12 M20 20 V5" {...p} />}
      {name === 'perfil' && (
        <>
          <Circle cx={12} cy={8} r={4} {...p} />
          <Path d="M4.5 20.5 C5.5 16.5 8.5 14.5 12 14.5 C15.5 14.5 18.5 16.5 19.5 20.5" {...p} />
        </>
      )}
      {name === 'sino' && (
        <>
          <Path d="M6 16V11a6 6 0 1 1 12 0v5l1.5 2h-15z" {...p} />
          <Path d="M10 20.5a2 2 0 0 0 4 0" {...p} />
        </>
      )}
      {name === 'chevron' && <Path d="M9 6l6 6-6 6" {...p} />}
      {name === 'selecionado' && <Path d="M5 12.5l4.5 4.5L19 7.5" {...p} strokeWidth={2.2} />}
      {name === 'pendente' && <Circle cx={12} cy={12} r={8} {...p} />}
      {name === 'alerta' && (
        <>
          <Path d="M12 4l9 16H3z" {...p} />
          <Path d="M12 10v4M12 17.4v.1" {...p} />
        </>
      )}
      {name === 'fechar' && <Path d="M6 6l12 12M18 6L6 18" {...p} strokeWidth={2} />}
    </Svg>
  );
}
