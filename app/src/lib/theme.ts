import type { TextStyle } from 'react-native';

// Brand Book v2.1 (sem modo escuro).
export const colors = {
  blue: '#1255C6',
  deepBlue: '#103675',
  gold: '#D4A63D', // apenas detalhe, nunca texto sobre branco
  darkGold: '#8A6414', // texto e ícones
  bg: '#F4F7FC', // cinza claro: só superfícies secundárias (o fundo das telas é branco, Brand Book 5.1)
  ink: '#15243B',
  muted: '#5E6E86',
  white: '#FFFFFF',
  danger: '#B42318',
  line: '#D9E0EC',
  // V6.0: tons de apoio consolidados (antes repetidos como literais em cada tela).
  divider: '#EEF2F8', // separador interno de listas e blocos
  blueSoft: '#EAF1FD', // fundo de destaque informativo
  goldSoft: '#FBF4E2', // fundo de conquista
  success: '#0B6B3A',
  successSoft: '#E7F5EC',
  warning: '#9A3412',
  warningSoft: '#FDEEE6',
  dangerSoft: '#FDECEA',
};

// V4.6 — Design System (docs/v46_design_system.md). Inter é a fonte única (lib/text.tsx).
// Escala de texto: título 26, seção 19, cartão 17, texto 15–16, legenda 13–14, metadados 12–13, números 28–36.
export const type: Record<
  'display' | 'title' | 'section' | 'cardTitle' | 'body' | 'bodySm' | 'caption' | 'meta' | 'label' | 'number' | 'numberSm',
  TextStyle
> = {
  // V6.0: números esportivos (placar, OVR) e rótulos curtos acima de valores.
  display: { fontSize: 40, lineHeight: 46, fontWeight: '800', color: '#103675', fontVariant: ['tabular-nums'] },
  title: { fontSize: 26, lineHeight: 32, fontWeight: '700', color: '#103675' },
  section: { fontSize: 19, lineHeight: 25, fontWeight: '700', color: '#103675' },
  cardTitle: { fontSize: 17, lineHeight: 23, fontWeight: '600', color: '#15243B' },
  body: { fontSize: 16, lineHeight: 23, fontWeight: '400', color: '#15243B' },
  bodySm: { fontSize: 15, lineHeight: 21, fontWeight: '400', color: '#15243B' },
  caption: { fontSize: 14, lineHeight: 20, fontWeight: '400', color: '#5E6E86' },
  meta: { fontSize: 13, lineHeight: 18, fontWeight: '500', color: '#5E6E86' },
  label: { fontSize: 12, lineHeight: 16, fontWeight: '600', color: '#5E6E86', letterSpacing: 0.2 },
  numberSm: { fontSize: 20, lineHeight: 24, fontWeight: '800', color: '#103675', fontVariant: ['tabular-nums'] },
  number: { fontSize: 32, lineHeight: 38, fontWeight: '800', color: '#103675', fontVariant: ['tabular-nums'] },
};

/** Raios: campos e botões 12, cartões 14, folhas e modais 20, chips 22 (pílula). */
export const radius = { sm: 8, md: 12, card: 14, lg: 20, pill: 22 } as const;
/** Espaçamento em múltiplos de 4. */
export const space = { xs: 4, sm: 8, md: 12, lg: 16, xl: 20, xxl: 28, xxxl: 40 } as const;
/** Área de toque mínima (44) e altura dos botões (48). */
export const touch = { min: 44, button: 48 } as const;
/** Sombra moderada dos cartões (iOS/web) e elevação equivalente (Android). */
export const shadow = {
  card: { shadowColor: '#103675', shadowOpacity: 0.07, shadowRadius: 10, shadowOffset: { width: 0, height: 3 }, elevation: 2 },
} as const;

// V4.3: as dez posições oficiais (041). O setor é o que as fórmulas oficiais usam (inalteradas); a sigla é a
// posição específica do jogador. Registros antigos ficam só com o setor (Defensor, Meio-campista, Atacante)
// até o jogador escolher; Goleiro virou GOL automaticamente.
export const SECTORS = [
  { value: 'goalkeeper', label: 'Goleiro', legacy: 'Goleiro', short: 'GOL' },
  { value: 'defender', label: 'Defesa', legacy: 'Defensor', short: 'DEF?' },
  { value: 'midfielder', label: 'Meio-campo', legacy: 'Meio-campista', short: 'MEI?' },
  { value: 'attacker', label: 'Ataque', legacy: 'Atacante', short: 'ATA?' },
] as const;
export type Sector = (typeof SECTORS)[number]['value'];

export const POSITIONS = [
  { value: 'GOL', label: 'Goleiro', sector: 'goalkeeper' },
  { value: 'ZAG', label: 'Zagueiro', sector: 'defender' },
  { value: 'LD', label: 'Lateral-Direito', sector: 'defender' },
  { value: 'LE', label: 'Lateral-Esquerdo', sector: 'defender' },
  { value: 'VOL', label: 'Volante', sector: 'midfielder' },
  { value: 'MEI', label: 'Meio-Campo', sector: 'midfielder' },
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
