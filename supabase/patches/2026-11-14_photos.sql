-- =====================================================================
-- Patch du 14/11/2026 : photos jointes aux signalements.
-- À coller UNE SEULE FOIS dans Supabase > SQL Editor > New query > Run.
-- Sans danger si relancé. Ne supprime rien.
--
-- Les photos sont rangées dans un espace de stockage privé (bucket « photos »),
-- un dossier par signalement. Elles suivent exactement les mêmes règles de
-- visibilité que le signalement : une photo d'un logement privé n'est servie
-- qu'à ce logement, au Conseil syndical et au syndic.
-- =====================================================================

-- 1. Liste des photos d'un signalement (chemins dans l'espace de stockage)
alter table public.tickets add column if not exists photos text[] not null default '{}';

do $$ begin
  alter table public.tickets add constraint tickets_photos_max
    check (coalesce(array_length(photos, 1), 0) <= 6);
exception when duplicate_object then null; end $$;

-- 1 bis. Un résident doit pouvoir relire LE signalement qu'il vient de créer
-- (l'application a besoin de son numéro pour y rattacher les photos).
-- Il ne lit toujours que les colonnes autorisées, et seulement ses propres lignes :
-- tout le reste passe par la vue tickets_feed.
drop policy if exists tickets_select on public.tickets;
create policy tickets_select on public.tickets for select to authenticated using (
  case public.my_role()
    when 'cs_admin'   then deleted_at is null or public.is_admin()
    when 'syndic'     then deleted_at is null
    when 'contractor' then deleted_at is null and category = public.my_category()
    when 'resident'   then deleted_at is null and author_id = auth.uid()
    else false
  end);

-- 2. Qui a le droit de voir / d'ajouter les photos d'un signalement
create or replace function public.photo_ticket_num(p_name text) returns int
language sql immutable set search_path = '' as
$$ select case when p_name ~ '^[0-9]{1,9}/' then split_part(p_name, '/', 1)::int end $$;

create or replace function public.can_see_ticket_photos(p_num int) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.tickets t
    where t.num = p_num
      and (t.deleted_at is null or public.is_admin())
      and case public.my_role()
            when 'cs_admin'   then true
            when 'syndic'     then true
            when 'contractor' then t.category = public.my_category()
            when 'resident'   then t.target_type <> 'LOT' or t.lot_number = public.my_lot()
            else false
          end)
$$;

create or replace function public.can_add_ticket_photos(p_num int) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.tickets t
    where t.num = p_num and t.deleted_at is null
      and (t.author_id = auth.uid()
           or public.my_role() in ('cs_admin','syndic')
           or (public.my_role() = 'contractor' and t.category = public.my_category())))
$$;

revoke execute on function public.can_see_ticket_photos(int), public.can_add_ticket_photos(int),
  public.photo_ticket_num(text) from public, anon;
grant execute on function public.can_see_ticket_photos(int), public.can_add_ticket_photos(int),
  public.photo_ticket_num(text) to authenticated;

create or replace function public.can_delete_ticket_photo(p_num int) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.my_role() = 'cs_admin' or exists (
    select 1 from public.tickets t
    where t.num = p_num and t.deleted_at is null and t.author_id = auth.uid())
$$;
revoke execute on function public.can_delete_ticket_photo(int) from public, anon;
grant execute on function public.can_delete_ticket_photo(int) to authenticated;

-- 3. Rattacher une photo déjà envoyée (le navigateur ne modifie jamais la colonne lui-même)
create or replace function public.add_ticket_photos(p_num int, p_paths text[])
returns text[] language plpgsql security definer set search_path = '' as $$
declare cur text[]; p text;
begin
  if not public.can_add_ticket_photos(p_num) then
    raise exception 'Vous ne pouvez pas ajouter de photo à ce signalement.';
  end if;
  select photos into cur from public.tickets where num = p_num;
  foreach p in array coalesce(p_paths, '{}') loop
    if p !~ ('^' || p_num || '/[0-9a-z]{6,40}\.(jpg|jpeg|png|webp)$') then
      raise exception 'Chemin de photo invalide.';
    end if;
    if coalesce(array_length(cur, 1), 0) >= 6 then
      raise exception 'Six photos au maximum par signalement.';
    end if;
    if not (p = any(cur)) then cur := cur || p; end if;
  end loop;
  perform set_config('app.photos_ok', '1', true);
  update public.tickets set photos = cur where num = p_num;
  perform set_config('app.photos_ok', '', true);
  return cur;
