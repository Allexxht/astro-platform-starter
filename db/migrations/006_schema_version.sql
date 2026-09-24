-- =====================================================================
--  006 – Séma-verzió: melyik migráció futott le ezen az adatbázison
--
--  Miért: 2026. szeptember 24-én kiderült, hogy a 005 kódja (PR #8) már
--  élesben futott, az adatbázis-része viszont nem – és ezt semmi nem
--  jelezte. A kód olyan oszlopot kért, ami nem létezett, és a hiba csendben
--  vitt el több funkciót (rajzfeltöltés, Felhasználók fül, Cégek nézet,
--  kollégafelvétel). A kódot a Netlify mergeléskor magától kiteszi, a
--  migrációt kézzel kell futtatni – a kettőt eddig semmi nem kötötte össze.
--
--  Mit ad hozzá:
--   • mk_schema_versions – minden lefutott migráció egy sort kap (sorszám,
--     név, időpont). Nem a legmagasabb számot tároljuk, hanem a teljes
--     listát: ha valaki a 006-ot futtatja, de a 005-öt kihagyja, a lyuk is
--     látszik, nem csak a „legfrissebb” szám.
--   • mk_schema_state() – a lefutott sorszámok listája. A kliens ezt veti
--     össze azzal, amit a kód vár, és ha valami hiányzik, feltűnő
--     figyelmeztetést ad, pontosan megnevezve a futtatandó fájlokat.
--   • VISSZAMENŐLEGES FELTÖLTÉS a régi migrációkra – de nem vakon: minden
--     régi migrációt a tényleges nyoma alapján ismer fel (oszlop, tábla,
--     függvény). Ha az adatbázisban valami tényleg hiányzik, az a feltöltés
--     után is hiányként látszik.
--
--  A régi (001–005) migrációk végére is bekerült egy feltételes
--  bejegyzés: ha valamelyik kimaradt, és csak a 006 UTÁN futtatod le, a
--  nyilvántartásba magától bekerül. A 003–005 rollbackje pedig kiveszi a
--  saját sorát.
--
--  SZABÁLY minden jövőbeli migrációhoz (007-től):
--   • a fájl végén, a commit előtt jegyezze be magát:
--       insert into public.mk_schema_versions (version, name)
--       values (7, '007_valami') on conflict (version) do nothing;
--   • a rollbackje vegye ki a saját sorát
--       (delete from public.mk_schema_versions where version = 7);
--   • a fájlnév kerüljön be a kliens SCHEMA_MIGRATIONS listájába
--     (public/munkakovetes/index.html), és a supabase-setup.sql
--     séma-nyilvántartás szakaszába is.
--  A kereszt-teszt mindhármat forrásból ellenőrzi.
--
--  Futtatás: Supabase Dashboard → SQL Editor → New query → beillesztés → Run.
--  Idempotens: többször is lefuttatható. Egy tranzakcióban fut.
--  Visszaállítás: db/migrations/rollback/006_schema_version_rollback.sql.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1) A NYILVÁNTARTÁS
--    RLS bekapcsolva, policy nélkül: közvetlenül senki nem olvassa és nem
--    írja a kliensből, csak a lenti függvényen át olvasható.
-- ---------------------------------------------------------------------
create table if not exists public.mk_schema_versions (
  version     integer primary key,
  name        text not null,
  applied_at  timestamptz not null default now()
);
alter table public.mk_schema_versions enable row level security;

-- ---------------------------------------------------------------------
-- 2) mk_schema_state() – a lefutott migrációk sorszámai, növekvő sorrendben
--    anon is hívhatja: a bejelentkező képernyő már belépés előtt jelezni
--    tudja a lemaradást. Csak sorszámokat ad vissza, cégadatot nem.
-- ---------------------------------------------------------------------
create or replace function public.mk_schema_state()
returns integer[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(version order by version), '{}') from public.mk_schema_versions;
$$;
revoke all on function public.mk_schema_state() from public;
grant execute on function public.mk_schema_state() to anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) VISSZAMENŐLEGES FELTÖLTÉS – a régi migrációk nyomai alapján
-- ---------------------------------------------------------------------
insert into public.mk_schema_versions (version, name)
select 1, '001_archive_columns'
 where exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'mk_employees' and column_name = 'archived_at')
on conflict (version) do nothing;

insert into public.mk_schema_versions (version, name)
select 2, '002_attachments'
 where exists (select 1 from information_schema.tables
                where table_schema = 'public' and table_name = 'mk_attachments')
on conflict (version) do nothing;

insert into public.mk_schema_versions (version, name)
select 3, '003_multitenant'
 where exists (select 1 from information_schema.tables
                where table_schema = 'public' and table_name = 'mk_companies')
on conflict (version) do nothing;

insert into public.mk_schema_versions (version, name)
select 4, '004_licenc_felhasznalok'
 where exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'mk_write_allowed')
on conflict (version) do nothing;

insert into public.mk_schema_versions (version, name)
select 5, '005_email_login'
 where exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'mk_profiles' and column_name = 'email')
on conflict (version) do nothing;

-- ---------------------------------------------------------------------
-- 4) A 006 SAJÁT BEJEGYZÉSE
-- ---------------------------------------------------------------------
insert into public.mk_schema_versions (version, name)
values (6, '006_schema_version')
on conflict (version) do nothing;

commit;

-- Ellenőrzés: melyik migráció van nyilvántartva
select version, name, applied_at from public.mk_schema_versions order by version;
