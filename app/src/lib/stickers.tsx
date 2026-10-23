// V4.6: figurinhas do álbum (protótipo aprovado em 23/10/2026). Uma ilustração própria por coleção (nada de emoji ou
// ícone genérico) e o acabamento pelo nível: I bronze, II prata, III ouro, IV azul premium, V dourado superior e
// Lendário (azul profundo com dourado). Cada coleção mantém a quantidade real de níveis do catálogo (017); os critérios
// de desbloqueio não mudam. Tudo desenhado em SVG numa caixa 150 × 200.
import { useId } from 'react';
import Svg, { Circle, Defs, Ellipse, G, LinearGradient, Path, Polygon, RadialGradient, Rect, Stop, Text as SvgText } from 'react-native-svg';

export type StickerArtCode = 'craque' | 'artilheiro' | 'garcom' | 'presenca' | 'pe_quente' | 'invencivel' | 'nota_alta' | 'rei_do_mes' | 'selecao';
export type Finish = 'bronze' | 'prata' | 'ouro' | 'azul' | 'superior' | 'lendario';

type Palette = { bg0: string; bg1: string; m0: string; m1: string; m2: string; ink: string; line: string; text: string; double: boolean };

export const FINISH: Record<Finish, Palette & { label: string }> = {
  bronze: { label: 'Bronze', bg0: '#5E3216', bg1: '#C98A57', m0: '#F6D2B0', m1: '#C07F4C', m2: '#6E3B18', ink: '#3A1F0C', line: '#F0C29A', text: '#FFF4EA', double: false },
  prata: { label: 'Prata', bg0: '#4B5158', bg1: '#BCC4CD', m0: '#FFFFFF', m1: '#C3CAD2', m2: '#5E6670', ink: '#23282E', line: '#EEF1F4', text: '#FFFFFF', double: true },
  ouro: { label: 'Ouro', bg0: '#6A4606', bg1: '#DDB04A', m0: '#FFF4C9', m1: '#E3B84E', m2: '#8A6414', ink: '#103675', line: '#F8DD8E', text: '#FFF8E1', double: true },
  azul: { label: 'Azul premium', bg0: '#0B2A63', bg1: '#1E66DE', m0: '#EEF3FF', m1: '#8FB3F5', m2: '#1B4A9E', ink: '#0B2A63', line: '#A9C5FA', text: '#FFFFFF', double: true },
  superior: { label: 'Dourado superior', bg0: '#4A3003', bg1: '#F2CB5E', m0: '#FFFCEB', m1: '#F5D673', m2: '#8A6414', ink: '#103675', line: '#FFF0BF', text: '#FFFFFF', double: true },
  lendario: { label: 'Lendário', bg0: '#06163A', bg1: '#1A4699', m0: '#FFF6D5', m1: '#D4A63D', m2: '#8A6414', ink: '#103675', line: '#D4A63D', text: '#FFE9A8', double: true },
};

/** Acabamento do nível (1 = I ... 6 = Lendário). */
export const finishOf = (level: number): Finish => (['bronze', 'prata', 'ouro', 'azul', 'superior', 'lendario'] as const)[Math.min(Math.max(level, 1), 6) - 1];

const BALL = (cx: number, cy: number, r: number, t: Palette, m: string, sw = 1) => {
  // bola com gomo central e costuras (proporções do troféu)
  const k = r / 28;
  const pt = (x: number, y: number) => `${cx + x * k},${cy + y * k}`;
  return (
    <G>
      <Circle cx={cx} cy={cy} r={r} fill={m} stroke={t.m2} strokeWidth={sw} />
      <Polygon points={[pt(0, -12), pt(10.5, -4.4), pt(6.5, 8), pt(-6.5, 8), pt(-10.5, -4.4)].join(' ')} fill={t.ink} />
      <Path
        d={`M${pt(0, -12)} L${pt(0, -27)} M${pt(10.5, -4.4)} L${pt(25, -9)} M${pt(6.5, 8)} L${pt(15, 22)} M${pt(-6.5, 8)} L${pt(-15, 22)} M${pt(-10.5, -4.4)} L${pt(-25, -9)}`.replace(/,/g, ' ')}
        stroke={t.m2}
        strokeWidth={sw}
      />
    </G>
  );
};

