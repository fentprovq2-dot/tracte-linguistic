-- Llocs a prop d'un punt, amb distància i resum de valoracions.
-- Permet filtrar per qualificació (1–6), incloure o no els llocs sense prou valoracions,
-- i filtrar per sector (categoria).
create or replace function public.llocs_a_prop(
  p_lat        float8,
  p_lon        float8,
  p_radi_m     int default 500,
  p_valors     smallint[] default null,      -- qualificacions a incloure; null = totes
  p_sense_qual boolean default false,        -- incloure llocs amb menys de 3 valoracions
  p_categoria  text default null,
  p_limit      int default 300
)
returns table (
  id uuid, nom text, modalitat public.modalitat, categoria text, canal public.canal,
  municipi text, adreca text, lat float8, lon float8, font text,
  n int, distribucio int[], mitjana numeric, predominant text, qualificacio smallint, distancia_m int
)
language sql stable security definer
set search_path = ''
as $$
  with params as (
    select least(greatest(coalesce(p_radi_m, 500), 50), 5000) as radi
  ),
  base as (
    select l.*, privat.distancia_m(p_lat, p_lon, l.lat, l.lon) as dist
    from public.llocs l, params
    where l.actiu and l.modalitat <> 'no_presencial'
      -- prefiltre ràpid per capsa abans de calcular la distància exacta
      and l.lat between p_lat - params.radi / 111320.0 and p_lat + params.radi / 111320.0
      and l.lon between p_lon - params.radi / (111320.0 * cos(radians(p_lat)))
                    and p_lon + params.radi / (111320.0 * cos(radians(p_lat)))
      and (p_categoria is null or l.categoria = p_categoria)
  ),
  dins as (
    select b.* from base b, params where b.dist <= params.radi
  ),
  agr as (
    select v.lloc_id, count(*)::int as n,
           array[
             count(*) filter (where v.valor = 1), count(*) filter (where v.valor = 2),
             count(*) filter (where v.valor = 3), count(*) filter (where v.valor = 4),
             count(*) filter (where v.valor = 5), count(*) filter (where v.valor = 6)
           ]::int[] as dist,
           round(avg(v.valor), 2) as mitjana
    from public.valoracions v
    where v.lloc_id in (select d.id from dins d)
    group by v.lloc_id
  ),
  res as (
    select d.*, coalesce(a.n, 0) as n_, coalesce(a.dist, array[0,0,0,0,0,0]) as dist_,
           case when a.n >= 3 then a.mitjana end as mitjana_,
           case when a.n >= 3 then round(a.mitjana)::smallint end as qual
    from dins d left join agr a on a.lloc_id = d.id
  )
  select r.id, r.nom, r.modalitat, r.categoria, r.canal, r.municipi, r.adreca, r.lat, r.lon, r.font,
         r.n_, r.dist_, r.mitjana_,
         (select e.etiqueta from public.escala e where e.valor = r.qual),
         r.qual, round(r.dist)::int
  from res r
  where (r.qual is not null and (p_valors is null or r.qual = any (p_valors)))
     or (r.qual is null and p_sense_qual)
  order by r.qual desc nulls last, r.dist
  limit least(greatest(coalesce(p_limit, 300), 1), 1000)
$$;

revoke all on function public.llocs_a_prop from public;
grant execute on function public.llocs_a_prop to anon, authenticated;

-- Sectors disponibles (per al filtre)
create or replace function public.sectors()
returns table (categoria text, n int)
language sql stable security definer
set search_path = ''
as $$
  select categoria, count(*)::int from public.llocs
  where actiu and modalitat <> 'no_presencial'
  group by categoria order by count(*) desc
$$;
revoke all on function public.sectors from public;
grant execute on function public.sectors to anon, authenticated;
