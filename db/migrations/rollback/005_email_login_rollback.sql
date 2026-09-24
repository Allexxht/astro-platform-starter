-- =====================================================================
--  VISSZAÁLLÍTÁS a 005_email_login.sql migrációhoz.
--
--  Mit állít vissza:
--   • Eldobja a mk_profiles.email oszlopot (a bejelentkezési cím tükrét).
--   • Az oszlop-szintű jogokat a 004 szerinti állapotban hagyja
--     (role + contact_email) – azon a 005 sem változtatott.
--
--  FIGYELEM: az oszlop eldobásával a benne tárolt tükör elvész, de ez NEM
--  adatvesztés: a forrás az auth.users.email, onnan bármikor újratölthető
--  (ezt teszi a 005 3. szakasza is).
--
--  A visszaállítás után a KLIENS is a régi, felhasználónév + domain alapú
--  bejelentkezésre kell visszaálljon – önmagában ez a script nem elég
--  hozzá, a Netlify oldalt is vissza kell állítani a megfelelő deployra.
--
--  Egy tranzakcióban fut: vagy teljesen lefut, vagy semmi nem változik.
-- =====================================================================

begin;

alter table public.mk_profiles drop column if exists email;

-- A 004 által beállított oszlop-szintű jogok visszaállítása (ugyanaz, ami
-- a 005 előtt is volt – kimondva, hogy a séma-összevetés pontosan
-- egyezzen akkor is, ha a 005 után futott bármilyen jogosultság-állítás).
revoke update on public.mk_profiles from authenticated;
grant update (role, contact_email) on public.mk_profiles to authenticated;

-- A séma-nyilvántartásból (006) is kivesszük, hogy a kliens jelezze: ez a
-- migráció most nincs érvényben ezen az adatbázison.
do $$
begin
  if to_regclass('public.mk_schema_versions') is not null then
    delete from public.mk_schema_versions where version = 5;
  end if;
end $$;

commit;
