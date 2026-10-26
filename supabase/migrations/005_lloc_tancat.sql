-- Avisos de "aquest lloc ja no existeix / ha tancat".
-- Un lloc es desactiva automàticament quan l'han marcat com a tancat 3 dispositius diferents
-- des d'almenys 2 connexions diferents. L'administrador el pot reactivar.

create table privat.avisos_tancat (
  id               bigint generated always as identity primary key,
  lloc_id          uuid not null references public.llocs (id) on delete cascade,
  dispositiu_hash  text not null,
  ip_hash          text not null,
  creat_at         timestamptz not null default now(),
  unique (lloc_id, dispositiu_hash)
);
create index avisos_tancat_lloc_idx on privat.avisos_tancat (lloc_id);
create index avisos_tancat_disp_idx on privat.avisos_tancat (dispositiu_hash, creat_at);

alter table public.llocs add column if not exists desactivat_at timestamptz;
alter table public.llocs add column if not exists motiu_desactivacio text;

create or replace function public.informa_tancat(p_lloc uuid, p_dispositiu uuid)
returns json
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  d    text := privat.empremta('disp:' || p_dispositiu::text);
  ip   text := privat.ip_hash();
  ndis int;
  nip  int;
  tancat boolean := false;
begin
  if not exists (select 1 from public.llocs where id = p_lloc and actiu) then
    raise exception 'Aquest lloc no existeix' using errcode = 'P0002';
  end if;
  if (select count(*) from privat.avisos_tancat
       where dispositiu_hash = d and creat_at > now() - interval '24 hours') >= 10 then
    raise exception 'Has arribat al límit d''avisos d''avui.' using errcode = 'P0001';
  end if;

  insert into privat.avisos_tancat (lloc_id, dispositiu_hash, ip_hash)
  values (p_lloc, d, ip)
  on conflict (lloc_id, dispositiu_hash) do nothing;

  select count(distinct dispositiu_hash), count(distinct ip_hash) into ndis, nip
  from privat.avisos_tancat where lloc_id = p_lloc;

  if ndis >= 3 and nip >= 2 then
    update public.llocs set actiu = false, desactivat_at = now(), motiu_desactivacio = 'tancat (avisos d''usuaris)'
    where id = p_lloc;
    tancat := true;
  end if;

  return json_build_object('ok', true, 'desactivat', tancat);
end $$;

revoke all on function public.informa_tancat from public;
grant execute on function public.informa_tancat to anon, authenticated;

-- Vista per a l'administrador (només accessible amb la clau de servei o des del tauler de Supabase)
create or replace view privat.revisio_tancats as
select l.id, l.nom, l.categoria, l.adreca, l.actiu, l.desactivat_at,
       count(distinct a.dispositiu_hash) as avisos, max(a.creat_at) as darrer_avis
from public.llocs l join privat.avisos_tancat a on a.lloc_id = l.id
group by l.id
order by darrer_avis desc;
