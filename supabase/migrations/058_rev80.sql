-- Minuto 91 / 058: REV 8.0 (backend).
--
-- O motor de notas/OVR (050-052) NÃO é tocado: nenhuma fórmula, peso, benchmark ou calibração muda.
-- Defesas de goleiro temporário e confirmações de posição secundária por partida ficam fora das tabelas que
-- alimentam o motor (match_keeper_saves continua só para goleiros de posição principal).
--
-- REV-050  Partida cancelada: status 'cancelled' (só rascunho; resultado publicado segue a anulação 054), motivo,
--          autor, data, data original; remarcação na mesma linha (sem duplicar); histórico em match_schedule_events.
-- REV-047/048  Períodos de vínculo (membership_periods): saída fecha, retorno reabre o MESMO vínculo; ausência não conta.
-- REV-008  Classificação de mensalista (billing_class): pendente em toda entrada/retorno; nada é cobrado até o admin decidir.
-- REV-049  Saída encerra a mensalidade aberta (dívidas ficam); geração de mensalidade só para quem estava ativo no
--          vencimento; extrato do jogador separa pendências anteriores à saída das novas.
-- REV-007  Pagamentos em lote: um lançamento por cobrança, atômico, idempotente por request_id.
-- REV-010  Goleiro temporário por partida (match_participants.temp_goalkeeper), sem mudar posição nem carta.
-- REV-011  Posição secundária vale na Seleção só se a administração confirmar que o jogador atuou nela NAQUELA partida.
-- REV-013  Defesas difíceis informadas pelo goleiro, revisadas pela administração (claims com trilha).
-- REV-002  Álbum global: desbloqueio por pessoa somando as peladas (sequências: melhor marca), com revogação rastreável.
-- REV-018  Rankings Premium (média, jogos, vitórias) verificados no servidor.
-- REV-019/026/032  Retrospectiva Premium só com a temporada encerrada E consolidada; versões imutáveis, sem duplicar.
-- REV-028  Pendências administrativas agregadas para a Central do Jogador.
-- REV-006  Criação de pelada em etapas: local, times/cores padrão e agenda; criação idempotente por request_id.
--
-- Rollback: dropar as funções e tabelas novas; restaurar generate_monthly_charges (043), get_season_ranking (051),
-- snapshot_secondary_position (056), create_pelada/join_pelada sem mudanças de assinatura (não alteradas aqui);
-- voltar match_status_check para ('draft','voting_open','finalizing','finalized','annulled') depois de remarcar
-- ou excluir partidas 'cancelled'.

---------------------------------------------------------------------------------------------------
-- REV-050: partidas canceladas
---------------------------------------------------------------------------------------------------
alter table public.matches drop constraint match_status_check;
alter table public.matches add constraint match_status_check
 check (status in ('draft','voting_open','finalizing','finalized','annulled','cancelled'));
alter table public.matches
 add column cancelled_at timestamptz,
 add column cancelled_by uuid references public.profiles(id) on delete set null,
 add column cancel_reason text check (cancel_reason is null or length(cancel_reason) <= 200),
 add column originally_scheduled_at timestamptz,
 add constraint match_cancel_consistent check ((status = 'cancelled') = (cancelled_at is not null));

-- 054 libera colunas de matches uma a uma: as novas entram na lista.
grant select (status, cancelled_at, cancelled_by, cancel_reason, originally_scheduled_at) on public.matches to authenticated;

create table private.match_schedule_events (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null references public.matches(id) on delete cascade,
 kind text not null check (kind in ('cancelled','rescheduled')),
 from_at timestamptz not null,
 to_at timestamptz,
 reason text,
 actor_user_id uuid,
 created_at timestamptz not null default now()
);
create index match_schedule_events_by_match on private.match_schedule_events(match_id, created_at);

create function public.cancel_match(p_match uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_reason text := nullif(btrim(p_reason), '');
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_m.pelada_id from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_m.pelada_id for update;
 select * into v_m from public.matches where id=p_match for update;
 if not private.is_active_staff(v_m.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 if v_m.status = 'cancelled' then return; end if; -- idempotente
 -- Resultado oficial já publicado: só pela anulação/correção excepcional (054).
 if v_m.status <> 'draft' then raise exception 'MATCH_ALREADY_PUBLISHED'; end if;
 if v_reason is not null and length(v_reason) > 200 then raise exception 'INVALID_REASON'; end if;
 update public.matches set status='cancelled', cancelled_at=now(), cancelled_by=auth.uid(), cancel_reason=v_reason,
  originally_scheduled_at=coalesce(originally_scheduled_at, played_at)
 where id=p_match;
 insert into private.match_schedule_events(pelada_id,match_id,kind,from_at,reason,actor_user_id)
 values(v_m.pelada_id,p_match,'cancelled',v_m.played_at,v_reason,auth.uid());
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),'match_cancelled',jsonb_build_object('match_id',p_match,'played_at',v_m.played_at));
end $$;

-- Remarcação: a MESMA partida volta a rascunho com a nova data (a validação de data/temporada é a do rascunho).
create function public.reschedule_match(p_match uuid, p_played_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_a text; v_b text; v_season uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_m.pelada_id from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_m.pelada_id for update;
 select * into v_m from public.matches where id=p_match for update;
 if not private.is_active_staff(v_m.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 if v_m.status not in ('cancelled','draft') then raise exception 'MATCH_ALREADY_PUBLISHED'; end if;
 select * into v_a, v_b, v_season from private.prepare_match(v_m.pelada_id, p_played_at, v_m.team_a_name, v_m.team_b_name);
 update public.matches set status='draft', played_at=p_played_at, season_id=v_season,
  originally_scheduled_at=coalesce(originally_scheduled_at, v_m.played_at),
  cancelled_at=null, cancelled_by=null, cancel_reason=null
 where id=p_match;
 insert into private.match_schedule_events(pelada_id,match_id,kind,from_at,to_at,actor_user_id)
 values(v_m.pelada_id,p_match,'rescheduled',v_m.played_at,p_played_at,auth.uid());
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),'match_rescheduled',jsonb_build_object('match_id',p_match,'from',v_m.played_at,'to',p_played_at));
end $$;

create function public.get_match_schedule_history(p_match uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_pelada uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_pelada from public.matches where id=p_match;
 if v_pelada is null or not private.is_active_member(v_pelada) then raise exception 'MATCH_NOT_FOUND'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('kind',e.kind,'from_at',e.from_at,'to_at',e.to_at,
   'reason',e.reason,'actor_name',(select display_name from public.profiles where id=e.actor_user_id),
   'created_at',e.created_at) order by e.created_at)
  from private.match_schedule_events e where e.match_id=p_match), '[]'::jsonb);
end $$;

