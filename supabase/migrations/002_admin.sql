-- Configuració d'administració, només accessible amb la clau de servei (Edge Functions)
create table public.admin_config (clau text primary key, valor text not null);
alter table public.admin_config enable row level security;   -- sense polítiques: ningú del públic hi accedeix
revoke all on public.admin_config from anon, authenticated;
insert into public.admin_config values ('carrega_clau', encode(extensions.gen_random_bytes(24), 'hex'));

-- Per poder cridar la càrrega des de SQL (net.http_post)
create extension if not exists pg_net;
