-- =====================================================================
-- Les Caméliats – Suivi technique : schéma de la base Supabase
-- À coller UNE SEULE FOIS dans Supabase > SQL Editor > New query > Run.
-- Les droits (RG-SEC-02 / RG-SEC-03) sont appliqués ici, côté serveur :
-- un navigateur ne reçoit jamais un signalement qu'il n'a pas le droit de voir.
-- =====================================================================

-- ---------- Tables ----------
create table public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         text,
  name          text not null check (char_length(name) between 1 and 80),
  role          text not null default 'pending'
                check (role in ('cs_admin','syndic','resident','contractor','pending')),
  lot           int  check (lot between 1 and 39),
  cage          text check (cage in ('A','B','C')),
  floor         int  check (floor between 0 and 6),
  resident_type text check (char_length(resident_type) <= 40),
  category      text check (category in ('plumbing','electricity','door','elevator','cleanliness','damage')),
  requested_at  timestamptz not null default now()
);

create table public.settings (
  id          boolean primary key default true check (id),
  invite_code text not null check (char_length(invite_code) between 4 and 40)
);
-- Code d'invitation initial tiré au hasard ; le CS le lit et le change dans l'écran Administration.
insert into public.settings (invite_code)
values (upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8)));

create table public.code_attempts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  n       int not null default 0,
  last_at timestamptz not null default now()
);

create table public.tickets (
  num                 int generated always as identity primary key,
  floor               int not null check (floor between -2 and 6),
  x                   numeric(5,2) not null check (x between 0 and 100),
  y                   numeric(5,2) not null check (y between 0 and 100),
  target_type         text not null check (target_type in ('COMMON','LOT','PARKING','CAVE')),
  target_id           text not null default '' check (char_length(target_id) <= 40),
  lot_number          int check (lot_number between 1 and 39),
  room                text not null default 'NONE' check (char_length(room) <= 20),
  location            text not null check (char_length(location) between 1 and 120),
  title               text not null check (char_length(title) between 1 and 50),
  category            text not null check (category in ('plumbing','electricity','door','elevator','cleanliness','damage')),
  urgency             text not null check (urgency in ('low','medium','high')),
  status              text not null default 'reported' check (status in ('reported','in_progress','resolved')),
  date                date not null default current_date,
  author_id           uuid references auth.users(id) on delete set null,
  author              text not null default '' check (char_length(author) <= 80),
  description         text not null default '' check (char_length(description) <= 4000),
  os_number           text not null default '' check (char_length(os_number) <= 40),
  assigned_contractor text not null default '' check (char_length(assigned_contractor) <= 80),
  source              text not null default 'app' check (source in ('app','whatsapp','json')),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (target_type <> 'LOT' or lot_number is not null)
);
create index tickets_floor_idx on public.tickets (floor);

-- ---------- Fonctions d'identité (lues par les règles d'accès) ----------
create function public.my_role() returns text
language sql stable security definer set search_path = '' as
$$ select role from public.profiles where id = auth.uid() $$;

create function public.my_lot() returns int
language sql stable security definer set search_path = '' as
$$ select lot from public.profiles where id = auth.uid() $$;

create function public.my_category() returns text
language sql stable security definer set search_path = '' as
$$ select category from public.profiles where id = auth.uid() $$;

-- ---------- Règles d'accès (row level security) ----------
alter table public.profiles      enable row level security;
alter table public.settings      enable row level security;
alter table public.code_attempts enable row level security;   -- aucune règle : inaccessible depuis le navigateur
alter table public.tickets       enable row level security;

-- Profils : chacun lit le sien ; le Conseil syndical lit, modifie et supprime tous les profils.
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.my_role() = 'cs_admin');
create policy profiles_update on public.profiles for update to authenticated
  using (public.my_role() = 'cs_admin') with check (public.my_role() = 'cs_admin');
create policy profiles_delete on public.profiles for delete to authenticated
  using (public.my_role() = 'cs_admin');
-- Pas de règle d'insertion : un profil ne se crée que par request_access().

