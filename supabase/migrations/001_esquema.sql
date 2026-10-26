-- =====================================================================
-- Tracte lingüístic · esquema inicial (prototip, ciutat pilot: Girona)
--
-- Principis:
--  · Es valora EXCLUSIVAMENT el respecte als drets lingüístics,
--    no la qualitat del producte o del servei.
--  · Sense comentaris lliures: només una de les sis categories.
--  · Valoracions anònimes, amb límits per dispositiu i per connexió.
--  · Les taules no són accessibles directament des del navegador:
--    tot passa per funcions (RPC) que apliquen els límits.
-- =====================================================================

create extension if not exists pg_trgm  with schema extensions;
create extension if not exists unaccent with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists privat;
revoke all on schema privat from public, anon, authenticated;

-- unaccent no és IMMUTABLE; aquest embolcall permet fer-lo servir en columnes generades
create or replace function public.normalitza(t text)
returns text language sql immutable parallel safe
set search_path = ''
as $$ select lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(t, ''))) $$;

-- ---------------------------------------------------------------------
-- Escala de valoració (1 = hostil … 6 = idoni)
-- ---------------------------------------------------------------------
create table public.escala (
  valor       smallint primary key check (valor between 1 and 6),
  etiqueta    text not null unique,
  descripcio  text not null
);

insert into public.escala (valor, etiqueta, descripcio) values
 (1, 'hostil',  'Rebuig explícit del català: menyspreu, burla o exigència de canviar de llengua per ser atès.'),
 (2, 'negatiu', 'No m''atenen en català ni l''entenen, i això dificulta o impedeix rebre el servei, sense hostilitat.'),
 (3, 'neutre',  'M''entenen però responen en una altra llengua; puc continuar parlant en català sense cap problema.'),
 (4, 'amable',  'Bona disposició: fan l''esforç de respondre en català o faciliten que m''atengui algú en català.'),
 (5, 'positiu', 'M''atenen en català amb normalitat.'),
 (6, 'idoni',   'Català per defecte en l''atenció i també en retolació, documentació i canals (web, tiquets, carta).');

-- ---------------------------------------------------------------------
-- Llocs i serveis valorables
-- ---------------------------------------------------------------------
create type public.modalitat as enum ('presencial', 'servei_public', 'no_presencial');
create type public.canal     as enum ('telefon', 'web', 'app', 'xat', 'correu', 'altres');

create table public.llocs (
  id         uuid primary key default gen_random_uuid(),
  nom        text not null check (char_length(nom) between 2 and 120),
  modalitat  public.modalitat not null,
  categoria  text not null check (char_length(categoria) between 2 and 60),
  canal      public.canal,
  municipi   text,
  adreca     text,
  lat        double precision check (lat between -90 and 90),
  lon        double precision check (lon between -180 and 180),
  font       text not null default 'usuaris' check (font in ('osm', 'usuaris', 'oficial')),
  font_id    text,
  actiu      boolean not null default true,
  creat_at   timestamptz not null default now(),
  nom_norm   text generated always as (public.normalitza(nom)) stored,
  constraint ubicacio_coherent check (
       (modalitat = 'no_presencial' and lat is null and lon is null and canal is not null)
    or (modalitat <> 'no_presencial' and lat is not null and lon is not null)
  ),
  unique (font, font_id)
);

create index llocs_coords_idx on public.llocs (lat, lon);
create index llocs_nom_trgm_idx on public.llocs using gin (nom_norm extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------
-- Valoracions (mai llegibles des del navegador)
-- Es desen només empremtes (hash) del dispositiu i de la connexió.
-- ---------------------------------------------------------------------
create table public.valoracions (
  id               bigint generated always as identity primary key,
  lloc_id          uuid not null references public.llocs (id) on delete cascade,
  valor            smallint not null references public.escala (valor),
  dispositiu_hash  text not null,
  ip_hash          text not null,
  creat_at         timestamptz not null default now(),
  actualitzat_at   timestamptz not null default now(),
  unique (lloc_id, dispositiu_hash)
);
create index valoracions_lloc_idx on public.valoracions (lloc_id);
create index valoracions_disp_idx on public.valoracions (dispositiu_hash, creat_at);
create index valoracions_ip_idx   on public.valoracions (ip_hash, creat_at);

-- Registre d'altes de llocs proposades per usuaris (per als límits)
create table privat.propostes (
  id               bigint generated always as identity primary key,
  lloc_id          uuid references public.llocs (id) on delete set null,
  dispositiu_hash  text not null,
  ip_hash          text not null,
  creat_at         timestamptz not null default now()
);

-- Sal secreta per a les empremtes (generada un sol cop)
create table privat.config (clau text primary key, valor text not null);
insert into privat.config values ('sal', encode(extensions.gen_random_bytes(32), 'hex'));

-- ---------------------------------------------------------------------
-- Seguretat: RLS activat i cap accés directe
-- ---------------------------------------------------------------------
alter table public.escala      enable row level security;
alter table public.llocs       enable row level security;
alter table public.valoracions enable row level security;

create policy "escala llegible" on public.escala for select to anon, authenticated using (true);
create policy "llocs actius llegibles" on public.llocs for select to anon, authenticated using (actiu);
-- valoracions: cap política → ningú hi accedeix directament

revoke insert, update, delete on public.escala, public.llocs, public.valoracions from anon, authenticated;
revoke select on public.valoracions from anon, authenticated;

-- ---------------------------------------------------------------------
-- Funcions auxiliars privades
-- ---------------------------------------------------------------------
create or replace function privat.empremta(t text)
returns text language sql stable
set search_path = ''
as $$
  select encode(extensions.digest((select valor from privat.config where clau = 'sal') || ':' || t, 'sha256'), 'hex')
$$;

-- Empremta de la connexió a partir de la capçalera que posa la passarel·la de Supabase
create or replace function privat.ip_hash()
returns text language plpgsql stable
set search_path = ''
as $$
declare
  h  json := nullif(current_setting('request.headers', true), '')::json;
  ip text;
begin
  ip := coalesce(
    nullif(split_part(h ->> 'x-forwarded-for', ',', 1), ''),
    h ->> 'cf-connecting-ip',
    'desconeguda');
  return privat.empremta('ip:' || trim(ip));
end $$;

create or replace function privat.distancia_m(lat1 float8, lon1 float8, lat2 float8, lon2 float8)
returns float8 language sql immutable
set search_path = ''
as $$
  select 6371000 * 2 * asin(sqrt(
      power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)))
