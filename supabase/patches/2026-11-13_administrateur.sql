-- =====================================================================
-- Patch du 13/11/2026 : rôle « administrateur » en plus du Conseil syndical.
-- À coller UNE SEULE FOIS dans Supabase > SQL Editor > New query > Run
-- (après les patchs précédents ; sans danger si répété).
--
-- L'administrateur est un membre du Conseil syndical avec des droits en plus.
-- Lui seul peut : importer (WhatsApp / JSON IA), changer les plans,
-- voir la corbeille et le journal, restaurer ou supprimer définitivement.
-- Le Conseil syndical garde le reste (valider les comptes, statuts, suppression
-- vers la corbeille, etc.), mais ne peut plus ni voir la corbeille ni toucher au compte administrateur.
-- =====================================================================

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

-- Contrôle : doit afficher UNE ligne avec is_admin = true (votre compte).
select name, role, is_admin from public.profiles where role = 'cs_admin' order by requested_at;
