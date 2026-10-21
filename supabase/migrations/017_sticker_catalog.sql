-- Minuto 91 / 017: sticker catalog (Doc 03 sec. 22, Doc 04 sec. 26.1-26.2).
-- 9 collections, 48 stickers (catalog_version 1). Level 6 is "Lendário".
-- The catalog is configurable data (new levels need rows, not columns), readable by
-- every signed-in user, written only by migrations. Stickers cannot be bought.
-- metric_code (career, per pelada; computed in 018):
--  mvp_count            Craque da Partida titles (shared titles count for everyone)
--  goals / assists      official individual goals (no own/unattributed goals) / assists
--  matches_played       matches played, never annulled
--  best_win_streak      longest run of consecutive wins
--  best_unbeaten_streak longest run without a loss
--  high_ratings         matches with displayed final rating >= 8.0
--  monthly_king_count   Rei do Mês titles (shared count for everyone)
--  selection_count      appearances in published Seleções da Rodada

create table public.sticker_collections (
 id uuid primary key default gen_random_uuid(),
 code text not null unique,
 name text not null,
 description text,
 display_order integer not null,
 is_active boolean not null default true
);

create table public.sticker_definitions (
 id uuid primary key default gen_random_uuid(),
 collection_id uuid not null references public.sticker_collections(id),
 code text not null unique,
 name text not null,
 level integer not null check (level between 1 and 6),
 metric_code text not null check (metric_code in ('mvp_count','goals','assists','matches_played',
  'best_win_streak','best_unbeaten_streak','high_ratings','monthly_king_count','selection_count')),
 threshold integer not null check (threshold > 0),
 artwork_path text,
 catalog_version integer not null default 1,
 display_order integer not null,
 is_active boolean not null default true,
 unique (collection_id, level)
);

alter table public.sticker_collections enable row level security;
alter table public.sticker_definitions enable row level security;
revoke all on public.sticker_collections, public.sticker_definitions from anon,authenticated;
grant select on public.sticker_collections, public.sticker_definitions to authenticated;
create policy collections_read on public.sticker_collections for select to authenticated using (true);
create policy definitions_read on public.sticker_definitions for select to authenticated using (true);
-- No client writes.

insert into public.sticker_collections(code,name,description,display_order) values
 ('craque','Craque da Partida','Títulos de Craque da Partida.',1),
 ('artilheiro','Artilheiro','Gols marcados.',2),
 ('garcom','Garçom','Assistências.',3),
 ('presenca','Presença','Partidas disputadas.',4),
 ('pe_quente','Pé Quente','Vitórias consecutivas.',5),
 ('invencivel','Invencível','Partidas seguidas sem perder.',6),
 ('nota_alta','Nota Alta','Partidas com nota 8,0 ou mais.',7),
 ('rei_do_mes','Rei do Mês','Títulos de Rei do Mês.',8),
 ('selecao','Seleção da Rodada','Convocações para a Seleção da Rodada.',9);

-- (collection, prefix of the name, metric, thresholds by level)
with spec(col, label, metric, thresholds) as (values
 ('craque','Craque','mvp_count',array[1,5,10,20,50,100]),
 ('artilheiro','Artilheiro','goals',array[1,10,25,50,100,200]),
 ('garcom','Garçom','assists',array[1,10,25,50,100,200]),
 ('presenca','Presença','matches_played',array[1,10,25,50,100,200]),
 ('pe_quente','Pé Quente','best_win_streak',array[3,5,10,15,20]),
 ('invencivel','Invencível','best_unbeaten_streak',array[5,10,15,20,30]),
 ('nota_alta','Nota Alta','high_ratings',array[1,5,10,20,50]),
 ('rei_do_mes','Rei do Mês','monthly_king_count',array[1,3,5,10]),
 ('selecao','Seleção','selection_count',array[1,5,10,20,50]))
insert into public.sticker_definitions(collection_id,code,name,level,metric_code,threshold,display_order)
select c.id, s.col||'_'||t.threshold,
 s.label||' '||(array['I','II','III','IV','V','Lendário'])[t.level], t.level, s.metric, t.threshold,
 c.display_order*10 + t.level
from spec s join public.sticker_collections c on c.code=s.col
cross join lateral unnest(s.thresholds) with ordinality t(threshold, level);
