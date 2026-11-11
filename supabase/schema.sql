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

-- Signalements, lecture (RG-SEC-03) :
--   CS et syndic : tout ; prestataire : sa catégorie ;
--   résident : parties communes, parkings, caves et SON logement ;
--   en attente : tout sauf les logements.
create policy tickets_select on public.tickets for select to authenticated using (
  case public.my_role()
    when 'cs_admin'   then true
    when 'syndic'     then true
    when 'contractor' then category = public.my_category()
    when 'resident'   then target_type <> 'LOT' or lot_number = public.my_lot()
    when 'pending'    then target_type <> 'LOT'
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
grant select, insert, update, delete on public.tickets to authenticated;
revoke execute on function public.request_access(text,text,text,int,int,text) from public, anon;
revoke execute on function public.hidden_private_count() from public, anon;
grant execute on function public.request_access(text,text,text,int,int,text) to authenticated;
grant execute on function public.hidden_private_count() to authenticated;
grant execute on function public.my_role(), public.my_lot(), public.my_category() to authenticated;

-- ---------- Plans : espace de stockage privé ----------
insert into storage.buckets (id, name, public) values ('plans', 'plans', false)
on conflict (id) do nothing;
create policy plans_read on storage.objects for select to authenticated
  using (bucket_id = 'plans' and public.my_role() is not null);
create policy plans_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'plans' and public.my_role() = 'cs_admin');
create policy plans_update on storage.objects for update to authenticated
  using (bucket_id = 'plans' and public.my_role() = 'cs_admin')
  with check (bucket_id = 'plans' and public.my_role() = 'cs_admin');
create policy plans_delete on storage.objects for delete to authenticated
  using (bucket_id = 'plans' and public.my_role() = 'cs_admin');
