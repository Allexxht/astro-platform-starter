-- =====================================================================
--  005 – E-mailes bejelentkezés (a felhasználónév + cégenkénti domain
--        helyett)
--
--  Miért: az auth.users.email GLOBÁLISAN egyedi, tehát önmagában
--  megmondja, melyik céghez tartozik a belépő – a kliensnek nem kell
--  domaint hozzáfűznie, és cégválasztó sem kell. Ezzel szűnik meg a
--  CLAUDE.md „Nyitott hiányosságok" 1. pontja: a beégetett bremat.local
--  domain miatt egy másik cég felhasználója puszta névvel a BREMAT
--  fiókjába próbált volna belépni.
--
--  Mit ad hozzá:
--   • mk_profiles.email – az auth.users.email TÜKRE. Azért kell, mert a
--     kliens az auth.users táblát nem látja (és nem is szabad látnia), a
--     Felhasználók listának viszont mutatnia kell, ki melyik címmel lép
--     be. Írni csak service_role tudja: a 004 óta oszlop-szintű GRANT van
--     az mk_profiles-on, és az kizárólag a role + contact_email oszlopra
--     szól – ez az oszlop szándékosan kimarad belőle.
--   • A meglévő sorok feltöltése az auth.users-ből.
--
--  Amit NEM csinál:
--   • Nem dobja el a mk_companies.login_domain oszlopot és a
--     mk_profiles.username-et. A login_domain használaton kívülre kerül
--     (a kód nem hivatkozik rá), a username pedig MEGJELENÍTENDŐ NÉVVÉ
--     válik – nem bejelentkezési azonosító többé. Egy fölösleges oszlop
--     eldobása csak kockázat lenne, haszon nélkül.
--   • Nem nyúl a tablethez: az `anon` + PIN útvonal változatlan.
--
--  Futtatás: Supabase Dashboard → SQL Editor → New query → beillesztés → Run.
--  Idempotens: többször is lefuttatható. Egy tranzakcióban fut.
--  Visszaállítás: db/migrations/rollback/005_email_login_rollback.sql.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1) mk_profiles.email – a bejelentkezési cím tükre
-- ---------------------------------------------------------------------
alter table public.mk_profiles add column if not exists email text;

-- ---------------------------------------------------------------------
-- 2) OSZLOP-SZINTŰ JOGOK – változatlanul csak role + contact_email
--    Kimondva is szerepel itt, hogy látszódjon: az új email oszlopot a
--    kliens nem írhatja. Ha írhatná, egy owner átírhatná a kollégája
--    (vagy a saját) megjelenített bejelentkezési címét úgy, hogy az
--    auth.users-ben más marad – a felület és a valóság szétcsúszna.
-- ---------------------------------------------------------------------
revoke update on public.mk_profiles from authenticated;
grant update (role, contact_email) on public.mk_profiles to authenticated;

-- ---------------------------------------------------------------------
-- 3) A MEGLÉVŐ SOROK FELTÖLTÉSE
--    A tükör forrása mindig az auth.users – a mai @bremat.local fiókok is
--    ide kerülnek, változatlanul. Ha később a Dashboardon átírod egy
--    felhasználó e-mail címét, ezt a lépést futtasd le újra.
-- ---------------------------------------------------------------------
update public.mk_profiles p
   set email = u.email
  from auth.users u
 where u.id = p.user_id
   and p.email is distinct from u.email;

commit;
