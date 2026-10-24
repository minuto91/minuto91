-- SÓ NO SUPABASE DEV. Apaga a massa de QA da V6.1 (10_qa_v61.sql): as peladas "QA Quinta" e "QA Resenha",
-- tudo o que pende delas e os usuários @qa.minuto91.invalid. Não toca em nenhum outro dado.
do $$
declare v_p uuid[]; v_t text; v_done int := 0; v_try int := 0;
begin
  select array_agg(p.id) into v_p from public.peladas p
  where p.name in ('QA Quinta','QA Resenha')
    and exists (select 1 from public.pelada_memberships m join auth.users u on u.id = m.user_id
                where m.pelada_id = p.id and u.email like '%@qa.minuto91.invalid');
  if v_p is null then raise notice 'Nada para apagar.'; else
    -- Apaga em ordem de dependência: repete enquanto alguma tabela ainda tiver linhas dessas peladas.
    loop
      v_try := v_try + 1; v_done := 0;
      for v_t in select c.table_name from information_schema.columns c
                 join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
                 where c.table_schema = 'public' and c.column_name = 'pelada_id' and t.table_type = 'BASE TABLE' loop
        begin
          execute format('delete from public.%I where pelada_id = any($1)', v_t) using v_p;
          v_done := v_done + 1;
        exception when foreign_key_violation or restrict_violation then null;
        end;
      end loop;
      begin delete from public.peladas where id = any(v_p); exit; exception when foreign_key_violation or restrict_violation then null; end;
      if v_try > 15 then raise exception 'Não consegui apagar as peladas de QA (dependência não prevista).'; end if;
    end loop;
  end if;
  delete from auth.users where email like '%@qa.minuto91.invalid';
end $$;
select count(*) as usuarios_qa_restantes from auth.users where email like '%@qa.minuto91.invalid';
