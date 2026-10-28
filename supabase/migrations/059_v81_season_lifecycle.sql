-- Minuto 91 / 059: V8.1 etapas 43, 44 e 45 (ciclo de vida da temporada).
--
-- 043  Suspensão formal (só admin, com motivo). Temporada suspensa continua em disputa: o calendário NÃO a encerra
--      e ela não é consolidada. Ausência de partidas é só informação (get_season_lifecycle); NUNCA encerra, suspende
--      ou premia sozinha.
-- 044  Cancelamento (só admin, com motivo). Nada é apagado: partidas, estatísticas, prêmios válidos e histórico ficam.
--      Temporada cancelada não é consolidada (sem retrospectiva/título sazonal).
-- 045  Reativação excepcional de temporada cancelada (só admin, com motivo): volta a 'normal', mesma linha (mesmo id,
--      nome, datas, partidas). Não concede nada automaticamente; consolidação segue as regras de sempre.
--
-- O motor de notas (050-052) e as datas/estado calculado (seasons.status) NÃO mudam: o ciclo de vida é uma coluna à parte.
-- Rollback: dropar as funções novas e a tabela, remover a coluna seasons.lifecycle e restaurar sync_season_status (006)
-- e season_consolidation (058).

alter table public.seasons
 add column lifecycle text not null default 'normal' check (lifecycle in ('normal','suspended','cancelled'));

create table private.season_lifecycle_events (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 season_id uuid not null references public.seasons(id),
 kind text not null check (kind in ('suspension','resumption','cancellation','reactivation')),
 reason text not null check (length(reason) between 3 and 300),
 actor_user_id uuid not null,
 occurred_at timestamptz not null default clock_timestamp()
);
create index idx_season_lifecycle_events on private.season_lifecycle_events(season_id, occurred_at);
revoke all on private.season_lifecycle_events from public, anon, authenticated;

-- Imutável: só INSERT.
create function private.season_lifecycle_events_immutable() returns trigger
language plpgsql set search_path = '' as $$
begin raise exception 'SEASON_LIFECYCLE_EVENTS_IMMUTABLE'; end $$;
create trigger season_lifecycle_events_immutable before update or delete on private.season_lifecycle_events
for each row execute function private.season_lifecycle_events_immutable();

