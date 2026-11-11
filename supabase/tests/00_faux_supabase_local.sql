drop database if exists ftest;
create database ftest;
\c ftest
do $$ begin
  if not exists (select from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
end $$;
create schema auth; create schema storage;
create table auth.users(id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('email',(select email from auth.users where id=auth.uid())) $$;
create table storage.buckets(id text primary key, name text, public boolean);
create table storage.objects(id serial primary key, bucket_id text, name text);
alter table storage.objects enable row level security;
grant usage on schema public, auth, storage to anon, authenticated;
grant execute on all functions in schema auth to anon, authenticated;
grant select on auth.users to authenticated; -- mock only (for auth.jwt)
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
