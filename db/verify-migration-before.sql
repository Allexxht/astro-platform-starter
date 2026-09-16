-- =====================================================================
--  Ellenőrző lista – 1. rész: FUTTASD KÖZVETLENÜL A 003_multitenant.sql
--  ELŐTT (miután az éles adatot már bemásoltad stagingre).
--
--  Elmenti a jelenlegi (migráció előtti) sorszámokat egy ideiglenes
--  táblába, hogy a verify-migration-after.sql – ami egy KÜLÖN SQL Editor
--  futtatásban, a migráció UTÁN fut – össze tudja hasonlítani velük.
--
--  Lásd db/MIGRATION_RUNBOOK.md.
-- =====================================================================

create table if not exists public._migration_verify_snapshot (
  metric      text primary key,
  value       bigint not null,
  captured_at timestamptz not null default now()
);
truncate public._migration_verify_snapshot;

insert into public._migration_verify_snapshot (metric, value) values
  ('mk_teams',                 (select count(*) from public.mk_teams)),
  ('mk_locations',             (select count(*) from public.mk_locations)),
  ('mk_employees',             (select count(*) from public.mk_employees)),
  ('mk_tasks',                 (select count(*) from public.mk_tasks)),
  ('mk_terminals',             (select count(*) from public.mk_terminals)),
  ('mk_assignments',           (select count(*) from public.mk_assignments)),
  ('mk_attachments',           (select count(*) from public.mk_attachments)),
  ('mk_assignment_attachments',(select count(*) from public.mk_assignment_attachments)),
  ('mk_events',                (select count(*) from public.mk_events)),
  ('mk_pins',                  (select count(*) from public.mk_pins)),
  ('mk_pin_failures',          (select count(*) from public.mk_pin_failures));

-- Ez a tábla jelen kell legyen a migráció (003_multitenant.sql) UTÁN is,
-- hogy a verify-migration-after.sql lássa – NE töröld a migráció előtt.
select 'Pillanatkép elmentve. Most futtasd a db/migrations/003_multitenant.sql-t, majd a verify-migration-after.sql-t.' as info;
select * from public._migration_verify_snapshot order by metric;
