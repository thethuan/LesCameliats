-- =====================================================================
-- Patch du 11/11/2026 : nouvelles règles de visibilité.
-- À coller UNE SEULE FOIS dans Supabase > SQL Editor > New query > Run.
-- (La base doit déjà contenir le schéma d'origine : ne pas relancer schema.sql.)
--
--  * Compte en attente : ne voit plus aucun signalement ni aucun plan.
--  * Résident : voit tous les signalements. Pour le logement d'un autre,
--    seuls la catégorie, la gravité, le statut, la date et l'étage s'affichent.
--  * Auteur d'un signalement : visible du Conseil syndical, du syndic et
--    de l'auteur lui-même. Personne d'autre.
-- =====================================================================

-- 1. La table n'est plus lisible par les résidents ni les comptes en attente.
drop policy if exists tickets_select on public.tickets;
create policy tickets_select on public.tickets for select to authenticated using (
  case public.my_role()
    when 'cs_admin'   then true
    when 'syndic'     then true
    when 'contractor' then category = public.my_category()
    else false
  end);

-- 2. Le nom de l'auteur ne se lit plus directement dans la table.
revoke select on public.tickets from authenticated;
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

-- 4. Les plans ne sont plus servis aux comptes en attente.
drop policy if exists plans_read on storage.objects;
create policy plans_read on storage.objects for select to authenticated
  using (bucket_id = 'plans' and public.my_role() is not null and public.my_role() <> 'pending');
