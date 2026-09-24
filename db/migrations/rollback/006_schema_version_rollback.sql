-- =====================================================================
--  VISSZAÁLLÍTÁS a 006_schema_version.sql migrációhoz.
--
--  Eldobja a séma-verzió nyilvántartást és a lekérdező függvényt. Üzleti
--  adat nincs benne, csak az, hogy melyik migráció futott le – ez a 006
--  újrafuttatásával a meglévő séma nyomai alapján visszaépül.
--
--  A visszaállítás után a kliens „nincs séma-verzió” figyelmeztetést ad,
--  amíg a 006 újra le nem fut – ez szándékos.
--
--  Egy tranzakcióban fut, és többször is lefuttatható.
-- =====================================================================

begin;

drop function if exists public.mk_schema_state();
drop table if exists public.mk_schema_versions;

commit;