-- O calendário não encerra temporada suspensa (continua em disputa). Demais regras idênticas à 006.
create or replace function private.sync_season_status(p_pelada uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_today date := private.pelada_today(p_pelada);
begin
 update public.seasons s set
  status = x.st,
  closed_at = case when x.st='closed' then coalesce(s.closed_at, now()) end
 from (select id, case when ends_on < v_today then 'closed'
                       when starts_on > v_today then 'planned' else 'active' end st
       from public.seasons where pelada_id=p_pelada and lifecycle <> 'suspended') x
 where s.id=x.id and s.status is distinct from x.st;
end $$;

-- Consolidação: suspensa ou cancelada nunca está pronta (mesmas condições da 058 para o resto).
create or replace function private.season_consolidation(p_season uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object(
  'calendar_closed', s.ends_on < private.pelada_today(s.pelada_id),
  'lifecycle', s.lifecycle,
  'pending_matches', (select count(*) from public.matches m where m.season_id=s.id and m.status in ('voting_open','finalizing')),
  'pending_votes', (select count(*) from public.rating_vote_sessions v join public.matches m on m.id=v.match_id
     where m.season_id=s.id and m.status='finalized' and v.status not in ('published','cancelled')),
  'ready', s.lifecycle='normal' and s.ends_on < private.pelada_today(s.pelada_id)
   and not exists(select 1 from public.matches m where m.season_id=s.id and m.status in ('voting_open','finalizing'))
   and not exists(select 1 from public.rating_vote_sessions v join public.matches m on m.id=v.match_id
     where m.season_id=s.id and m.status='finalized' and v.status not in ('published','cancelled')))
 from public.seasons s where s.id=p_season;
$$;

-- Núcleo: troca o estado exigindo o estado de origem, com a linha travada. Repetir a chamada falha (sem duplicar).
create function private.season_lifecycle_change(p_season uuid, p_kind text, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_s public.seasons; v_reason text := btrim(coalesce(p_reason,'')); v_from text; v_to text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_s from public.seasons where id=p_season for update;
 if not found or not private.is_active_member(v_s.pelada_id) then raise exception 'SEASON_NOT_FOUND'; end if;
 if not private.is_active_admin(v_s.pelada_id) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if length(v_reason) not between 3 and 300 then raise exception 'REASON_REQUIRED'; end if;
 select f, t into v_from, v_to from (values
  ('suspension','normal','suspended'), ('resumption','suspended','normal'),
  ('cancellation','normal','cancelled'), ('cancellation','suspended','cancelled'),
  ('reactivation','cancelled','normal')) x(k,f,t)
  where x.k=p_kind and x.f=v_s.lifecycle limit 1;
 if v_to is null then raise exception 'INVALID_SEASON_STATE'; end if;
 update public.seasons set lifecycle=v_to where id=p_season;
 insert into private.season_lifecycle_events(pelada_id,season_id,kind,reason,actor_user_id)
 values(v_s.pelada_id,p_season,p_kind,v_reason,auth.uid());
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_s.pelada_id,auth.uid(),'season_'||p_kind,jsonb_build_object('season_id',p_season,'from',v_from,'to',v_to,'reason',v_reason));
 -- recalcula o estado de calendário (suspensa que volta pode já ter passado do fim)
 perform private.sync_season_status(v_s.pelada_id);
end $$;

create function public.suspend_season(p_season uuid, p_reason text) returns void
language sql security definer set search_path = '' as $$ select private.season_lifecycle_change(p_season,'suspension',p_reason) $$;
create function public.resume_season(p_season uuid, p_reason text) returns void
language sql security definer set search_path = '' as $$ select private.season_lifecycle_change(p_season,'resumption',p_reason) $$;
create function public.cancel_season(p_season uuid, p_reason text) returns void
language sql security definer set search_path = '' as $$ select private.season_lifecycle_change(p_season,'cancellation',p_reason) $$;
create function public.reactivate_season(p_season uuid, p_reason text) returns void
language sql security definer set search_path = '' as $$ select private.season_lifecycle_change(p_season,'reactivation',p_reason) $$;

-- Estado + linha do tempo. Motivos e autores só para admin. last_match_at/days_since_last_match são só informação:
-- nenhuma regra usa esses números.
create function public.get_season_lifecycle(p_season uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_s public.seasons; v_admin boolean; v_last timestamptz;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_s from public.seasons where id=p_season;
 if not found or not private.is_active_member(v_s.pelada_id) then raise exception 'SEASON_NOT_FOUND'; end if;
 v_admin := private.is_active_admin(v_s.pelada_id);
 select max(played_at) into v_last from public.matches
  where season_id=p_season and status in ('finalized','voting_open','finalizing');
 return jsonb_build_object('season_id',p_season,'lifecycle',v_s.lifecycle,
  'last_match_at',v_last,
  'days_since_last_match', case when v_last is null then null
    else (private.pelada_today(v_s.pelada_id) - (v_last at time zone 'UTC')::date) end,
  'events', coalesce((select jsonb_agg(
     jsonb_build_object('kind',e.kind,'occurred_at',e.occurred_at)
     || case when v_admin then jsonb_build_object('reason',e.reason,'actor_user_id',e.actor_user_id) else '{}'::jsonb end
     order by e.occurred_at, e.id)
   from private.season_lifecycle_events e where e.season_id=p_season), '[]'::jsonb));
end $$;

revoke all on function private.season_lifecycle_change(uuid,text,text), private.season_lifecycle_events_immutable() from public, anon, authenticated;
revoke all on function public.suspend_season(uuid,text), public.resume_season(uuid,text), public.cancel_season(uuid,text),
 public.reactivate_season(uuid,text), public.get_season_lifecycle(uuid) from public, anon;
grant execute on function public.suspend_season(uuid,text), public.resume_season(uuid,text), public.cancel_season(uuid,text),
 public.reactivate_season(uuid,text), public.get_season_lifecycle(uuid) to authenticated;