$$;

-- ---------------------------------------------------------------------
-- RPC: cercar llocs amb el resum de valoracions
-- Les etiquetes només es mostren a partir d'un mínim de valoracions.
-- ---------------------------------------------------------------------
create or replace function public.cerca_llocs(
  p_text       text default null,
  p_modalitat  public.modalitat default null,
  p_min_lat    float8 default null, p_min_lon float8 default null,
  p_max_lat    float8 default null, p_max_lon float8 default null,
  p_limit      int default 400
)
returns table (
  id uuid, nom text, modalitat public.modalitat, categoria text, canal public.canal,
  municipi text, adreca text, lat float8, lon float8, font text,
  n int, distribucio int[], mitjana numeric, predominant text
)
language sql stable security definer
set search_path = ''
as $$
  with base as (
    select l.*
    from public.llocs l
    where l.actiu
      and (p_modalitat is null or l.modalitat = p_modalitat)
      and (p_text is null or btrim(p_text) = ''
           or l.nom_norm operator(extensions.%) public.normalitza(p_text)
           or l.nom_norm like '%' || public.normalitza(p_text) || '%')
      and (p_min_lat is null or l.modalitat = 'no_presencial'
           or (l.lat between p_min_lat and p_max_lat and l.lon between p_min_lon and p_max_lon))
  ),
  agr as (
    select v.lloc_id,
           count(*)::int as n,
           array[
             count(*) filter (where v.valor = 1), count(*) filter (where v.valor = 2),
             count(*) filter (where v.valor = 3), count(*) filter (where v.valor = 4),
             count(*) filter (where v.valor = 5), count(*) filter (where v.valor = 6)
           ]::int[] as dist,
           round(avg(v.valor), 2) as mitjana
    from public.valoracions v
    where v.lloc_id in (select b.id from base b)
    group by v.lloc_id
  )
  select b.id, b.nom, b.modalitat, b.categoria, b.canal, b.municipi, b.adreca, b.lat, b.lon, b.font,
         coalesce(a.n, 0),
         coalesce(a.dist, array[0,0,0,0,0,0]),
         case when a.n >= 3 then a.mitjana end,
         case when a.n >= 3 then (select e.etiqueta from public.escala e where e.valor = round(a.mitjana)) end
  from base b
  left join agr a on a.lloc_id = b.id
  order by
    case when p_text is not null and btrim(p_text) <> ''
         then extensions.similarity(b.nom_norm, public.normalitza(p_text)) end desc nulls last,
    coalesce(a.n, 0) desc, b.nom
  limit least(greatest(p_limit, 1), 1000)
$$;

-- ---------------------------------------------------------------------
-- RPC: valorar (o canviar la valoració pròpia)
-- Límits: 15 valoracions noves/dia per dispositiu, 40/dia per connexió,
-- i com a màxim 3 dispositius diferents per connexió i lloc cada 30 dies.
-- ---------------------------------------------------------------------
create or replace function public.valorar(p_lloc uuid, p_valor smallint, p_dispositiu uuid)
returns json
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  d   text := privat.empremta('disp:' || p_dispositiu::text);
  ip  text := privat.ip_hash();
  ja  boolean;
