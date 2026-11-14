-- Test des photos (14/11/2026). Base neuve : 00, schema.sql, puis ce fichier.
-- Les ERROR affichées sont des refus attendus.
\set ON_ERROR_STOP 0
insert into auth.users values
 ('00000000-0000-0000-0000-000000000001','admin@x.fr'),('00000000-0000-0000-0000-000000000002','res22@x.fr'),
 ('00000000-0000-0000-0000-000000000003','res05@x.fr');
update public.settings set invite_code='CODE1234';
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false); select request_access('Thuan','x','B',1,5,'') as a;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false); select request_access('Karim','x','C',2,22,'CODE1234') as a;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false); select request_access('Lea','x','B',1,6,'CODE1234') as a;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
update profiles set role='resident' where id in ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003');
update profiles set lot=22 where id='00000000-0000-0000-0000-000000000002';
update profiles set lot=6 where id='00000000-0000-0000-0000-000000000003';

\echo == 1 Karim declare dans SON logement ; photos vides a la creation
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
insert into tickets(floor,x,y,target_type,target_id,lot_number,location,title,category,urgency,photos)
 values (2,30,40,'LOT','22',22,'Appartement C22','Fuite sous evier','plumbing','medium','{"9/triche.jpg"}');
select num, photos as attendu_vide from tickets_feed where num=1;
select num as relecture_propre_ligne from tickets where num=1;
\echo == 2 Karim rattache deux photos a son signalement
select add_ticket_photos(1,
  array[1||'/aaaaaa11.jpg',
        1||'/bbbbbb22.webp']) as deux_photos;
\echo == 3 chemin d un autre signalement : refuse
select add_ticket_photos(1, array['999/cccccc33.jpg']);
\echo == 4 Lea (autre logement) ne voit ni les photos ni leur existence
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
select title, photos as attendu_vide from tickets_feed where num=1;
select can_see_ticket_photos(1) as lea_attendu_f;
select can_add_ticket_photos(1) as lea_attendu_f;
select add_ticket_photos(1, array[1||'/dddddd44.jpg']);
\echo == 5 le Conseil syndical voit les photos
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select photos as attendu_2 from tickets_feed where num=1;
select can_see_ticket_photos(1) as cs_attendu_t;
\echo == 6 la colonne ne se modifie pas directement
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
update tickets set photos='{}' where num=1;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select array_length(photos,1) as toujours_2 from tickets where num=1;
\echo == 7 lecture du numero de dossier dans un chemin
select photo_ticket_num('12/aaaaaa11.jpg') as attendu_12, photo_ticket_num('plans/p01') as attendu_null,
       photo_ticket_num('../etc') as attendu_null2;
\echo == 8 Karim retire sa photo, Lea ne peut pas
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
select remove_ticket_photo(1, 1||'/aaaaaa11.jpg');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
select remove_ticket_photo(1, 1||'/aaaaaa11.jpg') as reste_1;
\echo == 8 bis qui peut supprimer le fichier : l auteur et le CS (attendu t, t), pas Lea (f)
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false); select can_delete_ticket_photo(1) as auteur_attendu_t;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false); select can_delete_ticket_photo(1) as cs_attendu_t;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false); select can_delete_ticket_photo(1) as lea_attendu_f;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
\echo == 9 maximum six photos
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select add_ticket_photos(1, array(select 1||'/eeee'||i||'00.jpg' from generate_series(1,6) i));
