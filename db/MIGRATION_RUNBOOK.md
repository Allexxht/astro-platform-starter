# Többbérlős migráció (003_multitenant) – futtatási útmutató

Ez a dokumentum a `db/migrations/003_multitenant.sql` stagingen, majd éles
Supabase projekten való futtatásának lépéssora. Lásd még: `CLAUDE.md`
„Többbérlős SaaS – terv” → „Migráció: BREMAT mint első cég” és „Kockázatok”.

**Alapszabály: élesben csak akkor futtass bármit, ha a staging végigment
hiba nélkül, és a lenti ellenőrző lista minden pontja rendben van.**

A `cross-tenant-rollback-test` CI job (`.github/workflows/cross-tenant-test.yml`)
minden PR-on automatikusan kipróbálja a `003_multitenant.sql` + a hozzá
tartozó rollback scriptet egy eldobható adatbázison, és bájtra pontosan
ellenőrzi, hogy a séma és minden tábla sorszáma pontosan visszaáll-e – ez
a lenti lépéssor helyességét adja, nem helyettesíti (a te futásod éles
adaton, valódi Storage-fájlokkal történik, azt a CI nem tudja lemodellezni).

## 0. Amire szükséged lesz

- A **staging** Supabase projekt "Direct connection" Postgres URI-ja
  (Dashboard → Project Settings → Database → Connection string → URI,
  "Direct connection", NEM a pooled). A jelszót csak a terminálban add meg,
  soha ne írd fájlba/chatbe.
- Ugyanez az **éles** (BREMAT, `nuufcwpbjfimykumufgi`) projekthez.
- `psql` és `pg_dump` telepítve a gépeden (PostgreSQL kliens csomag).
- A staging projekt **üres** (nincs még séma rajta) – ha korábban futtattál
  rajta bármit, előbb egyeztessünk, mielőtt ez az útmutató épít rá.

## 1. Staging séma: a JELENLEGI (migráció előtti) állapot

Ez azért kell, hogy a staging pontosan azt a szerkezetet kapja, amiben az
éles adatbázis MOST van – a migrációt utána ugyanúgy kell tudni lefuttatni
stagingen, mint élesben.

1. Nyisd meg a staging projekt Supabase Dashboardját → SQL Editor → New query.
2. Illeszd be a `db/supabase-setup.sql` tartalmát **a `main` ágról, a
   003-as migráció PR-jának mergelése ELŐTTI állapotból** (ha ezt az
   útmutatót a PR mergelése UTÁN olvasod, nézd meg a git historyban a PR
   előtti commitot, vagy szólj és segítek kikeresni). Run.
3. Ellenőrzés: `select count(*) from information_schema.tables where table_schema='public';`
   – a szokásos 11 `mk_` tábla legyen ott, `mk_companies`/`mk_profiles` MÉG NE.

## 2. Éles adat másolása stagingre

Csak a `public` séma **adatait** másoljuk (nem a sémát – az már megvan az
1. lépésből –, és NEM az `auth` sémát – a staging saját, szintetikus
teszt-felhasználókat kap, nem az éles BREMAT-fiókokat).

```bash
# Éles adat kiexportálása (csak adat, csak public séma, trigger-ek kikapcsolva
# a betöltéskor, hogy a sorrend ne számítson)
pg_dump "postgresql://postgres:<ÉLES_DB_JELSZÓ>@db.nuufcwpbjfimykumufgi.supabase.co:5432/postgres" \
  --schema=public --data-only --no-owner --no-privileges --disable-triggers \
  -f prod_public_data.sql

# Betöltés a stagingre
psql "postgresql://postgres:<STAGING_DB_JELSZÓ>@db.fbkcjvplcsnenjgsirfx.supabase.co:5432/postgres" \
  -v ON_ERROR_STOP=1 -f prod_public_data.sql
```

Ellenőrzés: a táblák sorszáma stagingen egyezzen az éles projektével (pl.
`select count(*) from mk_employees;` mindkét projekten).

