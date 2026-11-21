-- Simule, sur un Postgres local, ce que Supabase fournit pour les notifications :
-- le rôle service_role et l'extension pg_net (net.http_post), dont les appels sont notés dans net._calls.
-- À lancer après 00_faux_supabase_local.sql. Charger ensuite schema.sql SANS la ligne « create extension … pg_net ».
\c ftest
do $$ begin
  if not exists (select from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
grant usage on schema public to service_role;
create schema if not exists net;
create table if not exists net._calls (id serial primary key, url text, body jsonb, headers jsonb);
create or replace function net.http_post(url text, body jsonb default '{}', params jsonb default '{}',
  headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint
language sql security definer as $$ insert into net._calls (url, body, headers) values (url, body, headers) returning id $$;
grant usage on schema net to public;