---------------------------------------------------------------------------------------------------
-- REV-047/048/008: períodos de vínculo e classificação de mensalista
---------------------------------------------------------------------------------------------------
-- Ex-integrante continua lendo o próprio histórico (a leitura de pelada_memberships exige vínculo ativo).
create function private.is_my_membership(p_membership uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.pelada_memberships where id=p_membership and user_id=auth.uid());
$$;
grant execute on function private.is_my_membership(uuid) to authenticated;

create table public.membership_periods (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 membership_id uuid not null,
 started_at timestamptz not null,
 ended_at timestamptz,
 foreign key (membership_id, pelada_id) references public.pelada_memberships(id, pelada_id),
 check (ended_at is null or ended_at >= started_at)
);
create unique index membership_periods_one_open on public.membership_periods(membership_id) where ended_at is null;
create index membership_periods_by_member on public.membership_periods(membership_id, started_at);
alter table public.membership_periods enable row level security;
revoke all on public.membership_periods from anon, authenticated;
grant select on public.membership_periods to authenticated;
create policy membership_periods_read on public.membership_periods for select to authenticated
 using ((select private.is_active_staff(pelada_id))
  or (select private.is_my_membership(membership_id)));

-- Backfill: um período por vínculo; quem já saiu fica com o período fechado na última alteração conhecida.
insert into public.membership_periods(pelada_id, membership_id, started_at, ended_at)
select pelada_id, id, joined_at, case when status='active' then null else greatest(updated_at, joined_at) end
from public.pelada_memberships;

alter table public.pelada_memberships
 add column billing_class text check (billing_class is null or billing_class in ('pending','monthly','not_monthly'));

create function private.is_member_active_on(p_membership uuid, p_at date) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.membership_periods p join public.pelada_memberships m on m.id=p.membership_id
  where p.membership_id=p_membership
   and private.pelada_local_date(m.pelada_id, p.started_at) <= p_at
   and (p.ended_at is null or private.pelada_local_date(m.pelada_id, p.ended_at) >= p_at));
$$;

create function private.membership_period_track() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_fm uuid; v_old text;
begin
 if tg_op = 'INSERT' then
  if new.status = 'active' then
   insert into public.membership_periods(pelada_id,membership_id,started_at) values(new.pelada_id,new.id,new.joined_at);
  end if;
  return null;
 end if;
 if old.status = 'active' and new.status <> 'active' then
  update public.membership_periods set ended_at=now() where membership_id=new.id and ended_at is null;
  -- REV-049: a mensalidade aberta termina na saída; cobranças já geradas (dívidas) ficam.
  for v_fm, v_old in update public.finance_members f set status='ended', ends_on=private.pelada_today(new.pelada_id),
    updated_at=now(), version=version+1
   from (select id, status from public.finance_members where membership_id=new.id and status <> 'ended' for update) o
   where f.id=o.id returning f.id, o.status loop
   perform private.finance_log(new.pelada_id,'monthly_status','monthly_member',v_fm,jsonb_build_object('status',v_old),
    jsonb_build_object('status','ended','reason','member_left'));
  end loop;
 elsif old.status <> 'active' and new.status = 'active' then
  insert into public.membership_periods(pelada_id,membership_id,started_at) values(new.pelada_id,new.id,now())
  on conflict do nothing;
  -- REV-048/008: o retorno pede nova classificação; nada é cobrado até a decisão.
  update public.pelada_memberships set billing_class='pending' where id=new.id;
  insert into private.audit_events(pelada_id,subject_membership_id,event_type)
  values(new.pelada_id,new.id,'member_period_reopened');
 end if;
 return null;
end $$;
create trigger memberships_period_insert after insert on public.pelada_memberships
 for each row execute function private.membership_period_track();
create trigger memberships_period_status after update of status on public.pelada_memberships
 for each row when (old.status is distinct from new.status) execute function private.membership_period_track();

-- Novo integrante (não o criador da pelada): classificação pendente.
create function private.membership_billing_default() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.role <> 'admin' and new.user_id is not null then new.billing_class := coalesce(new.billing_class, 'pending'); end if;
 return new;
end $$;
create trigger memberships_billing_default before insert on public.pelada_memberships
 for each row execute function private.membership_billing_default();

alter table public.pelada_settings add column default_monthly_cents integer
 check (default_monthly_cents is null or default_monthly_cents between 1 and 100000000);

-- "Será mensalista?" Sim: cria a mensalidade a partir de hoje (nunca retroativa). Não: só registra.
-- Sem Premium (Financeiro indisponível) a classificação fica registrada e nenhuma cobrança é criada.
create function public.classify_member_billing(p_membership uuid, p_monthly boolean, p_amount_cents integer default null,
 p_due_day integer default 10) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m public.pelada_memberships; v_fm uuid; v_amount integer;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_m.pelada_id from public.pelada_memberships where id=p_membership;
 if not found then raise exception 'MEMBER_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_m.pelada_id for update;
 select * into v_m from public.pelada_memberships where id=p_membership for update;
 if not private.is_active_admin(v_m.pelada_id) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if v_m.status <> 'active' then raise exception 'ACTIVE_MEMBERSHIP_REQUIRED'; end if;
 if p_monthly is null then raise exception 'INVALID_VALUE'; end if;
 select id into v_fm from public.finance_members where membership_id=p_membership and status <> 'ended';
 if not p_monthly then
  update public.pelada_memberships set billing_class='not_monthly' where id=p_membership;
 else
  v_amount := coalesce(p_amount_cents, (select default_monthly_cents from public.pelada_settings where pelada_id=v_m.pelada_id));
  if v_amount is null or v_amount not between 1 and 100000000 then raise exception 'FINANCE_INVALID_AMOUNT'; end if;
  if p_due_day is null or p_due_day not between 1 and 28 then raise exception 'FINANCE_INVALID_DATE'; end if;
  if v_fm is null and private.pelada_has_premium(v_m.pelada_id) then
   insert into public.finance_members(pelada_id,membership_id,amount_cents,due_day,starts_on,created_by)
   values(v_m.pelada_id,p_membership,v_amount,p_due_day,private.pelada_today(v_m.pelada_id),auth.uid()) returning id into v_fm;
   perform private.finance_log(v_m.pelada_id,'monthly_created','monthly_member',v_fm,null,
    jsonb_build_object('membership_id',p_membership,'amount_cents',v_amount,'due_day',p_due_day,'source','classification'));
  end if;
  update public.pelada_memberships set billing_class='monthly' where id=p_membership;
 end if;
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),p_membership,'member_billing_classified',
  jsonb_build_object('monthly',p_monthly,'finance_member_id',v_fm));
 return jsonb_build_object('billing_class', case when p_monthly then 'monthly' else 'not_monthly' end,
  'finance_member_id', v_fm);
