// Atributos da carta e OVR exibido por versão da fórmula (puro: sem Supabase, testável em node).
// v1: Finalização/Garçom/Presença/Pé Quente/Resenha; V5 (formula_version 2): ATU/EST/PEQ/RES/DIS;
// V7.7 (formula_version 3): DEF, LET (linha) ou REF (goleiro), APR, RES, DIS.
type CardFields = {
  overall: number;
  tier: 'bronze' | 'prata' | 'ouro';
  matches_played: number;
  formula_version?: number | null;
  atu?: number | null;
  def?: number | null;
  sec_code?: 'LET' | 'REF' | null;
  ovr_display?: number | null;
};

export const ATTRIBUTES = [
  { key: 'finishing', label: 'Finalização', code: 'FIN' },
  { key: 'assisting', label: 'Garçom', code: 'GAR' },
  { key: 'attendance', label: 'Presença', code: 'PRE' },
  { key: 'winning', label: 'Pé Quente', code: 'PEQ' },
  { key: 'peer_rating', label: 'Resenha', code: 'RES' },
] as const;

// V5: os cinco atributos do OVR, iguais para todas as posições (goleiro sem GAR: o EST dele já é defesas + defesa).
export const ATTRIBUTES_V2 = [
  { key: 'atu', label: 'Atuação', code: 'ATU' },
  { key: 'est', label: 'Estatísticas', code: 'EST' },
  { key: 'peq', label: 'Performance da Equipe', code: 'PEQ' },
  { key: 'res', label: 'Regularidade', code: 'RES' },
  { key: 'dis', label: 'Disciplina', code: 'DIS' },
] as const;

// V7.7: atributos definitivos. O segundo é LET (jogador de linha) ou REF (goleiro), nunca os dois.
export const ATTRIBUTES_V3_LINE = [
  { key: 'def', label: 'Defesa', code: 'DEF' },
  { key: 'sec', label: 'Letalidade', code: 'LET' },
  { key: 'apr', label: 'Aproveitamento', code: 'APR' },
  { key: 'res', label: 'Resenha', code: 'RES' },
  { key: 'dis', label: 'Disciplina', code: 'DIS' },
] as const;
export const ATTRIBUTES_V3_KEEPER = [
  { key: 'def', label: 'Defesa', code: 'DEF' },
  { key: 'sec', label: 'Reflexo', code: 'REF' },
  { key: 'apr', label: 'Aproveitamento', code: 'APR' },
  { key: 'res', label: 'Resenha', code: 'RES' },
  { key: 'dis', label: 'Disciplina', code: 'DIS' },
] as const;

// Basta a parte da carta que as telas recebem (algumas listas vêm sem id).
type Versioned = Partial<Pick<CardFields, 'formula_version' | 'atu' | 'def' | 'sec_code'>>;
type CardLike = Pick<CardFields, 'overall' | 'tier' | 'matches_played'> & Partial<Pick<CardFields, 'formula_version' | 'atu' | 'def' | 'ovr_display'>>;

export const isV3 = (c: Versioned) => (c.formula_version ?? 1) >= 3 && c.def !== null && c.def !== undefined;
/** Carta com OVR do motor novo (V5 ou V7.7): sem número antes da 5ª partida. */
export const isV2 = (c: Versioned) => isV3(c) || ((c.formula_version ?? 1) >= 2 && c.atu !== null && c.atu !== undefined);
export const attributesV3 = (secCode: string | null | undefined) => (secCode === 'REF' ? ATTRIBUTES_V3_KEEPER : ATTRIBUTES_V3_LINE);
export const cardAttributes = (c: Versioned) => (isV3(c) ? attributesV3(c.sec_code) : isV2(c) ? ATTRIBUTES_V2 : ATTRIBUTES);
/** OVR mostrado: null = avaliação em andamento (menos de 5 partidas, sem número fictício). */
export const cardOverall = (c: CardLike): number | null => (isV2(c) ? (c.ovr_display ?? null) : Math.round(c.overall));
