// V8.5: lógica pura do sorteio exato, composições, campo ilustrativo e imagens (sem React; testada em tests/v85.test.ts).
// Nada aqui usa OVR, nota ou força: o sorteio é só posicional (REV-31) e é feito no servidor.

export type Team = 'A' | 'B';
export type PrepParticipant = {
  pid: string;
  membership_id: string | null;
  guest_id: string | null;
  guest: boolean;
  name: string;
  position: string | null;
  group: string;
  captain_team: Team | null;
  avatar_path?: string | null;
  eligible: boolean;
};
export type GroupCount = { group: string; a: number; b: number };
export type Summary = { cost: number; size_a: number; size_b: number; by_group: GroupCount[] };
export type PreviewPlayer = { pid: string; team: Team; name: string; guest: boolean; position: string | null; group: string; captain: boolean };
export type PreviewRound = { round: number; optimal: { cost: number; count: string } | null; summary: Summary; players: PreviewPlayer[] };
export type Preview = { id: string; prep_version: number; source: 'draw' | 'manual' | 'copy'; status: string; stale: boolean; rounds: PreviewRound[] };
export type Preparation = {
  id: string;
  pelada_id: string;
  mode: 'single' | 'independent';
  rounds_total: number;
  round_dates: string[] | null;
  captains_enabled: boolean;
  status: string;
  version: number;
  problems: { pid: string; problem: string }[];
  participants: PrepParticipant[];
  preview: Preview | null;
  source_composition_id?: string | null;
  notice?: string | null;
  suggested?: { pid: string; team: Team }[];
};
export type CompMember = {
  pid: string;
  membership_id: string | null;
  guest: boolean;
  name: string;
  position: string | null;
  group: string;
  team: Team;
  captain: boolean;
  avatar_path?: string | null;
  eligible: boolean;
};
export type Composition = {
  id: string;
  pelada_id: string;
  source: 'draw' | 'manual' | 'copy';
  mode: 'single' | 'independent';
  round_number: number;
  rounds_total: number;
  round_date: string | null;
  label: string;
  team_a_name: string;
  team_b_name: string;
  captains_enabled: boolean;
  status: string;
  version: number;
  members: CompMember[];
  summary: Summary | null;
  notices?: { op: number; notice: string; pid: string }[];
};
export type Point = { x: number; y: number };
export type Positions = Record<string, Point>;
export type SharePayload = {
  composition_id: string;
  pelada_name: string;
  label: string;
  round_number: number;
  rounds_total: number;
  round_date: string | null;
  team_a_name: string;
  team_b_name: string;
  composition_version: number;
  field_seq: number | null;
  field: { positions: Positions; missing: string[]; needs_review: boolean } | null;
  members: CompMember[];
  count: number;
  stamp: string;
  generated_at: string;
};

// ---------------------------------------------------------------------------------------------------------------
// Grupos posicionais (REV-01/02): mesma ordem do servidor (private.draw_group_order).
export const GROUP_ORDER = ['GOL', 'ZAG', 'LD', 'LE', 'DEF', 'VOL', 'MEI', 'MEIO', 'ATA', 'none'];
export const GROUP_LABEL: Record<string, string> = {
  GOL: 'Goleiros',
  ZAG: 'Zagueiros',
  LD: 'Laterais direitos',
  LE: 'Laterais esquerdos',
  DEF: 'Defensores (posição antiga)',
  VOL: 'Volantes',
  MEI: 'Meias',
  MEIO: 'Meio-campistas (posição antiga)',
  ATA: 'Atacantes',
  none: 'Sem posição',
};
export const groupRank = (g: string) => {
  const i = GROUP_ORDER.indexOf(g);
  return i < 0 ? 99 : i;
};
export function groupKey(position: string | null | undefined): string {
  if (!position) return 'none';
  if (position === 'GOL' || position === 'goalkeeper') return 'GOL';
  if (['ZAG', 'LD', 'LE', 'VOL', 'MEI'].includes(position)) return position;
  if (['CA', 'PD', 'PE', 'ATA', 'attacker'].includes(position)) return 'ATA';
  if (position === 'defender') return 'DEF';
  if (position === 'midfielder') return 'MEIO';
  return 'none';
}