end $$;

create function public.set_default_monthly_amount(p_pelada uuid, p_amount_cents integer) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 if p_amount_cents is not null and p_amount_cents not between 1 and 100000000 then raise exception 'FINANCE_INVALID_AMOUNT'; end if;
 update public.pelada_settings set default_monthly_cents=p_amount_cents where pelada_id=p_pelada;
end $$;

-- REV-049: mensalidade só nas competências em que o vínculo esteve ativo (ausência nunca gera cobrança).
create or replace function public.generate_monthly_charges(p_pelada uuid, p_month date default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare v_month date; v_end date; v_today date; v_n integer := 0; f public.finance_members; v_id uuid; v_due date;
begin
 perform private.require_finance(p_pelada, true);
 v_today := private.pelada_today(p_pelada);
 v_month := date_trunc('month', coalesce(p_month, v_today))::date;
 if v_month > (date_trunc('month', v_today) + interval '1 month')::date then raise exception 'FINANCE_INVALID_DATE'; end if;
 v_end := (v_month + interval '1 month - 1 day')::date;
 for f in select * from public.finance_members where pelada_id=p_pelada and status='active' and starts_on <= v_end
   and (membership_id is null or exists(select 1 from public.pelada_memberships m where m.id=membership_id and m.status='active'))
   and (payer_id is null or exists(select 1 from public.finance_payers p where p.id=payer_id and p.archived_at is null))
   order by created_at loop
  v_due := make_date(extract(year from v_month)::int, extract(month from v_month)::int, f.due_day);
  -- Ausência no mês inteiro (depois de uma saída) = sem mensalidade naquela competência. Antes da primeira entrada vale
  -- o início definido pelo admin na mensalidade (043).
  if f.membership_id is not null and exists(select 1 from public.membership_periods p where p.membership_id=f.membership_id
    and private.pelada_local_date(p_pelada, p.ended_at) < v_month) and not exists(select 1 from public.membership_periods p where p.membership_id=f.membership_id
    and private.pelada_local_date(p_pelada, p.started_at) <= v_end
    and (p.ended_at is null or private.pelada_local_date(p_pelada, p.ended_at) >= v_month)) then continue; end if;
  -- Saiu e voltou no mesmo mês: a competência já cobrada não se repete pela nova mensalidade.
  if f.membership_id is not null and exists(select 1 from public.finance_charges c where c.membership_id=f.membership_id
    and c.kind='monthly' and c.reference_month=v_month and c.status <> 'cancelled') then continue; end if;
  insert into public.finance_charges(pelada_id,kind,finance_member_id,membership_id,payer_id,reference_month,description,
   amount_due_cents,due_date,created_by)
  values(p_pelada,'monthly',f.id,f.membership_id,f.payer_id,v_month,'Mensalidade '||to_char(v_month,'MM/YYYY'),
   f.amount_cents, v_due, auth.uid())
  on conflict (finance_member_id, reference_month) do nothing
  returning id into v_id;
  if v_id is not null then
   v_n := v_n + 1;
   perform private.finance_log(p_pelada,'charge_created','charge',v_id,null,
    jsonb_build_object('kind','monthly','amount_due_cents',f.amount_cents,'reference_month',v_month));
   v_id := null;
  end if;
 end loop;
 return v_n;
end $$;

-- Extrato do jogador: cada cobrança pela competência original, separadas em "antes da última saída" e "atual".
create function public.get_member_finance_statement(p_membership uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_pelada uuid; v_cut timestamptz;
begin
 select pelada_id into v_pelada from public.pelada_memberships where id=p_membership;
 if v_pelada is null then raise exception 'FINANCE_NOT_FOUND'; end if;
 if not private.has_finance_access(v_pelada) then raise exception 'FINANCE_FORBIDDEN' using errcode='42501'; end if;
 -- Fim da última saída: o que foi cobrado até ali é pendência anterior; depois, mensalidade nova.
 select max(p.ended_at) into v_cut from public.membership_periods p where p.membership_id=p_membership and p.ended_at is not null;
 return jsonb_build_object(
  'periods', coalesce((select jsonb_agg(jsonb_build_object('started_at',started_at,'ended_at',ended_at) order by started_at)
    from public.membership_periods where membership_id=p_membership), '[]'::jsonb),
  'charges', coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'kind',c.kind,'reference_month',c.reference_month,
     'description',c.description,'amount_due_cents',c.amount_due_cents,'amount_paid_cents',c.amount_paid_cents,
     'due_date',c.due_date,'status',c.status,
     'segment',case when v_cut is not null and c.created_at <= v_cut then 'before_leave' else 'current' end)
    order by c.due_date, c.id)
    from public.finance_charges c where c.membership_id=p_membership and c.status <> 'cancelled'), '[]'::jsonb),
  'open_cents', (select coalesce(sum(amount_due_cents-amount_paid_cents),0) from public.finance_charges
    where membership_id=p_membership and status in ('pending','partial')));
end $$;

