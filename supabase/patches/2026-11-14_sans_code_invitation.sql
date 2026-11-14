-- =====================================================================
-- Patch du 14/11/2026 : plus de code d'invitation à l'inscription.
-- À coller UNE SEULE FOIS dans Supabase > SQL Editor > New query > Run.
-- Sans danger si relancé. Ne supprime rien.
--
-- Toute personne connectée (e-mail vérifié ou Google) peut déposer une demande.
-- Elle reste « en attente », sans rien voir, jusqu'à validation par le Conseil syndical.
-- Garde-fou contre les demandes en masse : 40 demandes en attente au maximum.
-- =====================================================================
create or replace function public.request_access(p_name text, p_type text, p_cage text, p_floor int, p_lot int, p_code text)
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); r text; mail text := auth.jwt() ->> 'email';
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
  if (select count(*) from public.profiles where role = 'pending') >= 40 then return 'full'; end if;
  insert into public.profiles (id, email, name, role, lot, cage, floor, resident_type)
  values (uid, mail, btrim(p_name), 'pending', p_lot, p_cage, p_floor, p_type);
  return 'pending';                                   -- p_code est ignoré (gardé pour compatibilité)
end $$;

-- Contrôle : doit afficher « ok ».
select 'ok' as code_invitation_retire;
