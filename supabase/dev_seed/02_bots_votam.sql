-- SÓ NO SUPABASE DEV. Os 5 bots conferem a súmula (versão atual) e votam na votação aberta
-- da Pelada Teste. Notas de 6,0 a 9,0; Craque = o administrador; Bola Murcha = um colega.
-- Se todos já votaram (inclusive o administrador), a votação fecha e o resultado sai na hora.
do $$
declare
  v_pid constant uuid := '55a69aba-465e-4241-8638-19cfb7675d16'; -- Pelada Teste
  v_s record;
  v_ver integer;
  v_uid uuid;
  v_mem uuid;
  v_scores jsonb;
  v_craque uuid;
  v_bola uuid;
  r jsonb;
begin
  select id, match_id, bola_murcha_required into v_s from public.voting_sessions
  where pelada_id=v_pid and status='open' order by created_at desc limit 1;
  if not found then raise exception 'Nenhuma votação aberta na Pelada Teste'; end if;
  select sheet_version into v_ver from public.matches where id=v_s.match_id;
  select e.membership_id into v_craque from public.voting_eligible_members e
  join public.pelada_memberships m on m.id=e.membership_id
  where e.session_id=v_s.id and m.role='admin';

  for i in 1..5 loop
    v_uid := ('b0750000-0000-4000-8000-00000000000' || i)::uuid;
    select e.membership_id into v_mem from public.voting_eligible_members e
    join public.pelada_memberships m on m.id=e.membership_id
    where e.session_id=v_s.id and m.user_id=v_uid;
    continue when v_mem is null; -- bot fora desta súmula

    select jsonb_agg(jsonb_build_object('membership_id', e.membership_id,
             'rating', 6 + (abs(hashtext(e.membership_id::text || i)) % 7) * 0.5))
    into v_scores
    from public.voting_eligible_members e
    where e.session_id=v_s.id and e.membership_id<>v_mem;

    select e.membership_id into v_bola from public.voting_eligible_members e
    join public.pelada_memberships m on m.id=e.membership_id
    where e.session_id=v_s.id and m.role<>'admin' and e.membership_id<>v_mem
    order by m.player_name limit 1;

    perform set_config('request.jwt.claim.sub', v_uid::text, true);
    perform set_config('role', 'authenticated', true);
    perform public.confirm_match_sheet(v_s.match_id, v_ver);
    r := public.submit_ballot(v_s.id, v_ver, v_scores,
           case when v_craque=v_mem then v_bola else v_craque end,
           case when v_s.bola_murcha_required then v_bola end,
           'bot-' || v_s.id || '-' || i || '-v' || v_ver);
    execute 'reset role';
    raise notice 'Bot % votou: %', i, r;
  end loop;
end $$;

-- Confere: quantos votaram e se a votação fechou.
select s.status, s.is_valid, s.eligible_voter_count,
       (select count(*) from public.vote_receipts v where v.session_id=s.id) as votos
from public.voting_sessions s
where s.pelada_id='55a69aba-465e-4241-8638-19cfb7675d16'
order by s.created_at desc limit 1;