## 2.5. "Előtte" pillanatkép mentése (ezt MÉG A MIGRÁCIÓ ELŐTT fusd le)

Staging SQL Editor → új query → illeszd be a **`db/verify-migration-before.sql`**
teljes tartalmát → Run. Ez elmenti a jelenlegi (migráció előtti) sorszámokat
egy ideiglenes táblába (`_migration_verify_snapshot`), amit az 5. lépés
ellenőrző scriptje a migráció UTÁN fog összehasonlítani a ténylegessel. Ha
ezt kihagyod, az 5. lépés ellenőrzése nem tud számokkal összehasonlítani.

## 3. Szintetikus teszt-felhasználó stagingre

Mivel az `auth.users`-t nem másoltuk át, a migráció `mk_profiles` backfillje
üres maradna. Hozz létre 1-2 teszt-felhasználót a staging projekten:
Dashboard → Authentication → Users → Add user (pl. `teszt@bremat.local`,
tetszőleges jelszó). Ezek lesznek a migráció után `role='owner'`.

## 4. A migráció futtatása stagingen

1. Staging Dashboard → SQL Editor → New query.
2. Illeszd be a **`db/migrations/003_multitenant.sql`** teljes tartalmát
   (ebből a PR-ból/branch-ből). Run.
3. Az SQL Editor zöld pipát/"Success" üzenetet mutasson hiba nélkül. Az egész
   script egy tranzakcióban fut (`begin`/`commit`) – ha bárhol hibázna,
   automatikusan semmi nem marad félig alkalmazva.

## 5. Ellenőrző lista stagingen (ezt fusd le, mielőtt élesre mész)

Staging SQL Editor → új query → illeszd be a **`db/verify-migration-after.sql`**
teljes tartalmát → Run. Ez a 2.5. lépésben elmentett "előtte" pillanatképet
hasonlítja össze a ténylegessel, és egyetlen összegző sorban megmondja, hogy
minden rendben van-e:

- **Sorszám-ellenőrzés** táblánként (nem veszett-e el sor a migráció alatt).
- **`company_id`-ellenőrzés** táblánként (mindegyik sor kapott-e céget).
- **`mk_companies`**: pontosan 1 sor (BREMAT).
- **`mk_profiles`**: legalább 1 `owner` (a 3. lépésben létrehozott teszt-felhasználó(k)).
- **Storage**: hány `mk_attachments` sorhoz van ténylegesen meglévő objektum
  a Storage-ban az új, `<company_id>/` prefixű útvonalon. Ha a
  `scripts/migrate-storage-to-company-prefix.mjs` még nem futott (lásd 8.
  lépés, élesben; stagingen csak akkor releváns, ha oda is átmásoltad a
  storage objektumokat), ez a sor jelzi, hogy még hiányoznak – ez ilyenkor
  **nem hiba**, csak korai állapot.

A végén egy `osszegzes` sor: **„✅ OK”** vagy **„❌ HIÁNYOSSÁGOK”**, alatta a
pontos részletek soronként (HIBA-k előbb). Ha bármi HIBA, ne menj tovább,
derítsd ki, mi hiányzik, mielőtt élesre mész.

Ezután **a valódi appon keresztül** is nézd meg:
- Jelentkezz be a staging projekttel (ideiglenesen írd át a
  `public/munkakovetes/index.html` `CONFIG.SUPABASE_URL`/`SUPABASE_ANON_KEY`
  mezőit a staging értékeire a saját gépeden, NE commitold) a 3. lépésben
  létrehozott teszt-felhasználóval – nézd meg, hogy a heti terv, élő nézet,
  törzsadatok ugyanúgy működnek, mint eddig.
- Nyiss meg egy tablet linket (`?terminal=<staging mk_terminals.id>`) és
  jelentkezz be egy meglévő (átmásolt) dolgozó PIN-jével – működjön a Kezdés/
  Feladatváltás/Szünet/Elakadtam/Műszak vége.