---------------------------------------------------------------------------------------------------
-- REV-007: pagamentos em lote
---------------------------------------------------------------------------------------------------
-- p_items: [{"charge_id": uuid, "amount_cents": n}]. Tudo ou nada; reenviar o mesmo request_id não duplica.
create function public.register_payments_batch(p_pelada uuid, p_items jsonb, p_received_on date, p_method text,
 p_request_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e jsonb; v_charge uuid; v_out jsonb := '[]'::jsonb; v_done jsonb; v_seen uuid[] := '{}'; v_total bigint := 0; v_n integer := 0;
begin
 perform private.require_finance(p_pelada, true);
 if p_request_id is null then raise exception 'FINANCE_REQUEST_ID_REQUIRED'; end if;
 -- Lote já gravado (duplo clique, retry de rede): devolve o resumo sem repetir nada.
 select after_data into v_done from public.finance_events where pelada_id=p_pelada and event_type='payment_batch_registered'
  and entity_id=p_request_id;
 if found then return v_done || jsonb_build_object('replayed', true); end if;
 if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 100 then
  raise exception 'INVALID_VALUE'; end if;
 for e in select * from jsonb_array_elements(p_items) loop
  v_charge := private.try_uuid(e->>'charge_id');
  if v_charge is null or v_charge = any(v_seen) then raise exception 'INVALID_VALUE'; end if;
  if not exists(select 1 from public.finance_charges where id=v_charge and pelada_id=p_pelada) then
   raise exception 'FINANCE_NOT_FOUND'; end if;
  v_seen := v_seen || v_charge;
  -- Um lançamento por cobrança; o request_id de cada item deriva do lote (idempotência por item).
  v_out := v_out || public.register_payment(v_charge, (e->>'amount_cents')::integer, p_received_on, p_method, null,
   md5(p_request_id::text || ':' || v_charge::text)::uuid, true);
  v_total := v_total + (e->>'amount_cents')::integer; v_n := v_n + 1;
 end loop;
 perform private.finance_log(p_pelada,'payment_batch_registered','batch',p_request_id,null,
  jsonb_build_object('count',v_n,'total_cents',v_total,'received_on',p_received_on,'method',p_method));
 return jsonb_build_object('count',v_n,'total_cents',v_total,'charges',v_out);
end $$;

---------------------------------------------------------------------------------------------------
-- REV-010/011/013: goleiro temporário, secundária por partida, defesas difíceis informadas
---------------------------------------------------------------------------------------------------
alter table public.match_participants add column temp_goalkeeper boolean not null default false;
create unique index participants_one_temp_gk_per_team on public.match_participants(match_id, team) where temp_goalkeeper;

create table private.match_secondary_confirmations (
 match_id uuid not null references public.matches(id) on delete cascade,
 membership_id uuid not null references public.pelada_memberships(id),
 position text not null check (position in ('goalkeeper','defender','midfielder','attacker')),
 confirmed_by uuid,
 confirmed_at timestamptz not null default now(),
 primary key (match_id, membership_id)
);

-- REV-011: o retrato da secundária na súmula só existe com a confirmação daquela partida.
create or replace function private.snapshot_secondary_position() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.membership_id is not null and (tg_op='INSERT' or new.membership_id is distinct from old.membership_id) then
  select c.position into new.secondary_position from private.match_secondary_confirmations c
  join public.pelada_memberships m on m.id=c.membership_id
  where c.match_id=new.match_id and c.membership_id=new.membership_id
   and m.secondary_status='confirmed' and m.secondary_position=c.position;
 end if;
 if new.secondary_position = new.primary_position then new.secondary_position := null; end if;
 return new;
end $$;

create function public.set_match_secondary_played(p_match uuid, p_membership uuid, p_played boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_mem public.pelada_memberships; v_pos text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_m.pelada_id from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_m.pelada_id for update;
 select * into v_m from public.matches where id=p_match for update;
 if not private.is_active_staff(v_m.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 if v_m.status in ('annulled','cancelled') then raise exception 'MATCH_NOT_EDITABLE'; end if;
 select * into v_mem from public.pelada_memberships where id=p_membership and pelada_id=v_m.pelada_id;
 if not found or not exists(select 1 from public.match_participants where match_id=p_match and membership_id=p_membership) then
  raise exception 'NOT_A_PARTICIPANT'; end if;
 if coalesce(p_played, false) then
  if v_mem.secondary_status is distinct from 'confirmed' then raise exception 'SECONDARY_NOT_CONFIRMED'; end if;
  v_pos := v_mem.secondary_position;
  insert into private.match_secondary_confirmations(match_id,membership_id,position,confirmed_by)
  values(p_match,p_membership,v_pos,auth.uid())
  on conflict (match_id, membership_id) do update set position=excluded.position, confirmed_by=excluded.confirmed_by, confirmed_at=now();
 else
  delete from private.match_secondary_confirmations where match_id=p_match and membership_id=p_membership;
 end if;
 update public.match_participants set secondary_position=case when v_pos is distinct from primary_position then v_pos end
 where match_id=p_match and membership_id=p_membership;
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),p_membership,'match_secondary_played',jsonb_build_object('match_id',p_match,'played',coalesce(p_played,false),'position',v_pos));
 if v_m.status='finalized' then perform private.compute_round_selection(p_match); end if;
end $$;

create function public.set_match_temp_goalkeeper(p_match uuid, p_participant uuid, p_on boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_p public.match_participants;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select pelada_id into v_m.pelada_id from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 perform 1 from public.peladas where id=v_m.pelada_id for update;
 select * into v_m from public.matches where id=p_match for update;
 if not private.is_active_staff(v_m.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 if v_m.status in ('annulled','cancelled') then raise exception 'MATCH_NOT_EDITABLE'; end if;
 select * into v_p from public.match_participants where id=p_participant and match_id=p_match for update;
 if not found then raise exception 'NOT_A_PARTICIPANT'; end if;
 if coalesce(p_on, false) then
  if v_p.primary_position = 'goalkeeper' then raise exception 'ALREADY_GOALKEEPER'; end if;
  if exists(select 1 from public.match_participants where match_id=p_match and team=v_p.team and primary_position='goalkeeper') then
   raise exception 'TEAM_HAS_GOALKEEPER'; end if;
  update public.match_participants set temp_goalkeeper=false where match_id=p_match and team=v_p.team and temp_goalkeeper and id<>p_participant;
 end if;
 update public.match_participants set temp_goalkeeper=coalesce(p_on,false) where id=p_participant;
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),v_p.membership_id,'temp_goalkeeper_set',jsonb_build_object('match_id',p_match,'participant_id',p_participant,'on',coalesce(p_on,false)));
end $$;

create table public.match_keeper_save_claims (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null,
 match_id uuid not null,
 participant_id uuid not null,
 membership_id uuid not null,
 claimed_saves integer not null check (claimed_saves between 0 and 99),
 status text not null default 'pending' check (status in ('pending','confirmed','corrected','rejected')),
 official_saves integer check (official_saves is null or official_saves between 0 and 99),
 claimed_at timestamptz not null default now(),
 reviewed_by uuid references public.profiles(id) on delete set null,
 reviewed_at timestamptz,
 foreign key (match_id, pelada_id) references public.matches(id, pelada_id) on delete cascade,
 foreign key (participant_id, match_id) references public.match_participants(id, match_id) on delete cascade,
 unique (match_id, participant_id),
 check ((status = 'pending') = (reviewed_at is null))
);
alter table public.match_keeper_save_claims enable row level security;
revoke all on public.match_keeper_save_claims from anon, authenticated;
grant select on public.match_keeper_save_claims to authenticated;
create policy keeper_claims_read on public.match_keeper_save_claims for select to authenticated
 using ((select private.is_active_staff(pelada_id))
  or (select private.is_my_membership(membership_id)));

-- O goleiro (de posição ou temporário naquela partida) informa; reenviar só enquanto pendente.
create function public.submit_keeper_saves_claim(p_match uuid, p_saves integer) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_p public.match_participants; v_id uuid; v_status text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_m from public.matches where id=p_match;
 if not found then raise exception 'MATCH_NOT_FOUND'; end if;
 if v_m.status not in ('voting_open','finalized') then raise exception 'MATCH_NOT_OFFICIAL'; end if;
 if p_saves is null or p_saves not between 0 and 99 then raise exception 'INVALID_VALUE'; end if;
 select x.* into v_p from public.match_participants x join public.pelada_memberships pm on pm.id=x.membership_id
 where x.match_id=p_match and pm.user_id=auth.uid();
 if not found or not (v_p.primary_position='goalkeeper' or v_p.temp_goalkeeper) then raise exception 'NOT_A_GOALKEEPER'; end if;
 select id, status into v_id, v_status from public.match_keeper_save_claims where match_id=p_match and participant_id=v_p.id for update;
 if v_id is not null and v_status <> 'pending' then raise exception 'CLAIM_ALREADY_REVIEWED'; end if;
 insert into public.match_keeper_save_claims(pelada_id,match_id,participant_id,membership_id,claimed_saves)
 values(v_m.pelada_id,p_match,v_p.id,v_p.membership_id,p_saves)
 on conflict (match_id, participant_id) do update set claimed_saves=excluded.claimed_saves, claimed_at=now()
 returning id into v_id;
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
 values(v_m.pelada_id,auth.uid(),v_p.membership_id,'keeper_saves_claimed',jsonb_build_object('match_id',p_match,'saves',p_saves));
 return v_id;
end $$;

-- Administração confirma (p_saves = o informado), corrige (outro valor) ou recusa (null).
-- Só o goleiro de POSIÇÃO alimenta o motor (match_keeper_saves); o temporário fica só no registro da partida.
create function public.review_keeper_saves_claim(p_claim uuid, p_saves integer) returns void
language plpgsql security definer set search_path = '' as $$
declare v_c public.match_keeper_save_claims; v_p public.match_participants; v_status text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v_c from public.match_keeper_save_claims where id=p_claim;
 if not found then raise exception 'NOT_FOUND'; end if;
 if not private.is_active_staff(v_c.pelada_id) then raise exception 'STAFF_REQUIRED' using errcode='42501'; end if;
 select * into v_c from public.match_keeper_save_claims where id=p_claim for update;
 if p_saves is not null and p_saves not between 0 and 99 then raise exception 'INVALID_VALUE'; end if;
 select * into v_p from public.match_participants where id=v_c.participant_id;
 v_status := case when p_saves is null then 'rejected' when p_saves = v_c.claimed_saves then 'confirmed' else 'corrected' end;
 update public.match_keeper_save_claims set status=v_status, official_saves=p_saves, reviewed_by=auth.uid(), reviewed_at=now()
 where id=p_claim;
 if v_p.primary_position = 'goalkeeper' then
  perform public.set_match_hard_saves(v_c.match_id, jsonb_build_array(jsonb_build_object('participant_id',v_p.id,'hard_saves',p_saves)));
 end if;
 insert into private.audit_events(pelada_id,actor_user_id,subject_membership_id,event_type,metadata)
 values(v_c.pelada_id,auth.uid(),v_c.membership_id,'keeper_saves_reviewed',jsonb_build_object('claim_id',p_claim,
  'claimed',v_c.claimed_saves,'official',p_saves,'status',v_status,'temporary',v_p.primary_position<>'goalkeeper'));
end $$;

---------------------------------------------------------------------------------------------------
-- REV-002: álbum global por pessoa
---------------------------------------------------------------------------------------------------
create table public.player_global_sticker_unlocks (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id) on delete cascade,
 sticker_definition_id uuid not null references public.sticker_definitions(id),
 unlocked_at timestamptz not null default now(),
 status text not null default 'active' check (status in ('active','revoked')),
 revoked_at timestamptz,
 check ((status='revoked') = (revoked_at is not null))
);
create unique index one_active_global_unlock on public.player_global_sticker_unlocks(user_id, sticker_definition_id) where status='active';
alter table public.player_global_sticker_unlocks enable row level security;
revoke all on public.player_global_sticker_unlocks from anon, authenticated;
grant select on public.player_global_sticker_unlocks to authenticated;
create policy global_unlocks_own on public.player_global_sticker_unlocks for select to authenticated
 using (user_id = (select auth.uid()));