// REV-46/47: resumo discreto, sem força nem OVR. Diferença inevitável explicada sem alarmismo.
export function summaryText(s: Summary, optimalCost?: number | null): { headline: string; lines: string[]; unavoidable: boolean } {
  const lines = [...s.by_group]
    .sort((x, y) => groupRank(x.group) - groupRank(y.group))
    .map((g) => `${GROUP_LABEL[g.group] ?? g.group}: ${g.a} x ${g.b}`);
  const unavoidable = s.cost > 0 && optimalCost != null && s.cost === optimalCost;
  const headline =
    s.cost === 0
      ? `${s.size_a} x ${s.size_b} · posições equilibradas`
      : unavoidable
        ? `${s.size_a} x ${s.size_b} · melhor equilíbrio possível com esses jogadores`
        : `${s.size_a} x ${s.size_b}`;
  return { headline, lines, unavoidable };
}

/** Quantidade de composições ótimas (texto exato vindo do servidor) em forma legível. */
export function countLabel(count: string): string {
  const n = BigInt(count);
  if (n === 1n) return 'só existe 1 divisão ideal';
  if (n < 1_000_000n) return `sorteado entre ${n.toLocaleString('pt-BR')} divisões ideais`;
  return `sorteado entre mais de ${(Number(n / 1_000_000n)).toLocaleString('pt-BR')} milhões de divisões ideais`;
}

// ---------------------------------------------------------------------------------------------------------------
// Homônimos (REV-29/70): diferenciação visual discreta sem alterar o nome cadastrado.
export function nameHints<T extends { pid: string; name: string; position: string | null; guest?: boolean }>(ps: T[]): Record<string, string> {
  const norm = (s: string) => s.trim().toLocaleLowerCase('pt-BR');
  const byName = new Map<string, T[]>();
  for (const p of ps) byName.set(norm(p.name), [...(byName.get(norm(p.name)) ?? []), p]);
  const out: Record<string, string> = {};
  for (const group of byName.values()) {
    if (group.length < 2) continue;
    const sorted = [...group].sort((a, b) => a.pid.localeCompare(b.pid));
    const keys = sorted.map((p) => `${p.position ?? 'sem posição'}${p.guest ? ' · convidado' : ''}`);
    const unique = new Set(keys).size === keys.length;
    sorted.forEach((p, i) => (out[p.pid] = unique ? keys[i] : `${keys[i]} · ${i + 1}`));
  }
  return out;
}

