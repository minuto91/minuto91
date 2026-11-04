-- Minuto 91 / 083 (V10.0, REV-138): o servidor recusa PUBLICAR a súmula com gol sem autor (decisão do fundador, 04/11/2026).
-- Gatilho na saída de 'draft' (vale para qualquer versão de publish_match): gol sem autor ou gol contra sem o jogador
-- adversário responsável => GOAL_AUTHOR_REQUIRED. Só publicação; correções de partidas já publicadas e anulação não mudam.
-- Rollback: drop trigger matches_goal_authors on public.matches; drop function private.require_goal_authors();
create or replace function private.require_goal_authors() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if old.status = 'draft' and new.status <> 'draft' and new.status not in ('cancelled','annulled') then
  if exists(select 1 from public.match_events where match_id = new.id
    and (event_type = 'unattributed_goal' or (event_type = 'own_goal' and participant_id is null))) then
   raise exception 'GOAL_AUTHOR_REQUIRED';
  end if;
 end if;
 return new;
end $$;
revoke all on function private.require_goal_authors() from public, anon, authenticated;
create trigger matches_goal_authors before update of status on public.matches
 for each row execute function private.require_goal_authors();