-- Valor global: soma das peladas (contagens); sequências = melhor marca entre as peladas.
create function private.global_sticker_values(p_user uuid) returns table(sticker_definition_id uuid, global_value integer)
language sql stable security definer set search_path = '' as $$
 select d.id, coalesce(case when d.metric_code in ('best_win_streak','best_unbeaten_streak')
   then max(p.current_value) else sum(p.current_value) end, 0)::integer
 from public.sticker_definitions d
 left join public.player_sticker_progress p on p.sticker_definition_id=d.id
  and p.membership_id in (select id from public.pelada_memberships where user_id=p_user)
 group by d.id, d.metric_code;
$$;

create function private.reconcile_global_stickers(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if p_user is null or not exists(select 1 from public.profiles where id=p_user) then return; end if;
 perform pg_advisory_xact_lock(hashtextextended('global_stickers:' || p_user::text, 0));
 update public.player_global_sticker_unlocks u set status='revoked', revoked_at=now()
 from private.global_sticker_values(p_user) v join public.sticker_definitions d on d.id=v.sticker_definition_id
 where u.user_id=p_user and u.status='active' and u.sticker_definition_id=v.sticker_definition_id and v.global_value < d.threshold;
 insert into public.player_global_sticker_unlocks(user_id, sticker_definition_id)
 select p_user, v.sticker_definition_id from private.global_sticker_values(p_user) v
 join public.sticker_definitions d on d.id=v.sticker_definition_id
 where v.global_value >= d.threshold
 on conflict (user_id, sticker_definition_id) where status='active' do nothing;
end $$;

create function private.on_sticker_progress_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 perform private.reconcile_global_stickers((select user_id from public.pelada_memberships
  where id=coalesce(new.membership_id, old.membership_id)));
 return null;
end $$;
create trigger sticker_progress_global after insert or update or delete on public.player_sticker_progress
 for each row execute function private.on_sticker_progress_changed();

do $$ declare u uuid; begin
 for u in select distinct pm.user_id from public.player_sticker_progress p
  join public.pelada_memberships pm on pm.id=p.membership_id where pm.user_id is not null loop
  perform private.reconcile_global_stickers(u);
 end loop;
end $$;

create function public.get_my_global_album() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 return jsonb_build_object(
  'collections', coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'code',c.code,'name',c.name) order by c.display_order)
    from public.sticker_collections c), '[]'::jsonb),
  'stickers', coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'collection_id',d.collection_id,'name',d.name,
     'level',d.level,'threshold',d.threshold,'value',v.global_value,
     'unlocked_at',(select u.unlocked_at from public.player_global_sticker_unlocks u
       where u.user_id=auth.uid() and u.sticker_definition_id=d.id and u.status='active'))
    order by d.display_order)
    from public.sticker_definitions d join private.global_sticker_values(auth.uid()) v on v.sticker_definition_id=d.id), '[]'::jsonb));
end $$;