**NE futtasd a `tests/cross-tenant/run.mjs`-t közvetlenül staging ellen** –
az saját, eldobható próba-cégeket/felhasználókat hoz létre, és a staginget
szennyezné. A kereszt-tesztnek a CI-ban (GitHub Actions, helyi Supabase CLI
stack) van a helye, nem itt.

## 6. Ha valami nem stimmel stagingen

```sql
-- Staging SQL Editor, teljes tartalom beillesztve:
-- db/migrations/rollback/003_multitenant_rollback.sql
```

Ellenőrizd, hogy a séma pontosan visszaállt (nincs `mk_companies` tábla,
`company_id` oszlopok eltűntek), majd derítsd ki, mi hibázott, javítsd a
migrációt, és kezdd újra a 4. lépéstől.

## 7. Teljes mentés éles adatbázisról a migráció ELŐTT

Ez különbözik a 2. lépés adat-exportjától: ez egy **teljes** (séma + adat,
minden séma, nem csak `public`) biztonsági mentés, amiből katasztrófa esetén
vissza lehet állni.

```bash
pg_dump "postgresql://postgres:<ÉLES_DB_JELSZÓ>@db.nuufcwpbjfimykumufgi.supabase.co:5432/postgres" \
  --no-owner --no-privileges -Fc \
  -f bremat_prod_backup_$(date +%Y%m%d_%H%M).dump
```

Tedd el ezt a fájlt biztonságos, a Supabase-től független helyre (saját
gépeden + egy felhős tárhelyen).

**A mentés csak akkor ér valamit, ha kipróbáltad, hogy vissza is lehet
tölteni belőle** (CLAUDE.md „Kockázatok” 3. pont) – ezt a staging projekten
(vagy egy harmadik, eldobható projekten) próbáld ki a migráció előtt, NEM
élesben:

```bash
pg_restore --no-owner --no-privileges --clean --if-exists \
  -d "postgresql://postgres:<CÉLPROJEKT_DB_JELSZÓ>@db.<célprojekt-ref>.supabase.co:5432/postgres" \
  bremat_prod_backup_20260916_1200.dump
```

Ha ez sikerrel lefut és a célprojekt táblái/sorai megegyeznek az élessel,
tudod, hogy a mentésből ténylegesen vissza lehet állni – csak ez után menj
tovább az éles migrációra.

## 8. Éles migráció (ezt te futtatod, én nem)

Csak akkor, ha az 5. lépés minden pontja stagingen rendben volt, ÉS a 7.
lépés mentése igazoltan visszatölthető:

1. Éles Dashboard → SQL Editor → `db/verify-migration-before.sql` teljes
   tartalma → Run (elmenti az éles "előtte" pillanatképet).
2. Éles Dashboard → SQL Editor → `db/migrations/003_multitenant.sql` teljes
   tartalma → Run.
3. Éles Dashboard → SQL Editor → `db/verify-migration-after.sql` teljes
   tartalma → Run – az összegzés sor legyen „✅ OK”, mielőtt továbblépnél.
4. `SUPABASE_URL=https://nuufcwpbjfimykumufgi.supabase.co SUPABASE_SERVICE_ROLE_KEY=<éles service role> node scripts/migrate-storage-to-company-prefix.mjs --dry-run`
   – nézd át a kimenetet, majd `--dry-run` nélkül futtasd valóban.
5. Futtasd újra a `db/verify-migration-after.sql`-t – most a Storage-sornak
   is „✅ OK”-nak kell lennie (minden csatolmányhoz van objektum az új
   útvonalon).
6. Ha bármi gyanús: `db/migrations/rollback/003_multitenant_rollback.sql`
   azonnal, élesben is, majd vizsgáld ki a mentésből (7. lépés), mielőtt
   újra próbálkoznál.

A `public/munkakovetes/index.html` `CONFIG`-ja élesben NEM változik ebben a
körben (a service role kulcs csak a Netlify env varban van, a storage-script
futtatásához a terminálban add meg ideiglenesen, ne mentsd el sehova).