end $$;

create or replace function public.remove_ticket_photo(p_num int, p_path text)
returns text[] language plpgsql security definer set search_path = '' as $$
declare cur text[];
begin
  if not (public.my_role() = 'cs_admin'
          or exists (select 1 from public.tickets t where t.num = p_num and t.author_id = auth.uid())) then
    raise exception 'Vous ne pouvez pas retirer cette photo.';
  end if;
  perform set_config('app.photos_ok', '1', true);
  update public.tickets set photos = array_remove(photos, p_path) where num = p_num
    returning photos into cur;
  perform set_config('app.photos_ok', '', true);
  return coalesce(cur, '{}');
end $$;

revoke execute on function public.add_ticket_photos(int, text[]), public.remove_ticket_photo(int, text)
  from public, anon;
grant execute on function public.add_ticket_photos(int, text[]), public.remove_ticket_photo(int, text)
  to authenticated;

-- 4. La colonne ne se modifie pas directement depuis le navigateur
create or replace function public.tickets_photos_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.photos := '{}'; end if;
  elsif coalesce(current_setting('app.photos_ok', true), '') <> '1' then
    new.photos := old.photos;                            -- seules les fonctions ci-dessus y touchent
  end if;
  return new;
end $$;
drop trigger if exists tickets_photos_t on public.tickets;
create trigger tickets_photos_t before insert or update on public.tickets
  for each row execute function public.tickets_photos_guard();

-- 5. La vue de lecture : les photos suivent le masquage des autres détails
drop view if exists public.tickets_feed;
create view public.tickets_feed as
select s.num, s.floor,
  case when s.detail then s.x end                                     as x,
  case when s.detail then s.y end                                     as y,
  s.target_type,
  case when s.detail then s.target_id else '' end                     as target_id,
  case when s.detail then s.lot_number end                            as lot_number,
  case when s.detail then s.room else 'NONE' end                      as room,
  case when s.detail then s.location else 'Logement privé' end        as location,
  case when s.detail then s.title else 'Incident dans un logement privé' end as title,
  s.category, s.urgency, s.status, s.date,
  case when s.show_author then s.author else '' end                   as author,
  case when s.detail then s.description else '' end                   as description,
  case when s.detail then s.os_number else '' end                     as os_number,
  case when s.detail then s.assigned_contractor else '' end           as assigned_contractor,
  case when s.detail then s.source else 'app' end                     as source,
  case when s.detail then s.photos else '{}'::text[] end              as photos,
  s.created_at, s.updated_at,
  s.detail                                                            as detail
from (
  select t.*,
    (public.my_role() in ('cs_admin','syndic','contractor')
       or t.target_type <> 'LOT'
       or t.lot_number = public.my_lot())                             as detail,
    (public.my_role() in ('cs_admin','syndic')
       or t.author_id = auth.uid())                                   as show_author
  from public.tickets t
  where t.deleted_at is null
    and case public.my_role()
          when 'cs_admin'   then true
          when 'syndic'     then true
          when 'contractor' then t.category = public.my_category()
          when 'resident'   then true
          else false
        end
) s;
revoke all on public.tickets_feed from public, anon;
grant select on public.tickets_feed to authenticated;

-- 6. Espace de stockage privé des photos
insert into storage.buckets (id, name, public) values ('photos', 'photos', false)
on conflict (id) do nothing;

drop policy if exists photos_read on storage.objects;
create policy photos_read on storage.objects for select to authenticated
  using (bucket_id = 'photos' and public.can_see_ticket_photos(public.photo_ticket_num(name)));
drop policy if exists photos_insert on storage.objects;
create policy photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and public.can_add_ticket_photos(public.photo_ticket_num(name)));
drop policy if exists photos_delete on storage.objects;
create policy photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and public.can_delete_ticket_photo(public.photo_ticket_num(name)));

-- Contrôle : doit afficher une ligne 'photos'.
select id, public from storage.buckets where id = 'photos';