-- Code d'invitation : Conseil syndical uniquement.
create policy settings_select on public.settings for select to authenticated
  using (public.my_role() = 'cs_admin');
create policy settings_update on public.settings for update to authenticated
  using (public.my_role() = 'cs_admin') with check (public.my_role() = 'cs_admin');

-- Signalements, lecture (RG-SEC-03), table : CS et syndic (tout) ; prestataire (sa catégorie).
-- Résidents et comptes en attente passent par la vue tickets_feed (plus bas), qui masque
-- l'auteur et le détail des logements des autres.
create policy tickets_select on public.tickets for select to authenticated using (
  case public.my_role()
    when 'cs_admin'   then true
    when 'syndic'     then true
    when 'contractor' then category = public.my_category()
    else false
  end);

-- Création : CS, syndic, résident (un résident ne déclare en privatif que pour son logement).
create policy tickets_insert on public.tickets for insert to authenticated with check (
  case public.my_role()
    when 'cs_admin' then true
    when 'syndic'   then true
    when 'resident' then target_type <> 'LOT' or lot_number = public.my_lot()
    else false
  end);

-- Modification : CS et syndic (tout) ; prestataire (statut de sa catégorie, voir le déclencheur).
create policy tickets_update on public.tickets for update to authenticated
  using (public.my_role() in ('cs_admin','syndic')
         or (public.my_role() = 'contractor' and category = public.my_category()))
  with check (public.my_role() in ('cs_admin','syndic')
         or (public.my_role() = 'contractor' and category = public.my_category()));

-- Suppression : Conseil syndical uniquement.
create policy tickets_delete on public.tickets for delete to authenticated
  using (public.my_role() = 'cs_admin');

-- ---------- Déclencheurs ----------
create function public.tickets_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r text; n text;
begin
  if auth.uid() is null then return new; end if;            -- éditeur SQL / maintenance
  select role, name into r, n from public.profiles where id = auth.uid();
  new.author_id  := auth.uid();
  new.created_at := now();
  new.updated_at := now();
  if new.target_type <> 'LOT' then new.lot_number := null; end if;
  if r = 'resident' then                                     -- un résident ne fixe ni statut, ni OS, ni auteur
    new.status := 'reported'; new.os_number := ''; new.assigned_contractor := '';
    new.source := 'app'; new.date := current_date; new.author := n;
  elsif new.source = 'app' or new.author = '' then
    new.author := n;                                         -- les imports gardent l'auteur d'origine
  end if;
  return new;
end $$;
create trigger tickets_bi before insert on public.tickets
  for each row execute function public.tickets_before_insert();

create function public.tickets_before_update() returns trigger
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
  return new;
end $$;
create trigger tickets_bu before update on public.tickets
  for each row execute function public.tickets_before_update();

-- Il doit toujours rester au moins un membre du Conseil syndical.
create function public.profiles_keep_admin() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.role = 'cs_admin' and (tg_op = 'DELETE' or new.role <> 'cs_admin')
     and not exists (select 1 from public.profiles where role = 'cs_admin' and id <> old.id) then
    raise exception 'Il doit rester au moins un membre du Conseil syndical.';
  end if;
  if tg_op = 'UPDATE' then
    new.id := old.id; new.email := old.email; new.requested_at := old.requested_at;
    if new.role <> 'contractor' then new.category := null; end if;
    return new;
  end if;
  return old;
end $$;
create trigger profiles_guard before update or delete on public.profiles
  for each row execute function public.profiles_keep_admin();

