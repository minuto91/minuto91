-- Minuto 91 / 079 (V10.0, REV-137): a partida nasce com os nomes e as cores dos times cadastrados na criação da pelada.
-- Antes o rascunho ficava "Time A"/"Time B" e sem cor. O gatilho cobre todos os caminhos que criam ou renomeiam a partida
-- (create_match, sorteio, update_match_draft). Só preenche quando a pelada tem nome/cor cadastrados; sem cadastro, nada muda
-- (fallback "Time A"/"Time B", sem cor oficial inventada). Partidas já existentes não são alteradas (o gatilho só atua em
-- INSERT e em mudança de nome). Cores só são preenchidas se a partida ainda não tem nenhuma.
-- Rollback: drop trigger matches_team_defaults on public.matches; drop function private.apply_match_team_defaults();
create or replace function private.apply_match_team_defaults() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p public.peladas;
begin
 select * into p from public.peladas where id = new.pelada_id;
 if not found then return new; end if;
 if new.team_a_name = 'Time A' and p.default_team_a_name is not null then new.team_a_name := p.default_team_a_name; end if;
 if new.team_b_name = 'Time B' and p.default_team_b_name is not null then new.team_b_name := p.default_team_b_name; end if;
 if tg_op = 'INSERT' and new.team_a_color is null and new.team_b_color is null
    and p.default_team_a_color is not null and p.default_team_b_color is not null then
  new.team_a_color := p.default_team_a_color; new.team_b_color := p.default_team_b_color;
 end if;
 return new;
end $$;
revoke all on function private.apply_match_team_defaults() from public, anon, authenticated;

create trigger matches_team_defaults before insert or update of team_a_name, team_b_name on public.matches
 for each row execute function private.apply_match_team_defaults();