begin
  if p_valor not between 1 and 6 then
    raise exception 'Valor no vàlid' using errcode = '22023';
  end if;
  if not exists (select 1 from public.llocs where id = p_lloc and actiu) then
    raise exception 'Aquest lloc no existeix' using errcode = 'P0002';
  end if;

  select exists (select 1 from public.valoracions where lloc_id = p_lloc and dispositiu_hash = d) into ja;

  if not ja then
    if (select count(*) from public.valoracions
         where dispositiu_hash = d and creat_at > now() - interval '24 hours') >= 15 then
      raise exception 'Has arribat al límit de valoracions d''avui. Torna-hi demà.' using errcode = 'P0001';
    end if;
    if (select count(*) from public.valoracions
         where ip_hash = ip and creat_at > now() - interval '24 hours') >= 40 then
      raise exception 'S''ha arribat al límit de valoracions des d''aquesta connexió.' using errcode = 'P0001';
    end if;
    if (select count(distinct dispositiu_hash) from public.valoracions
         where ip_hash = ip and lloc_id = p_lloc and creat_at > now() - interval '30 days') >= 3 then
      raise exception 'Aquest lloc ja s''ha valorat diverses vegades des d''aquesta connexió.' using errcode = 'P0001';
    end if;
  end if;

  insert into public.valoracions (lloc_id, valor, dispositiu_hash, ip_hash)
  values (p_lloc, p_valor, d, ip)
  on conflict (lloc_id, dispositiu_hash)
  do update set valor = excluded.valor, ip_hash = excluded.ip_hash, actualitzat_at = now();

  return json_build_object('ok', true, 'actualitzada', ja);
end $$;

-- RPC: quina valoració he fet jo d'aquest lloc (per marcar el botó)
create or replace function public.la_meva_valoracio(p_lloc uuid, p_dispositiu uuid)
returns smallint language sql stable security definer
set search_path = ''
as $$
  select valor from public.valoracions
  where lloc_id = p_lloc and dispositiu_hash = privat.empremta('disp:' || p_dispositiu::text)
$$;

-- ---------------------------------------------------------------------
-- RPC: proposar un lloc nou (amb detecció de duplicats)
-- Límits: 5 altes/dia per dispositiu i 10/dia per connexió.
-- ---------------------------------------------------------------------
create or replace function public.proposa_lloc(
  p_nom text, p_modalitat public.modalitat, p_categoria text,
  p_lat float8, p_lon float8, p_canal public.canal, p_adreca text, p_municipi text,
  p_dispositiu uuid
)
returns json
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  d    text := privat.empremta('disp:' || p_dispositiu::text);
  ip   text := privat.ip_hash();
  nn   text := public.normalitza(btrim(p_nom));
  dup  record;
  nou  uuid;
begin
  if char_length(btrim(coalesce(p_nom, ''))) < 2 then
    raise exception 'Cal indicar un nom' using errcode = '22023';
  end if;

  if (select count(*) from privat.propostes where dispositiu_hash = d and creat_at > now() - interval '24 hours') >= 5
  or (select count(*) from privat.propostes where ip_hash = ip and creat_at > now() - interval '24 hours') >= 10 then
    raise exception 'Has arribat al límit d''altes d''avui.' using errcode = 'P0001';
  end if;

  -- Duplicats: nom semblant i a menys de 120 m (o mateix canal, si és no presencial)
  select l.id, l.nom into dup
  from public.llocs l
  where l.actiu and l.modalitat = p_modalitat
    and extensions.similarity(l.nom_norm, nn) > 0.45
    and (
      (p_modalitat = 'no_presencial' and l.canal = p_canal)
      or (p_modalitat <> 'no_presencial' and privat.distancia_m(l.lat, l.lon, p_lat, p_lon) < 120)
    )
  order by extensions.similarity(l.nom_norm, nn) desc
  limit 1;

  if found then
    return json_build_object('id', dup.id, 'existent', true, 'nom', dup.nom);
  end if;

  insert into public.llocs (nom, modalitat, categoria, canal, lat, lon, adreca, municipi, font)
  values (
    btrim(p_nom), p_modalitat, coalesce(nullif(btrim(p_categoria), ''), 'altres'),
    case when p_modalitat = 'no_presencial' then p_canal end,
    case when p_modalitat <> 'no_presencial' then p_lat end,
    case when p_modalitat <> 'no_presencial' then p_lon end,
    nullif(btrim(p_adreca), ''), nullif(btrim(p_municipi), ''), 'usuaris')
  returning id into nou;

  insert into privat.propostes (lloc_id, dispositiu_hash, ip_hash) values (nou, d, ip);
  return json_build_object('id', nou, 'existent', false, 'nom', btrim(p_nom));
end $$;

-- ---------------------------------------------------------------------
-- Permisos d'execució
-- ---------------------------------------------------------------------
revoke all on function public.cerca_llocs, public.valorar, public.la_meva_valoracio, public.proposa_lloc from public;
grant execute on function public.cerca_llocs        to anon, authenticated;
grant execute on function public.valorar            to anon, authenticated;
grant execute on function public.la_meva_valoracio  to anon, authenticated;
grant execute on function public.proposa_lloc       to anon, authenticated;
revoke all on all functions in schema privat from public, anon, authenticated;
