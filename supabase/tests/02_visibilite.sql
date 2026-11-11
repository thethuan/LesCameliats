-- Tests des règles de visibilité du 11/11/2026 (à lancer après 00 et schema.sql, sur une base neuve).
\set ON_ERROR_STOP 0
insert into auth.users values
 ('00000000-0000-0000-0000-000000000001','cs@x.fr'),('00000000-0000-0000-0000-000000000002','res22@x.fr'),
 ('00000000-0000-0000-0000-000000000003','res8@x.fr'),('00000000-0000-0000-0000-000000000004','pro@x.fr'),
 ('00000000-0000-0000-0000-000000000005','syn@x.fr'),('00000000-0000-0000-0000-000000000006','pend@x.fr');
update public.settings set invite_code='CODE1234';
grant select on storage.objects to authenticated;
insert into storage.objects(bucket_id,name) values ('plans','p01');
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false); select request_access('Hélène','x','B',1,5,'');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false); select request_access('Karim','x','C',2,22,'CODE1234');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false); select request_access('Paul','x','B',2,8,'CODE1234');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false); select request_access('Martin','x','A',0,1,'CODE1234');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false); select request_access('Delorme','x','A',0,1,'CODE1234');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000006',false); select request_access('Lucie','x','B',2,8,'CODE1234');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
update profiles set role='resident' where id in ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003');
update profiles set role='contractor', category='plumbing' where id='00000000-0000-0000-0000-000000000004';
update profiles set role='syndic' where id='00000000-0000-0000-0000-000000000005';
insert into tickets(floor,x,y,target_type,target_id,lot_number,location,title,category,urgency,description) values
 (2,10,10,'LOT','22',22,'C21 cuisine','Fuite C21','plumbing','medium','secret C21'),
 (2,20,20,'LOT','8',8,'B22','Fissure B22','damage','low','secret B22'),
 (0,30,30,'COMMON','hall',null,'Hall','Porte hall','door','low','ferme-porte'),
 (-1,40,40,'PARKING','72',null,'Parking 5','Néon','electricity','low','');
\echo == A resident 22 (Karim) via la vue : 4 lignes ; le logement 8 est masque ; aucun auteur
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
select num, title, location, target_id, lot_number, x, y, description, author, detail from tickets_feed order by num;
\echo == B resident insere dans son lot : son auteur est visible pour lui seul
insert into tickets(floor,x,y,target_type,target_id,lot_number,location,title,category,urgency) values (2,1,1,'LOT','22',22,'x','mine','damage','low');
insert into tickets(floor,x,y,target_type,location,title,category,urgency) values (0,1,1,'COMMON','x','mon hall','door','low');
select num, title, author from tickets_feed where num>=5 order by num;
\echo == C resident ne peut PAS lire la table directement (attendu : 0 ligne / erreur)
select count(*) from tickets;
select author from tickets;
select count(*) from tickets where title='x';
\echo == D resident autre (Paul, lot 8) : voit le titre de B22, pas celui de Karim, et aucun auteur
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
select num, title, author, detail from tickets_feed order by num;
\echo == E compte en attente : 0 ligne partout
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000006',false);
select count(*) as vue from tickets_feed; select count(*) as table_ from tickets; select hidden_private_count();
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000006',false);
select count(*) as plans_vus_par_pending from storage.objects;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
select count(*) as plans_vus_par_resident from storage.objects;
\echo == F prestataire (plomberie) : sa categorie seulement, details complets, sans auteur dans la vue
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
select num, title, author, detail from tickets_feed order by num;
update tickets set status='in_progress', title='HACK' where num=1 returning num,status,title;
select author from tickets;
\echo == G syndic et CS : tout, avec auteur
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false);
select num, title, author, detail from tickets_feed order by num;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select count(*) from tickets_feed;
update tickets set os_number='OS-1' where num=1 returning num, os_number;
delete from tickets where num=4; select count(*) from tickets_feed;
\echo == H anon : rien
reset role; set role anon; select set_config('request.jwt.claim.sub','',false);
select count(*) from tickets_feed;
