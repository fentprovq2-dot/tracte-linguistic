-- Càrrega de llocs des d'un client autoritzat (p. ex. el navegador de l'administrador),
-- per quan la Edge Function no pot accedir a Overpass. Requereix la clau d'administració.
create or replace function public.carrega_llocs(p_clau text, p_files jsonb)
returns int
language plpgsql volatile security definer
set search_path = ''
as $$
declare n int;
begin
  if p_clau is null or p_clau <> (select valor from public.admin_config where clau = 'carrega_clau') then
    raise exception 'No autoritzat' using errcode = '42501';
  end if;
  if jsonb_array_length(p_files) > 2000 then
    raise exception 'Massa files en un sol lot' using errcode = '22023';
  end if;

  insert into public.llocs (nom, modalitat, categoria, municipi, adreca, lat, lon, font, font_id)
  select left(f->>'nom', 120), (f->>'modalitat')::public.modalitat, f->>'categoria',
         f->>'municipi', f->>'adreca', (f->>'lat')::float8, (f->>'lon')::float8, 'osm', f->>'font_id'
  from jsonb_array_elements(p_files) f
  where f->>'modalitat' in ('presencial', 'servei_public')
  on conflict (font, font_id) do update
    set nom = excluded.nom, modalitat = excluded.modalitat, categoria = excluded.categoria,
        municipi = excluded.municipi, adreca = excluded.adreca, lat = excluded.lat, lon = excluded.lon;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.carrega_llocs from public;
grant execute on function public.carrega_llocs to anon;
