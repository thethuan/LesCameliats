-- Test des notifications (21/11/2026). Base neuve : 00, 00b, schema.sql (sans la ligne pg_net), puis ce fichier.
-- Les ERROR affichées sont des refus attendus.
\set ON_ERROR_STOP 0
insert into auth.users values
 ('00000000-0000-0000-0000-000000000001','admin@x.fr'),('00000000-0000-0000-0000-000000000002','cs2@x.fr'),
 ('00000000-0000-0000-0000-000000000003','syn@x.fr'),('00000000-0000-0000-0000-000000000004','res@x.fr');
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false); select request_access('Thuan','x','B',1,5,'') a;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false); select request_access('Marc Leroy','x','B',3,12,'') a;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false); select request_access('Syndic Durand','x','A',0,1,'') a;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false); select request_access('Karim','x','C',2,22,'') a;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
update profiles set role='cs_admin' where id='00000000-0000-0000-0000-000000000002';
update profiles set role='syndic'   where id='00000000-0000-0000-0000-000000000003';
update profiles set role='resident' where id='00000000-0000-0000-0000-000000000004';
\echo == 1 pas de cles serveur : aucun appel, meme avec des abonnes
select push_subscribe('https://fcm.googleapis.com/fcm/send/ADMIN', repeat('B',87), repeat('a',22), 'iPhone');
insert into tickets(floor,x,y,target_type,location,title,category,urgency) values (0,1,1,'COMMON','Hall A','Avant cles','door','low');
reset role; select count(*) as appels_attendu_0 from net._calls;
\echo == 2 la fonction (service_role) cree les cles
set role service_role; select push_set_vapid('PUBLIQUE','{"d":"x"}'); select push_set_vapid('AUTRE','{}');
select vapid_public as attendu_PUBLIQUE from push_vapid();
\echo == 3 abonnements : resident refuse, CS et syndic acceptes
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
select push_subscribe('https://fcm.googleapis.com/fcm/send/RES', repeat('B',87), repeat('a',22), '');
select push_public_key() as resident_attendu_null;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
select push_subscribe('https://fcm.googleapis.com/fcm/send/CS2', repeat('B',87), repeat('a',22), 'Android');
select push_public_key() as cs_attendu_PUBLIQUE;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
select push_subscribe('https://web.push.apple.com/SYN', repeat('B',87), repeat('a',22), 'iPhone');
select count(*) as mes_appareils_attendu_1 from push_my_targets();
\echo == 4 nouveau signalement urgent par l administrateur : un appel, auteur exclu
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
insert into tickets(floor,x,y,target_type,location,title,category,urgency) values (0,1,1,'COMMON','Hall A','Fuite hall','plumbing','high');
reset role;
select body->>'event' as evenement, body->'data'->>'title' as titre, (body->>'secret') = (select secret from push_config) as secret_ok,
       body->>'actor' as acteur, url like '%/functions/v1/notify' as url_ok from net._calls order by id desc limit 1;
select secret as sec from push_config \gset
set role service_role;
select endpoint as destinataires_cs2_et_syndic from push_targets(:'sec','urgent','00000000-0000-0000-0000-000000000001') order by 1;
select count(*) as mauvais_secret_attendu_0 from push_targets('FAUX','urgent',null);
\echo == 5 demande d acces : seulement le Conseil syndical (pas le syndic)
select endpoint as acces_attendu_ADMIN_CS2 from push_targets(:'sec','access',null) order by 1;
\echo == 6 preferences : CS2 coupe nouveaux et urgents
set role authenticated; select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
select set_notify_prefs(false,false,true,true); select get_notify_prefs() as prefs;
set role service_role;
select endpoint as urgent_sans_cs2 from push_targets(:'sec','urgent',null) order by 1;
\echo == 7 import WhatsApp : aucun appel ; changement de statut : un appel
reset role; delete from net._calls;
set role authenticated; select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
insert into tickets(floor,x,y,target_type,location,title,category,urgency,source,author) values (0,1,1,'COMMON','Hall','Import','door','low','whatsapp','P');
update tickets set status='in_progress' where title='Fuite hall';
reset role; select body->>'event' as evenements_attendu_status, body->'data'->>'status' as statut from net._calls order by id;
\echo == 8 nouvelle inscription : evenement access, prenom + initiale
delete from net._calls; insert into auth.users values ('00000000-0000-0000-0000-000000000005','z@x.fr');
set role authenticated; select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false);
select request_access('Zoé Martin','x','C',3,24,'');
reset role; select body->>'event' as ev, body->'data'->>'name' as nom_attendu_Zoe_M from net._calls;
\echo == 9 navigateur : pas d acces aux secrets ni aux fonctions de la fonction
set role authenticated;
select * from push_config;
select * from push_subscriptions;
select * from push_targets((select 'x'),'new',null);
select * from push_vapid();
set role anon; select push_public_key();