---------------------------------------------------------------------------------------------------
-- REV-018: rankings Premium no servidor
---------------------------------------------------------------------------------------------------
create or replace function public.get_season_ranking(p_season uuid, p_metric text)
returns table(rank_position bigint, membership_id uuid, metric_value numeric)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare v_pelada uuid;
begin
 v_pelada := private.check_season_access(p_season);
 if p_metric is null or p_metric not in ('overall','goals','assists','avg_rating','matches','wins') then
  raise exception 'INVALID_METRIC'; end if;
 if p_metric in ('avg_rating','matches','wins') and not private.pelada_has_premium(v_pelada) then
  raise exception 'PREMIUM_REQUIRED'; end if;
 return query
 select rank() over (order by t.v desc), t.mem, t.v from (
  select c.membership_id mem, case when c.formula_version >= 2 then round(c.overall,0) else c.overall end v
  from public.player_cards c where p_metric='overall' and c.season_id=p_season
   and (c.formula_version < 2 or not c.is_provisional)
  union all
  select s.membership_id, case p_metric when 'goals' then s.goals when 'assists' then s.assists
   when 'matches' then s.matches_played when 'wins' then s.wins else s.avg_final_rating end
  from public.player_season_stats s where p_metric<>'overall' and s.season_id=p_season
   and (p_metric<>'avg_rating' or s.avg_final_rating is not null)) t
 order by 1, 2;
end $$;

---------------------------------------------------------------------------------------------------
-- REV-019/026/032: retrospectiva consolidada e versionada
---------------------------------------------------------------------------------------------------
create table public.season_retrospectives (
 id uuid primary key default gen_random_uuid(),
 pelada_id uuid not null references public.peladas(id),
 season_id uuid not null references public.seasons(id),
 version integer not null,
 fingerprint text not null,
 data jsonb not null,
 generated_at timestamptz not null default now(),
 unique (season_id, version),
 unique (season_id, fingerprint)
);
alter table public.season_retrospectives enable row level security;
revoke all on public.season_retrospectives from anon, authenticated;

