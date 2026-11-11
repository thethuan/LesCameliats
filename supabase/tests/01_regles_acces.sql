\set ON_ERROR_STOP 0
insert into auth.users values
 ('00000000-0000-0000-0000-000000000001','cs@x.fr'),('00000000-0000-0000-0000-000000000002','res22@x.fr'),
 ('00000000-0000-0000-0000-000000000003','res8@x.fr'),('00000000-0000-0000-0000-000000000004','pro@x.fr'),
 ('00000000-0000-0000-0000-000000000005','syn@x.fr'),('00000000-0000-0000-0000-000000000006','pend@x.fr'),
 ('00000000-0000-0000-0000-000000000007','stranger@x.fr');
update public.settings set invite_code='CODE1234';
set role authenticated;
\echo == 1 bootstrap: first user becomes cs_admin (no code)
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select request_access('Hélène','Copropriétaire résident','B',1,5,'');
\echo == 2 bad code then good
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
select request_access('Karim','Locataire','C',2,22,'nope');
select request_access('Karim','Locataire','C',2,22,' code1234 ');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false); select request_access('Paul','Locataire','B',2,8,'CODE1234');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false); select request_access('Martin','x','A',0,1,'CODE1234');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false); select request_access('Delorme','x','A',0,1,'CODE1234');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000006',false); select request_access('Lucie','x','B',2,8,'CODE1234');
\echo == 3 pending cannot read settings/profiles of others, cannot self-promote
select count(*) as settings_rows from settings; select count(*) as profiles_seen from profiles;
update profiles set role='cs_admin' where id=auth.uid(); select role from profiles;
insert into profiles(id,name,role) values ('00000000-0000-0000-0000-000000000007','x','cs_admin');
\echo == 4 admin approves
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
select invite_code from settings; select count(*) as profiles_seen from profiles;
update profiles set role='resident' where id in ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003');
update profiles set role='contractor', category='plumbing' where id='00000000-0000-0000-0000-000000000004';
update profiles set role='syndic' where id='00000000-0000-0000-0000-000000000005';
\echo == 4b last admin cannot demote self
update profiles set role='resident' where id=auth.uid();
\echo == 5 tickets by admin
insert into tickets(floor,x,y,target_type,target_id,lot_number,location,title,category,urgency) values
 (2,10,10,'LOT','22',22,'C21','Fuite C21','plumbing','medium'),
 (2,10,10,'LOT','8',8,'B22','Fissure B22','damage','low'),
 (0,10,10,'COMMON','hall',null,'Hall','Porte hall','door','low'),
 (-1,10,10,'PARKING','72',null,'Parking 5','Néon','electricity','low');
\echo == 6 resident 22 view (expect 3: own lot + common + parking), hidden=1
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
select num,title from tickets order by num; select hidden_private_count();
\echo == 6b resident inserts: other lot refused, own ok w/ forced fields
insert into tickets(floor,x,y,target_type,target_id,lot_number,location,title,category,urgency) values (2,1,1,'LOT','8',8,'x','hack','damage','low');
insert into tickets(floor,x,y,target_type,target_id,lot_number,location,title,category,urgency,status,os_number,author,source) values (2,1,1,'LOT','22',22,'x','mine','damage','low','resolved','OS-1','Fake','json') returning num,status,os_number,author,source;
update tickets set status='resolved' where num=3; select num,status from tickets where num=3;
delete from tickets where num=3; select count(*) from tickets;
\echo == 7 contractor: sees plumbing only (1), can change status only
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
select num,title from tickets;
update tickets set status='in_progress', title='HACK', os_number='X' where num=1 returning num,status,title,os_number;
update tickets set status='resolved' where num=3; 
insert into tickets(floor,x,y,target_type,location,title,category,urgency) values (0,1,1,'COMMON','x','pro','plumbing','low');
\echo == 8 pending: commons+parking only (2), no insert
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000006',false);
select num,title from tickets order by num; select hidden_private_count();
insert into tickets(floor,x,y,target_type,location,title,category,urgency) values (0,1,1,'COMMON','x','pend','plumbing','low');
\echo == 9 stranger without profile: nothing
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000007',false);
select count(*) from tickets; select count(*) from profiles;
\echo == 9b lockout after 8 bad codes
select request_access('S','x','A',0,1,'bad') from generate_series(1,8);
select request_access('S','x','A',0,1,'CODE1234');
\echo == 10 syndic: all (5), sets OS, import keeps author, cannot delete
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000005',false);
select count(*) from tickets;
update tickets set os_number='OS-9' where num=1 returning num,os_number;
insert into tickets(floor,x,y,target_type,location,title,category,urgency,author,source,date) values (0,1,1,'COMMON','x','import','door','low','Marc L','whatsapp','2026-11-03') returning num,author,date;
delete from tickets where num=1; select count(*) from tickets;
\echo == 11 anon
reset role; set role anon; select set_config('request.jwt.claim.sub','',false);
select count(*) from tickets;
select request_access('a','b','A',0,1,'CODE1234');
