-- =====================================================================
-- Import sans doublons : empreinte unique par message importé.
-- À coller une seule fois dans Supabase > SQL Editor > Run.
-- Ne supprime rien. Peut être relancé sans danger.
-- =====================================================================

alter table public.tickets add column if not exists import_key text;

-- Une empreinte ne peut exister qu'une fois (les signalements saisis à la main n'en ont pas).
create unique index if not exists tickets_import_key_uq on public.tickets (import_key);

-- Le navigateur n'a pas besoin de lire l'empreinte directement (voir known_imports ci-dessous).
-- Les droits de lecture sont déjà limités colonne par colonne : import_key n'en fait pas partie.

-- Seuls les imports (CS, syndic) portent une empreinte ; elle ne change jamais ensuite.
create or replace function public.tickets_import_key_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null and (new.source = 'app' or public.my_role() not in ('cs_admin','syndic')) then
      new.import_key := null;
    end if;
    if new.import_key is not null then new.import_key := left(new.import_key, 80); end if;
  else
    new.import_key := old.import_key;
  end if;
  return new;
end $$;

drop trigger if exists tickets_key_t on public.tickets;
create trigger tickets_key_t before insert or update on public.tickets
  for each row execute function public.tickets_import_key_guard();

-- Liste des empreintes déjà importées (corbeille comprise), réservée au CS et au syndic.
create or replace function public.known_imports()
returns table (import_key text, num int, deleted boolean)
language sql stable security definer set search_path = '' as $$
  select t.import_key, t.num, t.deleted_at is not null
  from public.tickets t
  where t.import_key is not null and public.my_role() in ('cs_admin','syndic')
$$;
revoke execute on function public.known_imports() from public, anon;
grant execute on function public.known_imports() to authenticated;