-- Encerramento do calendário x consolidação esportiva: as duas condições são exigidas.
create function private.season_consolidation(p_season uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
 select jsonb_build_object(
  'calendar_closed', s.ends_on < private.pelada_today(s.pelada_id),
  'pending_matches', (select count(*) from public.matches m where m.season_id=s.id and m.status in ('voting_open','finalizing')),
  'pending_votes', (select count(*) from public.rating_vote_sessions v join public.matches m on m.id=v.match_id
     where m.season_id=s.id and m.status='finalized' and v.status not in ('published','cancelled')),
  'ready', s.ends_on < private.pelada_today(s.pelada_id)
   and not exists(select 1 from public.matches m where m.season_id=s.id and m.status in ('voting_open','finalizing'))
   and not exists(select 1 from public.rating_vote_sessions v join public.matches m on m.id=v.match_id
     where m.season_id=s.id and m.status='finalized' and v.status not in ('published','cancelled')))
 from public.seasons s where s.id=p_season;
$$;

create function public.get_season_consolidation(p_season uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_pelada uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 v_pelada := private.check_season_access(p_season);
 return private.season_consolidation(p_season) || jsonb_build_object('premium', private.pelada_has_premium(v_pelada));
end $$;

-- Gera (ou reaproveita) a versão oficial. Dados iguais = mesma versão; correção posterior = nova versão.
create function public.get_season_retrospective_official(p_season uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_pelada uuid; v_data jsonb; v_fp text; v_row public.season_retrospectives; v_cons jsonb; v_me uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 v_pelada := private.check_season_access(p_season);
 if not private.pelada_has_premium(v_pelada) then raise exception 'PREMIUM_REQUIRED'; end if;
 v_cons := private.season_consolidation(p_season);
 if not (v_cons->>'ready')::boolean then raise exception 'SEASON_NOT_CONSOLIDATED'; end if;
 v_data := public.get_season_retrospective(p_season, null) - 'me' || jsonb_build_object(
  'season', (select jsonb_build_object('id',id,'name',name,'starts_on',starts_on,'ends_on',ends_on) from public.seasons where id=p_season),
  'selection_leaders', private.retro_top((select coalesce(jsonb_agg(jsonb_build_object('membership_id',x.membership_id,
     'name',x.name,'value',x.c)),'[]') from (select sp.membership_id, min(pm.player_name) name, count(*) c
     from public.round_selection_players sp join public.round_selections rs on rs.id=sp.selection_id and rs.status='published'
     join public.matches m on m.id=rs.match_id and m.status='finalized' and m.season_id=p_season
     join public.pelada_memberships pm on pm.id=sp.membership_id group by sp.membership_id) x)),
  'records', public.get_season_records(p_season));
 v_fp := md5(v_data::text);
 perform pg_advisory_xact_lock(hashtextextended('retro:' || p_season::text, 0));
 select * into v_row from public.season_retrospectives where season_id=p_season and fingerprint=v_fp;
 if not found then
  insert into public.season_retrospectives(pelada_id,season_id,version,fingerprint,data)
  values(v_pelada,p_season,coalesce((select max(version) from public.season_retrospectives where season_id=p_season),0)+1,v_fp,v_data)
  returning * into v_row;
 end if;
 select id into v_me from public.pelada_memberships where pelada_id=v_pelada and user_id=auth.uid();
 return v_row.data || jsonb_build_object('version',v_row.version,'generated_at',v_row.generated_at,
  'me',(public.get_season_retrospective(p_season, v_me))->'me');
end $$;

---------------------------------------------------------------------------------------------------
-- REV-028: pendências administrativas (só peladas que a pessoa administra; só o que existe)
---------------------------------------------------------------------------------------------------
create function public.get_my_admin_pending() returns jsonb
language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_agg(x order by x->>'pelada_name'), '[]'::jsonb) from (
  select jsonb_strip_nulls(jsonb_build_object('pelada_id',p.id,'pelada_name',p.name,
   'drafts', nullif((select count(*) from public.matches m where m.pelada_id=p.id and m.status='draft'
      and private.pelada_local_date(p.id, m.played_at) < private.pelada_today(p.id)),0),
   'keeper_claims', nullif((select count(*) from public.match_keeper_save_claims c where c.pelada_id=p.id and c.status='pending'),0),
   'secondary_requests', nullif((select count(*) from public.pelada_memberships x where x.pelada_id=p.id and x.status='active'
      and x.secondary_status='pending'),0),
   'position_requests', nullif((select count(*) from public.position_change_requests r where r.pelada_id=p.id and r.status='pending'),0),
   'billing_pending', case when pm.role='admin' then nullif((select count(*) from public.pelada_memberships x
      where x.pelada_id=p.id and x.status='active' and x.billing_class='pending'),0) end,
   'votes_suspended', nullif((select count(*) from private.rating_vote_suspensions s join public.rating_vote_sessions v on v.id=s.session_id
      where v.pelada_id=p.id and s.resolved_at is null),0))) x
  from public.pelada_memberships pm join public.peladas p on p.id=pm.pelada_id
  where pm.user_id=auth.uid() and pm.status='active' and pm.role in ('admin','assistant')) t(x)
 where (select count(*) from jsonb_object_keys(x)) > 2;
$$;

---------------------------------------------------------------------------------------------------
-- REV-006: criação de pelada em etapas
---------------------------------------------------------------------------------------------------
alter table public.peladas
 add column location text check (location is null or length(btrim(location)) between 1 and 120),
 add column default_team_a_name text check (default_team_a_name is null or length(btrim(default_team_a_name)) between 1 and 40),
 add column default_team_b_name text check (default_team_b_name is null or length(btrim(default_team_b_name)) between 1 and 40),
 add column default_team_a_color text check (default_team_a_color is null or default_team_a_color in ('azul','branco','preto','vermelho','amarelo','laranja','roxo','rosa')),
 add column default_team_b_color text check (default_team_b_color is null or default_team_b_color in ('azul','branco','preto','vermelho','amarelo','laranja','roxo','rosa')),
 add constraint peladas_default_colors_differ check (default_team_a_color is null or default_team_b_color is null or default_team_a_color <> default_team_b_color);

create table private.pelada_create_requests (
 user_id uuid not null,
 request_id uuid not null,
 pelada_id uuid not null references public.peladas(id),
 created_at timestamptz not null default now(),
 primary key (user_id, request_id)
);

-- p: {name, position, location, team_a_name, team_b_name, team_a_color, team_b_color, weekday, time,
--     voting_duration_minutes, minimum_numeric_ratings, cards_tracking, bola_murcha_enabled}
-- Recursos Premium pedidos sem Premium são ignorados no servidor (não confiar na tela).
create function public.create_pelada_wizard(p jsonb, p_request_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_id uuid; v_wd smallint; v_time time; v_dur integer; v_min integer;
begin
 if v_user is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 if p_request_id is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
 perform pg_advisory_xact_lock(hashtextextended('create_pelada:' || v_user::text, 0));
 select pelada_id into v_id from private.pelada_create_requests where user_id=v_user and request_id=p_request_id;
 if found then return v_id; end if;
 v_wd := nullif(p->>'weekday','')::smallint;
 if v_wd is not null and v_wd not between 0 and 6 then raise exception 'INVALID_VALUE'; end if;
 v_time := nullif(p->>'time','')::time;
 v_dur := coalesce(nullif(p->>'voting_duration_minutes','')::integer, 240);
 if v_dur not in (120,240,360) then raise exception 'INVALID_VOTING_DURATION'; end if;
 v_min := nullif(p->>'minimum_numeric_ratings','')::integer;
 if v_min is not null and v_min not between 1 and 99 then raise exception 'INVALID_MINIMUM_RATINGS'; end if;
 v_id := public.create_pelada(p->>'name', p->>'position', null);
 update public.peladas set location=nullif(btrim(p->>'location'),''),
  default_team_a_name=nullif(btrim(p->>'team_a_name'),''), default_team_b_name=nullif(btrim(p->>'team_b_name'),''),
  default_team_a_color=nullif(p->>'team_a_color',''), default_team_b_color=nullif(p->>'team_b_color',''),
  recurring_weekday=v_wd, recurring_time=v_time
 where id=v_id;
 update public.pelada_settings set voting_duration_minutes=v_dur, minimum_numeric_ratings=v_min,
  cards_tracking=coalesce((p->>'cards_tracking')::boolean, false),
  bola_murcha_enabled=case when private.pelada_has_premium(v_id) then coalesce((p->>'bola_murcha_enabled')::boolean, true) else bola_murcha_enabled end,
  team_names_customized=(nullif(btrim(p->>'team_a_name'),'') is not null or nullif(btrim(p->>'team_b_name'),'') is not null)
 where pelada_id=v_id;
 insert into private.pelada_create_requests(user_id,request_id,pelada_id) values(v_user,p_request_id,v_id);
 return v_id;
end $$;

-- Times/cores/local editáveis depois (Configurações > Times / Identidade).
create function public.update_pelada_identity(p_pelada uuid, p jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if not private.is_active_admin(p_pelada) then raise exception 'ADMIN_REQUIRED' using errcode='42501'; end if;
 update public.peladas set location=case when p ? 'location' then nullif(btrim(p->>'location'),'') else location end,
  default_team_a_name=case when p ? 'team_a_name' then nullif(btrim(p->>'team_a_name'),'') else default_team_a_name end,
  default_team_b_name=case when p ? 'team_b_name' then nullif(btrim(p->>'team_b_name'),'') else default_team_b_name end,
  default_team_a_color=case when p ? 'team_a_color' then nullif(p->>'team_a_color','') else default_team_a_color end,
  default_team_b_color=case when p ? 'team_b_color' then nullif(p->>'team_b_color','') else default_team_b_color end,
  recurring_weekday=case when p ? 'weekday' then nullif(p->>'weekday','')::smallint else recurring_weekday end,
  recurring_time=case when p ? 'time' then nullif(p->>'time','')::time else recurring_time end
 where id=p_pelada;
 insert into private.audit_events(pelada_id,actor_user_id,event_type) values(p_pelada,auth.uid(),'pelada_identity_updated');
end $$;

---------------------------------------------------------------------------------------------------
-- Permissões
---------------------------------------------------------------------------------------------------
revoke all on function private.is_member_active_on(uuid,date), private.membership_period_track(),
 private.membership_billing_default(), private.global_sticker_values(uuid), private.reconcile_global_stickers(uuid),
 private.on_sticker_progress_changed(), private.season_consolidation(uuid) from public, anon, authenticated;

revoke all on function public.cancel_match(uuid,text), public.reschedule_match(uuid,timestamptz),
 public.get_match_schedule_history(uuid), public.classify_member_billing(uuid,boolean,integer,integer),
 public.set_default_monthly_amount(uuid,integer), public.get_member_finance_statement(uuid),
 public.register_payments_batch(uuid,jsonb,date,text,uuid), public.set_match_secondary_played(uuid,uuid,boolean),
 public.set_match_temp_goalkeeper(uuid,uuid,boolean), public.submit_keeper_saves_claim(uuid,integer),
 public.review_keeper_saves_claim(uuid,integer), public.get_my_global_album(), public.get_season_consolidation(uuid),
 public.get_season_retrospective_official(uuid), public.get_my_admin_pending(), public.create_pelada_wizard(jsonb,uuid),
 public.update_pelada_identity(uuid,jsonb) from public, anon;
grant execute on function public.cancel_match(uuid,text), public.reschedule_match(uuid,timestamptz),
 public.get_match_schedule_history(uuid), public.classify_member_billing(uuid,boolean,integer,integer),
 public.set_default_monthly_amount(uuid,integer), public.get_member_finance_statement(uuid),
 public.register_payments_batch(uuid,jsonb,date,text,uuid), public.set_match_secondary_played(uuid,uuid,boolean),
 public.set_match_temp_goalkeeper(uuid,uuid,boolean), public.submit_keeper_saves_claim(uuid,integer),
 public.review_keeper_saves_claim(uuid,integer), public.get_my_global_album(), public.get_season_consolidation(uuid),
 public.get_season_retrospective_official(uuid), public.get_my_admin_pending(), public.create_pelada_wizard(jsonb,uuid),
 public.update_pelada_identity(uuid,jsonb) to authenticated;

---------------------------------------------------------------------------------------------------
-- REV-001: Artilheiro do Mês na Sala de Troféus e na Minha Carreira
-- O prêmio já é concedido em close_month (049/056): mês da partida, gols oficiais, empate compartilhado, mínimo 1 gol,
-- sem duplicar em recálculos. Aqui ele só passa a ser contado e listado (mesma regra de temporadas visíveis).
---------------------------------------------------------------------------------------------------
alter function public.get_player_career_summary(uuid) rename to get_player_career_summary_v77;
alter function public.get_player_career_summary_v77(uuid) set schema private;
create function public.get_player_career_summary(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := private.get_player_career_summary_v77(p_user); v_peladas jsonb;
begin
 if not coalesce((v->>'visible')::boolean, false) then return v; end if;
 select coalesce(jsonb_agg(e || jsonb_build_object('trophies', (e->'trophies') || jsonb_build_object('top_scorer',
   (select count(*) from public.awards a where a.membership_id=(e->>'membership_id')::uuid and a.status='active'
     and a.award_type='top_scorer' and a.season_id = any(array(select private.career_seasons((e->>'pelada_id')::uuid))))))
   order by o), '[]'::jsonb)
 into v_peladas from jsonb_array_elements(v->'peladas') with ordinality q(e, o);
 return v || jsonb_build_object('peladas', v_peladas,
  'trophies', (v->'trophies') || jsonb_build_object('top_scorer',
   (select coalesce(sum((e->'trophies'->>'top_scorer')::int),0) from jsonb_array_elements(v_peladas) e)));
end $$;

alter function public.get_trophy_history(uuid,text,jsonb,integer) rename to get_trophy_history_v77;
alter function public.get_trophy_history_v77(uuid,text,jsonb,integer) set schema private;
create function public.get_trophy_history(p_user uuid, p_type text, p_after jsonb default null, p_limit integer default 20)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_level text; v_lim integer := private.page_limit(p_limit, 20, 50); a_at date; a_id uuid; v_items jsonb; v_n integer;
begin
 if p_type is distinct from 'top_scorer' then return private.get_trophy_history_v77(p_user, p_type, p_after, p_limit); end if;
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select career_visibility into v_level from public.profiles where id = p_user;
 if not found or not private.can_view_global(p_user, v_level) then return jsonb_build_object('visible', false); end if;
 if p_after is not null then
  begin a_at := (p_after->>'at')::date; a_id := (p_after->>'id')::uuid;
  exception when others then raise exception 'INVALID_CURSOR'; end;
 end if;
 select coalesce(jsonb_agg(x order by (x->>'period_month') desc, x->>'id' desc), '[]'::jsonb) into v_items from (
  select jsonb_build_object('id',a.id,'period_month',a.period_month,'is_shared',a.is_shared,'pelada_id',m.pelada_id,
   'pelada_name',p.name,'crest_path',p.crest_path,'season_name',s.name) x
  from public.pelada_memberships m join public.peladas p on p.id=m.pelada_id
  join public.awards a on a.membership_id=m.id join public.seasons s on s.id=a.season_id
  where m.user_id=p_user and m.status in ('active','left') and a.status='active' and a.award_type='top_scorer'
   and a.season_id = any(array(select private.career_seasons(m.pelada_id)))
   and (a_id is null or (a.period_month, a.id) < (a_at, a_id))
  order by a.period_month desc, a.id desc limit v_lim + 1) t;
 v_n := jsonb_array_length(v_items);
 return jsonb_build_object('visible', true,
  'items', case when v_n > v_lim then v_items - v_lim else v_items end,
  'next', case when v_n > v_lim then jsonb_build_object('at', v_items->(v_lim-1)->>'period_month', 'id', v_items->(v_lim-1)->>'id') end);
end $$;

revoke all on function private.get_player_career_summary_v77(uuid), private.get_trophy_history_v77(uuid,text,jsonb,integer)
 from public, anon, authenticated;
revoke all on function public.get_player_career_summary(uuid), public.get_trophy_history(uuid,text,jsonb,integer) from public, anon;
grant execute on function public.get_player_career_summary(uuid), public.get_trophy_history(uuid,text,jsonb,integer) to authenticated;

---------------------------------------------------------------------------------------------------
-- REV-003 / REV-047: histórico da carreira com cartões e indicação de participação encerrada
---------------------------------------------------------------------------------------------------
alter function public.get_my_match_history(uuid,jsonb,integer) rename to get_my_match_history_v45;
alter function public.get_my_match_history_v45(uuid,jsonb,integer) set schema private;
create function public.get_my_match_history(p_pelada uuid default null, p_after jsonb default null, p_limit integer default 20)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := private.get_my_match_history_v45(p_pelada, p_after, p_limit);
begin
 return v || jsonb_build_object('items', coalesce((select jsonb_agg(i || (
   select jsonb_build_object(
    'yellow_cards', coalesce(sum(e.quantity) filter (where e.event_type='yellow_card'),0),
    'red_cards', coalesce(sum(e.quantity) filter (where e.event_type in ('red_card','second_yellow')),0),
    'pelada_active', bool_or(pm.status='active'))
   from public.match_participants x join public.pelada_memberships pm on pm.id=x.membership_id and pm.user_id=auth.uid()
   left join public.match_events e on e.participant_id=x.id
   where x.match_id=(i->>'match_id')::uuid) order by o)
  from jsonb_array_elements(v->'items') with ordinality q(i, o)), '[]'::jsonb));
end $$;
revoke all on function private.get_my_match_history_v45(uuid,jsonb,integer) from public, anon, authenticated;
revoke all on function public.get_my_match_history(uuid,jsonb,integer) from public, anon;
grant execute on function public.get_my_match_history(uuid,jsonb,integer) to authenticated;
