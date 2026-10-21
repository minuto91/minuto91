// Brand Book v2.1 (sem modo escuro).
export const colors = {
  blue: '#1255C6',
  deepBlue: '#103675',
  gold: '#D4A63D', // apenas detalhe, nunca texto sobre branco
  darkGold: '#8A6414', // texto e ícones
  bg: '#F4F7FC',
  ink: '#15243B',
  muted: '#5E6E86',
  white: '#FFFFFF',
  danger: '#B42318',
  line: '#D9E0EC',
};

export const POSITIONS = [
  { value: 'goalkeeper', label: 'Goleiro' },
  { value: 'defender', label: 'Defensor' },
  { value: 'midfielder', label: 'Meia' },
  { value: 'attacker', label: 'Atacante' },
] as const;

export type Position = (typeof POSITIONS)[number]['value'];

export const positionLabel = (v: string) =>
  POSITIONS.find((p) => p.value === v)?.label ?? v;
