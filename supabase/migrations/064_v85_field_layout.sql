-- Minuto 91 / 064: V8.5 — campo ilustrativo com rascunho e publicação (REV-53/54/59..64) e pacote de compartilhamento
-- (REV-50/52/57/60/65, LAC-05/06).
--
--  * O campo é só ilustração: posição no desenho não muda equipe, posição oficial, OVR, presença nem estatística
--    (REV-54); fora do desenho = área neutra, não é reserva (REV-53). Coordenadas em % (x,y de −15 a 115).
--  * Um rascunho por composição e por responsável (REV-62), versionado (REV-61). Publicar exige a mesma versão da
--    composição em que o rascunho foi feito; se a composição mudou, as posições compatíveis ficam e o resto pede
--    revisão (REV-63). Se outro administrador publicou antes, a publicação pede atualização (sem trava permanente).
--  * Jogadores veem só a disposição publicada vigente.
--  * get_share_payload: tudo o que as duas imagens precisam, de UMA versão oficial (composição + campo publicado),
--    com um carimbo de integridade; o app só libera o arquivo se o carimbo e a lista conferirem (REV-65/LAC-06).

create table public.composition_field_layouts (
 id uuid primary key default gen_random_uuid(),
 composition_id uuid not null references public.team_compositions(id) on delete cascade,
 kind text not null check (kind in ('draft','published')),
 owner_user_id uuid references public.profiles(id) on delete cascade, -- rascunho: responsável
 base_composition_version integer not null,
 version integer not null default 1,     -- rascunho: controle otimista
 published_seq integer,                  -- publicada: sequência (1, 2, ...)
 positions jsonb not null default '{}'::jsonb, -- {pid: {"x": n, "y": n}}
 formation_a text check (formation_a in ('4-3-3','4-4-2')),
 formation_b text check (formation_b in ('4-3-3','4-4-2')),
 status text not null default 'active' check (status in ('active','superseded')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create unique index field_layout_one_draft on public.composition_field_layouts(composition_id, owner_user_id) where kind='draft';
create unique index field_layout_one_published on public.composition_field_layouts(composition_id) where kind='published' and status='active';
alter table public.composition_field_layouts enable row level security;
revoke all on public.composition_field_layouts from anon, authenticated;

create function private.v85_valid_positions(p jsonb) returns boolean
language sql immutable set search_path = '' as $$
 select jsonb_typeof(p) = 'object' and not exists(select 1 from jsonb_each(p) e
  where private.try_uuid(e.key) is null or jsonb_typeof(e.value) <> 'object'
   or jsonb_typeof(e.value->'x') <> 'number' or jsonb_typeof(e.value->'y') <> 'number'
   or (e.value->>'x')::numeric not between -15 and 115 or (e.value->>'y')::numeric not between -15 and 115);
$$;

-- Mantém só jogadores ainda presentes na composição vigente (REV-63: posições compatíveis preservadas).
create function private.v85_compatible_positions(p_comp uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) from jsonb_each(coalesce(p,'{}')) e
 where exists(select 1 from public.team_composition_members m where m.composition_id=p_comp and m.version_to is null and m.pid::text=e.key);
$$;

create function private.v85_layout_json(p_layout public.composition_field_layouts, p_comp public.team_compositions) returns jsonb
language sql stable security definer set search_path = '' as $$
 select case when p_layout.id is null then null else jsonb_build_object('id', p_layout.id, 'kind', p_layout.kind,
  'version', p_layout.version, 'published_seq', p_layout.published_seq, 'base_composition_version', p_layout.base_composition_version,
  'needs_review', p_layout.base_composition_version <> p_comp.version,
  'positions', private.v85_compatible_positions(p_comp.id, p_layout.positions),
  'missing', (select coalesce(jsonb_agg(m.pid), '[]'::jsonb) from public.team_composition_members m
    where m.composition_id=p_comp.id and m.version_to is null and not (p_layout.positions ? m.pid::text)),
  'formation_a', p_layout.formation_a, 'formation_b', p_layout.formation_b, 'updated_at', p_layout.updated_at) end;
$$;

create function public.get_field_layout(p_comp uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v public.team_compositions; v_pub public.composition_field_layouts; v_draft public.composition_field_layouts; v_staff boolean;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v from public.team_compositions where id=p_comp;
 if not found or not private.is_active_member(v.pelada_id) or v.status <> 'active' then raise exception 'COMPOSITION_NOT_FOUND'; end if;
 v_staff := private.is_active_staff(v.pelada_id);
 select * into v_pub from public.composition_field_layouts where composition_id=p_comp and kind='published' and status='active';
 if v_staff then select * into v_draft from public.composition_field_layouts where composition_id=p_comp and kind='draft' and owner_user_id=auth.uid(); end if;
 return jsonb_build_object('composition_id', p_comp, 'composition_version', v.version,
  'published', private.v85_layout_json(v_pub, v), 'draft', case when v_staff then private.v85_layout_json(v_draft, v) end);
end $$;

create function public.save_field_draft(p_comp uuid, p_expected integer, p_positions jsonb, p_formation_a text default null,
 p_formation_b text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.team_compositions; v_d public.composition_field_layouts;
begin
 select * into v from public.team_compositions where id=p_comp;
 if not found then raise exception 'COMPOSITION_NOT_FOUND'; end if;
 perform private.require_draw_staff(v.pelada_id);
 if v.status <> 'active' then raise exception 'COMPOSITION_NOT_ACTIVE'; end if;
 if not private.v85_valid_positions(p_positions) then raise exception 'FIELD_LAYOUT_INVALID'; end if;
 select * into v_d from public.composition_field_layouts where composition_id=p_comp and kind='draft' and owner_user_id=auth.uid() for update;
 if found then
  if p_expected is null or p_expected <> v_d.version then raise exception 'VERSION_CONFLICT'; end if;
  update public.composition_field_layouts set positions=private.v85_compatible_positions(p_comp, p_positions),
   formation_a=p_formation_a, formation_b=p_formation_b, base_composition_version=v.version, version=version+1, updated_at=now()
  where id=v_d.id returning * into v_d;
 else
  insert into public.composition_field_layouts(composition_id,kind,owner_user_id,base_composition_version,positions,formation_a,formation_b)
  values(p_comp,'draft',auth.uid(),v.version,private.v85_compatible_positions(p_comp, p_positions),p_formation_a,p_formation_b) returning * into v_d;
 end if;
 return private.v85_layout_json(v_d, v);
end $$;

-- Publica o rascunho do responsável. p_expected_seq: sequência publicada que ele viu (null = nenhuma).
create function public.publish_field_layout(p_comp uuid, p_expected_draft integer, p_expected_seq integer, p_request uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.team_compositions; v_d public.composition_field_layouts; v_pub public.composition_field_layouts; v_replay jsonb; v_out jsonb;
begin
 v_replay := private.v85_replay(p_request, 'field_publish'); if v_replay is not null then return v_replay; end if;
 select * into v from public.team_compositions where id=p_comp;
 if not found then raise exception 'COMPOSITION_NOT_FOUND'; end if;
 perform private.require_draw_staff(v.pelada_id);
 select * into v from public.team_compositions where id=p_comp for update;
 select * into v_d from public.composition_field_layouts where composition_id=p_comp and kind='draft' and owner_user_id=auth.uid() for update;
 if not found then raise exception 'LAYOUT_DRAFT_NOT_FOUND'; end if;
 if p_expected_draft is null or v_d.version <> p_expected_draft then raise exception 'VERSION_CONFLICT'; end if;
 if v_d.base_composition_version <> v.version then raise exception 'LAYOUT_NEEDS_REVIEW'; end if; -- REV-63
 select * into v_pub from public.composition_field_layouts where composition_id=p_comp and kind='published' and status='active' for update;
 if (v_pub.id is null and p_expected_seq is not null) or (v_pub.id is not null and v_pub.published_seq is distinct from p_expected_seq) then
  raise exception 'LAYOUT_PUBLISHED_BY_OTHER'; end if; -- REV-61
 update public.composition_field_layouts set status='superseded' where id=v_pub.id;
 insert into public.composition_field_layouts(composition_id,kind,base_composition_version,published_seq,positions,formation_a,formation_b)
 values(p_comp,'published',v.version,coalesce(v_pub.published_seq,0)+1,v_d.positions,v_d.formation_a,v_d.formation_b) returning * into v_pub;
 delete from public.composition_field_layouts where id=v_d.id;
 insert into private.audit_events(pelada_id,actor_user_id,event_type,metadata)
 values(v.pelada_id,auth.uid(),'field_layout_published',jsonb_build_object('composition_id',p_comp,'seq',v_pub.published_seq,'composition_version',v.version));
 v_out := private.v85_layout_json(v_pub, v);
 return private.v85_done(p_request, v.pelada_id, 'field_publish', v_out);
end $$;

-- Pacote das duas imagens (lista integral e campo), de UMA versão oficial. Fotos: só integrante com conta e sem
-- bloqueio (LAC-05); convidado e sem foto → avatar neutro. Nomes: os cadastrados, nunca alterados (REV-70).
create function public.get_share_payload(p_comp uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v public.team_compositions; v_pub public.composition_field_layouts; v_members jsonb; v_stamp text;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
 select * into v from public.team_compositions where id=p_comp;
 if not found or not private.is_active_member(v.pelada_id) or v.status <> 'active' then raise exception 'COMPOSITION_NOT_FOUND'; end if;
 select * into v_pub from public.composition_field_layouts where composition_id=p_comp and kind='published' and status='active';
 v_members := private.v85_composition_json(p_comp, false)->'members';
 v_stamp := md5(p_comp::text || ':' || v.version || ':' || coalesce(v_pub.published_seq,0) || ':' ||
  (select string_agg((x->>'pid') || (x->>'team') || (x->>'captain'), ',' order by x->>'pid') from jsonb_array_elements(v_members) x));
 return jsonb_build_object('composition_id', p_comp, 'pelada_name', (select name from public.peladas where id=v.pelada_id),
  'label', v.label, 'round_number', v.round_number, 'rounds_total', v.rounds_total, 'round_date', v.round_date,
  'team_a_name', v.team_a_name, 'team_b_name', v.team_b_name, 'composition_version', v.version,
  'field_seq', v_pub.published_seq, 'field', case when v_pub.id is not null then private.v85_layout_json(v_pub, v) end,
  'members', v_members, 'count', jsonb_array_length(v_members), 'stamp', v_stamp, 'generated_at', now());
end $$;

revoke all on function private.v85_valid_positions(jsonb), private.v85_compatible_positions(uuid,jsonb),
 private.v85_layout_json(public.composition_field_layouts, public.team_compositions) from public, anon, authenticated;
revoke all on function public.get_field_layout(uuid), public.save_field_draft(uuid,integer,jsonb,text,text),
 public.publish_field_layout(uuid,integer,integer,uuid), public.get_share_payload(uuid) from public, anon;
grant execute on function public.get_field_layout(uuid), public.save_field_draft(uuid,integer,jsonb,text,text),
 public.publish_field_layout(uuid,integer,integer,uuid), public.get_share_payload(uuid) to authenticated;
