-- SÓ NO SUPABASE DEV. Cria 5 jogadores de teste ("Bot 1" a "Bot 5") na Pelada Teste, para
-- testar a votação (mínimo de 6 eleitores) sem precisar de 5 contas reais.
-- Os bots NÃO têm senha: ninguém consegue entrar com eles. Votam pelo script 02.
-- Pode rodar mais de uma vez (não duplica). Para apagar: 99_apagar_bots.sql.
do $$
declare
  v_pid constant uuid := '55a69aba-465e-4241-8638-19cfb7675d16'; -- Pelada Teste
  v_admin uuid;
  v_tok text;
  v_uid uuid;
  pos text[] := array['goalkeeper','defender','midfielder','attacker','defender'];
begin
  select user_id into v_admin from public.pelada_memberships
  where pelada_id=v_pid and role='admin' and status='active';
  if v_admin is null then raise exception 'Pelada Teste não encontrada ou sem administrador'; end if;

  -- Convite gerado como o administrador.
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('role', 'authenticated', true);
  v_tok := public.create_pelada_invite(v_pid, 24, 10);
  execute 'reset role';

  for i in 1..5 loop
    v_uid := ('b0750000-0000-4000-8000-00000000000' || i)::uuid;
    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
    values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'bot' || i || '@minuto91.invalid', '', now(), now(), now())
    on conflict (id) do nothing;

    perform set_config('request.jwt.claim.sub', v_uid::text, true);
    perform set_config('role', 'authenticated', true);
    perform public.complete_onboarding('Bot ' || i, true, true);
    if not exists (select 1 from public.pelada_memberships where pelada_id=v_pid and user_id=v_uid and status='active') then
      perform public.join_pelada(v_tok, pos[i]);
    end if;
    execute 'reset role';
  end loop;
end $$;

-- Confere: devem aparecer Rafa e Bot 1..5.
select player_name, role, preferred_position
from public.pelada_memberships
where pelada_id='55a69aba-465e-4241-8638-19cfb7675d16' and status='active'
order by joined_at;
