-- Minuto 91 / 061: V8.5 — motor de sorteio exato (REV-01..07, 21, 31..35, 42..44; LAC-02).
--
-- Substitui, para NOVOS sorteios, o algoritmo por OVR (039/040, algorithm_version 1 e 2). Sorteios históricos
-- ficam intactos. O motor de notas/OVR V7.7 (050..057) e a calibração V7.5 não são tocados.
--
-- Entrada: um grupo posicional por participante (já individualmente identificado e ordenado pelo chamador) e,
-- opcionalmente, a equipe fixa dos capitães ('A'/'B'). Não há OVR, nota, gol, atributo ou força em lugar nenhum.
--
-- Objetivo (REV-31): minimizar  Σ_g |a_g − b_g|  (a_g/b_g = participantes do grupo g em A/B), sujeito a
-- |A| − |B| ∈ {−1,0,1} (REV-05) e capitães fixos (REV-21). Total ímpar: as duas orientações entram (REV-33).
--
-- Método exato (REV-42):
--  * Programação dinâmica sobre os grupos e o tamanho parcial de A: para cada estado guarda o custo mínimo e a
--    QUANTIDADE EXATA (numeric, precisão ilimitada = BigInt) de composições completas que o atingem, onde
--    escolher x livres de m para A contribui C(m, x) composições distintas de jogadores identificados.
--  * Total de composições ótimas = soma das contagens ótimas nos tamanhos finais permitidos.
--  * Sorteio: um único inteiro r uniforme em [0, total) vindo de gen_random_bytes com rejeição (sem viés de
--    módulo), e r é DECODIFICADO (unranking) numa composição. O decodificador é uma bijeção entre [0, total) e
--    o conjunto de composições ótimas: logo a amostra é exatamente uniforme (REV-32). A bijeção é verificada por
--    força bruta nos testes (LAC-02). Guardar (entrada, r) torna o sorteio auditável e reproduzível (REV-07).
--  * Até 100 participantes (limite rígido); grupos vazios/escassos e desequilíbrio inevitável aceitos (REV-34).
--
-- Grupos (REV-01/02): GOL → ZAG → LD → LE → VOL → MEI → ATA → sem posição; CA/PD/PE/ATA agrupados em ATA.
-- Registros legados só com o setor (Defensor/Meio-campista, sem posição específica) formam grupo próprio
-- (não se inventa posição, 041 §8.5); Atacante legado entra em ATA (o próprio REV-01 agrupa todo o ataque).

create function private.draw_group_key(p text) returns text
language sql immutable set search_path = '' as $$
 select case
  when p is null then 'none'
  when p in ('GOL','goalkeeper') then 'GOL'
  when p in ('ZAG','LD','LE','VOL','MEI') then p
  when p in ('CA','PD','PE','ATA','attacker') then 'ATA'
  when p = 'defender' then 'DEF'
  when p = 'midfielder' then 'MEIO'
  else 'none' end;
$$;

create function private.draw_group_order(p_key text) returns integer
language sql immutable set search_path = '' as $$
 select coalesce(array_position(array['GOL','ZAG','LD','LE','DEF','VOL','MEI','MEIO','ATA','none'], p_key), 99);
$$;

-- Inteiro uniforme em [0, p_bound), sem viés (rejeição), a partir de gen_random_bytes.
create function private.secure_below(p_bound numeric) returns numeric
language plpgsql volatile set search_path = '' as $$
declare k integer := 1; space numeric := 256; lim numeric; v numeric; b bytea; i integer;
begin
 if p_bound is null or p_bound < 1 or p_bound <> trunc(p_bound) then raise exception 'DRAW_INVALID_BOUND'; end if;
 if p_bound = 1 then return 0; end if;
 while space < p_bound * 256 loop k := k + 1; space := space * 256; end loop; -- folga de 1 byte: rejeição < 1/256
 lim := space - mod(space, p_bound);
 loop
  b := extensions.gen_random_bytes(k); v := 0;
  for i in 0..k-1 loop v := v * 256 + get_byte(b, i); end loop;
  if v < lim then return mod(v, p_bound); end if;
 end loop;
