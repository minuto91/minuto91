// V8.4 — E14: regras de exibição do feed de notificações (puras, testadas em tests/v84.test.ts).
// Os textos nunca trazem autoria de voto nem valores financeiros (esses dados nem chegam ao feed).

export type Notif = {
  id: string;
  event_type: string;
  pelada_id: string | null;
  pelada_name: string | null;
  created_at: string;
  read_at: string | null;
  payload: { pelada_id?: string; match_id?: string; award_type?: string; period_month?: string };
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (v: unknown): v is string => typeof v === 'string' && UUID_RE.test(v);

export function notifText(n: Pick<Notif, 'event_type' | 'pelada_name'>): { title: string; body: string } {
  const where = n.pelada_name ? ` em ${n.pelada_name}` : '';
  switch (n.event_type) {
    case 'voting_opened':
      return { title: 'Votação aberta', body: `A súmula foi publicada${where}. Avalie os colegas.` };
    case 'voting_restarted':
      return { title: 'Votação reiniciada', body: `A votação${where} recomeçou.` };
    case 'sheet_corrected':
      return { title: 'Súmula corrigida', body: `A súmula${where} foi corrigida.` };
    case 'voting_closing_soon':
      return { title: 'A votação está terminando', body: `Se ainda não votou${where}, confira o prazo.` };
    case 'result_published':
      return { title: 'Resultado publicado', body: `O resultado${where} já está disponível.` };
    case 'match_annulled':
      return { title: 'Partida anulada', body: `Uma partida${where} foi anulada.` };
    case 'admin_succession':
      return { title: 'Mudança na administração', body: `Houve mudança na administração${where}.` };
    case 'role_changed':
    case 'successor_designated':
      return { title: 'Seu papel mudou', body: `Seu papel${where} foi atualizado.` };
    case 'subscription_changed':
      return { title: 'Assinatura atualizada', body: `A assinatura${where} mudou.` };
    case 'sticker_unlocked':
      return { title: 'Nova figurinha', body: 'Você desbloqueou uma figurinha.' };
    case 'season_review':
      return { title: 'Retrospectiva pronta', body: `A retrospectiva${where} está disponível.` };
    case 'account_transferred':
      return { title: 'Histórico transferido', body: 'O histórico desta conta foi transferido.' };
    default:
      return n.event_type.startsWith('award_')
        ? { title: 'Nova conquista', body: `Você recebeu um prêmio${where}.` }
        : { title: 'Novo aviso', body: n.pelada_name ? `Aviso de ${n.pelada_name}.` : 'Você tem um aviso.' };
  }
}

/**
 * Caminho do destino (E15-06/23/32): só com IDs válidos; sem ID válido não há destino e o aviso abre sem link.
 * Quem decide o acesso é o destino (RLS), nunca o link (E15-30).
 */
export function notifPath(n: Pick<Notif, 'event_type' | 'pelada_id' | 'payload'>): string | null {
  const pelada = isUuid(n.pelada_id) ? n.pelada_id : isUuid(n.payload.pelada_id) ? n.payload.pelada_id : null;
  const match = isUuid(n.payload.match_id) ? n.payload.match_id : null;
  switch (n.event_type) {
    case 'voting_opened':
    case 'voting_restarted':
    case 'sheet_corrected':
    case 'voting_closing_soon':
    case 'result_published':
    case 'match_annulled':
      return match ? `/partida/${match}` : null;
    case 'admin_succession':
    case 'role_changed':
    case 'successor_designated':
    case 'subscription_changed':
      return pelada ? `/pelada/${pelada}` : null;
    case 'sticker_unlocked':
      return '/album';
    case 'season_review':
      return pelada ? `/pelada/${pelada}/retrospectiva` : null;
    case 'account_transferred':
      return '/conta';
    default:
      if (n.event_type.startsWith('award_')) return match ? `/partida/${match}` : pelada ? `/pelada/${pelada}` : null;
      return null;
  }
}

export type NotifGroupKey = 'today' | 'yesterday' | 'week' | 'older';
export const GROUP_LABEL: Record<NotifGroupKey, string> = { today: 'Hoje', yesterday: 'Ontem', week: 'Esta semana', older: 'Anteriores' };

const dayStart = (t: number) => {
  const d = new Date(t);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
};

/** Hoje / Ontem / Esta semana (últimos 7 dias corridos) / Anteriores, no fuso do aparelho. */
export function groupOf(createdAt: string, now: number): NotifGroupKey {
  const diff = Math.round((dayStart(now) - dayStart(new Date(createdAt).getTime())) / 86_400_000);
  return diff <= 0 ? 'today' : diff === 1 ? 'yesterday' : diff < 7 ? 'week' : 'older';
}

export function groupNotifs(items: Notif[], now: number) {
  const order: NotifGroupKey[] = ['today', 'yesterday', 'week', 'older'];
  return order
    .map((key) => ({ key, label: GROUP_LABEL[key], items: items.filter((n) => groupOf(n.created_at, now) === key) }))
    .filter((g) => g.items.length > 0);
}

/** Junta a próxima página sem repetir avisos (toque duplo em "carregar mais", resposta repetida). */
export function mergePage(current: Notif[], page: Notif[]): Notif[] {
  const seen = new Set(current.map((n) => n.id));
  return [...current, ...page.filter((n) => !seen.has(n.id))];
}

export const markRead = (items: Notif[], id: string, readAt: string): Notif[] =>
  items.map((n) => (n.id === id && !n.read_at ? { ...n, read_at: readAt } : n));
export const markAllRead = (items: Notif[], readAt: string): Notif[] => items.map((n) => (n.read_at ? n : { ...n, read_at: readAt }));

const WEEKDAY = ['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb'];
const two = (n: number) => String(n).padStart(2, '0');

/** Rótulo curto de hora/data de cada aviso (já agrupado por dia): hora, 'ontem', dia da semana ou dd/mm. */
export function whenLabel(createdAt: string, now: number): string {
  const d = new Date(createdAt);
  const g = groupOf(createdAt, now);
  if (g === 'today') return `${two(d.getHours())}:${two(d.getMinutes())}`;
  if (g === 'yesterday') return 'ontem';
  if (g === 'week') return WEEKDAY[d.getDay()];
  return `${two(d.getDate())}/${two(d.getMonth() + 1)}`;
}
