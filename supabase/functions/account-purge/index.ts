// Minuto 91 / V7.7 (055): última etapa da exclusão de conta quando o banco não consegue apagar auth.users.
// private.purge_account já apagou os dados pessoais e anonimizou as participações (checkpoints 'votes' e
// 'personal'); a solicitação fica 'pending' com error_code AUTH_DELETE_FAILED. Esta função apaga o login pela
// API administrativa do Supabase Auth e só então chama complete_account_purge_auth, que confere e conclui.
// - Chamada pelo agendador (Supabase Cron → Edge Function, ex.: a cada hora) com o header Authorization igual ao
//   secret ACCOUNT_PURGE_AUTH. JWT desligado, como no storage-cleanup.
// - Não registra nem devolve e-mail ou nome: só ids de solicitação e contagens.
import { createClient } from 'npm:@supabase/supabase-js@2';

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

Deno.serve(async (req) => {
  const secret = Deno.env.get('ACCOUNT_PURGE_AUTH');
  if (!secret || !sameSecret(req.headers.get('Authorization') ?? '', secret)) return new Response('forbidden', { status: 403 });
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey(), { auth: { persistSession: false } });
  const { data, error } = await supabase.rpc('list_pending_auth_purges', { p_limit: 20 });
  if (error) return Response.json({ ok: false, error: 'LIST_FAILED' }, { status: 500 });
  let done = 0;
  const failed: string[] = [];
  for (const r of (data ?? []) as { request_id: string; user_id: string }[]) {
    const del = await supabase.auth.admin.deleteUser(r.user_id);
    // Já apagado antes (retry depois de uma resposta perdida) também conclui.
    if (del.error && del.error.status !== 404) {
      failed.push(r.request_id);
      continue;
    }
    const fin = await supabase.rpc('complete_account_purge_auth', { p_request: r.request_id });
    if (fin.error) failed.push(r.request_id);
    else done++;
  }
  return Response.json({ ok: failed.length === 0, completed: done, failed });
});
