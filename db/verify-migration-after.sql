-- =====================================================================
--  Ellenőrző lista – 2. rész: FUTTASD A 003_multitenant.sql UTÁN
--  (a Storage-sorral kapcsolatos részhez érdemes a
--  scripts/migrate-storage-to-company-prefix.mjs lefutása után futtatni,
--  különben minden csatolmány "HIÁNYZIK"-nak fog látszani – ez akkor
--  még helyes, csak korai).
--
--  Nem kell semmit kézzel átnézni számolgatással – a végén egy
--  "OK" vagy "HIÁNYOSSÁGOK" sort ad, alatta a pontos részletekkel.
--
--  Lásd db/MIGRATION_RUNBOOK.md.
-- =====================================================================

do $$
begin
  if not exists (select 1 from information_schema.tables where table_schema='public' and table_name='_migration_verify_snapshot') then
    raise exception 'Nincs elmentett "előtte" pillanatkép. Előbb futtasd a db/verify-migration-before.sql-t A MIGRÁCIÓ ELŐTT, majd ezt a scriptet a migráció után.';
  end if;
end $$;

drop table if exists pg_temp.verify_results;
create temp table verify_results (severity text, detail text);

-- 1) Sorszám-ellenőrzés: minden tábla pontosan annyi sort tartalmazzon, mint
--    a migráció előtt (a migráció sose töröl, csak company_id-t ad hozzá).
do $$
declare
  r record;
  v_now bigint;
begin
  for r in select metric, value from public._migration_verify_snapshot loop
    execute format('select count(*) from public.%I', r.metric) into v_now;
    if v_now <> r.value then
      insert into verify_results values ('HIBA',
        format('%s: előtte %s sor volt, most %s van (%s sor eltűnt/hozzáadódott)', r.metric, r.value, v_now, v_now - r.value));
    else
      insert into verify_results values ('OK', format('%s: %s sor, egyezik a migráció előttivel', r.metric, v_now));
    end if;
  end loop;
end $$;

-- 2) company_id-ellenőrzés: minden company_id-s táblában 0 NULL legyen.
do $$
declare
  t text;
  v_null bigint;
begin
  foreach t in array array['mk_teams','mk_locations','mk_employees','mk_tasks','mk_terminals',
                            'mk_assignments','mk_attachments','mk_assignment_attachments','mk_events',
                            'mk_pins','mk_pin_failures'] loop
    if exists (select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name='company_id') then
      execute format('select count(*) from public.%I where company_id is null', t) into v_null;
      if v_null > 0 then
        insert into verify_results values ('HIBA', format('%s: %s sornak nincs company_id-ja', t, v_null));
      else
        insert into verify_results values ('OK', format('%s: minden sornak van company_id-ja', t));
      end if;
    else
      insert into verify_results values ('HIBA', format('%s: nincs is company_id oszlopa – lefutott a migráció?', t));
    end if;
  end loop;
end $$;

-- 3) mk_companies: pontosan 1 cég (BREMAT) legyen.
insert into verify_results
select case when count(*) = 1 then 'OK' else 'HIBA' end,
       format('mk_companies: %s sor (1-nek kellene lennie)', count(*))
  from public.mk_companies;

-- 4) mk_profiles: legyen legalább 1 owner.
insert into verify_results
select case when count(*) > 0 then 'OK' else 'HIBA' end,
       format('mk_profiles: %s owner szerepkörű sor', count(*))
  from public.mk_profiles where role = 'owner';

-- 5) Storage: az mk_attachments sorokhoz ténylegesen van-e objektum a
--    Storage-ban az ÚJ (company_id-vel prefixelt) útvonalon. Ez a
--    storage.objects metaadatot nézi (van-e ilyen nevű objektum a
--    bucketben) – a tényleges fájl-bájtok letölthetőségét ez nem
--    garantálja, ahhoz nyiss meg ténylegesen egy-két rajzot az appból.
insert into verify_results
select
  case when count(*) filter (where so.name is null) = 0 then 'OK' else 'HIBA' end,
  format('mk_attachments: %s / %s csatolmányhoz van meglévő Storage objektum a <company_id>/ útvonalon (%s hiányzik – futtattad már a scripts/migrate-storage-to-company-prefix.mjs-t?)',
         count(*) filter (where so.name is not null), count(*), count(*) filter (where so.name is null))
  from public.mk_attachments att
  left join storage.objects so on so.bucket_id = 'mk-rajzok' and so.name = att.storage_path;

-- ---------------------------------------------------------------------
-- ÖSSZEGZÉS – ezt nézd meg először
-- ---------------------------------------------------------------------
select
  case when not exists (select 1 from verify_results where severity = 'HIBA')
       then '✅ OK – minden ellenőrzés rendben, semmi nem veszett el'
       else '❌ HIÁNYOSSÁGOK – nézd meg a lenti HIBA sorokat' end
  as osszegzes;

-- Részletek (HIBA-k előbb, hogy azonnal látszódjanak)
select severity, detail from verify_results order by (severity = 'HIBA') desc, detail;

-- Ha végeztél az ellenőrzéssel (akár most, akár később, miután a storage
-- scriptet is lefuttattad és újra lefuttattad ezt a scriptet), ezt a sort
-- külön futtatva takarítsd el az ideiglenes pillanatkép-táblát:
--   drop table if exists public._migration_verify_snapshot;
