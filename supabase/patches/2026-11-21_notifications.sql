-- =====================================================================
-- Patch du 21/11/2026 : notifications sur téléphone (Web Push).
-- À coller UNE SEULE FOIS dans Supabase > SQL Editor > New query > Run.
-- Sans danger si relancé. Ne supprime rien.
--
-- Qui reçoit : les membres du Conseil syndical et le syndic qui ont activé
-- les notifications sur au moins un appareil. Chacun choisit ses événements.
-- La base prévient la fonction « notify », qui chiffre et envoie le message.
-- Les signalements importés (WhatsApp, JSON) ne déclenchent pas de notification.
-- =====================================================================

create extension if not exists pg_net with schema extensions;

-- 1. Réglages internes : secret partagé avec la fonction et clés du serveur.
--    Aucun accès depuis le navigateur.
create table if not exists public.push_config (
  id            boolean primary key default true check (id),
  secret        text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  vapid_public  text,
  vapid_private text
);
insert into public.push_config default values on conflict (id) do nothing;
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;

-- 2. Appareils abonnés et préférences de chacun
create table if not exists public.push_subscriptions (
  endpoint   text primary key check (endpoint ~ '^https://' and char_length(endpoint) <= 1000),
  user_id    uuid not null references auth.users(id) on delete cascade,
  p256dh     text not null check (char_length(p256dh) between 80 and 120),
  auth       text not null check (char_length(auth) between 16 and 40),
  device     text not null default '' check (char_length(device) <= 80),
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;

create table if not exists public.notify_prefs (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  new_ticket boolean not null default true,
  urgent     boolean not null default true,
  access     boolean not null default true,
  status     boolean not null default true
);
alter table public.notify_prefs enable row level security;
revoke all on public.notify_prefs from anon, authenticated;

-- 3. Fonctions appelées par l'application (personne connectée)
create or replace function public.push_public_key() returns text
language sql stable security definer set search_path = '' as
$$ select vapid_public from public.push_config where public.my_role() in ('cs_admin','syndic') $$;

create or replace function public.push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_device text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if public.my_role() not in ('cs_admin','syndic') then
    raise exception 'Les notifications sont réservées au Conseil syndical et au syndic.';
  end if;
  delete from public.push_subscriptions where endpoint = p_endpoint;
  if (select count(*) from public.push_subscriptions where user_id = auth.uid()) >= 10 then
    raise exception 'Dix appareils au maximum.';
  end if;
  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth, device)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth, left(coalesce(p_device, ''), 80));
end $$;

create or replace function public.push_unsubscribe(p_endpoint text) returns void
language sql security definer set search_path = '' as
$$ delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid() $$;

create or replace function public.push_is_registered(p_endpoint text) returns boolean
language sql stable security definer set search_path = '' as
$$ select exists (select 1 from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid()) $$;

create or replace function public.push_my_targets()
returns table (endpoint text, p256dh text, auth text)
language sql stable security definer set search_path = '' as
$$ select s.endpoint, s.p256dh, s.auth from public.push_subscriptions s where s.user_id = auth.uid() $$;

create or replace function public.get_notify_prefs() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'new_ticket', coalesce(n.new_ticket, true), 'urgent', coalesce(n.urgent, true),
    'access', coalesce(n.access, true), 'status', coalesce(n.status, true))
  from (select 1) x left join public.notify_prefs n on n.user_id = auth.uid()
$$;

