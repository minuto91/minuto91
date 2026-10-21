-- SÓ NO SUPABASE DEV. Tira os 5 bots da Pelada Teste e apaga as contas deles.
-- O histórico esportivo fica sem identidade (como numa exclusão de conta).
update public.pelada_memberships set status='left', role='player', assistant_since=null
where user_id::text like 'b0750000-0000-4000-8000-%' and role<>'admin';
delete from auth.users where id::text like 'b0750000-0000-4000-8000-%';
