// Minuto 91 / push-sender: regras puras (sem rede, sem Deno), testadas em supabase/local_db/push_logic.test.mjs.
// Textos curtos, sem dados sensíveis: nunca notas, votos ou nomes de outros jogadores. O nome da pelada
// aparece porque o destinatário é membro dela (o banco confere isso na hora do envio, migração 035).

export type Claimed = {
  id: string;
  user_id: string;
  pelada_id: string | null;
  event_type: string;
  payload: Record<string, unknown>;
  tokens: string[];
  attempt: number;
};

export type ExpoMessage = {
  to: string;
  title: string;
  body: string;
  data: { path: string; notification_id: string };
  sound: 'default';
  priority: 'high' | 'default';
  channelId: 'default';
};

export type Ticket = { status: 'ok'; id: string } | { status: 'error'; message?: string; details?: { error?: string } };

export type Outcome = {
  id: string;
  outcome: 'accepted' | 'retry' | 'failed';
  error?: string;
  tickets?: { token: string; ticket_id: string }[];
  invalid_tokens?: string[];
};

const AWARD: Record<string, string> = {
  match_craque: 'Você foi o Craque da Partida',
  monthly_king: 'Você é o Rei do Mês',
  top_scorer: 'Você é o Artilheiro do mês',
  top_assist: 'Você é o Garçom do mês',
  match_garcom: 'Você foi o Garçom da Partida',
  monthly_garcom: 'Você é o Garçom do Mês',
  most_improved: 'Você teve a Maior evolução do mês',
};

const str = (v: unknown) => (typeof v === 'string' ? v : null);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const uuid = (v: unknown) => (typeof v === 'string' && UUID.test(v) ? v : null);

/** Título e texto do aviso. null = não há texto para esse tipo (não envia). */
export function texts(eventType: string, payload: Record<string, unknown>, peladaName: string | null): { title: string; body: string } | null {
  const p = peladaName ? `na ${peladaName}` : 'na sua pelada';
  const da = peladaName ? `da ${peladaName}` : 'da sua pelada';
  switch (eventType) {
    case 'voting_opened':
      return { title: 'Votação aberta', body: `A votação da partida ${p} começou. Dê suas notas.` };
    case 'voting_closing_soon':
      return { title: 'Falta 1 hora para votar', body: `A votação ${da} fecha em menos de 1 hora e ainda falta o seu voto.` };
    case 'sheet_corrected':
      return { title: 'Súmula corrigida', body: `A súmula da partida ${p} foi corrigida. Confira antes de votar.` };
    case 'voting_restarted':
      return { title: 'Votação reiniciada', body: `A votação ${da} recomeçou depois de uma correção. Vote de novo.` };
    case 'result_published':
      return { title: 'Resultado publicado', body: `Saiu o resultado da partida ${p}: notas, Craque e Cards atualizados.` };
    case 'match_annulled':
      return { title: 'Partida anulada', body: `Uma partida ${da} foi anulada. Os números foram recalculados.` };
    case 'admin_succession':
      return { title: 'Administração da pelada', body: `A administração ${da} mudou.` };
    case 'subscription_changed':
      return { title: 'Premium da pelada', body: `Houve uma mudança na assinatura ${da}.` };
    case 'account_transferred':
      return { title: 'Conta transferida', body: 'Seu histórico foi transferido para outra conta com o seu código.' };
    case 'role_changed':
      return payload.is_assistant === true
        ? { title: 'Nova função', body: `Você agora é assistente ${da}.` }
        : { title: 'Função alterada', body: `Você não é mais assistente ${da}.` };
    case 'successor_designated':
      return { title: 'Sucessor indicado', body: `Você foi indicado como sucessor do administrador ${da}.` };
    case 'sticker_unlocked':
      return { title: 'Figurinha nova', body: `Você liberou uma figurinha no álbum ${da}.` };
    case 'season_review':
      return { title: 'Temporada encerrada', body: `A temporada ${da} terminou. Veja a retrospectiva.` };
  }
  if (eventType.startsWith('award_')) {
    const t = AWARD[eventType.slice(6)];
    return t ? { title: 'Conquista', body: `${t} ${p}!` } : null; // Bola Murcha não tem texto (035: POLICY)
  }
  return null;
}

