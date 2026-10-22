// Minuto 91: envio de push (Expo) a partir da fila notification_events (022 + 035).
// Chamada pelo agendador (pg_cron + pg_net, a cada minuto; ver supabase/deploy/push_sender_cron.sql).
// - Autenticação: header x-push-secret igual ao secret PUSH_SENDER_SECRET (deploy com "Verify JWT" desligado).
// - Usa a chave secreta do projeto só aqui (nunca no app).
// - Fluxo: claim_notifications -> Expo /push/send -> complete_notifications (aceito, tentar de novo ou falha);
//   depois recibos: claim_push_receipts -> Expo /push/getReceipts -> record_push_receipts.
// - "sent" quer dizer que o Expo ACEITOU a mensagem. A entrega à Apple/Google aparece nos recibos;
//   a chegada ao aparelho não é garantida por ninguém (aparelho desligado, modo foco etc.).
// - EXPO_ACCESS_TOKEN (opcional): exigido se o "push security" estiver ligado na conta Expo.
import { createClient } from 'npm:@supabase/supabase-js@2';

import { buildMessages, chunk, outcomeFor, receiptFor } from './logic.ts';
import type { Claimed, ExpoMessage, Outcome, Ticket } from './logic.ts';

const EXPO = 'https://exp.host/--/api/v2/push';
const MAX_ROUNDS = 5; // até 5 x 100 notificações por chamada

function sameSecret(a: string, b: string) {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

function serviceKey() {
  const keys = Deno.env.get('SUPABASE_SECRET_KEYS');
  if (keys) return JSON.parse(keys)['default'] as string;
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
}

async function expo(path: string, body: unknown) {
  const token = Deno.env.get('EXPO_ACCESS_TOKEN');
  return await fetch(`${EXPO}/${path}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      accept: 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
}

Deno.serve(async (req) => {
  const secret = Deno.env.get('PUSH_SENDER_SECRET');
  if (!secret || !sameSecret(req.headers.get('x-push-secret') ?? '', secret)) return new Response('unauthorized', { status: 401 });

  const db = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey(), { auth: { persistSession: false } });
  const report = { claimed: 0, accepted: 0, retry: 0, failed: 0, receipts: 0 };
  const names = new Map<string, string>();

  for (let round = 0; round < MAX_ROUNDS; round++) {
    const { data, error } = await db.rpc('claim_notifications', { p_limit: 100 });
    if (error) return new Response(`claim: ${error.message}`, { status: 500 });
    const batch = (data ?? []) as Claimed[];
    if (!batch.length) break;
    report.claimed += batch.length;

    const missing = [...new Set(batch.map((n) => n.pelada_id).filter((p): p is string => !!p && !names.has(p)))];
    if (missing.length) {
      const { data: ps } = await db.from('peladas').select('id, name').in('id', missing);
      for (const p of ps ?? []) names.set(p.id as string, p.name as string);
    }

    const outcomes: Outcome[] = [];
    const items = batch.map((n) => ({ n, messages: buildMessages(n, n.pelada_id ? (names.get(n.pelada_id) ?? null) : null) }));
    for (const it of items) if (!it.messages.length) outcomes.push({ id: it.n.id, outcome: 'failed', error: 'NO_TEMPLATE' });

    // O Expo aceita até 100 mensagens por pedido; uma notificação pode ter vários aparelhos.
    const flat: { id: string; msg: ExpoMessage }[] = items.flatMap((it) => it.messages.map((msg) => ({ id: it.n.id, msg })));
    const ticketsOf = new Map<string, Ticket[]>();
    const failedRequest = new Map<string, string>();
    for (const part of chunk(flat, 100)) {
      try {
        const res = await expo('send', part.map((p) => p.msg));
        const body = await res.json().catch(() => null);
        if (!res.ok || !Array.isArray(body?.data)) {
          const err = `HTTP ${res.status}${body?.errors?.[0]?.code ? ` ${body.errors[0].code}` : ''}`;
          part.forEach((p) => failedRequest.set(p.id, err));
          continue;
        }
        part.forEach((p, i) => ticketsOf.set(p.id, [...(ticketsOf.get(p.id) ?? []), body.data[i] as Ticket]));
      } catch (e) {
        part.forEach((p) => failedRequest.set(p.id, `NETWORK ${(e as Error).message}`.slice(0, 200)));
      }
    }
    for (const it of items) {
      if (!it.messages.length) continue;
      const err = failedRequest.get(it.n.id);
      // Pedido inteiro falhou (rede, 429, 5xx): tenta de novo mais tarde, com espera crescente (035).
      outcomes.push(err ? { id: it.n.id, outcome: 'retry', error: err } : outcomeFor(it.n.id, it.messages, ticketsOf.get(it.n.id) ?? []));
    }
    const { error: e2 } = await db.rpc('complete_notifications', { p_results: outcomes });
    if (e2) return new Response(`complete: ${e2.message}`, { status: 500 }); // as reservas vencem em 5 min e voltam
    for (const o of outcomes) report[o.outcome]++;
    if (batch.length < 100) break;
  }

  // Recibos (entrega à Apple/Google), 15 minutos depois do aceite.
  const { data: rs } = await db.rpc('claim_push_receipts', { p_limit: 300 });
  const pending = (rs ?? []) as { id: string; tickets: { token: string; ticket_id: string }[]; sent_at: string }[];
  if (pending.length) {
    const receipts: Record<string, Ticket> = {};
    for (const ids of chunk(pending.flatMap((p) => p.tickets.map((t) => t.ticket_id)), 1000)) {
      try {
        const res = await expo('getReceipts', { ids });
        const body = await res.json().catch(() => null);
        if (res.ok && body?.data) Object.assign(receipts, body.data);
      } catch {
        // sem rede: tenta na próxima chamada
      }
    }
    const results = pending.map((p) => receiptFor(p.id, p.tickets, receipts, p.sent_at)).filter((r) => r !== undefined);
    if (results.length) {
      await db.rpc('record_push_receipts', { p_results: results });
      report.receipts = results.length;
    }
  }

  return new Response(JSON.stringify(report), { headers: { 'content-type': 'application/json' } });
});