// Nomes longos (REV-67): abreviação visual só se não criar ambiguidade na mesma imagem.
export function displayNames<T extends { pid: string; name: string }>(ps: T[], max = 18): Record<string, string> {
  // Só abrevia quando o último termo é uma palavra (nunca número ou sufixo): "Ana Luíza Souza" → "Ana S.".
  const short = (n: string) => {
    const parts = n.trim().split(/\s+/);
    const last = parts[parts.length - 1];
    return parts.length > 1 && /^\p{L}/u.test(last) ? `${parts[0]} ${last[0]}.` : n.trim();
  };
  const out: Record<string, string> = {};
  const candidates = ps.map((p) => ({ p, s: p.name.length > max ? short(p.name) : p.name }));
  for (const { p, s } of candidates) {
    const clash = candidates.some((c) => c.p.pid !== p.pid && c.s.toLocaleLowerCase('pt-BR') === s.toLocaleLowerCase('pt-BR'));
    out[p.pid] = clash ? p.name : s; // ambíguo: mantém o nome inteiro (o layout quebra a linha)
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------------------
// Imagens: paginação (REV-60) e integridade (REV-65, LAC-06).
export type SharePage = { page: number; pages: number; A: CompMember[]; B: CompMember[] };

const sortMembers = (ms: CompMember[]) =>
  [...ms].sort((a, b) => Number(b.captain) - Number(a.captain) || groupRank(a.group) - groupRank(b.group) || a.name.localeCompare(b.name, 'pt-BR') || a.pid.localeCompare(b.pid));

/** Divide a lista integral em páginas; cada página leva até `perTeam` de cada equipe, todos aparecem uma vez. */
export function paginateList(members: CompMember[], perTeam = 14): SharePage[] {
  const A = sortMembers(members.filter((m) => m.team === 'A'));
  const B = sortMembers(members.filter((m) => m.team === 'B'));
  const pages = Math.max(1, Math.ceil(Math.max(A.length, B.length) / perTeam));
  return Array.from({ length: pages }, (_, i) => ({
    page: i + 1,
    pages,
    A: A.slice(i * perTeam, (i + 1) * perTeam),
    B: B.slice(i * perTeam, (i + 1) * perTeam),
  }));
}

/** Campo: até `perField` jogadores por imagem; quem passa vai para imagens seguintes (mesma versão). */
export function paginateField(members: CompMember[], perField = 22): CompMember[][] {
  const all = sortMembers(members);
  const out: CompMember[][] = [];
  for (let i = 0; i < all.length; i += perField) out.push(all.slice(i, i + perField));
  return out.length ? out : [[]];
}

export type IntegrityIssue = 'MISSING' | 'DUPLICATE' | 'TEAM_MISMATCH' | 'CAPTAINS' | 'VERSION' | 'EMPTY';

/** Confere, antes de liberar cada arquivo, que as páginas cobrem exatamente a versão oficial do pacote. */
export function checkPages(payload: SharePayload, pages: { members: { pid: string; team: Team; captain: boolean }[]; version: number; stamp: string }[]): IntegrityIssue[] {
  const issues = new Set<IntegrityIssue>();
  if (!payload.members.length) issues.add('EMPTY');
  if (pages.some((p) => p.version !== payload.composition_version || p.stamp !== payload.stamp)) issues.add('VERSION');
  const seen = new Map<string, { team: Team; captain: boolean }>();
  for (const p of pages)
    for (const m of p.members) {
      if (seen.has(m.pid)) issues.add('DUPLICATE');
      seen.set(m.pid, { team: m.team, captain: m.captain });
    }
  for (const m of payload.members) {
    const s = seen.get(m.pid);
    if (!s) issues.add('MISSING');
    else if (s.team !== m.team) issues.add('TEAM_MISMATCH');
    else if (s.captain !== m.captain) issues.add('CAPTAINS');
  }
  if (seen.size !== payload.members.length) issues.add('DUPLICATE');
  return [...issues];
}

// ---------------------------------------------------------------------------------------------------------------
// Campo ilustrativo (Etapa 33, REV-53/54/64). Coordenadas em %; time A embaixo, B em cima; fora de 0..100 = neutro.
const ROW_Y: Record<string, number> = { GOL: 93, ZAG: 82, LD: 76, LE: 76, DEF: 82, VOL: 72, MEI: 64, MEIO: 68, ATA: 56, none: 88 };
const ROW_SHIFT: Record<string, number> = { VOL: -14, MEI: 14, none: 30 };
const ROW_X: Record<string, number> = { LD: 85, LE: 15 };

/** Posicionamento inicial automático por grupo; nunca muda a equipe nem a posição oficial. */
export function autoPositions(members: CompMember[], keep: Positions = {}): Positions {
  const out: Positions = {};
  for (const team of ['A', 'B'] as Team[]) {
    const byRow = new Map<string, CompMember[]>();
    for (const m of members.filter((x) => x.team === team && !keep[x.pid])) {
      const g = m.group || groupKey(m.position);
      byRow.set(g, [...(byRow.get(g) ?? []), m]);
    }
    for (const [g, ms] of byRow) {
      const yA = ROW_Y[g] ?? 70;
      ms.sort((a, b) => a.name.localeCompare(b.name, 'pt-BR')).forEach((m, i) => {
        const x = ROW_X[g] ?? Math.min(95, Math.max(5, Math.round(((i + 1) * 100) / (ms.length + 1)) + (ms.length === 1 ? (ROW_SHIFT[g] ?? 0) : 0)));
        const yOffset = ROW_X[g] && ms.length > 1 ? i * 6 : 0;
        out[m.pid] = { x, y: team === 'A' ? yA - yOffset : 100 - yA + yOffset };
      });
    }
  }
  // Afasta quem ficou sobreposto (só os automáticos; posições editadas pelo administrador ficam como estão).
  for (let pass = 0; pass < 20; pass++) {
    const pairs = overlaps(out);
    if (!pairs.length) break;
    for (const [a, b] of pairs) {
      const pa = out[a];
      const pb = out[b];
      const dir = pa.x <= pb.x ? -1 : 1;
      out[a] = { x: Math.min(97, Math.max(3, pa.x + dir * 4)), y: pa.y };
      out[b] = { x: Math.min(97, Math.max(3, pb.x - dir * 4)), y: pb.y };
    }
  }
  return { ...out, ...keep };
}

export const isOutside = (p: Point) => p.x < 0 || p.x > 100 || p.y < 0 || p.y > 100;

/** Pares que se sobrepõem a ponto de atrapalhar a leitura (indicação discreta, nunca bloqueia). */
export function overlaps(pos: Positions, minDist = 9): [string, string][] {
  const ks = Object.keys(pos).sort();
  const out: [string, string][] = [];
  for (let i = 0; i < ks.length; i++)
    for (let j = i + 1; j < ks.length; j++) {
      const a = pos[ks[i]];
      const b = pos[ks[j]];
      if (Math.hypot(a.x - b.x, a.y - b.y) < minDist) out.push([ks[i], ks[j]]);
    }
  return out;
}

export const clampPoint = (p: Point): Point => ({ x: Math.min(115, Math.max(-15, Math.round(p.x))), y: Math.min(115, Math.max(-15, Math.round(p.y))) });

// ---------------------------------------------------------------------------------------------------------------
// Rede (REV-20/40): operação com request_id; se a resposta se perder, consulta o resultado real em vez de repetir.
export type RpcResult<T> = { data: T | null; error: { message: string } | null };
export const isNetworkError = (m?: string | null) => !!m && /Failed to fetch|Network request failed|NetworkError|timeout|ETIMEDOUT|aborted/i.test(m);

export async function idempotent<T>(
  call: () => Promise<RpcResult<T>>,
  lookup: () => Promise<RpcResult<{ found: boolean; result?: T }>>,
  attempts = 3,
): Promise<RpcResult<T>> {
  let last: RpcResult<T> = { data: null, error: { message: 'Network request failed' } };
  for (let i = 0; i < attempts; i++) {
    if (i > 0) {
      const l = await lookup();
      if (!l.error && l.data?.found) return { data: (l.data.result ?? null) as T, error: null };
    }
    last = await call(); // repetir com o MESMO request_id é seguro: o servidor devolve o resultado gravado
    if (!last.error || !isNetworkError(last.error.message)) return last;
  }
  return last;
}

/** Gate contra respostas obsoletas: só a última requisição de uma chave pode aplicar o resultado. */
export function createGate() {
  const seq = new Map<string, number>();
  return {
    next(key: string) {
      const n = (seq.get(key) ?? 0) + 1;
      seq.set(key, n);
      return () => seq.get(key) === n;
    },
  };
}

// ---------------------------------------------------------------------------------------------------------------
// Partidas (Etapas 8/22): rótulos de status, pendência e próxima ação.
export const MATCH_STATUS: Record<string, string> = {
  draft: 'Rascunho',
  voting_open: 'Votação aberta',
  finalizing: 'Apurando',
  finalized: 'Publicada',
  annulled: 'Anulada',
  cancelled: 'Cancelada',
};
export const MATCH_PENDING: Record<string, string> = {
  SCHEDULED: 'Agendada',
  REVIEW_PLANNED: 'Revisar escalação prevista',
  CONFIRM_PARTICIPATION: 'Confirmar quem jogou',
  FINISH_SHEET: 'Súmula pendente',
  VOTING: 'Votação em andamento',
};
export const NEXT_ACTION: Record<string, string> = {
  EDIT_PLANNED: 'Ajustar escalação',
  CONFIRM_PARTICIPATION: 'Confirmar quem jogou',
  RESUME_SHEET: 'Continuar súmula',
  VIEW: 'Ver partida',
};
export const REVIEW_CODE: Record<string, string> = {
  MATCH_NOT_DRAFT: 'A partida já foi publicada.',
  TEAMS_INCOMPLETE: 'Os dois times precisam de jogadores.',
  MATCH_IN_FUTURE: 'A data da partida ainda não chegou.',
  PARTICIPATION_NOT_CONFIRMED: 'Confirme quem realmente jogou.',
  PARTICIPANT_INELIGIBLE: 'Há jogador que não faz mais parte da pelada.',
  UNATTRIBUTED_GOALS: 'Há gols sem autor (não contam para ninguém).',
  NO_ASSISTS: 'Nenhuma assistência registrada.',
  TEAM_SIZES_DIFFER: 'Os times têm tamanhos diferentes.',
};