const BOOT = (t: Palette, m: string, dy = 0) => (
  <G transform={`translate(0 ${dy})`}>
    <Path
      d="M4 64 C4 54 9 46 17 45 L29 44 C33 44 35 48 39 50 L50 55 C55 57 58 61 58 66 C58 71 55 74 49 74 L10 74 C6 74 4 71 4 68 Z"
      fill={m}
      stroke={t.m2}
      strokeWidth={1.2}
      strokeLinejoin="round"
    />
    <Path d="M4 69 H58" stroke={t.m2} strokeWidth={1.4} />
    <Path d="M22 47 L26 56 M28 46 L32 55 M34 47.5 L37 55" stroke="#FFFFFF" strokeWidth={1.6} strokeLinecap="round" opacity={0.85} />
    <Path d="M14 62 C24 58 36 60 48 64" stroke={t.ink} strokeWidth={3} strokeLinecap="round" fill="none" />
    {[10, 22, 38, 48].map((x) => (
      <Rect key={x} x={x} y={74} width={5} height={4} rx={1} fill={t.m2} />
    ))}
  </G>
);

function Art({ code, t, m, fl }: { code: StickerArtCode; t: Palette; m: string; fl: string }) {
  switch (code) {
    case 'craque':
      return (
        <G>
          {BALL(46, 56, 28, t, m, 1.3)}
          <Path d="M28 42 C32 35 38 31 45 30" stroke="#FFFFFF" strokeWidth={2.4} strokeLinecap="round" opacity={0.6} fill="none" />
          <Polygon points="76,10 80.4,19.6 90.8,20.6 83,27.6 85.2,38 76,32.6 66.8,38 69,27.6 61.2,20.6 71.6,19.6" fill="#FFFFFF" stroke={t.m2} strokeWidth={1.2} strokeLinejoin="round" />
          <Polygon points="76,15 78.6,21.6 76,29.4 73.4,21.6" fill={t.m1} opacity={0.7} />
        </G>
      );
    case 'artilheiro':
      return (
        <G>
          {BALL(72, 66, 17, t, m, 1.1)}
          {BOOT(t, m)}
          <Path d="M8 50 C9 48 11 47 14 46.5" stroke="#FFFFFF" strokeWidth={2} strokeLinecap="round" opacity={0.55} fill="none" />
        </G>
      );
    case 'garcom':
      return (
        <G>
          <G transform="rotate(-18 34 58)">{BOOT(t, m, -6)}</G>
          <Path d="M60 52 C68 40 76 36 84 36" stroke="#FFFFFF" strokeWidth={1.6} strokeDasharray="3 3.5" strokeLinecap="round" fill="none" opacity={0.9} />
          <Path d="M56 60 L64 58 M57 66 L66 66" stroke="#FFFFFF" strokeWidth={1.4} strokeLinecap="round" opacity={0.6} />
          {BALL(86, 30, 10, t, m, 0.9)}
        </G>
      );
    case 'presenca':
      return (
        <G>
          <Rect x={10} y={20} width={72} height={64} rx={8} fill={m} stroke={t.m2} strokeWidth={1.2} />
          <Path d="M10 28 Q10 20 18 20 H74 Q82 20 82 28 V36 H10 Z" fill={t.ink} />
          <Rect x={24} y={13} width={5} height={14} rx={2.5} fill={t.m1} stroke={t.m2} strokeWidth={1} />
          <Rect x={63} y={13} width={5} height={14} rx={2.5} fill={t.m1} stroke={t.m2} strokeWidth={1} />
          <Path d="M18 46 H74 M18 56 H74 M18 66 H74 M18 76 H60 M30 40 V80 M44 40 V80 M58 40 V80" stroke={t.m2} strokeWidth={0.8} opacity={0.55} />
          <Path d="M20 49.5 L23 52.5 L27.5 46.5 M34 49.5 L37 52.5 L41.5 46.5 M48 59.5 L51 62.5 L55.5 56.5" stroke={t.ink} strokeWidth={1.6} fill="none" strokeLinecap="round" strokeLinejoin="round" />
          {BALL(76, 76, 15, t, m, 1.1)}
        </G>
      );
    case 'pe_quente':
      return (
        <G>
          <Path d="M8 72 C2 60 8 50 12 44 C12 52 16 54 18 54 C16 44 22 30 32 24 C30 34 36 40 40 42 C40 34 44 28 50 24 C50 34 58 38 62 46 C64 40 66 36 70 34 C70 46 80 54 78 66 Z" fill={fl} opacity={0.95} />
          <Path d="M22 70 C18 62 22 56 26 52 C26 58 30 60 32 60 C32 52 36 46 42 42 C42 50 48 54 50 58 C52 54 54 52 58 50 C58 58 64 62 62 70 Z" fill="#FFE08A" opacity={0.9} />
          <G transform="translate(10 4) scale(0.85)">{BOOT(t, m)}</G>
        </G>
      );
    case 'invencivel':
      return (
        <G>
          <Path d="M50 8 L84 20 V46 C84 66 70 80 50 90 C30 80 16 66 16 46 V20 Z" fill={m} stroke={t.m2} strokeWidth={1.4} strokeLinejoin="round" />
          <Path d="M50 16 L77 25.6 V46 C77 62 66 73.6 50 82 C34 73.6 23 62 23 46 V25.6 Z" fill={t.ink} />
          {BALL(50, 46, 13, t, m, 1)}
          <Path d="M27 60 L36 60 M64 60 L73 60" stroke={t.m1} strokeWidth={1.6} strokeLinecap="round" />
          <Path d="M22 22 C30 18 40 14 48 12" stroke="#FFFFFF" strokeWidth={2} strokeLinecap="round" opacity={0.6} fill="none" />
        </G>
      );
    case 'nota_alta':
      return (
        <G>
          <Path d="M44 74 L40 90 M56 74 L60 90" stroke={t.m2} strokeWidth={4} strokeLinecap="round" />
          <Rect x={12} y={16} width={76} height={60} rx={9} fill={m} stroke={t.m2} strokeWidth={1.4} />
          <Rect x={19} y={23} width={62} height={46} rx={5} fill={t.ink} />
          <SvgText x={50} y={59} textAnchor="middle" fontSize={34} fontFamily="Inter_800ExtraBold" fontWeight="800" fill="#FFFFFF">
            10
          </SvgText>
          <Circle cx={18} cy={22} r={2} fill={t.m2} />
          <Circle cx={82} cy={22} r={2} fill={t.m2} />
        </G>
      );
    case 'rei_do_mes':
      return (
        <G>
          <Path d="M16 76 L10 30 L30 50 L50 18 L70 50 L90 30 L84 76 Z" fill={m} stroke={t.m2} strokeWidth={1.4} strokeLinejoin="round" />
          <Rect x={15} y={70} width={70} height={11} rx={3} fill={t.m2} />
          <Circle cx={10} cy={28} r={4.5} fill={m} stroke={t.m2} strokeWidth={1} />
          <Circle cx={90} cy={28} r={4.5} fill={m} stroke={t.m2} strokeWidth={1} />
          <Circle cx={50} cy={56} r={11} fill="#FFFFFF" stroke={t.m2} strokeWidth={1} />
          {BALL(50, 56, 9, t, '#FFFFFF', 0.8)}
          <Circle cx={50} cy={16} r={5} fill={t.ink} stroke={t.m2} strokeWidth={1} />
          <Circle cx={30} cy={63} r={3.4} fill={t.ink} />
          <Circle cx={70} cy={63} r={3.4} fill={t.ink} />
          <Path d="M16 36 L22 66" stroke="#FFFFFF" strokeWidth={1.8} strokeLinecap="round" opacity={0.5} />
        </G>
      );
    case 'selecao':
      return (
        <G>
          <Path d="M34 12 C38 17 44 19 50 19 C56 19 62 17 66 12 L86 22 L94 42 L80 48 L76 40 V88 H24 V40 L20 48 L6 42 L14 22 Z" fill={m} stroke={t.m2} strokeWidth={1.4} strokeLinejoin="round" />
          <Path d="M34 12 C38 17 44 19 50 19 C56 19 62 17 66 12 L63 10 C59 13 55 14.4 50 14.4 C45 14.4 41 13 37 10 Z" fill={t.ink} />
          <Path d="M24 52 H76 M24 58 H76" stroke={t.ink} strokeWidth={3} />
          <Polygon points="50,28 53.2,35 60.8,35.6 55,40.6 56.8,48 50,44 43.2,48 45,40.6 39.2,35.6 46.8,35" fill="#FFFFFF" stroke={t.m2} strokeWidth={1} strokeLinejoin="round" />
          <Path d="M28 44 C28 36 30 30 34 26" stroke="#FFFFFF" strokeWidth={2} strokeLinecap="round" opacity={0.5} fill="none" />
        </G>
      );
  }
}

