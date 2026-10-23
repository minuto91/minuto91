-- Minuto 91 / 050: V5 (Prompt Master v2.0), dados que o motor de OVR precisa e o banco ainda não tinha.
--
-- 1. Cartões: além do vermelho, a súmula aceita 'yellow_card' e 'second_yellow' (expulsão por segundo
--    amarelo = UMA penalidade de vermelho; quem leva o segundo amarelo recebe só 'second_yellow', sem
--    os amarelos que o causaram).
-- 2. pelada_settings.cards_tracking (desligado por padrão): a pelada registra cartões? Desligado => DIS 70.
-- 3. matches.discipline_status: 'not_tracked' (pelada sem registro), 'confirmed' (súmula oficial vale
--    como registro disciplinar, inclusive "sem cartões") ou 'pending' (admin marcou como incompleto;
--    não conta como partida limpa). Decisão técnica: com o registro ligado, a publicação da súmula
--    confirma a disciplina; o admin pode marcar como pendente e confirmar depois.
-- 4. Defesas difíceis do goleiro (public.match_keeper_saves): uma linha = registro confirmado pelo admin
--    (0 é um valor; ausência de linha = sem registro, nunca zero).
-- 5. Posição principal: a primeira escolha continua do jogador; depois da primeira partida oficial a troca
--    exige o admin (pedido do jogador + aprovação, ou o admin direto). public.position_changes guarda
--    anterior, nova, data, versão e quem aprovou (usado na transição de 5 partidas).
-- Nada histórico é reescrito. Rollback: dropar as tabelas/colunas novas e recriar as funções da 041/009.

---------------------------------------------------------------------------------------------------
-- 1. Cartões na súmula
---------------------------------------------------------------------------------------------------
alter table public.match_events drop constraint match_events_event_type_check;
alter table public.match_events add constraint match_events_event_type_check check (event_type in
 ('goal','assist','own_goal','red_card','unattributed_goal','yellow_card','second_yellow'));
alter table public.match_events drop constraint event_participant_check;
alter table public.match_events add constraint event_participant_check check (case event_type
  when 'unattributed_goal' then participant_id is null
  when 'own_goal' then true
  else participant_id is not null end);

