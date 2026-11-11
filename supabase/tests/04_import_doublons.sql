-- Test de l'import sans doublons (12/11/2026).
-- Base neuve : 00, schema.sql, puis ce fichier. Les ERROR pour anon sont des refus attendus.
\set ON_ERROR_STOP 0
insert into auth.users values
 ('00000000-0000-0000-0000-000000000001','cs@x.fr'),('00000000-0000-0000-0000-000000000002','res22@x.fr'),
 ('00000000-0000-0000-0000-000000000005','syn@x.fr');
update public.settings set invite_code='CODE1234';
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false); select request_access('Hélène','x','B',1,5,'') as cs;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false); select request_access('Karim','x','C',2,22,'CODE1234') as r;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false); select request_access('Delorme','x','A',0,1,'CODE1234') as r;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
update profiles set role='resident' where id='00000000-0000-0000-0000-000000000002';
update profiles set role='syndic' where id='00000000-0000-0000-0000-000000000005';
\echo == 1 deux imports identiques : le second est refuse (ERROR 23505 attendue), une seule ligne
insert into tickets(floor,x,y,target_type,location,title,category,urgency,source,author,import_key) values (0,10,10,'COMMON','Hall','Fuite test','plumbing','medium','whatsapp','Paul','K1');
insert into tickets(floor,x,y,target_type,location,title,category,urgency,source,author,import_key) values (0,10,10,'COMMON','Hall','Fuite test','plumbing','medium','whatsapp','Paul','K1');
select count(*) as attendu_1 from tickets where title='Fuite test';
\echo == 2 le CS et le syndic voient la liste des empreintes, pas le resident
select count(*) as cs_attendu_1 from known_imports();
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false); select count(*) as syndic_attendu_1 from known_imports();
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false); select count(*) as resident_attendu_0 from known_imports();
\echo == 3 l empreinte ne change pas a la modification
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
update tickets set import_key='ZZZ', title='Fuite test 2' where title='Fuite test';
select import_key as attendu_K1 from known_imports();
\echo == 4 incident en corbeille : l empreinte reste connue (deleted = true)
update tickets set deleted_at=now() where title='Fuite test 2';
select import_key, deleted as attendu_t from known_imports();
\echo == 5 un resident ne peut pas poser d empreinte
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
insert into tickets(floor,x,y,target_type,location,title,category,urgency,import_key) values (0,10,10,'COMMON','Hall','Test resident','damage','low','R1');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select count(*) as attendu_1_seule_cle from known_imports();
\echo == 6 anon : refus
reset role; set role anon; select * from known_imports();
