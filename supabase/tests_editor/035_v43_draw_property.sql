-- V4.3 (migração 040, algoritmo 2): teste de propriedade do sorteio com as dez posições.
-- 2.400 sorteios aleatórios (2 a 30 jogadores, dez posições, grupos legados, sem posição, overall variado):
--   |posição A - posição B| <= 1 para cada posição; |total A - total B| <= 1; cada jogador exatamente uma vez;
--   exatamente dois goleiros => um em cada time; quatro => 2 x 2.
-- 150 sequências independentes (3 a 6 rodadas): nenhuma composição repetida quando há alternativa conhecida
-- (12+ jogadores com posições variadas) e todas as rodadas válidas.
-- Cole no SQL Editor do Supabase DEV. Termina SEMPRE com o erro proposital "PASS: 035_v43_draw_property".
do $test$
declare
 v_pos text[]; v_ov numeric[]; v_mem uuid[]; v_t text[]; v_n int; v_fail int := 0; v_gk2 int := 0; v_gk4 int := 0; v_legacy int := 0;
 v_keys text[]; v_rep int := 0; v_seq int := 0; v_rounds int; v_rule_fail int := 0; v_pool text[] :=
  array['GOL','ZAG','LD','LE','VOL','MEI','CA','PD','PE','ATA','defender','midfielder','attacker',null];
 v_once int := 0;
begin
for v_trial in 1..2400 loop
 v_n := 2 + floor(random()*29)::int;
 -- distribuições variadas: às vezes concentradas em poucas posições, às vezes espalhadas
 v_pos := array(select v_pool[1 + floor(random()*(case v_trial % 4 when 0 then 14 when 1 then 10 when 2 then 4 else 13 end))::int]
                from generate_series(1,v_n));
 v_ov := array(select round((random()*60 + 30)::numeric, 2) from generate_series(1,v_n));
 v_mem := array(select gen_random_uuid() from generate_series(1,v_n));
 v_t := private.draw_split_v2(v_pos, v_ov, v_mem, 'prop43-'||v_trial, 8, '{}');
 if not (cardinality(v_t)=v_n and private.draw_balanced(v_pos, v_t)) then v_fail := v_fail + 1; end if;
 -- cada jogador uma vez: uma entrada por jogador, só A ou B
 if (select count(*) from unnest(v_t) t where t in ('A','B')) <> v_n then v_fail := v_fail + 1; else v_once := v_once + 1; end if;
 -- verificação independente, posição por posição
 if exists(select 1 from (select coalesce(p,'none') p, t from unnest(v_pos, v_t) x(p,t)) y group by p
   having abs(count(*) filter (where t='A') - count(*) filter (where t='B')) > 1)
  or abs((select count(*) from unnest(v_t) t where t='A') - (select count(*) from unnest(v_t) t where t='B')) > 1 then
  v_rule_fail := v_rule_fail + 1; end if;
 if (select count(*) from unnest(v_pos) p where p='GOL')=2 then
  v_gk2 := v_gk2 + 1;
  if (select count(*) from unnest(v_pos, v_t) x(p,t) where p='GOL' and t='A') <> 1 then v_fail := v_fail + 1; end if;
 end if;
 if (select count(*) from unnest(v_pos) p where p='GOL')=4 then
  v_gk4 := v_gk4 + 1;
  if (select count(*) from unnest(v_pos, v_t) x(p,t) where p='GOL' and t='A') <> 2 then v_fail := v_fail + 1; end if;
 end if;
 if exists(select 1 from unnest(v_pos) p where p in ('defender','midfielder','attacker')) then v_legacy := v_legacy + 1; end if;
end loop;
if v_fail > 0 or v_rule_fail > 0 then
 raise exception 'FALHOU: propriedade violada (% pela função, % pela conferência independente) em 2400 sorteios', v_fail, v_rule_fail;
end if;
if v_gk2 < 20 or v_legacy < 500 or v_once <> 2400 then
 raise exception 'FALHOU: cobertura insuficiente (2 goleiros: %, com legados: %)', v_gk2, v_legacy;
end if;

-- Sequências independentes: com 12 a 24 jogadores de posições variadas há muitas divisões válidas.
for v_s in 1..150 loop
 v_n := 12 + floor(random()*13)::int;
 v_pos := array(select v_pool[1 + floor(random()*13)::int] from generate_series(1,v_n));
 v_ov := array(select round((random()*60 + 30)::numeric, 2) from generate_series(1,v_n));
 v_mem := array(select gen_random_uuid() from generate_series(1,v_n));
 v_rounds := 3 + floor(random()*4)::int;
 v_keys := '{}';
 for r in 1..v_rounds loop
  v_t := private.draw_split_v2(v_pos, v_ov, v_mem, 'seq-'||v_s||':'||r, 60, v_keys);
  if not private.draw_balanced(v_pos, v_t) then v_fail := v_fail + 1; end if;
  if private.draw_canon(v_mem, v_t) = any(v_keys) then v_rep := v_rep + 1; end if;
  v_keys := v_keys || private.draw_canon(v_mem, v_t);
 end loop;
 v_seq := v_seq + 1;
end loop;
if v_fail > 0 then raise exception 'FALHOU: rodada independente inválida (%)', v_fail; end if;
if v_rep > 0 then raise exception 'FALHOU: % composições repetidas em 150 sequências com alternativas', v_rep; end if;

-- Times invertidos são a mesma composição.
v_mem := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
if private.draw_canon(v_mem, array['A','B','A','B']) <> private.draw_canon(v_mem, array['B','A','B','A']) then
 raise exception 'FALHOU: inversão deveria ser a mesma composição'; end if;
-- A conferência reprova divisões inválidas com as dez posições.
if private.draw_balanced(array['ZAG','ZAG','ZAG','LD'], array['A','A','A','B']) then raise exception 'FALHOU: 3 ZAG x 0'; end if;
if private.draw_balanced(array['ZAG','ZAG','LD','LD'], array['A','A','B','B']) then raise exception 'FALHOU: ZAG 2x0 e LD 0x2 (não se compensam)'; end if;
if not private.draw_balanced(array['ZAG','ZAG','ZAG','LD','LD'], array['A','B','A','B','A']) then raise exception 'FALHOU: 3 ZAG 2x1 e 2 LD 1x1 é válido'; end if;
if private.draw_balanced(array['GOL','GOL','MEI','MEI'], array['A','A','B','B']) then raise exception 'FALHOU: dois goleiros juntos'; end if;

raise exception 'PASS: 035_v43_draw_property (2400 sorteios: % com 2 goleiros, % com 4, % com legados; % sequências independentes sem repetição)',
 v_gk2, v_gk4, v_legacy, v_seq;
end $test$;
