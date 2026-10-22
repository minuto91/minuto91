// Minuto 91: webhook do RevenueCat (Doc 04 sec. 28). Recebe os eventos da loja e chama
// apply_subscription_event (019) com a chave secreta do projeto, que só existe aqui (nunca no app).
// - Autenticação: o RevenueCat manda no header Authorization o valor configurado no painel dele;
//   comparamos com o secret REVENUECAT_WEBHOOK_AUTH.
// - Ambiente: se o secret REVENUECAT_ENVIRONMENT existir (PRODUCTION ou SANDBOX), eventos do outro
//   ambiente são aceitos (200) mas não aplicados.
// - Idempotência: o banco ignora event.id já aplicado ou rejeitado; erro do banco devolve 500 para o RevenueCat
//   tentar de novo e grava o evento como "recebido" (036), que o agendador reprocessa.
// - O banco também confere produto (private.app_config premium_product_ids) e ambiente (store_environment).
// - Usuário: o app compra com appUserID = id do usuário (uuid). Se o app_user_id não for uuid (usuário
//   anônimo do RevenueCat), usamos o primeiro uuid de original_app_user_id ou aliases.
import { createClient } from 'npm:@supabase/supabase-js@2';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type RcEvent = {
  id?: string;
  type?: string;
  app_user_id?: string;
  original_app_user_id?: string;
  aliases?: string[];
  product_id?: string;
  expiration_at_ms?: number | null;
  original_transaction_id?: string;
  environment?: string;
};

// Comparação em tempo constante para não vazar o segredo pelo tempo de resposta.
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

function buyerId(e: RcEvent) {
  return [e.app_user_id, e.original_app_user_id, ...(e.aliases ?? [])].find((v) => v && UUID.test(v)) ?? e.app_user_id;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });

  const expected = Deno.env.get('REVENUECAT_WEBHOOK_AUTH');
  if (!expected || !sameSecret(req.headers.get('Authorization') ?? '', expected)) {
    return new Response('unauthorized', { status: 401 });
  }

  let event: RcEvent;
  try {
    event = (await req.json()).event;
  } catch {
    return new Response('invalid json', { status: 400 });
  }
  if (!event?.id || !event?.type) return new Response('invalid event', { status: 400 });

  const env = Deno.env.get('REVENUECAT_ENVIRONMENT');
  if (env && event.environment && event.environment !== env) {
    return Response.json({ result: 'ignored_environment' });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey(), {
    auth: { persistSession: false },
  });
  const { data, error } = await supabase.rpc('apply_subscription_event', {
    // O evento inteiro fica guardado (private.subscription_events); só o comprador é normalizado.
    p_event: { ...event, app_user_id: buyerId(event) },
  });
  if (error) {
    console.error('apply_subscription_event', event.id, event.type, error.message);
    // A05 (036): o evento fica registrado como "recebido" e o agendador tenta de novo, mesmo que a loja desista.
    await supabase.rpc('record_store_event_failure', { p_event: { ...event, app_user_id: buyerId(event) }, p_error: error.message });
    return new Response('error', { status: 500 });
  }
  return Response.json({ result: data });
});
