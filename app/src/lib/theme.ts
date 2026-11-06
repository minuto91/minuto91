import type { TextStyle } from 'react-native';

// Brand Book v2.1 + revitalização visual (V9): paleta slate (equivalente à do Tailwind) com o azul e o dourado da marca.
// V10.1: tela em branco (decisão do fundador), superfícies secundárias em slate-100, texto em slate-900 e secundário em slate-500.
export const colors = {
  blue: '#1255C6',
  blueSoft: '#EAF1FD', // azul-50: fundo de item ativo e de botão secundário
  deepBlue: '#103675',
  gold: '#D4A63D', // apenas detalhe, nunca texto sobre branco
  darkGold: '#8A6414', // texto e ícones
  screen: '#FFFFFF', // V10.1: fundo das telas em branco (antes slate-50 #F8FAFC)
  bg: '#F1F5F9', // slate-100: superfícies secundárias e esqueletos
  ink: '#0F172A', // slate-900
  body: '#334155', // slate-700
  muted: '#64748B', // slate-500
  white: '#FFFFFF',
  danger: '#B42318',
  dangerSoft: '#FEF3F2',
  dangerLine: '#F3C7C2', // borda de bloco de erro
  success: '#0B6B3A', // V10.1: resultado positivo (vitória, subiu)
  successSoft: '#E7F5EC',
  caution: '#9A3412', // V10.1: resultado negativo (derrota, caiu)
  cautionSoft: '#FDEEE6',
  noticeWarn: '#FFF6E0', // fundo do aviso de atenção
  line: '#E2E8F0', // slate-200
};

// V9 — escala de texto (Tailwind): título 24 bold, seção 18 semibold, cartão 16 semibold, texto 15, legenda 13, meta 12.
export const type: Record<'title' | 'section' | 'cardTitle' | 'body' | 'bodySm' | 'caption' | 'meta' | 'number' | 'button' | 'buttonSm' | 'tabLabel', TextStyle> = {
  title: { fontSize: 24, lineHeight: 30, fontWeight: '700', color: '#0F172A', letterSpacing: -0.4 },
  section: { fontSize: 18, lineHeight: 24, fontWeight: '700', color: '#0F172A', letterSpacing: -0.2 },
  cardTitle: { fontSize: 16, lineHeight: 22, fontWeight: '600', color: '#0F172A' },
  body: { fontSize: 15, lineHeight: 22, fontWeight: '400', color: '#334155' },
  bodySm: { fontSize: 14, lineHeight: 20, fontWeight: '400', color: '#334155' },
  caption: { fontSize: 13, lineHeight: 19, fontWeight: '400', color: '#64748B' },
  meta: { fontSize: 12, lineHeight: 16, fontWeight: '500', color: '#64748B' },
  number: { fontSize: 30, lineHeight: 36, fontWeight: '800', color: '#0F172A', fontVariant: ['tabular-nums'] },
  // V10.1 (Figma "Texto/Botão", "Texto/Botão pequeno", "Texto/Rótulo de aba"): sem cor, quem usa define.
  button: { fontSize: 14, lineHeight: 20, fontWeight: '600' },
  buttonSm: { fontSize: 13, lineHeight: 18, fontWeight: '600' },
  tabLabel: { fontSize: 11, lineHeight: 14, fontWeight: '600' },
};

/** Raios (Tailwind): sm 8 (rounded-lg), md 10, card 12 (rounded-xl), lg 16 (rounded-2xl), pill 999 (rounded-full). */
export const radius = { sm: 8, md: 10, card: 12, lg: 16, pill: 999 } as const;
/** Margens laterais 16, espaço entre blocos 16 (Tailwind p-4 / gap-4), largura máxima do conteúdo ~560. */
export const layout = { gutter: 16, gap: 16, maxWidth: 560 } as const;
/** Espaçamento em múltiplos de 4 (Tailwind: 1, 2, 3, 4, 5, 7). */
export const space = { xs: 4, sm: 8, md: 12, lg: 16, xl: 20, xxl: 28 } as const;
/** Sombra leve dos cartões (shadow-sm) e elevação equivalente (Android). */
export const shadow = {
  card: { shadowColor: '#0F172A', shadowOpacity: 0.05, shadowRadius: 6, shadowOffset: { width: 0, height: 1 }, elevation: 1 },
} as const;

