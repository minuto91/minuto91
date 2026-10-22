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
};

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
