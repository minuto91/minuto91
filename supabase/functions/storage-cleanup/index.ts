// Minuto 91: limpeza de fotos órfãs do bucket privado "avatars" (migração 027, Doc 04 sec. 30.6).
// Apaga, pela Storage API (o Supabase não deixa apagar storage.objects por SQL), todo arquivo com mais
// de 1 hora que nenhum perfil usa: foto trocada, removida, moderada, conta apagada ou envio que falhou.
// - Chamada pelo agendador (Supabase Cron → Edge Function, ex.: a cada hora), com o header
//   Authorization igual ao secret STORAGE_CLEANUP_AUTH. JWT desligado, como no webhook do RevenueCat.
// - "Em uso" vem de avatar_paths_in_use (027), que só o service_role executa.
import { createClient } from 'npm:@supabase/supabase-js@2';

const BUCKET = 'avatars';
const MIN_AGE_MS = 60 * 60 * 1000;
const PAGE = 1000;

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
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!; // chave antiga, se o projeto ainda usar
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const expected = Deno.env.get('STORAGE_CLEANUP_AUTH');
  if (!expected || !sameSecret(req.headers.get('Authorization') ?? '', expected)) {
    return new Response('unauthorized', { status: 401 });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey(), { auth: { persistSession: false } });
  const storage = supabase.storage.from(BUCKET);
  const cutoff = Date.now() - MIN_AGE_MS;

  // Pastas = ids de usuários; arquivos = <id>/<uuid>.jpg.
  const candidates: string[] = [];
  for (let offset = 0; ; offset += PAGE) {
    const { data: folders, error } = await storage.list('', { limit: PAGE, offset });
    if (error) return new Response(`list: ${error.message}`, { status: 500 });
    for (const folder of folders ?? []) {
      const { data: files, error: e2 } = await storage.list(folder.name, { limit: PAGE });
      if (e2) return new Response(`list ${folder.name}: ${e2.message}`, { status: 500 });
      for (const f of files ?? []) {
        const created = Date.parse(f.created_at ?? '');
        if (f.id && Number.isFinite(created) && created < cutoff) candidates.push(`${folder.name}/${f.name}`);
      }
    }
    if ((folders ?? []).length < PAGE) break;
  }

  let removed = 0;
  for (let i = 0; i < candidates.length; i += 100) {
    const batch = candidates.slice(i, i + 100);
    const { data: inUse, error } = await supabase.rpc('avatar_paths_in_use', { p_paths: batch });
    if (error) return new Response(`in use: ${error.message}`, { status: 500 });
    const keep = new Set((inUse ?? []) as string[]);
    const orphans = batch.filter((p) => !keep.has(p));
    if (!orphans.length) continue;
    const { error: e3 } = await storage.remove(orphans);
    if (e3) return new Response(`remove: ${e3.message}`, { status: 500 });
    removed += orphans.length;
  }
  return Response.json({ checked: candidates.length, removed });
});