end $$;

-- Núcleo: resolve (p_rank null → só custo e contagem) ou decodifica a composição de índice p_rank.
-- p_group[i]: grupo do participante i; p_fixed[i]: 'A' | 'B' | null. Saída em jsonb:
--  {cost, count, sizes:[tamanhos de A permitidos], teams:[...] (só com p_rank)}.
create function private.draw_solve(p_group text[], p_fixed text[], p_rank numeric default null) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare
 n integer := coalesce(cardinality(p_group), 0); keys text[]; gcount integer; w integer;
 gn integer[]; gfa integer[]; gfb integer[]; gm integer[];
 fact numeric[]; cost integer[]; cnt numeric[]; g integer; s integer; sp integer; x integer; a integer; c integer;
 wgt numeric; idx integer; best integer; total numeric := 0; sizes integer[]; sz integer; r numeric; blk numeric;
 ch numeric; t numeric; k integer; j integer; free integer[]; teams text[]; chosen_s integer; fa integer := 0; fb integer := 0;
begin
 if n < 2 then raise exception 'DRAW_TOO_FEW_PLAYERS'; end if;
 if n > 100 then raise exception 'DRAW_TOO_MANY_PLAYERS'; end if;
 if cardinality(coalesce(p_fixed, '{}')) not in (0, n) then raise exception 'DRAW_INVALID_INPUT'; end if;
 if exists(select 1 from unnest(p_group) q where q is null) then raise exception 'DRAW_INVALID_INPUT'; end if;
 if exists(select 1 from unnest(coalesce(p_fixed,'{}')) f where f is not null and f not in ('A','B')) then
  raise exception 'DRAW_INVALID_INPUT'; end if;
 keys := array(select q from (select distinct q from unnest(p_group) q) z order by private.draw_group_order(q), q);
 gcount := cardinality(keys); w := n + 1;
 gn := array_fill(0, array[gcount]); gfa := gn; gfb := gn;
 for j in 1..n loop
  g := array_position(keys, p_group[j]); gn[g] := gn[g] + 1;
  if p_fixed is not null and p_fixed[j] = 'A' then gfa[g] := gfa[g] + 1; fa := fa + 1;
  elsif p_fixed is not null and p_fixed[j] = 'B' then gfb[g] := gfb[g] + 1; fb := fb + 1; end if;
 end loop;
 gm := array(select gn[q] - gfa[q] - gfb[q] from generate_subscripts(gn, 1) q);
 fact := array_fill(1::numeric, array[n + 1]); -- fact[k+1] = k!
 for j in 1..n loop fact[j + 1] := fact[j] * j; end loop;

 -- cost/cnt planos: índice g*w + s + 1, g = 0..gcount, s = 0..n. null = inalcançável.
 cost := array_fill(null::integer, array[(gcount + 1) * w]); cnt := array_fill(null::numeric, array[(gcount + 1) * w]);
 cost[1] := 0; cnt[1] := 1;
 for g in 1..gcount loop
  for sp in 0..n loop
   continue when cnt[(g-1)*w + sp + 1] is null;
   for x in 0..gm[g] loop
    a := gfa[g] + x; s := sp + a; exit when s > n;
    c := cost[(g-1)*w + sp + 1] + abs(2*a - gn[g]);
    wgt := cnt[(g-1)*w + sp + 1] * div(fact[gm[g]+1], fact[x+1] * fact[gm[g]-x+1]);
    idx := g*w + s + 1;
    if cost[idx] is null or c < cost[idx] then cost[idx] := c; cnt[idx] := wgt;
    elsif c = cost[idx] then cnt[idx] := cnt[idx] + wgt; end if;
   end loop;
  end loop;
 end loop;

 sizes := array(select distinct q from unnest(array[n / 2, (n + 1) / 2]) q order by q);
 select min(cost[gcount*w + q + 1]) into best from unnest(sizes) q;
 if best is null then raise exception 'DRAW_INFEASIBLE'; end if; -- ex.: capitães impossíveis
 sizes := array(select q from unnest(sizes) q where cost[gcount*w + q + 1] = best order by q);
 select sum(cnt[gcount*w + q + 1]) into total from unnest(sizes) q;
 if p_rank is null then
  return jsonb_build_object('cost', best, 'count', total::text, 'sizes', to_jsonb(sizes), 'groups', to_jsonb(keys));
 end if;
 if p_rank < 0 or p_rank >= total or p_rank <> trunc(p_rank) then raise exception 'DRAW_INVALID_RANK'; end if;

 -- Decodificação (bijeção [0,total) → composições ótimas).
 r := p_rank;
 foreach sz in array sizes loop
  if r < cnt[gcount*w + sz + 1] then chosen_s := sz; exit; end if;
  r := r - cnt[gcount*w + sz + 1];
 end loop;
 teams := array_fill(null::text, array[n]);
 s := chosen_s;
 for g in reverse gcount..1 loop
  for x in 0..gm[g] loop
   a := gfa[g] + x; sp := s - a;
   continue when sp < 0 or cnt[(g-1)*w + sp + 1] is null
    or cost[(g-1)*w + sp + 1] + abs(2*a - gn[g]) <> cost[g*w + s + 1];
   ch := div(fact[gm[g]+1], fact[x+1] * fact[gm[g]-x+1]);
   blk := cnt[(g-1)*w + sp + 1] * ch;
   if r < blk then
    t := mod(r, ch); r := div(r, ch);
    -- t-ésimo subconjunto (ordem lexicográfica) de tamanho x dos livres do grupo, na ordem da entrada.
    free := array(select q from generate_subscripts(p_group, 1) q
                  where p_group[q] = keys[g] and (p_fixed is null or p_fixed[q] is null) order by q);
    k := x;
    for j in 1..gm[g] loop
     if k = 0 then teams[free[j]] := 'B'; continue; end if;
     ch := div(fact[gm[g]-j+1], fact[k-1+1] * fact[gm[g]-j-(k-1)+1]); -- C(m−j, k−1)
     if t < ch then teams[free[j]] := 'A'; k := k - 1; else t := t - ch; teams[free[j]] := 'B'; end if;
    end loop;
    s := sp; exit;
   end if;
   r := r - blk;
  end loop;
 end loop;
 for j in 1..n loop if p_fixed is not null and p_fixed[j] is not null then teams[j] := p_fixed[j]; end if; end loop;
 if s <> 0 or exists(select 1 from unnest(teams) q where q is null) then raise exception 'DRAW_DECODE_FAILED'; end if;
 return jsonb_build_object('cost', best, 'count', total::text, 'sizes', to_jsonb(sizes), 'groups', to_jsonb(keys),
  'rank', p_rank::text, 'teams', to_jsonb(teams));
end $$;

-- Sorteio: custo/contagem exatos, índice uniforme seguro e composição decodificada.
create function private.draw_sample(p_group text[], p_fixed text[]) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare v jsonb;
begin
 v := private.draw_solve(p_group, p_fixed, null);
 return private.draw_solve(p_group, p_fixed, private.secure_below((v->>'count')::numeric));
end $$;

-- Custo de uma composição qualquer (verificação independente e resumo REV-46/47).
create function private.draw_cost(p_group text[], p_team text[]) returns integer
language sql immutable set search_path = '' as $$
 select coalesce(sum(abs(a - b)), 0)::integer from (
  select count(*) filter (where t = 'A') a, count(*) filter (where t = 'B') b
  from unnest(p_group, p_team) x(g, t) group by g) q;
$$;

revoke all on function private.draw_group_key(text), private.draw_group_order(text), private.secure_below(numeric),
 private.draw_solve(text[],text[],numeric), private.draw_sample(text[],text[]), private.draw_cost(text[],text[])
 from public, anon, authenticated;
