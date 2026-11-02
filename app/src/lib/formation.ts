// Formações táticas da V4.3 (042): 4-3-3 e 4-4-2, só para times com exatamente 11 jogadores (goleiro incluído).
// A formação diz ONDE cada jogador aparece no campo; nunca muda o time (definido à mão ou pelo sorteio) nem a
// posição cadastrada. Os espaços (slots) e a ordem são os mesmos do servidor (private.formation_slots).
import { positionSector } from './theme';

export type Formation = '4-3-3' | '4-4-2';
export const FORMATIONS: Formation[] = ['4-3-3', '4-4-2'];
export const FORMATION_SIZE = 11;

/**
 * Espaço tático: posição sugerida (uma ou mais siglas), outras posições que também servem ali (accepts) e lugar no
 * campo (x e y em %, ataque em cima). Meio-campo: MEI e VOL servem em qualquer um dos espaços do meio. Ataque: PD, PE,
 * ATA e CA servem em qualquer um dos espaços do ataque. Goleiro, laterais e zagueiros só servem na própria posição.
 */
export type Slot = { id: string; suggested: string[]; accepts?: string[]; x: number; y: number };

const MID = ['MEI', 'VOL'];
const FWD = ['PD', 'PE', 'ATA', 'CA'];

const BACK: Slot[] = [
  { id: 'GOL', suggested: ['GOL'], x: 50, y: 81 },
  { id: 'LE', suggested: ['LE'], x: 12, y: 60 },
  { id: 'ZAG1', suggested: ['ZAG'], x: 37, y: 64 },
  { id: 'ZAG2', suggested: ['ZAG'], x: 63, y: 64 },
  { id: 'LD', suggested: ['LD'], x: 88, y: 60 },
];

export const SLOTS: Record<Formation, Slot[]> = {
  '4-3-3': [
    ...BACK,
    { id: 'MEI1', suggested: ['MEI'], accepts: MID, x: 24, y: 38 },
    { id: 'VOL', suggested: ['VOL'], accepts: MID, x: 50, y: 44 },
    { id: 'MEI2', suggested: ['MEI'], accepts: MID, x: 76, y: 38 },
    { id: 'PE', suggested: ['PE'], accepts: FWD, x: 15, y: 14 },
    { id: 'CA', suggested: ['CA'], accepts: FWD, x: 50, y: 9 },
    { id: 'PD', suggested: ['PD'], accepts: FWD, x: 85, y: 14 },
  ],
  '4-4-2': [
    ...BACK,
    { id: 'MEI1', suggested: ['MEI'], accepts: MID, x: 12, y: 36 },
    { id: 'VOL1', suggested: ['VOL'], accepts: MID, x: 37, y: 42 },
    { id: 'VOL2', suggested: ['VOL', 'MEI'], accepts: MID, x: 63, y: 42 },
    { id: 'MEI2', suggested: ['MEI'], accepts: MID, x: 88, y: 36 },
    { id: 'CA', suggested: ['CA'], accepts: FWD, x: 35, y: 11 },
    { id: 'ATA', suggested: ['ATA'], accepts: FWD, x: 65, y: 11 },
  ],
};

/** Sigla mostrada no espaço (VOL2 do 4-4-2 é "VOL ou MEI"). */
export const slotLabel = (s: Slot) => s.suggested.join('/');

/** O jogador está num espaço diferente da posição oficial dele? (indicação discreta, nunca bloqueia) */
export function outOfPosition(slot: Slot, position: string | null | undefined) {
  if (!position) return true;
  if (slot.suggested.includes(position) || slot.accepts?.includes(position)) return false;
  // Cadastro antigo (só o setor): fora apenas se o setor for outro.
  if (!/^[A-Z]+$/.test(position)) return positionSector(slot.suggested[0]) !== position;
  return true;
}

/**
 * Distribuição inicial nos espaços (o admin ajusta depois): primeiro quem tem a sigla sugerida, depois quem é do
 * mesmo setor, depois o resto. Mantém quem já estava num espaço válido. Devolve { membership_id: slot }.
 */
export function autoAssign(
  players: { key: string; position: string | null }[],
  formation: Formation,
  keep: Record<string, string | null | undefined> = {},
): Record<string, string> {
  const slots = SLOTS[formation];
  const out: Record<string, string> = {};
  const taken = new Set<string>();
  for (const p of players) {
    const s = keep[p.key];
    if (s && slots.some((x) => x.id === s) && !taken.has(s)) {
      out[p.key] = s;
      taken.add(s);
    }
  }
  const free = () => players.filter((p) => !out[p.key]);
  const fill = (match: (slot: Slot, pos: string | null) => boolean) => {
    for (const slot of slots) {
      if (taken.has(slot.id)) continue;
      const p = free().find((x) => match(slot, x.position));
      if (p) {
        out[p.key] = slot.id;
        taken.add(slot.id);
      }
    }
  };
  fill((slot, pos) => !!pos && slot.suggested.includes(pos));
  fill((slot, pos) => !!pos && !!slot.accepts?.includes(pos));
  // Setor: nunca para o gol (jogador de linha só vai para o gol por último, quando o time não tem goleiro).
  fill((slot, pos) => slot.id !== 'GOL' && !!pos && positionSector(pos) === positionSector(slot.suggested[0]));
  fill((slot) => slot.id !== 'GOL');
  fill(() => true);
  return out;
}

/** Troca dois jogadores de lugar (ou move para um espaço vazio). */
export function swapSlots(map: Record<string, string>, a: string, b: string): Record<string, string> {
  const next = { ...map };
  const sa = next[a];
  const sb = next[b];
  if (sb) next[a] = sb;
  else delete next[a];
  if (sa) next[b] = sa;
  else delete next[b];
  return next;
}
