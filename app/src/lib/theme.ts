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

export const POSITIONS = [
  { value: 'goalkeeper', label: 'Goleiro' },
  { value: 'defender', label: 'Defensor' },
  { value: 'midfielder', label: 'Meio-campista' },
  { value: 'attacker', label: 'Atacante' },
] as const;

export type Position = (typeof POSITIONS)[number]['value'];

export const positionLabel = (v: string) =>
  POSITIONS.find((p) => p.value === v)?.label ?? v;

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