-- ---------- Fonctions appelées par l'application ----------
-- Demande d'accès après connexion (RG-SSO-02/03). Renvoie :
--   'cs_admin' (tout premier inscrit : il devient le Conseil syndical), 'pending',
--   'bad_code', 'locked' (trop d'essais), ou le rôle existant si le profil existe déjà.
create function public.request_access(p_name text, p_type text, p_cage text, p_floor int, p_lot int, p_code text)
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); r text; mail text := auth.jwt() ->> 'email'; a public.code_attempts;
begin
  if uid is null then raise exception 'Connexion requise.'; end if;
  select role into r from public.profiles where id = uid;
  if r is not null then return r; end if;
  lock table public.profiles in share row exclusive mode;
  if not exists (select 1 from public.profiles) then
    insert into public.profiles (id, email, name, role, lot, cage, floor, resident_type)
    values (uid, mail, btrim(p_name), 'cs_admin', p_lot, p_cage, p_floor, p_type);
    return 'cs_admin';
  end if;
  select * into a from public.code_attempts where user_id = uid;
  if a.n >= 8 and a.last_at > now() - interval '1 hour' then return 'locked'; end if;
  if upper(btrim(coalesce(p_code, ''))) <> (select upper(invite_code) from public.settings) then
    insert into public.code_attempts (user_id, n, last_at) values (uid, 1, now())
    on conflict (user_id) do update
      set n = case when public.code_attempts.last_at > now() - interval '1 hour'
                   then public.code_attempts.n + 1 else 1 end,
          last_at = now();
    return 'bad_code';
  end if;
  delete from public.code_attempts where user_id = uid;
  insert into public.profiles (id, email, name, role, lot, cage, floor, resident_type)
  values (uid, mail, btrim(p_name), 'pending', p_lot, p_cage, p_floor, p_type);
  return 'pending';
end $$;

-- Nombre de signalements privatifs masqués à l'utilisateur (pour le bandeau d'information).
create function public.hidden_private_count() returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.tickets t
  where t.target_type = 'LOT' and case public.my_role()
    when 'resident' then t.lot_number is distinct from public.my_lot()
    when 'pending'  then true
    else false end
$$;

-- ---------- Privilèges ----------
revoke all on public.profiles, public.settings, public.code_attempts, public.tickets from anon;
revoke all on public.code_attempts from authenticated;
grant select, update, delete on public.profiles to authenticated;
grant select, update on public.settings to authenticated;
revoke select on public.tickets from authenticated;
grant insert, update, delete on public.tickets to authenticated;
-- Le nom de l'auteur ne se lit pas directement dans la table (voir la vue tickets_feed).
grant select (num, floor, x, y, target_type, target_id, lot_number, room, location,
              title, category, urgency, status, date, description, os_number,
              assigned_contractor, source, created_at, updated_at)
  on public.tickets to authenticated;

-- 3. Vue de lecture : applique le masquage selon le profil de l'utilisateur.
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
  where case public.my_role()
          when 'cs_admin'   then true
          when 'syndic'     then true
          when 'contractor' then t.category = public.my_category()
          when 'resident'   then true
          else false
        end
) s;
revoke all on public.tickets_feed from public, anon;
grant select on public.tickets_feed to authenticated;

revoke execute on function public.request_access(text,text,text,int,int,text) from public, anon;
revoke execute on function public.hidden_private_count() from public, anon;
grant execute on function public.request_access(text,text,text,int,int,text) to authenticated;
grant execute on function public.hidden_private_count() to authenticated;
grant execute on function public.my_role(), public.my_lot(), public.my_category() to authenticated;

-- ---------- Plans : espace de stockage privé ----------
insert into storage.buckets (id, name, public) values ('plans', 'plans', false)
on conflict (id) do nothing;
create policy plans_read on storage.objects for select to authenticated
  using (bucket_id = 'plans' and public.my_role() is not null and public.my_role() <> 'pending');
create policy plans_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'plans' and public.my_role() = 'cs_admin');
create policy plans_update on storage.objects for update to authenticated
  using (bucket_id = 'plans' and public.my_role() = 'cs_admin')
  with check (bucket_id = 'plans' and public.my_role() = 'cs_admin');
create policy plans_delete on storage.objects for delete to authenticated
  using (bucket_id = 'plans' and public.my_role() = 'cs_admin');

-- =====================================================================
-- Corbeille, restauration et journal des modifications (patch du 11/11/2026, intégré)
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

-- ---------- Import sans doublons (patch 2026-11-12_import_doublons.sql) ----------
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

