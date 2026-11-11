-- Tests de la corbeille et du journal (11/11/2026).
-- À lancer sur une base neuve : 00, schema.sql (ou ancien schéma + les deux patchs), puis ce fichier.
\set ON_ERROR_STOP 0
insert into auth.users values
 ('00000000-0000-0000-0000-000000000001','cs@x.fr'),('00000000-0000-0000-0000-000000000002','res22@x.fr'),
 ('00000000-0000-0000-0000-000000000004','pro@x.fr'),('00000000-0000-0000-0000-000000000005','syn@x.fr');
update public.settings set invite_code='CODE1234';
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false); select request_access('Hélène','x','B',1,5,'') as cs;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false); select request_access('Karim','x','C',2,22,'CODE1234') as r;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false); select request_access('Martin','x','A',0,1,'CODE1234') as r;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false); select request_access('Delorme','x','A',0,1,'CODE1234') as r;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
update profiles set role='resident' where id='00000000-0000-0000-0000-000000000002';
update profiles set role='contractor', category='plumbing' where id='00000000-0000-0000-0000-000000000004';
update profiles set role='syndic' where id='00000000-0000-0000-0000-000000000005';
insert into tickets(floor,x,y,target_type,target_id,lot_number,location,title,category,urgency) values
 (2,10,10,'LOT','22',22,'C21','Fuite C21','plumbing','medium'),
 (0,30,30,'COMMON','hall',null,'Hall','Porte hall','door','low'),
 (-1,40,40,'PARKING','72',null,'Parking 5','Néon','electricity','low');
\echo == 1 CS met l incident 2 a la corbeille (deleted_by = CS, date serveur)
update tickets set deleted_at='2000-01-01' where num=2;
select num, deleted_at > now() - interval '1 minute' as date_serveur, deleted_by_name from tickets_trash where num=2;
\echo == 2 la liste ne montre plus l incident 2 : CS 2 lignes, syndic 2, resident 2 (dont 1 masque ou non)
select count(*) as cs_feed from tickets_feed;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false); select count(*) as syndic_feed from tickets_feed;
select count(*) as syndic_trash from tickets_trash;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false); select count(*) as resident_feed from tickets_feed; select count(*) as resident_trash from tickets_trash; select count(*) as resident_journal from ticket_log;
\echo == 3 le syndic ne peut ni supprimer, ni restaurer, ni modifier un incident supprime
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false);
update tickets set deleted_at=now() where num=1 returning num;
select count(*) as syndic_voit_vue_num1 from tickets_feed where num=1;
update tickets set os_number='X' where num=2 returning num;
update tickets set deleted_at=null where num=2 returning num;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select num as toujours_a_la_corbeille from tickets_trash where num=2; select count(*) as num1_pas_supprime from tickets_feed where num=1;
\echo == 4 corbeille visible du CS seul, restauration
select num, title, author, deleted_by_name from tickets_trash;
update tickets set deleted_at=null where num=2;
select count(*) as feed_apres_restauration from tickets_feed; select count(*) as trash_apres from tickets_trash;
\echo == 5 prestataire change un statut ; syndic pose un OS ; journal
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
update tickets set status='in_progress' where num=1;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false);
update tickets set os_number='OS-7', assigned_contractor='Ets Martin' where num=1;
\echo == 6 suppression definitive : le journal garde la trace mais plus le titre
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
update tickets set deleted_at=now() where num=3;
delete from tickets where num=3;
select ticket_num, action, detail, actor_name, ticket_title from ticket_log order by id;
\echo == 7 le syndic ne peut pas lire le journal ; un prestataire non plus
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false); select count(*) as syndic_journal from ticket_log;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false); select count(*) as prestataire_journal from ticket_log; select count(*) as prestataire_trash from tickets_trash;
\echo == 8 anon : rien
reset role; set role anon; select count(*) from ticket_log; select count(*) from tickets_trash;