/** Tela que o toque abre. Só caminhos conhecidos; o app confere de novo antes de navegar. */
export function pathFor(eventType: string, payload: Record<string, unknown>, peladaId: string | null): string {
  const match = uuid(payload.match_id);
  const pelada = uuid(peladaId) ?? uuid(payload.pelada_id);
  if (eventType === 'account_transferred') return '/conta';
  if (eventType === 'season_review' && pelada) return `/pelada/${pelada}/retrospectiva`;
  if (eventType.startsWith('award_') && !match && pelada) return `/pelada/${pelada}/rankings`;
  if (match) return `/partida/${match}`;
  if (pelada) return `/pelada/${pelada}`;
  return '/';
}

export function buildMessages(n: Claimed, peladaName: string | null): ExpoMessage[] {
  const t = texts(n.event_type, n.payload ?? {}, peladaName);
  if (!t) return [];
  const essential = !n.event_type.startsWith('award_') && n.event_type !== 'sticker_unlocked' && n.event_type !== 'season_review';
  return n.tokens.map((to) => ({
    to,
    title: t.title,
    body: t.body,
    data: { path: pathFor(n.event_type, n.payload ?? {}, n.pelada_id), notification_id: n.id },
    sound: 'default',
    priority: essential ? 'high' : 'default',
    channelId: 'default',
  }));
}

const RETRYABLE = new Set(['MessageRateExceeded']);

/**
 * Junta os tickets de uma notificação (um por aparelho, na mesma ordem das mensagens).
 * Aceita se algum aparelho foi aceito pelo Expo (aceite não é entrega: a entrega vem nos recibos).
 */
export function outcomeFor(id: string, messages: ExpoMessage[], tickets: Ticket[]): Outcome {
  const ok: { token: string; ticket_id: string }[] = [];
  const invalid: string[] = [];
  const errors: string[] = [];
  messages.forEach((m, i) => {
    const t = tickets[i];
    if (!t) errors.push('NO_TICKET');
    else if (t.status === 'ok') ok.push({ token: m.to, ticket_id: t.id });
    else {
      const code = t.details?.error ?? t.message ?? 'UNKNOWN';
      if (code === 'DeviceNotRegistered') invalid.push(m.to);
      errors.push(code);
    }
  });
  const invalid_tokens = invalid.length ? invalid : undefined;
  if (ok.length) return { id, outcome: 'accepted', tickets: ok, invalid_tokens };
  if (errors.some((e) => RETRYABLE.has(e) || e === 'NO_TICKET')) return { id, outcome: 'retry', error: errors.join(', '), invalid_tokens };
  return { id, outcome: 'failed', error: errors.join(', ') || 'NO_MESSAGES', invalid_tokens };
}

/** Recibos de uma notificação. undefined = ainda não dá para concluir (recibo não chegou e tem menos de 24h). */
export function receiptFor(
  id: string,
  tickets: { token: string; ticket_id: string }[],
  receipts: Record<string, Ticket | undefined>,
  sentAt: string,
  now = Date.now(),
): { id: string; error: string | null; invalid_tokens?: string[] } | undefined {
  const old = now - new Date(sentAt).getTime() > 23 * 3600 * 1000;
  const errors: string[] = [];
  const invalid: string[] = [];
  let missing = false;
  for (const t of tickets) {
    const r = receipts[t.ticket_id];
    if (!r) missing = true;
    else if (r.status === 'error') {
      const code = r.details?.error ?? r.message ?? 'UNKNOWN';
      if (code === 'DeviceNotRegistered') invalid.push(t.token);
      errors.push(code);
    }
  }
  if (missing && !old) return undefined;
  if (missing) errors.push('RECEIPT_UNAVAILABLE');
  return { id, error: errors.length ? errors.join(', ') : null, invalid_tokens: invalid.length ? invalid : undefined };
}

export function chunk<T>(xs: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < xs.length; i += size) out.push(xs.slice(i, i + size));
  return out;
}