-- ---------- Administrateur (patch 2026-11-13_administrateur.sql) ----------
-- 1. Marque « administrateur » sur le profil
alter table public.profiles add column if not exists is_admin boolean not null default false;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as
$$ select coalesce((select p.is_admin and p.role = 'cs_admin' from public.profiles p where p.id = auth.uid()), false) $$;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- Le premier membre du Conseil syndical inscrit devient administrateur (s'il n'y en a pas encore).
update public.profiles set is_admin = true
where not exists (select 1 from public.profiles where is_admin)
  and id = (select id from public.profiles where role = 'cs_admin' order by requested_at limit 1);

-- 2. Protection du compte administrateur
create or replace function public.profiles_keep_admin() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and old.is_admin and not public.is_admin() then
    raise exception 'Seul l''administrateur peut modifier ou retirer ce compte.';
  end if;
  if old.is_admin and (tg_op = 'DELETE' or not new.is_admin or new.role <> 'cs_admin')
     and not exists (select 1 from public.profiles where is_admin and id <> old.id) then
    raise exception 'Il doit rester au moins un administrateur.';
  end if;
  if old.role = 'cs_admin' and (tg_op = 'DELETE' or new.role <> 'cs_admin')
     and not exists (select 1 from public.profiles where role = 'cs_admin' and id <> old.id) then
    raise exception 'Il doit rester au moins un membre du Conseil syndical.';
  end if;
  if tg_op = 'UPDATE' then
    new.id := old.id; new.email := old.email; new.requested_at := old.requested_at;
    if auth.uid() is not null and not public.is_admin() then new.is_admin := old.is_admin; end if;
    if new.is_admin and new.role <> 'cs_admin' then
      raise exception 'Un administrateur doit être membre du Conseil syndical.';
    end if;
    if new.role <> 'contractor' then new.category := null; end if;
    return new;
  end if;
  return old;
end $$;

-- Le tout premier inscrit devient Conseil syndical et administrateur.
create or replace function public.request_access(p_name text, p_type text, p_cage text, p_floor int, p_lot int, p_code text)
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); r text; mail text := auth.jwt() ->> 'email'; a public.code_attempts;
begin
  if uid is null then raise exception 'Connexion requise.'; end if;
  select role into r from public.profiles where id = uid;
  if r is not null then return r; end if;
  lock table public.profiles in share row exclusive mode;
  if not exists (select 1 from public.profiles) then
    insert into public.profiles (id, email, name, role, is_admin, lot, cage, floor, resident_type)
    values (uid, mail, btrim(p_name), 'cs_admin', true, p_lot, p_cage, p_floor, p_type);
    return 'cs_admin';
  end if;
  select * into a from public.code_attempts where user_id = uid;
  if a.n >= 8 and a.last_at > now() - interval '1 hour' then return 'locked'; end if;
  if upper(btrim(coalesce(p_code, ''))) <> (select upper(invite_code) from public.settings) then
    insert into public.code_attempts (user_id, n, last_at) values (uid, 1, now())
    on conflict (user_id) do update
      set n = case when public.code_attempts.last_at > now() - interval '1 hour'
                   then public.code_attempts.n + 1 else 1 end,
          last_at = now();
    return 'bad_code';
  end if;
  delete from public.code_attempts where user_id = uid;
  insert into public.profiles (id, email, name, role, lot, cage, floor, resident_type)
  values (uid, mail, btrim(p_name), 'pending', p_lot, p_cage, p_floor, p_type);
  return 'pending';
end $$;

-- 3. Incidents supprimés : visibles et modifiables par l'administrateur seul
drop policy if exists tickets_select on public.tickets;
create policy tickets_select on public.tickets for select to authenticated using (
  case public.my_role()
    when 'cs_admin'   then deleted_at is null or public.is_admin()
    when 'syndic'     then deleted_at is null
    when 'contractor' then deleted_at is null and category = public.my_category()
    else false
  end);
