// V8.4 — E14: leituras e confirmações do feed de notificações (060). Nada é marcado como lido sem o servidor confirmar.
import type { Notif } from './notifs';
import { supabase } from './supabase';

type Page = { items: Notif[]; next: unknown };

export async function loadNotificationsPage(after: unknown): Promise<{ data: Page | null; empty?: boolean }> {
  const { data, error } = await supabase.rpc('get_my_notifications', { p_after: after ?? null, p_limit: 30 });
  if (error) throw error;
  const page = data as Page;
  return after === null && page.items.length === 0 ? { data: null, empty: true } : { data: page };
}

/** Devolve o instante de leitura confirmado pelo servidor (idempotente). */
export async function markNotificationRead(id: string): Promise<string> {
  const { data, error } = await supabase.rpc('mark_notification_read', { p_id: id });
  if (error) throw error;
  return (data as { read_at: string }).read_at;
}

export async function markAllNotificationsRead(): Promise<string> {
  const { error } = await supabase.rpc('mark_all_notifications_read');
  if (error) throw error;
  return new Date().toISOString();
}
