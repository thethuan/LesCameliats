-- Test du rôle administrateur (13/11/2026). Base neuve : 00, schema.sql, puis ce fichier.
-- Les ERROR affichées sont des refus attendus.
\set ON_ERROR_STOP 0
insert into auth.users values
 ('00000000-0000-0000-0000-000000000001','admin@x.fr'),('00000000-0000-0000-0000-000000000002','cs2@x.fr'),
 ('00000000-0000-0000-0000-000000000003','res@x.fr');
update public.settings set invite_code='CODE1234';
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false); select request_access('Thuan','x','B',1,5,'') as premier;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false); select request_access('Conseil2','x','A',0,1,'CODE1234') as r;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false); select request_access('Karim','x','C',2,22,'CODE1234') as r;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
update profiles set role='cs_admin' where id='00000000-0000-0000-0000-000000000002';
update profiles set role='resident' where id='00000000-0000-0000-0000-000000000003';
select name, role, is_admin from profiles order by requested_at;
\echo == 1 le premier inscrit est administrateur, pas le 2e membre du conseil (attendu t puis f)
select is_admin() as admin_ok; select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false); select is_admin() as cs2_pas_admin;
\echo == 2 le conseil (non admin) cree un incident normal et le met a la corbeille
insert into tickets(floor,x,y,target_type,location,title,category,urgency) values (0,10,10,'COMMON','Hall','Porte hall','door','low');
select trash_ticket(num) from tickets where title='Porte hall';
select count(*) as cs2_voit_corbeille_attendu_0 from tickets_trash;
select count(*) as cs2_voit_ligne_attendu_0 from tickets where title='Porte hall';
update tickets set deleted_at=null where title='Porte hall';
\echo == 3 le conseil ne peut ni restaurer, ni supprimer definitivement (UPDATE 0 / DELETE 0)
delete from tickets where title='Porte hall';
select count(*) as cs2_journal_attendu_0 from ticket_log;
\echo == 4 l administrateur voit la corbeille et restaure
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select count(*) as admin_voit_corbeille_attendu_1 from tickets_trash;
select count(*) as admin_journal_positif from ticket_log;
update tickets set deleted_at=null where title='Porte hall';
select count(*) as visible_apres_restauration_attendu_1 from tickets_feed where title='Porte hall';
\echo == 5 import : refuse au conseil, accepte pour l administrateur
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
insert into tickets(floor,x,y,target_type,location,title,category,urgency,source,author,import_key) values (0,10,10,'COMMON','Hall','Import interdit','plumbing','low','whatsapp','P','K9');
select count(*) as cs2_known_attendu_0 from known_imports();
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
insert into tickets(floor,x,y,target_type,location,title,category,urgency,source,author,import_key) values (0,10,10,'COMMON','Hall','Import ok','plumbing','low','whatsapp','P','K9');
select count(*) as admin_known_attendu_1 from known_imports();
\echo == 6 compte administrateur protege
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
update profiles set role='resident' where id='00000000-0000-0000-0000-000000000001';
delete from profiles where id='00000000-0000-0000-0000-000000000001';
update profiles set is_admin=true where id='00000000-0000-0000-0000-000000000002';
select is_admin as cs2_toujours_false from profiles where id='00000000-0000-0000-0000-000000000002';
\echo == 7 plans : ecriture refusee au conseil, permise a l administrateur
reset role; alter table storage.objects enable row level security; grant select, insert on storage.objects to authenticated; grant usage on all sequences in schema storage to authenticated; set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
insert into storage.objects(bucket_id,name) values ('plans','p01');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
insert into storage.objects(bucket_id,name) values ('plans','p01');
\echo == 8 l administrateur ne peut pas se retirer s il est le dernier
update profiles set role='resident' where id='00000000-0000-0000-0000-000000000001';
update profiles set is_admin=false where id='00000000-0000-0000-0000-000000000001';