drop policy if exists tickets_update on public.tickets;
create policy tickets_update on public.tickets for update to authenticated
  using (public.is_admin()
         or (deleted_at is null and (public.my_role() in ('cs_admin','syndic')
              or (public.my_role() = 'contractor' and category = public.my_category()))))
  with check (public.my_role() = 'cs_admin'
         or (deleted_at is null and (public.my_role() = 'syndic'
              or (public.my_role() = 'contractor' and category = public.my_category()))));
drop policy if exists tickets_delete on public.tickets;
create policy tickets_delete on public.tickets for delete to authenticated
  using (public.is_admin());

-- Le Conseil syndical peut mettre à la corbeille ; seul l'administrateur restaure.
create or replace function public.tickets_before_update() returns trigger
language plpgsql security definer set search_path = '' as $$
declare s text;
begin
  if auth.uid() is null then return new; end if;
  if public.my_role() = 'contractor' then
    s := new.status; new := old; new.status := s;
  end if;
  new.author_id  := old.author_id;
  new.created_at := old.created_at;
  new.updated_at := now();
  if new.target_type <> 'LOT' then new.lot_number := null; end if;
  if public.my_role() <> 'cs_admin' then
    new.deleted_at := old.deleted_at; new.deleted_by := old.deleted_by;
  elsif new.deleted_at is distinct from old.deleted_at then
    if new.deleted_at is null and not public.is_admin() then   -- restaurer : administrateur seul
      new.deleted_at := old.deleted_at; new.deleted_by := old.deleted_by;
    else
      new.deleted_by := case when new.deleted_at is null then null else auth.uid() end;
      new.deleted_at := case when new.deleted_at is null then null else now() end;
    end if;
  end if;
  return new;
end $$;

-- Mise à la corbeille : passe par une fonction (les règles de lecture ne laissent plus le Conseil syndical
-- voir une ligne supprimée, donc une modification directe serait refusée).
create or replace function public.trash_ticket(p_num int) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if public.my_role() <> 'cs_admin' then raise exception 'Réservé au Conseil syndical.'; end if;
  update public.tickets set deleted_at = now() where num = p_num and deleted_at is null;
end $$;
revoke execute on function public.trash_ticket(int) from public, anon;
grant execute on function public.trash_ticket(int) to authenticated;

-- 4. Journal et corbeille : administrateur seul
drop policy if exists log_select on public.ticket_log;
create policy log_select on public.ticket_log for select to authenticated
  using (public.is_admin());

create or replace view public.tickets_trash as
select t.num, t.floor, t.target_type, t.target_id, t.location, t.title, t.category, t.urgency,
       t.status, t.date, t.author, t.description, t.deleted_at,
       coalesce(p.name, '-') as deleted_by_name
from public.tickets t
left join public.profiles p on p.id = t.deleted_by
where public.is_admin() and t.deleted_at is not null;

-- 5. Import : administrateur seul (appliqué aussi côté base)
create or replace function public.tickets_import_key_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null and new.source <> 'app' and not public.is_admin() then
      raise exception 'L''import est réservé à l''administrateur.';
    end if;
    if auth.uid() is not null and new.source = 'app' then new.import_key := null; end if;
    if new.import_key is not null then new.import_key := left(new.import_key, 80); end if;
  else
    new.import_key := old.import_key;
  end if;
  return new;
end $$;

create or replace function public.known_imports()
returns table (import_key text, num int, deleted boolean)
language sql stable security definer set search_path = '' as $$
  select t.import_key, t.num, t.deleted_at is not null
  from public.tickets t
  where t.import_key is not null and public.is_admin()
$$;

-- 6. Plans : l'administrateur seul les ajoute, remplace ou supprime
drop policy if exists plans_insert on storage.objects;
create policy plans_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'plans' and public.is_admin());
drop policy if exists plans_update on storage.objects;
create policy plans_update on storage.objects for update to authenticated
  using (bucket_id = 'plans' and public.is_admin())
  with check (bucket_id = 'plans' and public.is_admin());
drop policy if exists plans_delete on storage.objects;
create policy plans_delete on storage.objects for delete to authenticated
  using (bucket_id = 'plans' and public.is_admin());