create or replace function public.set_notify_prefs(p_new boolean, p_urgent boolean, p_access boolean, p_status boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if public.my_role() not in ('cs_admin','syndic') then raise exception 'Réservé au Conseil syndical et au syndic.'; end if;
  insert into public.notify_prefs (user_id, new_ticket, urgent, access, status)
  values (auth.uid(), p_new, p_urgent, p_access, p_status)
  on conflict (user_id) do update set new_ticket = excluded.new_ticket, urgent = excluded.urgent,
    access = excluded.access, status = excluded.status;
end $$;

revoke execute on function public.push_public_key(), public.push_subscribe(text,text,text,text),
  public.push_unsubscribe(text), public.push_is_registered(text), public.push_my_targets(),
  public.get_notify_prefs(), public.set_notify_prefs(boolean,boolean,boolean,boolean) from public, anon;
grant execute on function public.push_public_key(), public.push_subscribe(text,text,text,text),
  public.push_unsubscribe(text), public.push_is_registered(text), public.push_my_targets(),
  public.get_notify_prefs(), public.set_notify_prefs(boolean,boolean,boolean,boolean) to authenticated;

-- 4. Fonctions réservées à la fonction « notify » (clé de service)
create or replace function public.push_vapid() returns table (vapid_public text, vapid_private text)
language sql stable security definer set search_path = '' as
$$ select c.vapid_public, c.vapid_private from public.push_config c $$;

create or replace function public.push_set_vapid(p_public text, p_private text) returns void
language sql security definer set search_path = '' as
$$ update public.push_config set vapid_public = p_public, vapid_private = p_private where vapid_public is null $$;

create or replace function public.push_forget(p_endpoint text) returns void
language sql security definer set search_path = '' as
$$ delete from public.push_subscriptions where endpoint = p_endpoint $$;

-- Destinataires d'un événement : rien si le secret est faux ; jamais l'auteur de l'action.
create or replace function public.push_targets(p_secret text, p_event text, p_actor uuid)
returns table (endpoint text, p256dh text, auth text)
language sql stable security definer set search_path = '' as $$
  select s.endpoint, s.p256dh, s.auth
  from public.push_subscriptions s
  join public.profiles p on p.id = s.user_id
  left join public.notify_prefs n on n.user_id = s.user_id
  where exists (select 1 from public.push_config c where c.secret = p_secret)
    and s.user_id is distinct from p_actor
    and p.role in ('cs_admin','syndic')
    and case p_event
          when 'new'    then coalesce(n.new_ticket, true)
          when 'urgent' then coalesce(n.new_ticket, true) or coalesce(n.urgent, true)
          when 'status' then coalesce(n.status, true)
          when 'access' then p.role = 'cs_admin' and coalesce(n.access, true)
          else false
        end
$$;

revoke execute on function public.push_vapid(), public.push_set_vapid(text,text), public.push_forget(text),
  public.push_targets(text,text,uuid) from public, anon, authenticated;
grant execute on function public.push_vapid(), public.push_set_vapid(text,text), public.push_forget(text),
  public.push_targets(text,text,uuid) to service_role;

-- 5. Déclencheurs : la base prévient la fonction « notify » (sans jamais bloquer un enregistrement)
create or replace function public.notify_send(p_event text, p_data jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.push_config;
begin
  select * into c from public.push_config;
  if c.vapid_public is null or not exists (select 1 from public.push_subscriptions) then return; end if;
  perform net.http_post(
    url     := 'https://xjpnlwegwlkvcfvfomwl.supabase.co/functions/v1/notify',
    body    := jsonb_build_object('action','event','secret',c.secret,'event',p_event,'actor',auth.uid(),'data',p_data),
    headers := jsonb_build_object('Content-Type','application/json',
                 'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhqcG5sd2Vnd2xrdmNmdmZvbXdsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQzMzczNTUsImV4cCI6MjEwOTkxMzM1NX0.qSRrVhl0588G5KWZatc5ZrtzKhzfjyu6LrKU4hQlDqQ'));
exception when others then
  raise warning 'Notification non envoyée : %', sqlerrm;
end $$;
revoke execute on function public.notify_send(text,jsonb) from public, anon, authenticated;

create or replace function public.tickets_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.deleted_at is not null then return null; end if;
  if tg_op = 'INSERT' then
    if new.source <> 'app' then return null; end if;          -- pas de rafale lors d'un import
    perform public.notify_send(case when new.urgency = 'high' then 'urgent' else 'new' end,
      jsonb_build_object('num', new.num, 'title', new.title, 'location', new.location));
  elsif new.status is distinct from old.status then
    perform public.notify_send('status', jsonb_build_object('num', new.num, 'title', new.title, 'status', new.status));
  end if;
  return null;
end $$;
drop trigger if exists tickets_notify_t on public.tickets;
create trigger tickets_notify_t after insert or update on public.tickets
  for each row execute function public.tickets_notify();

create or replace function public.profiles_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
declare nm text := btrim(new.name);
begin
  if new.role = 'pending' then
    perform public.notify_send('access', jsonb_build_object('name',
      split_part(nm, ' ', 1) || coalesce(' ' || nullif(left(split_part(nm, ' ', 2), 1), '') || '.', '')));
  end if;
  return null;
end $$;
drop trigger if exists profiles_notify_t on public.profiles;
create trigger profiles_notify_t after insert on public.profiles
  for each row execute function public.profiles_notify();

-- Contrôle : doit afficher « prêt ».
select case when exists (select 1 from public.push_config) then 'prêt' end as notifications;