/** Uma figurinha. locked: escurecida com cadeado (o requisito aparece fora, em texto). */
export function StickerTile({
  art,
  level,
  title,
  sub,
  locked = false,
  width = 120,
}: {
  art: StickerArtCode;
  level: number;
  title: string;
  sub?: string;
  locked?: boolean;
  width?: number;
}) {
  const uid = useId().replace(/[^a-zA-Z0-9]/g, '');
  const t = FINISH[finishOf(level)];
  const g = (n: string) => `${n}${uid}`;
  return (
    <Svg width={width} height={(width * 200) / 150} viewBox="0 0 150 200" accessibilityLabel={`${title}${locked ? ', bloqueada' : ''}`}>
      <Defs>
        <LinearGradient id={g('bg')} x1="0" y1="0" x2="0.4" y2="1">
          <Stop offset="0" stopColor={t.bg1} />
          <Stop offset="1" stopColor={t.bg0} />
        </LinearGradient>
        <LinearGradient id={g('m')} x1="0" y1="0" x2="0.8" y2="1">
          <Stop offset="0" stopColor={t.m0} />
          <Stop offset="0.5" stopColor={t.m1} />
          <Stop offset="1" stopColor={t.m2} />
        </LinearGradient>
        <RadialGradient id={g('glow')} cx="0.5" cy="0.42" r="0.55">
          <Stop offset="0" stopColor="#FFFFFF" stopOpacity={0.32} />
          <Stop offset="1" stopColor="#FFFFFF" stopOpacity={0} />
        </RadialGradient>
        <LinearGradient id={g('fl')} x1="0" y1="1" x2="0" y2="0">
          <Stop offset="0" stopColor="#E4571B" />
          <Stop offset="0.6" stopColor="#F59A2E" />
          <Stop offset="1" stopColor="#FFD866" />
        </LinearGradient>
      </Defs>
      <Rect x={1} y={1} width={148} height={198} rx={14} fill={`url(#${g('bg')})`} />
      <Rect x={1} y={1} width={148} height={198} rx={14} fill={`url(#${g('glow')})`} />
      <Rect x={7} y={7} width={136} height={186} rx={10} fill="none" stroke={t.line} strokeWidth={1.2} strokeOpacity={0.85} />
      {t.double && <Rect x={11} y={11} width={128} height={178} rx={8} fill="none" stroke={t.line} strokeWidth={0.6} strokeOpacity={0.7} />}
      <G transform="translate(25 20)" opacity={locked ? 0.5 : 1}>
        <Ellipse cx={50} cy={92} rx={30} ry={4} fill="#000000" opacity={0.22} />
        <Art code={art} t={t} m={`url(#${g('m')})`} fl={`url(#${g('fl')})`} />
      </G>
      {locked && (
        <G>
          <Rect x={1} y={1} width={148} height={198} rx={14} fill="#15243B" opacity={0.55} />
          <Rect x={63} y={58} width={24} height={20} rx={4} fill="#FFFFFF" />
          <Path d="M68 58 V52 C68 47.6 71 45 75 45 C79 45 82 47.6 82 52 V58" stroke="#FFFFFF" strokeWidth={3.4} fill="none" />
          <Circle cx={75} cy={67} r={2.6} fill="#15243B" />
        </G>
      )}
      <SvgText x={75} y={160} textAnchor="middle" fontSize={12.5} fontFamily="Inter_800ExtraBold" fontWeight="800" fill={t.text}>
        {title}
      </SvgText>
      {!!sub && (
        <SvgText x={75} y={176} textAnchor="middle" fontSize={10} fontFamily="Inter_600SemiBold" fontWeight="600" fill={t.text} opacity={0.85}>
          {sub}
        </SvgText>
      )}
    </Svg>
  );
}
