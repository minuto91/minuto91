-- Minuto 91: agenda o envio de push (Edge Function push-sender) a cada minuto. NÃO é migração:
-- leva um segredo e o endereço do projeto. Rodar UMA vez no SQL Editor de cada projeto (dev e produção),
-- depois de publicar a função push-sender e de criar o secret PUSH_SENDER_SECRET nela.
-- Troque <REF_DO_PROJETO> (ex.: lqirpgqrnbsycuowwoie) e <MESMO_VALOR_DO_PUSH_SENDER_SECRET>.
-- Precisa das extensões pg_cron e pg_net (Database > Extensions).

-- 1. Guarda o segredo no Vault (criptografado), em vez de deixá-lo escrito no agendamento.
select vault.create_secret('<MESMO_VALOR_DO_PUSH_SENDER_SECRET>', 'push_sender_secret');

-- 2. Agenda a chamada.
select cron.schedule('minuto91-push', '* * * * *', $job$
 select net.http_post(
  url := 'https://<REF_DO_PROJETO>.supabase.co/functions/v1/push-sender',
  headers := jsonb_build_object('content-type','application/json',
   'x-push-secret', (select decrypted_secret from vault.decrypted_secrets where name='push_sender_secret')),
  body := '{}'::jsonb,
  timeout_milliseconds := 30000);
$job$);

-- Conferir: select * from cron.job where jobname='minuto91-push';
--           select status_code, content from net._http_response order by created desc limit 5;
-- Parar:    select cron.unschedule('minuto91-push');
