-- =====================================================================
-- Patch du 11/11/2026 (2) : corbeille, restauration et journal des modifications.
-- À coller UNE SEULE FOIS dans Supabase > SQL Editor > New query > Run
-- (après le patch 2026-11-11_visibilite.sql ; sans danger si répété).
--
--  * « Supprimer » ne détruit plus rien : l'incident part dans la corbeille.
--  * Le Conseil syndical seul voit la corbeille, peut restaurer ou supprimer définitivement.
--  * Un journal conserve les créations, changements de statut, ordres de service,
--    suppressions, restaurations et suppressions définitives (visible du Conseil syndical seul).
-- =====================================================================

-- 1. Colonnes de la corbeille
alter table public.tickets add column if not exists deleted_at timestamptz;
alter table public.tickets add column if not exists deleted_by uuid references auth.users(id) on delete set null;
create index if not exists tickets_deleted_idx on public.tickets (deleted_at);

-- 2. Règles d'accès : seul le Conseil syndical voit et modifie un incident supprimé
drop policy if exists tickets_select on public.tickets;
create policy tickets_select on public.tickets for select to authenticated using (
  case public.my_role()
    when 'cs_admin'   then true
    when 'syndic'     then deleted_at is null
    when 'contractor' then deleted_at is null and category = public.my_category()
    else false
  end);
drop policy if exists tickets_update on public.tickets;
create policy tickets_update on public.tickets for update to authenticated
  using (public.my_role() = 'cs_admin'
         or (deleted_at is null and (public.my_role() = 'syndic'
              or (public.my_role() = 'contractor' and category = public.my_category()))))
  with check (public.my_role() = 'cs_admin'
         or (deleted_at is null and (public.my_role() = 'syndic'
              or (public.my_role() = 'contractor' and category = public.my_category()))));

-- 3. Déclencheurs : seul le Conseil syndical peut supprimer / restaurer
create or replace function public.tickets_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r text; n text;
begin
  if auth.uid() is null then return new; end if;            -- éditeur SQL / maintenance
  select role, name into r, n from public.profiles where id = auth.uid();
  new.author_id  := auth.uid();
  new.created_at := now();
  new.updated_at := now();
  new.deleted_at := null; new.deleted_by := null;
  if new.target_type <> 'LOT' then new.lot_number := null; end if;
  if r = 'resident' then                                     -- un résident ne fixe ni statut, ni OS, ni auteur
    new.status := 'reported'; new.os_number := ''; new.assigned_contractor := '';
    new.source := 'app'; new.date := current_date; new.author := n;
  elsif new.source = 'app' or new.author = '' then
    new.author := n;                                         -- les imports gardent l'auteur d'origine
  end if;
  return new;
end $$;

create or replace function public.tickets_before_update() returns trigger
language plpgsql security definer set search_path = '' as $$
declare s text;
begin
  if auth.uid() is null then return new; end if;
  if public.my_role() = 'contractor' then                   -- un prestataire ne change que le statut
    s := new.status; new := old; new.status := s;
  end if;
  new.author_id  := old.author_id;
  new.created_at := old.created_at;
  new.updated_at := now();
  if new.target_type <> 'LOT' then new.lot_number := null; end if;
  if public.my_role() <> 'cs_admin' then                     -- corbeille : Conseil syndical seul
    new.deleted_at := old.deleted_at; new.deleted_by := old.deleted_by;
  elsif new.deleted_at is distinct from old.deleted_at then
    new.deleted_by := case when new.deleted_at is null then null else auth.uid() end;
    new.deleted_at := case when new.deleted_at is null then null else now() end;
  end if;
  return new;
end $$;

-- 4. Journal des modifications (écrit par déclencheur, lu par le Conseil syndical seul)
create table if not exists public.ticket_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  ticket_num   int not null,
  ticket_title text,
  actor_id     uuid,
  actor_name   text not null default 'Système',
  action       text not null check (action in ('created','status','os','edited','deleted','restored','purged')),
  detail       text not null default ''
);
create index if not exists ticket_log_at_idx on public.ticket_log (at desc);
alter table public.ticket_log enable row level security;
drop policy if exists log_select on public.ticket_log;
create policy log_select on public.ticket_log for select to authenticated
  using (public.my_role() = 'cs_admin');
revoke all on public.ticket_log from public, anon, authenticated;
grant select on public.ticket_log to authenticated;

create or replace function public.tickets_log() returns trigger
language plpgsql security definer set search_path = '' as $$
declare an text := coalesce((select name from public.profiles where id = auth.uid()), 'Système');
begin
  if tg_op = 'INSERT' then
    insert into public.ticket_log(ticket_num, ticket_title, actor_id, actor_name, action, detail)
    values (new.num, new.title, auth.uid(), an, 'created', new.status);
  elsif tg_op = 'UPDATE' then
    if new.deleted_at is distinct from old.deleted_at then
      insert into public.ticket_log(ticket_num, ticket_title, actor_id, actor_name, action)
      values (new.num, new.title, auth.uid(), an, case when new.deleted_at is null then 'restored' else 'deleted' end);
    end if;
    if new.status is distinct from old.status then
      insert into public.ticket_log(ticket_num, ticket_title, actor_id, actor_name, action, detail)
      values (new.num, new.title, auth.uid(), an, 'status', old.status || ' > ' || new.status);
    end if;
    if new.os_number is distinct from old.os_number or new.assigned_contractor is distinct from old.assigned_contractor then
      insert into public.ticket_log(ticket_num, ticket_title, actor_id, actor_name, action, detail)
      values (new.num, new.title, auth.uid(), an, 'os',
              coalesce(nullif(new.os_number, ''), '-') || ' / ' || coalesce(nullif(new.assigned_contractor, ''), '-'));
    end if;
    if (new.title, new.description, new.category, new.urgency, new.location)
       is distinct from (old.title, old.description, old.category, old.urgency, old.location) then
      insert into public.ticket_log(ticket_num, ticket_title, actor_id, actor_name, action)
      values (new.num, new.title, auth.uid(), an, 'edited');
    end if;
  else  -- suppression définitive : on garde la trace, mais plus le titre (donnée personnelle potentielle)
    insert into public.ticket_log(ticket_num, actor_id, actor_name, action)
    values (old.num, auth.uid(), an, 'purged');
    update public.ticket_log set ticket_title = null where ticket_num = old.num and ticket_title is not null;
  end if;
  return null;
end $$;
drop trigger if exists tickets_log_t on public.tickets;
create trigger tickets_log_t after insert or update or delete on public.tickets
  for each row execute function public.tickets_log();

-- 5. Vues : la vue de lecture ignore la corbeille ; une vue réservée au Conseil syndical la liste
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

drop view if exists public.tickets_trash;
create view public.tickets_trash as
select t.num, t.floor, t.target_type, t.target_id, t.location, t.title, t.category, t.urgency,
       t.status, t.date, t.author, t.description, t.deleted_at,
       coalesce(p.name, '-') as deleted_by_name
from public.tickets t
left join public.profiles p on p.id = t.deleted_by
where public.my_role() = 'cs_admin' and t.deleted_at is not null;
revoke all on public.tickets_trash from public, anon;
grant select on public.tickets_trash to authenticated;