create or replace function private.write_match_sheet(p_m public.matches, p_participants jsonb, p_events jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e jsonb; v_mem uuid; v_guest uuid; v_team text; v_pos text; v_type text; v_qty int;
 v_part public.match_participants; v_id uuid; v_keep uuid[] := '{}'; v_a int; v_b int;
begin
 if jsonb_typeof(coalesce(p_participants,'[]')) <> 'array' or jsonb_typeof(coalesce(p_events,'[]')) <> 'array' then
  raise exception 'INVALID_SHEET'; end if;
 delete from public.match_events where match_id=p_m.id;

 begin
  for e in select * from jsonb_array_elements(coalesce(p_participants,'[]')) loop
   v_mem := (e->>'membership_id')::uuid; v_guest := (e->>'guest_id')::uuid; v_team := e->>'team';
   if (v_mem is null) = (v_guest is null) then raise exception 'INVALID_PARTICIPANT'; end if;
   if v_team is null or v_team not in ('A','B') then raise exception 'INVALID_TEAM'; end if;
   select id into v_id from public.match_participants
   where match_id=p_m.id and (membership_id=v_mem or guest_id=v_guest);
   if found and v_id = any(v_keep) then raise exception 'DUPLICATE_IN_SHEET'; end if;
   if v_guest is not null then
    if not exists(select 1 from public.guests where id=v_guest and pelada_id=p_m.pelada_id) then
     raise exception 'INVALID_PARTICIPANT'; end if;
    v_pos := e->>'position';
    if not private.valid_position(v_pos) then raise exception 'INVALID_POSITION'; end if;
   elsif v_id is null then
    select preferred_position into v_pos from public.pelada_memberships
    where id=v_mem and pelada_id=p_m.pelada_id and status='active';
    if not found then raise exception 'INVALID_PARTICIPANT'; end if;
   end if;
   if v_id is not null then
    update public.match_participants set team=v_team,
     primary_position=case when guest_id is not null then v_pos else primary_position end
    where id=v_id;
   else
    insert into public.match_participants(pelada_id,match_id,membership_id,guest_id,team,primary_position)
    values(p_m.pelada_id,p_m.id,v_mem,v_guest,v_team,v_pos) returning id into v_id;
   end if;
   v_keep := v_keep || v_id;
   v_id := null;
  end loop;
  delete from public.match_participants where match_id=p_m.id and not (id = any(v_keep));

  for e in select * from jsonb_array_elements(coalesce(p_events,'[]')) loop
   v_mem := (e->>'membership_id')::uuid; v_guest := (e->>'guest_id')::uuid;
   v_type := e->>'type'; v_qty := (e->>'quantity')::int; v_team := e->>'team';
   if v_type is null or v_type not in ('goal','assist','own_goal','red_card','unattributed_goal','yellow_card','second_yellow') then
    raise exception 'INVALID_EVENT'; end if;
   if v_qty is null or v_qty not between 1 and 99 then raise exception 'INVALID_EVENT'; end if;
   v_part := null;
   if v_mem is not null or v_guest is not null then
    if v_mem is not null and v_guest is not null then raise exception 'INVALID_EVENT'; end if;
    select * into v_part from public.match_participants where match_id=p_m.id
     and (membership_id=v_mem or guest_id=v_guest);
    if not found then raise exception 'EVENT_PARTICIPANT_NOT_IN_MATCH'; end if;
   end if;
   if v_type='unattributed_goal' then
    if v_part.id is not null then raise exception 'INVALID_EVENT'; end if;
   elsif v_type='own_goal' then
    if v_part.id is not null then v_team := case v_part.team when 'A' then 'B' else 'A' end; end if;
   else
    if v_part.id is null then raise exception 'INVALID_EVENT'; end if;
    v_team := v_part.team;
   end if;
   -- Uma expulsão por jogo: segundo amarelo vale 1; amarelos no máximo 2 (o segundo vira second_yellow).
   if v_type='second_yellow' and v_qty <> 1 then raise exception 'INVALID_EVENT'; end if;
   if v_type='yellow_card' and v_qty > 1 then raise exception 'INVALID_EVENT'; end if;
   if v_team is null or v_team not in ('A','B') then raise exception 'INVALID_TEAM'; end if;
   insert into public.match_events(pelada_id,match_id,participant_id,team,event_type,quantity)
   values(p_m.pelada_id,p_m.id,v_part.id,v_team,v_type,v_qty);
  end loop;
 exception
  when unique_violation then raise exception 'DUPLICATE_IN_SHEET';
  when invalid_text_representation then raise exception 'INVALID_SHEET';
 end;

 if exists(select 1 from (values ('A'),('B')) t(team) where
   coalesce((select sum(quantity) from public.match_events where match_id=p_m.id and team=t.team and event_type='assist'),0)
   > coalesce((select sum(quantity) from public.match_events where match_id=p_m.id and team=t.team
       and event_type in ('goal','unattributed_goal')),0)) then
  raise exception 'ASSISTS_EXCEED_GOALS'; end if;

 select coalesce(sum(quantity) filter (where team='A' and event_type in ('goal','own_goal','unattributed_goal')),0),
  coalesce(sum(quantity) filter (where team='B' and event_type in ('goal','own_goal','unattributed_goal')),0)
 into v_a, v_b from public.match_events where match_id=p_m.id;
 update public.matches set team_a_score=v_a, team_b_score=v_b where id=p_m.id;
 return jsonb_build_object('team_a_score',v_a,'team_b_score',v_b);
end $$;

---------------------------------------------------------------------------------------------------
-- 2/3. Registro disciplinar
---------------------------------------------------------------------------------------------------
alter table public.pelada_settings add column cards_tracking boolean not null default false;
alter table public.matches add column discipline_status text not null default 'not_tracked'
 check (discipline_status in ('not_tracked','pending','confirmed'));

-- Ao virar oficial, a partida herda o registro disciplinar da pelada.
create function private.matches_discipline_on_finalize() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.status='finalized' and old.status is distinct from 'finalized' then
  new.discipline_status := case when coalesce((select cards_tracking from public.pelada_settings
   where pelada_id=new.pelada_id), false) then 'confirmed' else 'not_tracked' end;
 end if;
 return new;
end $$;
create trigger matches_discipline_on_finalize before update of status on public.matches
 for each row execute function private.matches_discipline_on_finalize();

create function public.set_cards_tracking(p_pelada uuid, p_enabled boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_old boolean;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if p_enabled is null then raise exception 'INVALID_VALUE'; end if;
 select cards_tracking into v_old from public.pelada_settings where pelada_id=p_pelada for update;
 if not found then raise exception 'PELADA_NOT_FOUND'; end if;
 if v_old = p_enabled then return; end if;
 update public.pelada_settings set cards_tracking=p_enabled where pelada_id=p_pelada;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(p_pelada,auth.uid(),'cards_tracking_changed',jsonb_build_object('from',v_old,'to',p_enabled));
 perform private.after_rating_inputs_changed(p_pelada, null, 'cards_tracking');
end $$;

create function public.set_match_discipline_status(p_match uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match for update;
 if not found or not private.is_active_staff(v_m.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 if v_m.status <> 'finalized' then raise exception 'MATCH_NOT_OFFICIAL'; end if;
 if p_status not in ('pending','confirmed') then raise exception 'INVALID_VALUE'; end if;
 if v_m.discipline_status = 'not_tracked' then raise exception 'CARDS_NOT_TRACKED'; end if;
 if v_m.discipline_status = p_status then return; end if;
 update public.matches set discipline_status=p_status where id=p_match;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),'match_discipline_changed',jsonb_build_object('match_id',p_match,
  'from',v_m.discipline_status,'to',p_status));
 perform private.after_rating_inputs_changed(v_m.pelada_id, p_match, 'discipline');
end $$;

---------------------------------------------------------------------------------------------------
-- 4. Defesas difíceis
---------------------------------------------------------------------------------------------------
create table public.match_keeper_saves (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null,
 participant_id uuid not null,
 hard_saves integer not null check (hard_saves between 0 and 99),
 recorded_by uuid references public.profiles(id) on delete set null,
 recorded_at timestamptz not null default now(),
 foreign key (match_id, pelada_id) references public.matches(id, pelada_id) on delete cascade,
 foreign key (participant_id, match_id) references public.match_participants(id, match_id) on delete cascade,
 unique (match_id, participant_id)
);
alter table public.match_keeper_saves enable row level security;
revoke all on public.match_keeper_saves from anon,authenticated;
grant select on public.match_keeper_saves to authenticated;
create policy keeper_saves_read on public.match_keeper_saves for select to authenticated
 using (exists(select 1 from public.matches m where m.id=match_id));

-- p_saves: [{"participant_id": uuid, "hard_saves": n | null}] (null apaga o registro). Só goleiros da súmula.
create function public.set_match_hard_saves(p_match uuid, p_saves jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; e jsonb; v_part public.match_participants; v_n int; v_old int;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_m.pelada_id from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_m.pelada_id for update;
 select * into v_m from public.matches where id=p_match for update;
 if not private.is_active_staff(v_m.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 if v_m.status not in ('voting_open','finalized') then raise exception 'MATCH_NOT_OFFICIAL'; end if;
 if jsonb_typeof(p_saves) <> 'array' then raise exception 'INVALID_VALUE'; end if;
 for e in select * from jsonb_array_elements(p_saves) loop
  select * into v_part from public.match_participants where id=(e->>'participant_id')::uuid and match_id=p_match;
  if not found or v_part.primary_position <> 'goalkeeper' then raise exception 'NOT_A_GOALKEEPER'; end if;
  v_n := (e->>'hard_saves')::int;
  select hard_saves into v_old from public.match_keeper_saves where match_id=p_match and participant_id=v_part.id;
  if v_n is null then
   delete from public.match_keeper_saves where match_id=p_match and participant_id=v_part.id;
  else
   if v_n not between 0 and 99 then raise exception 'INVALID_VALUE'; end if;
   insert into public.match_keeper_saves(pelada_id,match_id,participant_id,hard_saves,recorded_by)
   values(v_m.pelada_id,p_match,v_part.id,v_n,auth.uid())
   on conflict (match_id, participant_id) do update set hard_saves=excluded.hard_saves,
    recorded_by=excluded.recorded_by, recorded_at=now();
  end if;
  if v_old is distinct from v_n then
   insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
   values(v_m.pelada_id,auth.uid(),v_part.membership_id,'hard_saves_changed',jsonb_build_object('match_id',p_match,
    'participant_id',v_part.id,'from',v_old,'to',v_n));
  end if;
 end loop;
 if v_m.status='finalized' then perform private.after_rating_inputs_changed(v_m.pelada_id, p_match, 'hard_saves'); end if;
end $$;

---------------------------------------------------------------------------------------------------
-- 5. Posição principal com autorização do admin
---------------------------------------------------------------------------------------------------
create table public.position_changes (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 membership_id uuid not null,
 from_position text,
 from_position_code text,
 to_position text not null,
 to_position_code text,
 position_version integer not null,
 approved_by uuid references public.profiles(id) on delete set null,
 changed_at timestamptz not null default now(),
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 unique (membership_id, position_version)
);
create index position_changes_by_member on public.position_changes(membership_id, changed_at desc);

create table public.position_change_requests (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 membership_id uuid not null,
 requested_position text not null,
 status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
 decided_by uuid references public.profiles(id) on delete set null,
 decided_at timestamptz,
 created_at timestamptz not null default now(),
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id)
);
create unique index one_pending_position_request on public.position_change_requests(membership_id) where status='pending';

alter table public.position_changes enable row level security;
alter table public.position_change_requests enable row level security;
revoke all on public.position_changes, public.position_change_requests from anon,authenticated;
grant select on public.position_changes, public.position_change_requests to authenticated;
create policy position_changes_read on public.position_changes for select to authenticated
 using ((select private.is_active_member(pelada_id)));
create policy position_requests_read on public.position_change_requests for select to authenticated
 using ((select private.is_active_staff(pelada_id)) or exists(select 1 from public.pelada_memberships m
  where m.id=membership_id and m.user_id=(select auth.uid())));

create function private.member_official_matches(p_membership uuid) returns integer
language sql stable security definer set search_path = '' as $$
 select count(*)::int from public.match_participants p join public.matches m on m.id=p.match_id
 where p.membership_id=p_membership and m.status='finalized';
$$;

-- Aplica a troca (caller já validou permissão e trava a filiação).
create function private.apply_position_change(p_membership uuid, p_position text, p_actor uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_m public.pelada_memberships; v_new public.pelada_memberships; v_ver int;
begin
 select * into v_m from public.pelada_memberships where id=p_membership for update;
 update public.pelada_memberships set preferred_position=p_position where id=v_m.id returning * into v_new;
 if v_new.preferred_position is not distinct from v_m.preferred_position and v_new.position_code is not distinct from v_m.position_code then
  return false; end if;
 select coalesce(max(position_version),0)+1 into v_ver from public.position_changes where membership_id=v_m.id;
 insert into public.position_changes(pelada_id,membership_id,from_position,from_position_code,to_position,to_position_code,
  position_version,approved_by)
 values(v_m.pelada_id,v_m.id,v_m.preferred_position,v_m.position_code,v_new.preferred_position,v_new.position_code,v_ver,p_actor);
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
 values(v_m.pelada_id,p_actor,v_m.id,'position_changed',jsonb_build_object('position',v_new.preferred_position,
  'position_code',v_new.position_code,'from_position',v_m.preferred_position,'from_position_code',v_m.position_code,
  'position_version',v_ver));
 perform private.after_rating_inputs_changed(v_m.pelada_id, null, 'position');
 return true;
end $$;

-- O jogador escolhe livremente até a primeira partida oficial; depois precisa pedir ao admin.
create or replace function public.set_my_position(p_pelada uuid, p_position text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.pelada_memberships;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.valid_position(p_position) then raise exception 'INVALID_POSITION'; end if;
 select * into v_m from public.pelada_memberships
 where pelada_id=p_pelada and user_id=auth.uid() and status='active' for update;
 if not found then raise exception 'ACTIVE_MEMBERSHIP_REQUIRED'; end if;
 if private.member_official_matches(v_m.id) > 0 and not private.is_active_admin(p_pelada) then
  raise exception 'POSITION_CHANGE_NEEDS_ADMIN'; end if;
 perform private.apply_position_change(v_m.id, p_position, auth.uid());
end $$;

create function public.request_position_change(p_pelada uuid, p_position text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_m public.pelada_memberships; v_id uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.valid_position(p_position) then raise exception 'INVALID_POSITION'; end if;
 select * into v_m from public.pelada_memberships
 where pelada_id=p_pelada and user_id=auth.uid() and status='active' for update;
 if not found then raise exception 'ACTIVE_MEMBERSHIP_REQUIRED'; end if;
 update public.position_change_requests set status='cancelled', decided_at=now()
 where membership_id=v_m.id and status='pending';
 insert into public.position_change_requests(pelada_id,membership_id,requested_position)
 values(p_pelada,v_m.id,p_position) returning id into v_id;
 perform private.notify(a.user_id, p_pelada, 'position_change_requested', 'essential', 'posreq:'||v_id||':'||a.user_id,
  jsonb_build_object('pelada_id',p_pelada,'request_id',v_id))
 from public.pelada_memberships a where a.pelada_id=p_pelada and a.status='active' and a.role='admin' and a.user_id is not null;
 return v_id;
end $$;

create function public.decide_position_change(p_request uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_r public.position_change_requests;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_r from public.position_change_requests where id=p_request for update;
 if not found or not private.is_active_admin(v_r.pelada_id) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if v_r.status <> 'pending' then raise exception 'REQUEST_NOT_PENDING'; end if;
 update public.position_change_requests set status=case when p_approve then 'approved' else 'rejected' end,
  decided_by=auth.uid(), decided_at=now() where id=p_request;
 if p_approve then perform private.apply_position_change(v_r.membership_id, v_r.requested_position, auth.uid()); end if;
end $$;

-- O admin muda a posição de um membro diretamente.
create function public.set_member_position(p_membership uuid, p_position text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if not private.valid_position(p_position) then raise exception 'INVALID_POSITION'; end if;
 select pelada_id into v_pelada from public.pelada_memberships where id=p_membership and status='active';
 if not found or not private.is_active_admin(v_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 perform private.apply_position_change(p_membership, p_position, auth.uid());
end $$;

-- Gancho do motor (substituído na 051).
create function private.after_rating_inputs_changed(p_pelada uuid, p_match uuid, p_event text) returns void
language plpgsql security definer set search_path = '' as $$
begin
 null;
end $$;

revoke all on function private.matches_discipline_on_finalize(), private.member_official_matches(uuid),
 private.apply_position_change(uuid,text,uuid), private.after_rating_inputs_changed(uuid,uuid,text)
 from public,anon,authenticated;
revoke all on function public.set_cards_tracking(uuid,boolean), public.set_match_discipline_status(uuid,text),
 public.set_match_hard_saves(uuid,jsonb), public.request_position_change(uuid,text),
 public.decide_position_change(uuid,boolean), public.set_member_position(uuid,text) from public,anon;
grant execute on function public.set_cards_tracking(uuid,boolean), public.set_match_discipline_status(uuid,text),
 public.set_match_hard_saves(uuid,jsonb), public.request_position_change(uuid,text),
 public.decide_position_change(uuid,boolean), public.set_member_position(uuid,text) to authenticated;