// V4.3: as dez posições oficiais (041). O setor é o que as fórmulas oficiais usam (inalteradas); a sigla é a
// posição específica do jogador. Registros antigos ficam só com o setor (Defensor, Meio-campista, Atacante)
// até o jogador escolher; Goleiro virou GOL automaticamente.
export const SECTORS = [
  { value: 'goalkeeper', label: 'Goleiro', legacy: 'Goleiro', short: 'GOL' },
  { value: 'defender', label: 'Defesa', legacy: 'Defensor', short: 'DEF?' },
  { value: 'midfielder', label: 'Meio-campo', legacy: 'Meio-campo', short: 'MEI?' },
  { value: 'attacker', label: 'Ataque', legacy: 'Atacante', short: 'ATA?' },
] as const;
export type Sector = (typeof SECTORS)[number]['value'];

export const POSITIONS = [
  { value: 'GOL', label: 'Goleiro', sector: 'goalkeeper' },
  { value: 'ZAG', label: 'Zagueiro', sector: 'defender' },
  { value: 'LD', label: 'Lateral-Direito', sector: 'defender' },
  { value: 'LE', label: 'Lateral-Esquerdo', sector: 'defender' },
  { value: 'VOL', label: 'Volante', sector: 'midfielder' },
  { value: 'MEI', label: 'Meio-campo', sector: 'midfielder' },
  { value: 'CA', label: 'Centroavante', sector: 'attacker' },
  { value: 'PD', label: 'Ponta-Direita', sector: 'attacker' },
  { value: 'PE', label: 'Ponta-Esquerda', sector: 'attacker' },
  { value: 'ATA', label: 'Atacante', sector: 'attacker' },
] as const;

export type Position = (typeof POSITIONS)[number]['value'];

const legacySector = (v: string) => SECTORS.find((s) => s.value === v);

/** Nome da posição: sigla oficial ou setor antigo (Defensor/Meio-campista/Atacante). */
export const positionLabel = (v: string | null | undefined) =>
  !v ? 'Posição não informada' : (POSITIONS.find((p) => p.value === v)?.label ?? legacySector(v)?.legacy ?? v);

/** Sigla curta: GOL, ZAG... ou DEF?/MEI?/ATA? (setor antigo: falta escolher a posição específica). */
export const positionShort = (v: string | null | undefined) =>
  !v ? '–' : POSITIONS.some((p) => p.value === v) ? v : (legacySector(v)?.short ?? '–');

export const positionSector = (v: string | null | undefined): Sector | null =>
  !v ? null : (POSITIONS.find((p) => p.value === v)?.sector ?? legacySector(v)?.value ?? null);

/** Posição atual de um membro: a sigla, ou o setor antigo enquanto não for escolhida. */
export const memberPosition = (m: { position_code?: string | null; preferred_position?: string | null }) =>
  m.position_code ?? m.preferred_position ?? null;

/** Registro antigo sem posição específica (o app avisa discretamente). */
export const needsPositionUpdate = (m: { position_code?: string | null; preferred_position?: string | null }) =>
  !m.position_code && !!m.preferred_position && m.preferred_position !== 'goalkeeper';

/** Ordem de exibição: GOL, ZAG, LD, LE, VOL, MEI, CA, PD, PE, ATA (setores antigos junto do seu setor). */
const ORDER = ['GOL', 'goalkeeper', 'ZAG', 'LD', 'LE', 'defender', 'VOL', 'MEI', 'midfielder', 'CA', 'PD', 'PE', 'ATA', 'attacker'];
export const positionRank = (v: string | null | undefined) => (v && ORDER.includes(v) ? ORDER.indexOf(v) : 99);

// Pé dominante (027): dado do perfil da conta, nunca usado em fórmula.
export const FEET = [
  { value: 'right', label: 'Direito' },
  { value: 'left', label: 'Esquerdo' },
  { value: 'both', label: 'Ambos' },
] as const;

export type Foot = (typeof FEET)[number]['value'];

export const footLabel = (v: string) => {
  const f = FEET.find((x) => x.value === v);
  return f ? (f.value === 'both' ? 'Ambos os pés' : `Pé ${f.label.toLowerCase()}`) : v;
};

/** Rota da Central (aba Início, app/(tabs)/index.tsx). */
export const HOME = '/' as import('expo-router').Href;
