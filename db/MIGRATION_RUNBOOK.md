# AndonWork – többbérlős migráció (003_multitenant), futtatási útmutató

Ez a dokumentum a `db/migrations/003_multitenant.sql` stagingen, majd éles
Supabase projekten való futtatásának lépéssora. Az éles projekt az AndonWork
termék adatbázisa; ma egyetlen ügyfele a BREMAT (az első cég). Lásd még: `CLAUDE.md`
„Többbérlős SaaS – terv” → „Migráció: BREMAT mint első cég” és „Kockázatok”.

**Alapszabály: élesben csak akkor futtass bármit, ha a staging végigment
hiba nélkül, és a lenti ellenőrző lista minden pontja rendben van.**

**Két éles útvonal van leírva (1–7. lépés stagingen mindkettőhöz közös):**
a **8. pont** a klasszikus migráció valódi adaton (jövőbeli használatra), a
**8b. pont** a kiürítés + friss telepítés – **ez fut most**, mert az éles
adatbázisban jelenleg nincs valódi adat (lásd 8b. pont eleje).

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
- Ugyanez az **éles** (AndonWork, `nuufcwpbjfimykumufgi`) projekthez.
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
Dashboard → Authentication → Users → Add user (pl. `teszt@example.com`,
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
  -f andonwork_prod_backup_$(date +%Y%m%d_%H%M).dump
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
  andonwork_prod_backup_20260916_1200.dump
```

Ha ez sikerrel lefut és a célprojekt táblái/sorai megegyeznek az élessel,
tudod, hogy a mentésből ténylegesen vissza lehet állni – csak ez után menj
tovább az éles migrációra.

## 8. Éles migráció klasszikus úton (jövőbeli valós adathoz – MOST NEM ez fut)

**A mostani BREMAT-átállásra a 8b. pontot használjuk** (lásd lent), mert az
éles adatbázisban jelen pillanatban nincs valódi adat (csak "Teszt Elek" és
próba-sorok) – ilyenkor egyszerűbb és kockázatmentesebb egy friss telepítés,
mint egy éles migráció. Ez a szakasz a **klasszikus migrációs útvonalat**
dokumentálja, ami akkor kell, ha már van valódi, visszaállítatlan éles adat
(pl. egy jövőbeli BREMAT-migráció, vagy a 2. ügyfél, ha közös DB-be kerül).

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

## 8b. Éles kiürítés + friss telepítés (EZ FUT MOST, mert nincs valódi adat)

A döntés: mivel az éles adatbázisban nincs megőrzendő valódi adat, nem a
klasszikus migrációt (8. pont) futtatjuk, hanem kiürítjük a `mk_` táblákat,
és a friss (többbérlős) `db/supabase-setup.sql`-t futtatjuk le rá nulláról –
ez pontosan az, amit CI-ban már háromszor egymás után hibamentesen
leteszteltünk. A migráció és a rollback (`db/migrations/003_multitenant.sql`
+ `db/migrations/rollback/`) **megmarad a repóban** – a jövőbeli valós
ügyféladathoz (2. cég, vagy egy későbbi valós BREMAT-migráció) kell majd.

### 8b.1. Mentés ELŐBB – gyakorlat arra, amikor már lesz mit védeni

Ugyanaz a teljes mentés, mint a 7. pontban, még akkor is, ha most nincs
sok veszíthető adat – ez a gyakorlás arra, amikor lesz:

```bash
pg_dump "postgresql://postgres:<ÉLES_DB_JELSZÓ>@db.nuufcwpbjfimykumufgi.supabase.co:5432/postgres" \
  --no-owner --no-privileges -Fc \
  -f andonwork_prod_backup_before_wipe_$(date +%Y%m%d_%H%M).dump
```

Ha van rá időd, próbáld vissza is tölteni egy eldobható projektbe (lásd 7.
pont visszatöltés-próbája) – most még nem szorul rá az élet, de a gyakorlat
számít, amikor majd igen.

### 8b.2. A `mk_` táblák kiürítése

Éles Dashboard → SQL Editor:

```sql
truncate table
  public.mk_events,
  public.mk_assignment_attachments,
  public.mk_attachments,
  public.mk_assignments,
  public.mk_pins,
  public.mk_pin_failures,
  public.mk_employees,
  public.mk_tasks,
  public.mk_terminals,
  public.mk_teams,
  public.mk_locations
cascade;
```

(`mk_companies`/`mk_profiles`/`mk_platform_admins` nem szerepel a listában –
azok még nem léteznek élesben, a friss `supabase-setup.sql` hozza létre
őket egy lépéssel lejjebb.)

Ha korábban feltöltöttél próba-rajzot a `mk-rajzok` Storage bucketbe: töröld
kézzel a Dashboard Storage nézetében (a `TRUNCATE` csak az `mk_attachments`
DB-sort törli, a tényleges fájlt a Storage-ban nem).

### 8b.3. Mi maradhat ott a régi állapotból, és mit kell még takarítani

A jó hír: a legtöbb dolog **önmagát gyógyítja**, mert a friss
`db/supabase-setup.sql` mindenhol `drop ... if exists` / `create or replace`
mintát használ, nem pedig "csak ha még nincs":

- **RLS policy-k** (a régi `office_all` és a `storage.objects`-en lévő
  régi policy-k): a script eldobja és újra létrehozza őket a többbérlős
  verzióval – nincs kézi teendő.
- **RPC függvények** (`mk_terminal_*`, `mk_archive_*`, `mk_set_pin`,
  `mk__pin_employee`): `create or replace function` – felülíródnak.
  Nincs kézi teendő.
- **Triggerek** (`mk_set_company_id_trg`, `mk_lock_company_id_trg`): a
  script `drop trigger if exists` + újra létrehozás – nincs kézi teendő.
- **Realtime publikáció** (`mk_events`/`mk_assignments` a
  `supabase_realtime`-ban): a script már eleve hibakezelve próbálja
  hozzáadni (`duplicate_object` esetén csendben átlép) – nincs kézi teendő.
- **`mk_companies`/`mk_profiles`/`mk_platform_admins` táblák**: még nem
  léteznek élesben (a migráció még sosem futott ott), a friss script
  létrehozza őket – nincs mit takarítani.

Amit **kézzel** kell megnézni:

- **`storage.objects` a `mk-rajzok` bucketben** – ha a 8b.2. pontban nem
  törölted ki a próba-fájlokat a Storage felületén, azok árván ott
  maradnak (nem funkcionális kockázat, csak felesleges hely/zavaró audit).
- **Bármi, amit korábban kézzel, kísérletként hoztál létre** élesben (pl.
  ha véletlenül bármikor futtattad a `db/verify-migration-before.sql`-t
  élesben, ami létrehozott egy `_migration_verify_snapshot` táblát) –
  ha ilyen van: `drop table if exists public._migration_verify_snapshot;`

### 8b.4. A friss séma telepítése

Éles Dashboard → SQL Editor → `db/supabase-setup.sql` teljes tartalma (ez a
PR-ban lévő, többbérlős verzió) → Run.

### 8b.5. auth.users ↔ mk_profiles ellenőrzés

Éles Dashboard → SQL Editor → `db/verify-auth-profiles.sql` teljes tartalma
→ Run. Az összegzés sor legyen „✅ OK”. Ha valamelyik meglévő irodai
bejelentkezési fiók (`auth.users`) profil nélkül maradt – ez azt jelentené,
hogy be tudna lépni, de üres/hibás képernyőt kapna, mert nincs cégéhez
kötve –, azt a hiányt a lenti móddal oldd fel, mielőtt bárkinek elküldöd
az új linket:

```sql
insert into public.mk_profiles (user_id, company_id, role)
select '<a hiányzó user_id a fenti listából>', (select id from public.mk_companies limit 1), 'owner';
```

### 8b.6. Törzsadatok kézi felvétele (~fél óra)

Az irodai felületen (Törzsadatok fül): a friss séma egy tipikus hegesztőüzem
mintaadataival indul (Hegesztők/Lakatosok/Raktár/Iroda csapatok, 1-es/2-es/
3-as csarnok + Raktár + Iroda helyszín, mintafeladatok, 3 tablet, "Teszt
Elek" dolgozó). Ezeket írd át/bővítsd a valódi adatokra: valódi dolgozók
(csapattal, PIN-nel), valódi feladatok (helyszín, szín, leírás), a valódi
tabletek linkjei kiosztva a csarnokokban. A "Teszt Elek" dolgozót ezután
archiváld vagy töröld (Törzsadatok → Dolgozók).

### 8b.7. Végigkattintós ellenőrző lista

Ezt fusd végig az élesített appon, mielőtt a csapatnak átadod:

- [ ] **Belépés** irodai felhasználónévvel/jelszóval sikeres, a fejlécben a
      helyes név jelenik meg.
- [ ] **Törzsadat felvétele**: egy új dolgozó és egy új feladat létrehozása
      a Törzsadatok fülön, mindkettő megjelenik a heti tervben.
- [ ] **Tablet PIN-nel**: a tablet linkje (`?terminal=<mk_terminals.id>`)
      megnyitva, PIN beírva, a dolgozó neve és a mai beosztása megjelenik.
- [ ] **Kezdés**: feladat elindítva a tableten, az élő nézetben azonnal
      (Realtime) megjelenik "Dolgozik" állapotban.
- [ ] **Rajz csatolása és megnyitása**: a heti tervben egy beosztáshoz
      rajz feltöltve, a tableten a beosztott munka kártyáján megjelenik a
      "Rajz megnyitása" gomb, és a rajz tényleg megnyílik (kép: pinch zoom;
      PDF: lapozás).
- [ ] **Élő nézet**: a csoportosítás (helyszín/csapat szerint) helyesen
      mutatja a dolgozó állapotát, helyét, munkaidejét.
- [ ] **Riport**: a Riportok fülön egy tetszőleges időszakra (pl. "Ez a
      hét") betöltődik mind a négy alfül, és az Excel letöltés is működik.
