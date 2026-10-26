-- Fitxa d'un lloc concret (per als enllaços directes ?lloc=<id>)
create or replace function public.lloc_per_id(p_id uuid)
returns table (
  id uuid, nom text, modalitat public.modalitat, categoria text, canal public.canal,
  municipi text, adreca text, lat float8, lon float8, font text,
  n int, distribucio int[], qualificacio smallint, dividit boolean, predominant text
)
language sql stable security definer
set search_path = ''
as $$
  select l.id, l.nom, l.modalitat, l.categoria, l.canal, l.municipi, l.adreca, l.lat, l.lon, l.font,
         coalesce(r.n, 0), coalesce(r.dist, array[0,0,0,0,0,0]),
         r.qualificacio, coalesce(r.dividit, false),
         (select e.etiqueta from public.escala e where e.valor = r.qualificacio)
  from public.llocs l
  left join privat.resum_valoracions(array[p_id]) r on r.lloc_id = l.id
  where l.id = p_id and l.actiu
$$;
revoke all on function public.lloc_per_id from public;
grant execute on function public.lloc_per_id to anon, authenticated;
