-- Identificació fiable de la connexió per als límits.
-- Abans es feia servir la primera adreça de x-forwarded-for, que el client pot falsejar
-- (Cloudflare hi afegeix la IP real al final, però conserva el que enviï el client al davant).
-- Ara es prioritza cf-connecting-ip, que Cloudflare sempre sobreescriu, i després
-- sb-forwarded-for (Supabase) i l'ÚLTIMA adreça de x-forwarded-for.
create or replace function privat.ip_hash()
returns text language plpgsql stable
set search_path = ''
as $$
declare
  h   json := nullif(current_setting('request.headers', true), '')::json;
  xff text[];
  ip  text;
begin
  xff := string_to_array(h ->> 'x-forwarded-for', ',');
  ip := coalesce(
    nullif(btrim(h ->> 'cf-connecting-ip'), ''),
    nullif(btrim(split_part(h ->> 'sb-forwarded-for', ',', 1)), ''),
    nullif(btrim(xff[array_length(xff, 1)]), ''),
    'desconeguda');
  return privat.empremta('ip:' || ip);
end $$;
