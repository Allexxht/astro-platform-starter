# Munkakövetés modul – projektjegyzet

## Mi ez
Munkakövető rendszer (MES-lite) a hegesztőüzemnek. Két felülete van:
- **Tablet (csarnok):** falra szerelt Android tablet kioszk módban. A dolgozó PIN-nel azonosít, látja a mai beosztását, és gombokkal jelez: Kezdés, Feladatváltás, Szünet, Elakadtam (okkal), Műszak vége.
- **Iroda:** heti beosztás (dolgozó × nap rács), élő nézet (ki mit csinál, hol, mióta), törzsadatok, riportok Excel exporttal.

A bevezetés ütemekben halad. Most az MVP kész, és az ötletek menet közben alakulnak át: ami nem válik be, azt kivesszük.

**Irányváltás (2026. szeptember):** a cél már nem csak a BREMAT belső rendszere, hanem több cégnek eladható, cégenkénti éves licencdíjas termék. A teljes terv a „Többbérlős SaaS – terv” szakaszban van; **ehhez még nem készült kód**, ez a szakasz a következő fejlesztési kör hivatkozási pontja.

## Fájlok
- `public/munkakovetes/index.html` – egyfájlos app (vanilla JS, nincs build lépés, CSS és JS inline, kommentfejlécekkel tagolva). A script elején van a `CONFIG`. Üres Supabase kulcsokkal DEMÓ módban fut, memóriában tárolt mintaadatokkal. Az Astro starter a `public/` mappát változtatás nélkül átmásolja, így az app a `/munkakovetes/` útvonalon szolgálódik ki.
- `src/pages/api/mk-attachment-url.ts` – Astro API endpoint (Netlify functionként fut). A tablet (anon) ezen keresztül kér rövid lejáratú (10 perces) signed URL-t egy csatolt rajzhoz. Ő az egyetlen hely, ahol a Supabase service role kulcs (env var) használva van.
- `db/supabase-setup.sql` – teljes séma, RLS, függvények, kezdő adatok. Többször is futtatható (idempotens). A Supabase Dashboard SQL Editorában kell futtatni.
- `db/migrations/NNN_*.sql` – növekményes DB-változások meglévő projekthez, sorszámozva. Mindegyik idempotens. Tartalmuk a `supabase-setup.sql` friss verziójában is benne van.

## Architektúra
- Stack: Netlify (GitHub CI/CD), Supabase (Postgres, Auth, Realtime). A supabase-js ESM-ként töltődik a jsdelivr CDN-ről, dinamikus importtal.
- Adatréteg: `createDemoAdapter()` és `createSupabaseAdapter()` ugyanazzal az interfésszel. Új funkciót mindkettőbe be kell építeni.
- Minden tábla `mk_` előtagot kap, mert ugyanabban a Supabase projektben él, mint a Valk logbook.
- URL-ek: iroda `/munkakovetes/`, tablet `/munkakovetes/?terminal=<mk_terminals.id>`.
- Az Excel export a SheetJS (`xlsx`) könyvtárat lazy módon, jsdelivr CDN-ről (`+esm`) tölti be, csak az „Excel letöltés” gomb megnyomásakor – ugyanaz a minta, mint a PDF.js betöltése a tabletes rajznézőnél.

## Adatmodell
- `mk_teams` (csapat/szakma) és `mk_locations` (helyszín/csarnok): szándékosan két külön dimenzió.
- `mk_employees`, `mk_tasks` (helyszín, szín, leírás, `ask_quantity`), `mk_terminals` (az id a tablet titkos kulcsa).
- `mk_employees.archived_at` és `mk_tasks.archived_at`: kitöltve = archivált. Az archivált elem eltűnik a törzsadatokból, a heti tervből és a tabletről (a listák `archived_at is null` / kliensoldali szűréssel), de a neve az `mk_events` soraiban megmarad, így a múltbeli napok élő nézete olvasható.
- `mk_assignments`: `work_date` + dolgozó + feladat egyedi. A `note` mezőbe kerül most a rendelésszám, a `details` mezőbe a többsoros leírás/tudnivaló.
- `mk_attachments`: feltöltött rajz (PDF/JPG/PNG) – `storage_path`, fájlnév, típus, méret. `mk_assignment_attachments`: beosztás ↔ csatolmány kapcsolótábla (több beosztás is hivatkozhat ugyanarra a fájlra). Csatolmány törlésekor (kliensoldali logika, `deleteAttachmentIfOrphan`) csak akkor törlődik a Storage-ból és az `mk_attachments`-ből, ha már semmilyen beosztás nem hivatkozik rá.
- `mk_events`: csak bővülő eseménynapló. Típusai: `start`, `pause`, `resume`, `block`, `end`, `qty`.
- Az állapotot és a munkaidőt mindig az eseménynaplóból számoljuk (`summarize()` a kliensben), külön állapotmezőt nem tárolunk.
- **Riportok:** nincs hozzá külön tábla vagy nézet. A Riportok fül a kiválasztott időszakra egyszer lekéri az `mk_events` és `mk_assignments` sorokat (ugyanazokkal az adatréteg-függvényekkel, mint az élő nézet és a heti terv), és a négy alfül, illetve a csapat/helyszín/dolgozó szűrők ebből, kliensoldalon számolnak újra – nincs újabb DB-hívás szűrő- vagy fülváltáskor. A nap-határokat (melyik esemény melyik naphoz tartozik) mindig Europe/Budapest szerint, `Intl.DateTimeFormat`-tal számoljuk, függetlenül attól, milyen időzónában fut a böngésző.

## Biztonság
- Iroda = bármely `authenticated` felhasználó (MVP). A nyilvános regisztráció legyen kikapcsolva.
- Irodai belépés felhasználónévvel: a kliens a `CONFIG.LOGIN_DOMAIN` (`bremat.local`) alapján e-maillé alakítja (kisbetű, ékezet le, szóköz→pont, pl. „Alex" → `alex@bremat.local`), és így hívja a Supabase `signInWithPassword`-öt. A Supabase Auth-ban a felhasználók `<valami>@bremat.local` e-maillel vannak. Aki `@`-ot ír be, azt változatlanul e-mailként használjuk (a régi valódi e-mailes fiók is működik).
- `mk_archive_employee` / `mk_archive_task`: security definer, csak `authenticated`. Akkor hívja a kliens, ha az elemhez már tartozik `mk_events` sor, ezért véglegesen nem törölhető. Kikapcsol, `archived_at`-et állít, a beosztásokat törli, dolgozónál a PIN-t is (`mk_pins`).
- Tablet = `anon`, csak RPC-t hívhat: `mk_terminal_catalog`, `mk_terminal_identify`, `mk_terminal_event`. A PIN minden hívással megy.
- Hibás PIN esetén tabletenként legfeljebb 10 próbálkozás engedett percenként.
- `mk_pins`: sha256 hash, RLS policy nélkül, csak security definer függvények érik el. `mk_set_pin` csak `authenticated` jogosultsággal hívható, `mk__pin_employee` belső függvény.
- `mk_events` táblára nincs update/delete policy.
- A „ma” a Europe/Budapest időzóna szerint számolódik.
- **Rajzok (ügyfél műszaki rajzok):** privát Supabase Storage bucket, `mk-rajzok`, nyilvános link nincs.
  - Iroda (`authenticated`): közvetlen storage policy (select/insert/delete a `mk-rajzok` bucketre) – feltöltés, megnyitás (`createSignedUrl`), törlés a kliensből megy.
  - Tablet (`anon`): nincs Storage policyja. Egy rajzot csak a `mk_terminal_attachment_path(p_terminal, p_pin, p_attachment)` security definer függvényen keresztül tud elérni, ami – a többi `mk_terminal_*` függvényhez hasonlóan – ellenőrzi a tablet + PIN párost, és csak akkor ad vissza tárolási útvonalat, ha a rajz az azonosított dolgozó MAI beosztásához tartozik. A tényleges signed URL-t a `src/pages/api/mk-attachment-url.ts` Netlify function állítja elő a Supabase service role kulccsal (ez a kulcs csak a Netlify env varban van, a repóban soha).
  - DEMÓ módban a fájlok a böngésző memóriájában élnek (`URL.createObjectURL`), a tablet ugyanúgy ellenőrzi a jogosultságot kliensoldalon, mint éles módban a szerver.

## Dizájn
- Színek: sötét acélszürke alap, izzó narancs a márkához és a fókuszhoz.
- Andon színek csak állapotot jelölnek: zöld = dolgozik, sárga = szünet, piros = elakadt. Feladatszínnek ezeket ne használd.
- Betűk: Barlow / Barlow Condensed. Minden UI-szöveg magyar.
- Tablet: kesztyűs kézre méretezett gombok, egy művelet legfeljebb 2–3 érintés. 45 mp tétlenség után visszaáll a PIN képernyőre – kivéve, amíg egy rajz nyitva van, akkor 10 perc (`CONFIG.TERMINAL_VIEWER_IDLE_SECONDS`).
- Rajz megjelenítő (tablet): teljes képernyős, az appon belül. Kép: `<img>` + saját pinch-zoom/pan (érintésfigyeléssel, nem natív böngésző zoom). PDF: PDF.js (cdnjs, `CONFIG.PDFJS_VERSION`), lapozással, canvas-ra rajzolva, ugyanazzal a pinch-zoommal.

## Többbérlős SaaS – terv (2026. szeptember 15.)

Ez a szakasz a megbeszélt, eldöntött irányt írja le a BREMAT-specifikus belső rendszerből eladható, több céges termékké váláshoz. **Még nem készült hozzá kód** – ez a következő fejlesztési kör tervezési alapja.

### Cégazonosítás az adatmodellben – ez épül MOST, a fizikai szétválasztás kérdésétől függetlenül
Minden `mk_` táblához egy `company_id` oszlop kerül (denormalizáltan, még ott is, ahol JOIN-nal levezethető lenne – egyszerűbb és gyorsabb RLS-t/indexet ad). Ehhez tartozik:
- `mk_companies` (cég neve, licenc-lejárat, `active` kézi kapcsoló, a dátumtól függetlenül).
- `mk_profiles` (`user_id` → `auth.users.id`, `company_id`, `role`: `owner`/`office` az induló verzióban – a `location_id` oszlop és a `location` szerepkör-érték fenntartva a jövőnek, de nem aktív, lásd „Szerepkörök”).
- `mk_platform_admins` (`user_id`) – **külön** tábla, szándékosan nem a `mk_profiles`-ban, hogy a rendszergazda-jog sose keveredjen a céges szerepkör-logikával.
- RLS minden táblán: `company_id = mk_current_company()` (egy `security definer stable` segédfüggvény, ami a hívó `auth.uid()`-jéhez tartozó `mk_profiles` sorból olvas). A `company_id`-t sose fogadjuk el a klienstől – egy `before insert` trigger mindig felülírja, a `with check` csak védőháló.
- **Ki írhatja az `mk_profiles` és `mk_companies` táblákat – ez a legkritikusabb pont, mert enélkül bárki átléptetheti magát másik céghez:**
  - `mk_profiles` INSERT: kliensoldalról soha. Minden felhasználó (az első owner és minden későbbi kolléga is) `auth.users` létrehozásán megy át, ami csak service role-lal lehetséges – tehát mindig a rendszergazda-felület, illetve egy jövőbeli "kolléga meghívása" szerveroldali (service role) végpontján keresztül jön létre, nem közvetlen kliens-INSERT-tel.
  - `mk_profiles` UPDATE: csak `role='owner'`, csak a saját cégén belül (`company_id = mk_current_company()` mindkét oldalon – a `using` és a `with check` is ugyanezt a kifejezést nézi, így a `company_id` gyakorlatilag módosíthatatlan ezen a policyn keresztül), és **kifejezetten kizárva a saját sora** (`user_id <> auth.uid()`) – egy owner nem tudja saját magát átminősíteni vagy más céghez áthelyezni. Extra védelem, ami RLS-hibától függetlenül is véd: oszlop-szintű `GRANT`/`REVOKE` úgy állítva, hogy `company_id`-t és `user_id`-t még owner se tudja szerepeltetni egy UPDATE-ben.
  - `mk_profiles` DELETE: csak `role='owner'`, csak a saját cégén belül, saját sora nélkül (kollégát lehet törölni/hozzáférést megszüntetni, saját magát nem).
  - `mk_companies` SELECT: mindenki csak a saját `company_id`-jű sorát látja.
  - `mk_companies` UPDATE: **a `license_expires_at` és az `active` oszlopot `authenticated` szerepkör egyáltalán nem tudja írni** – ez is oszlop-szintű `GRANT`/`REVOKE`, nem csak RLS-feltétel, tehát ezt kizárólag `service_role` (a rendszergazda-felület szerveroldali végpontja) módosíthatja, egy owner semmilyen módon nem. A `name` oszlopot egy owner írhatja a saját cégén.
  - `mk_companies` INSERT/DELETE: kliensoldalról soha – új cég létrehozása és megszüntetése is a rendszergazda-felület szerveroldali (service role) végpontján megy.
- **A tablet `security definer` RPC-i (`mk_terminal_*`, `mk_archive_*`, `mk_set_pin`) megkerülik az RLS-t** – ezekben KÉZZEL, minden lekérdezésben kell a `company_id` szűrés, ez a legkritikusabb kockázati pont. Ide **kettős védelem** kerül: a lekérdezés eleve szűrt, *és* a visszaadás előtt egy explicit ellenőrzés (ha mégis más cég sora jönne vissza, dobjon hibát).
- **PIN-egyediség céges hatókörre vált** – ma globálisan egyedi (4 jegyű PIN, 10 000 lehetőség, egyetlen cégnél nem ütközik, de több cégnél garantáltan lesz kollízió). A `mk_pins` és a PIN-keresés/egyediség-ellenőrzés cégen belülire szűkül.
- **Storage:** a `mk-rajzok` bucket tárolási útvonala `<company_id>/<uuid>/<fájlnév>` sémára vált, a storage policy a mappa első szegmensét hasonlítja `mk_current_company()`-hoz.

### Kereszt-teszt: valódi kapu, nem emlékezet
A kereszt-teszt nem "emlékeztető", hanem egy **GitHub Actions workflow**, ami minden pull requesten automatikusan lefut, és ha elbukik, a **branch protection** miatt a mergelés gombja le van tiltva – nincs "elfelejtettem" eshetőség.

**Hogyan fut a teszt:**
- A Supabase CLI helyi (Docker-alapú) dev stack-je (`supabase start`) indul el a CI futtatóban – ez egy önálló, eldobható Postgres+Auth+PostgREST+Storage környezet, nem az élő vagy a staging projekt.
- A séma (`db/supabase-setup.sql` + `db/migrations/*.sql`) alkalmazva lesz ellene.
- Egy teszt-script két próba-céget és felhasználót hoz létre, majd A cég bejelentkezett session-jével megpróbál hozzáférni B cég adataihoz – minden érintett táblán (select/insert/update) ÉS minden `mk_terminal_*`/`mk_archive_*` RPC-n (más cég terminal_id/task_id/attachment_id-jével hívva). Minden próbálkozásnak el kell buknia (üres eredmény vagy hiba) – ha bármelyik átmegy, a teszt bukik.
- A workflow PR-on és `main`-re irányuló push előtt is lefut.

**Két üzemmód, hogy a kapu ne zárja be a repót a többbérlős kód előtt:**
- **Bootstrap** (a `mk_companies` tábla még nem létezik): a teszt **zölden** fut le, jól látható üzenettel, hogy jelenleg nincs többbérlős séma, ezért semmit nem vizsgált. Ez a mai állapot – a jelenlegi, egycéges kód így továbbra is mergelhető.
- **Szigorú** (a `mk_companies` tábla létezik): innentől a teszt nem az emlékezetünkre hagyatkozik, hanem magában az adatbázisban keres meg minden `company_id` oszlopos táblát és minden `company_id`-t használó security definer függvényt (`information_schema` + `pg_proc` lekérdezéssel), és **bukik**, ha bármelyik hiányzik a `tests/cross-tenant/manifest.mjs`-ből (vagy ha az teljesen üres). Csak ezután fut le a tényleges A-cég-vs-B-cég próba a manifestben regisztrált táblákon/RPC-ken.

**Branch protection beállítása a GitHubon (ezt egyszer kell beállítani, kézzel, a repó Settings menüjében):**
1. GitHub repo → **Settings → Branches** → **Add branch protection rule**.
2. Branch name pattern: `main`.
3. Bekapcsolva: **Require a pull request before merging** – ettől kezdve a `main`-re közvetlen push le lesz tiltva, csak PR-on keresztül lehet mergelni.
4. Bekapcsolva: **Require status checks to pass before merging**, és a listából kiválasztva a kereszt-teszt workflow neve (csak azután jelenik meg a listában, hogy a workflow már lefutott legalább egyszer).
5. Bekapcsolva: **Require branches to be up to date before merging** – így a teszt mindig a legfrissebb `main` ellen fut.
6. **Fontos:** a **"Do not allow bypassing the above settings"** opció is bekapcsolva – ez a szabályt az adminra is érvényessé teszi, különben egy piros teszt mellett is lehetne "force merge"-elni, és pont ez ellen kell védekezni.

**Miért ez, és nem más:** egy lokális git pre-push hook gyengébb védelem, mert megkerülhető (`--no-verify`), vagy egyszerűen nincs telepítve egy friss klónon – jó gyors, helyi visszajelzésre, de nem helyettesíti a GitHub-oldali kaput. A GitHub Actions + branch protection az, ami tényleg **megállítja a feltöltést**, nem csak figyelmeztet.

### Két lehetséges út a cégek fizikai szétválasztására – a döntés elhalasztva a 2. ügyfélig
Az első ügyfél (BREMAT) saját, a Valk logbooktól leválasztott Supabase projektben van egyedül – **jelenleg nincs is különbség a két út között**, mert egy projektben egy cég van. A döntést a 2. ügyfél tényleges megjelenésekor hozzuk meg.

**(a) A 2. ügyfél ugyanabba a projektbe kerül (közös DB + RLS):**
- Nincs új infrastruktúra – csak egy új `mk_companies` sor + `mk_profiles` bejegyzés az első felhasználójának.
- Feltétel: a fenti `company_id` + RLS + kereszt-teszt már készen és bizonyítottan jól működik (ez amúgy is előfeltétele mindkét útnak).
- Kockázat: RLS/RPC-hiba esetén a szivárgás a közös DB-n belül elméletileg lehetséges – ezért a kereszt-teszt kötelező, mielőtt egy 2. valós ügyfél élő adatot kap.

**(b) A 2. ügyfél saját, dedikált Supabase projektet kap:**
- Új projekt létrehozása (Supabase Management API vagy kézzel a Dashboardon).
- A séma + RLS + függvények (`db/supabase-setup.sql` és a `db/migrations/*.sql` teljes sora) lefuttatása az új projekten – ha ez a modell nyer, ezt automatizálni kell, mert 3+ projektnél a kézi futtatás már hibázásra ad esélyt.
- Kell egy központi, kis "router"-tár (cég → projekt URL/kulcsok), amiből a kliens login előtt megtudja, melyik Supabase projekthez kell fordulnia.
- Migrációk automatikus futtatása minden projekten: egy CI-pipeline, ami a router-tárból végigmegy az aktív cégek projektjein, projektenként naplózva a sikert/hibát, és **leáll**, ha bármelyiken hiba van (nem fut tovább vakon a többivel).

### Mit kerüljünk el MOST, hogy ne zárjuk be magunkat egyik útba se
1. Ne épüljön be sehova olyan feltételezés, hogy "csak egy Supabase projekt létezik örökre" – a `CONFIG.SUPABASE_URL`/kulcs-hivatkozást úgy alakítsuk ki, hogy később egy lookup-réteg elé kerülhessen anélkül, hogy az app többi része tudna róla.
2. A service role kulcsot ne szórjuk több helyre – egy helyen (Netlify env var), dokumentáltan, hogy ha (b) felé mennénk, tudjuk, mit kell projektenként duplikálni.
3. Az új-cég-létrehozó admin-logikát ne írjuk hardkódolt, egyetlen Supabase URL-t feltételező módon – legyen paraméterezhető, még ha most csak egy értéket kap is.
4. Ne tervezzünk cégek közötti összesített lekérdezést/riportot ("az összes ügyfél összesített statisztikája") – ez architekturálisan csak közös DB-nél működne, és ha ilyen funkció felmerül, az implicit módon eldönti a kérdést. Ha kell, az explicit döntés legyen, ne egy mellékesen bevezetett funkció ereje.
5. A `company_id`-t mindenhol denormalizáljuk, sose csak JOIN-nal levezetve – ez mindkét útnál helyes, egyiknél sem árt.
6. A bejelentkezés-logikát úgy írjuk, hogy egy jövőbeli "melyik projekthez tartozol" lépés elé kerülhessen anélkül, hogy át kellene írni – most (egy projekt) ez nem kérdés, de a kód szerkezete ne zárja ki.

### Szerepkörök
Az induló verzió **csak két céges szerepkört tartalmaz** – a helyszín-korlátozott szerepkör kimarad az első körből (lásd alul, miért).

| Szerepkör | Jogkör |
|---|---|
| **Rendszergazda** (`mk_platform_admins`) | Csak cég-kezelés: cégek listája, létrehozás, licenc. **Nincs** alapértelmezett rálátása egy cég napi adataira (élő nézet, dolgozók, riport) – ez természetesen kijön abból, hogy `mk_current_company()` egy tiszta rendszergazdánál `NULL`, ami sose egyezik egy valódi céggel. |
| **Tulajdonos/admin** (`role='owner'`) | Minden a saját cégén belül, plusz a cég felhasználóinak kezelése (lásd fentebb az `mk_profiles` írási jogokat) és a licenc-állapot **megtekintése** (az írása nem – lásd fentebb, csak platform admin). |
| **Irodai** (`role='office'`) | Ugyanaz, mint a tulajdonos, csak felhasználó-kezelés és licenc nélkül (törzsadat-szerkesztés, PIN-kiadás is belefér). |

**Helyszín-korlátozott szerepkör – kimarad az első körből.** A döntés: vagy teljes RLS-kikényszerítéssel épül, vagy egyelőre nincs ilyen szerepkör – UI-szintű szűrés (ahol a szerver mindent visszaadna, csak a felület rejtené el a többit) nem elég, mert egy közvetlen API-hívás megkerülné. Amit a teljes RLS-hez tudni kell, mielőtt ez megépül:
- A `mk_events`/`mk_assignments` táblákra is kellene egy denormalizált `location_id` oszlop (a `company_id` mintájára, a hozzá tartozó feladat/tablet helyszínéből beírva íráskor) – ezzel az RLS gyors és egyszerű (`location_id = mk_current_location()`), nem kell drága JOIN-t futtatni minden sornál. A `mk_tasks`/`mk_terminals` táblákon már ma is van `location_id`, azokra a szűrés emiatt triviális lenne.
- **A nyitott, még megoldatlan rész: a `mk_employees` táblának nincs helyszíne** (a dolgozó a csapatához van kötve, nem egy helyszínhez). Egy helyszín-korlátozott felhasználó számára nem egyértelmű, mely dolgozókat "lássa" a törzsadatok között, hiszen valaki több helyszínen is dolgozhat különböző napokon – ez nem egy statikus oszlop, hanem egy levezetett kérdés ("ki kapott már beosztást ezen a helyszínen"). Ezt tisztázni kell, mielőtt a szerepkör megépül.
- Amíg ez a két pont nincs végiggondolva és megépítve, ez a szerepkör nem kerül be a termékbe – se UI-szintű, se félkész RLS-változatban.

### Új ügyfél beállítása (rendszergazda-felület)
Egy új, csak platform-adminnak látható nézet: cégnév, licenc-lejárat, első felhasználó (felhasználónév + jelszó), opcionális "példa adatok betöltése" kapcsoló (a mai BREMAT-mintájú csapatok/helyszínek/feladatok, amit az ügyfél átnevezhet – ha nincs bejelölve, a cég üresen indul). Technikai csavar: az `auth.users` létrehozása csak service role kulccsal lehetséges, ezért ez egy **új, író Netlify function** lesz (a meglévő `mk-attachment-url.ts` mintájára, de ez a hívó platform-admin jogosultságát is ellenőrzi, mielőtt bármit létrehoz).

### Licenc
- `mk_companies.license_expires_at` + `active` (kézi kapcsoló, a dátumtól függetlenül).
- Lejáratkor **türelmi időszak**: az iroda be tud jelentkezni, mindent lát, de nem tud új eseményt/beosztást rögzíteni; a tablet egy "Lejárt előfizetés, keresse az irodát" képernyőt mutat. A kikényszerítés DB/RPC szinten történik (a security-definer RPC-k itt is kézzel ellenőrzik – ugyanaz az ok, mint a `company_id`-nál), a kliens csak UX-et ad hozzá (banner), nem ez a védelmi határ.

### Bejelentkezés és MFA
- **Login UX marad**: felhasználónév + kitalált domain (mai minta), kiegészítve cég-azonosítóval – amíg csak BREMAT létezik, a UX nem változik.
- **Jelszó + TOTP** (Supabase Auth natív MFA, `auth.mfa.enroll/challenge/verify`), nincs hozzá extra szolgáltatás.
- **"Megbízható eszközön 30 napig ne kérdezze újra"**: ez nem Supabase-natív – egy saját `mk_trusted_devices` (user_id + eszköz-token + lejárat) rekord, sikeres MFA után beállítva. UX-kényelem, nem biztonsági garancia: a jelszó ellopott tokennel is kell a belépéshez.
- **E-mailes kód mint MFA-tartalék** (aki nem használ TOTP appot): ehhez **valós e-mail cím kell minden felhasználóhoz, külön mezőként** – ez bekerül az onboarding űrlapba (nem a bejelentkezési névtől függ, csak az MFA-tartalék e-mail kiküldés célja). Kell hozzá egy külső tranzakciós email-szolgáltatás (pl. Resend/Postmark – a Supabase beépített levélküldője csak tesztre elég, túl szűk rate-limittel).
- **Elveszett telefon**: a cég tulajdonosa tud egy KOLLÉGÁJA MFA-faktorát törölni (saját magát ne tudja simán kikapcsolni). Ha az egyetlen owner veszíti el, a rendszergazda service role-lal tud törölni – jól naplózott, vészhelyzeti admin-funkció.
- **Erős jelszó**: Supabase Auth Dashboard minimum-hossz beállítás (min. 12 karakterre emelve), plusz klienses komplexitás-ellenőrzés az űrlapon.
- **Sikertelen belépések naplózása/korlátozása** – itt van egy valódi kompromisszum, amit érdemes tudni:
  - A **saját `/api/mk-login` Netlify function** (a kliens nem hívja közvetlenül a Supabase-t, a function egy `mk_login_failures` táblával, a tablet `mk_pin_failures`-mintáján, felhasználóra szabottan korlátozza a próbálkozásokat) ad valódi, célzott fiókzárolást és naplózást. **Hátránya**: ez egy új, egyetlen pontban összefutó függőség lesz a bejelentkezésben – ha ez a function bármiért nem elérhető (kódhiba, Netlify-kiesés, timeout), **senki nem tud bejelentkezni**, miközben korábban a kliens közvetlenül a Supabase saját, jobban tesztelt, magas rendelkezésre állású Auth API-ját hívta. Ez a hátrány nem elméleti, hanem az architektúra egy valódi új törésponja.
  - **Alternatívák, amik nem vezetnek be ilyen töréspontot:**
    - **Supabase natív rate limitje** az Auth API-n – IP/globális szintű túlterhelés-védelem, kódolás nélkül működik, de nem ad felhasználóra szabott zárolást.
    - **Captcha** (pl. Cloudflare Turnstile) a login űrlapon – kliens-oldali widget, nincs saját szerver, jelentősen csökkenti az automatizált brute-force kockázatot.
    - **Kliens-oldali fékezés** (egyre hosszabb várakozás a gomb újbóli engedélyezése előtt) – gyenge, megkerülhető védelem, de nulla új infrastruktúra/kockázat.
  - **Ajánlott kiindulás: Supabase natív rate limit + Captcha.** A saját `/api/mk-login` végpontot csak akkor vezessük be, ha ez bizonyítottan nem elég – konkrétan, ha a hozzáférési logban (lásd lent) célzott, ismétlődő próbálkozást látunk egy adott ügyfél fiókjai ellen, vagy egy ügyfél szerződésben/megfelelőségi okból kifejezetten megköveteli a felhasználóra szabott zárolást.
- **Tablet marad PIN-only, MFA nélkül** – tudatos döntés, nem hanyagság: a tablet megosztott, fizikailag felügyelt kioszk-eszköz, nem személyes bejelentkezés; a védelmi határ nem a PIN ereje, hanem a tablet linkjének titkossága (lásd alább) + a meglévő percenkénti brute-force limit. A biztonsági befektetést oda koncentráljuk, ahol a legnagyobb kárt lehet okozni (irodai admin-hozzáférés).

### A tablet linkjének kockázata, ha kikerül
- **Eszközhöz kötés + "Link csere" gomb együtt épül**: az első sikeres PIN-belépés után a tablet egy eszköz-tokent kap (`mk_terminal_devices`: terminal_id + token), a szerver csak ismert eszközről fogad el hívást. A Törzsadatok → Tabletek oldalon egy "Link csere" gomb új azonosítót/kulcsot generál a régi helyett (a tablet előzménye, eseménynaplója megmarad), a régi link azonnal érvénytelen.
- Ma, PIN nélkül valaki csak a terminál nevét és a feladatlistát/helyszíneket látja (`mk_terminal_catalog`) – dolgozónevet, eseményt, beosztást nem. Ezt a katalógust érdemes még szűkebbre venni: a feladatlista csak sikeres PIN után jöjjön (a `mk_terminal_identify` válaszában).

### Hozzáférési napló
Egy `mk_access_log` tábla rögzíti, ki mikor melyik cég adatához fért hozzá – ez nem helyettesíti az RLS-t (ami magát a hozzáférést engedi/tiltja), hanem az utólagos kivizsgáláshoz kell.

**Mit naplózunk** (a lényeg, nem minden kattintás):
- **Bejelentkezés** – sikeres és sikertelen is (a sikertelen próbálkozások mintázata pont egy incidens korai jele lehet), ki, mikor, honnan (IP).
- **Riport-lekérés** – ki, melyik cég, melyik riport-fül, milyen időszak.
- **Csatolmány megnyitás** – ki (irodai felhasználó, vagy tablet+terminál+dolgozó), melyik csatolmány, melyik cég.
- **Cég-létrehozás** – melyik rendszergazda, milyen cégnév, mikor.

**Hogyan kerül be a log:** a bejelentkezés és a csatolmány-megnyitás már ma is egy szerveroldali RPC-n/végponton megy át (`mk_terminal_attachment_path`, a jövőbeli login-végpont vagy a natív Supabase Auth) – ott a naplózás a függvény/endpoint része, nem a kliensre van bízva. A riport-lekérés ma közvetlen, RLS-védett táblalekérdezés a kliensből – ide egy kliensoldali naplózó hívás kerül a sikeres lekérdezés után (ez nem biztonsági határ, csak láthatóság: magát az adatot már az RLS megvédte, a log csak azt rögzíti utólagos átláthatóság kedvéért, hogy ki nézte meg).

**Fontos korlát, amit tudni kell:** egy RLS által kiszűrt SELECT (amikor valaki más cég adatára próbál rákérdezni) a Postgres/PostgREST szintjén egyszerűen **üres eredményt** ad, nem hibát – ezt a kliens nem tudja megbízhatóan "elutasítva" eseményként naplózni, mert nem különbözik egy valóban üres eredménytől. A biztonsági védelmet itt is a kereszt-teszt adja (lásd fentebb), nem a napló – a napló a *sikeres, jogos* hozzáférésekről ad képet, plusz a security-definer RPC-k (tablet) által *explicit elutasított* próbálkozásokról (azok hibát dobnak, azt lehet és kell naplózni).

**Megőrzés:** 24 hónap, utána egy időzített feladat törli a régebbi sorokat. Egy cég végleges törlésekor (lásd alább) a hozzá tartozó log-bejegyzések nem törlődnek azonnal a többivel együtt, hanem **anonimizálódnak** (a company_id/user_id hivatkozás egy "törölt cég" jelzésre változik, a tartalmi részletek eltávolítva) – így a platform saját auditálhatósága megmarad anélkül, hogy az ügyfél tényleges adatát tovább tartanánk.

**Incidens kivizsgálásnál:** a `mk_access_log`-ot company_id/user_id és időintervallum szerint szűrve nézzük át, összevetve a gyanú tárgyával (pl. "ez a felhasználó mikor és honnan jelentkezett be", "ki nyitotta meg ezt a csatolmányt") – ez az elsődleges eszköz ahhoz, hogy egy gyanús eset esetén rekonstruáljuk, mi történt.

### Adatmegőrzés és törlés a szerződés végén
- **Szerződés megszűnése után egy türelmi időszak (javaslat: 30 nap)**, amíg az adat megmarad, de a licenc-lejárathoz hasonló "csak olvasható" állapotban (lásd Licenc) – ha téves volt a lemondás, ez alatt még visszakapcsolható.
- **Export (GDPR adathordozhatóság):** az ügyfél kérésére egy "Teljes export" a Riportok Excel-exportján felül a törzsadatokat (dolgozók, feladatok, helyszínek, csapatok, tabletek) és a csatolt rajzokat is tartalmazza (egy ZIP-be csomagolva, a fájlokkal együtt) – ez a mai Riport-export bővítése, még nincs megépítve.
- **Végleges törlés** a türelmi időszak lejártával, dokumentált, ellenőrzött lépéssorban (nem kézi, sorról-sorra törlés): `DELETE ... WHERE company_id = X` minden `mk_` táblán a megfelelő sorrendben (vagy CASCADE-del), a `<company_id>/` prefixű Storage-objektumok törlése a Storage API-val (nem SQL-lel megy, lásd Migráció), és a céghez tartozó `auth.users` sorok törlése az Admin API-val. A `mk_access_log` bejegyzései nem törlődnek, csak anonimizálódnak (lásd Hozzáférési napló).

### Migráció: BREMAT mint első cég
1. Staging Supabase projekten próbafuttatás először.
2. Új, kizárólag a Munkakövetésnek fenntartott Supabase projekt (leválasztás a Valk logbooktól) – ez a migráció része, nem külön lépés.
3. Migrációs SQL: `mk_companies` egy sorral (BREMAT), `company_id` minden táblán (nullable → backfill → `NOT NULL` + FK + index), `mk_profiles` a meglévő `@bremat.local` felhasználóknak `role='owner'`-rel, RLS-csere, RPC-k cseréje.
4. Storage: a meglévő fájlok tényleges áthelyezése `<company_id>/` prefix alá – ez a Storage API `move()` hívásával megy (nem tiszta SQL-lel), egy egyszeri scriptben.
5. **A BREMAT-felhasználók UX-a eddig a pontig nem változik** – a company-választó csak akkor jelenik meg, ha már 2+ cég van.

### Kockázatok és kötelező tesztek/eljárások
1. **Frankfurt régió** – a Supabase projekt EU (Frankfurt) régióban legyen, GDPR/adatrezidencia miatt.
2. **Staging projekt** – minden RLS/séma-változás előbb ott, csak utána élesben.
3. **Visszaállítás – kétféle értelemben:**
   - Adat-visszaállítás: rendszeres, cégre szűrt logikai export a natív napi mentés mellett, kipróbálva (nem csak "van mentés", hanem tesztelve is, hogy vissza is lehet tölteni).
   - **Egy elrontott feltöltésből/migrációból fél órán belül vissza kell tudni állni.** Ez két részből áll: a Netlify oldal egy kattintással visszaállítható egy korábbi deployra (natív funkció), a DB-oldali visszaállításhoz pedig minden migráció mellé kell egy dokumentált (ha lehet, scriptelt) visszaállítási lépéssor, staging-en előre kipróbálva – nem elég, hogy "elméletileg vissza lehetne állni".
4. **Kereszt-teszt** – kötelező, automatizált, két próba-céggel, minden deploy előtt. Lásd „Kereszt-teszt: valódi kapu, nem emlékezet” szakasz a GitHub Actions + branch protection pontos beállításáért.
5. **`service_role` átnézése** – minden hely, ahol használva van (ma: `mk-attachment-url.ts`; holnap: az új cég-létrehozó endpoint, és csak ha tényleg bevezetjük, a `/api/mk-login` – lásd „Bejelentkezés és MFA”, ahol ez nem alapértelmezett terv, csak feltételes), célzott biztonsági átvizsgálásra kerül minden változásnál.
6. **Mentés** – a Supabase natív napi mentése mellett egy saját, cégre szűrt logikai export is fusson rendszeresen.
7. **Incidens-terv** – dokumentált eljárás gyanús hozzáférés/szivárgás esetére: kit értesítünk, hogyan zárjuk le a hozzáférést, hogyan vizsgáljuk ki, hogyan tájékoztatjuk az érintett ügyfelet.
8. **PWA** – a tablet-felület telepíthető Progressive Web App legyen, offline-toleranciával (a már előkészített `p_event_time` paraméterrel összekötve).
9. **Erős jelszó + kétlépcsős azonosítás** – lásd „Bejelentkezés és MFA” fent.

## Állapot (2026. szeptember 11.)
- Az MVP élesben fut: Netlify (`bremat.netlify.app`) + saját Supabase projekt (`nuufcwpbjfimykumufgi`). A `CONFIG`-ban be van írva a Supabase URL és a publishable key.
- Deploy: az `Allexxht/astro-platform-starter` repo, az app a `public/munkakovetes/` alatt.
- Azóta bekerült változások:
  - **Irodai belépés felhasználónévvel** e-mail helyett (`CONFIG.LOGIN_DOMAIN`, lásd Biztonság). A fejlécben a név a `@bremat.local` rész nélkül jelenik meg.
  - **Törlés a törzsadatoknál** minden fülön, megerősítéssel. A Kikapcsolás megmarad átmeneti állapotnak. Tablet: mindig végleges törlés (a link megszűnik). Dolgozó/feladat: esemény nélkül végleges törlés (beosztásokkal együtt), egyébként archiválás (`archived_at`). Helyszín/csapat: törlés, a megerősítő ablak kiírja, hány elemet érint.
  - **Leírás és rajz csatolása a beosztáshoz.** Heti tervben a beosztás ablaka (+ gomb, vagy egy meglévő chipre kattintva) most többsoros leírást és rajz(ok) feltöltését is kéri (PDF/JPG/PNG, max. 20 MB/fájl, több is). „Egész hétre” és „Előző hét másolása” a leírást és a rajzokat is átviszi, fájlonként csak egyszer töltve fel (`mk_attachments` + `mk_assignment_attachments`, lásd Adatmodell). A tabletkártyán (beosztott munka, kezdés előtt és munka közben is) teljes hosszban látszik a beosztás leírása és a feladat általános leírása, és minden rajzhoz van egy „Rajz megnyitása” gomb, ami a fenti teljes képernyős nézőt nyitja meg. Biztonsági modell: lásd Biztonság → Rajzok. A rajzok a beosztáshoz csatolva maradnak úgy, ahogy most vannak – nem lesz belőle külön dokumentumtár verziókezeléssel.
  - **Riportok fül, Excel exporttal.** Új „Riportok” fül az irodai fejlécben: időszakválasztó (Ma / Tegnap / Ez a hét / Előző hét / Ez a hónap / Előző hónap / Egyedi) és szűrők (csapat, helyszín, dolgozó), négy alfül – Jelenlét, Feladatonként, Terv és tény, Rendelésszám szerint. Nincs hozzá DB-változás: minden az `mk_events`/`mk_assignments` lekéréséből és a `summarize()`-ból számolódik, ugyanúgy, mint az élő nézetben. „Excel letöltés”: egy .xlsx, riportonként külön munkalappal (órák két tizedessel, magyar dátumformátum, a fájlnévben az időszak). Nyomtatáshoz fekvő A4-es print stílus. Demó módban több hetes mintaadat van hozzá.
- Még nincs kipróbálva éles Supabase ellen: a Realtime frissítés, a törlés/archiválás végigkattintása, a rajz-funkció (a `002_attachments.sql` migráció futtatása + a `MK_SUPABASE_SERVICE_ROLE_KEY` Netlify env var beállítása szükséges hozzá), és a Riportok Excel exportja (a SheetJS CDN-betöltését ellenőrizni kell éles, korlátozás nélküli hálózaton).
- Nyitott kérdések: mely ötletek nem tetszettek; a valódi törzsadatok (dolgozók, csapatok, csarnokok, feladatok); a tabletek száma; **az Elakadtam funkciót (a jelenlegi elakadás-jelzés workflow-ját) a próbahét után újragondoljuk** – egyelőre változatlan marad.
- **2026. szeptember 15.: a többbérlős SaaS irány és a részletes terv lezárva** (lásd „Többbérlős SaaS – terv” szakasz). Ehhez a ponthoz még nem készült kód – ez a következő fejlesztési kör alapja. A cégek fizikai szétválasztásának kérdése (közös DB+RLS vs. cégenkénti Supabase projekt) tudatosan elhalasztva a 2. valós ügyfél megjelenéséig; addig az adatmodell mindkét úthoz felkészítve épül (`company_id` + RLS mindenhol, kötelező kereszt-teszt).
- **2026. szeptember 16.: a kereszt-teszt kapu megépült, kód előtt.** `.github/workflows/cross-tenant-test.yml` + `tests/cross-tenant/run.mjs` + `tests/cross-tenant/manifest.mjs` (lásd „Kereszt-teszt: valódi kapu, nem emlékezet”), PR-ban (#3), még nem mergelve. A teszt **bootstrap módban zöld** (nincs `mk_companies` tábla → nincs mit vizsgálni, jól látható üzenettel), és attól a pillanattól válik szigorúvá, hogy a `mk_companies` tábla megjelenik a sémában – onnantól az adatbázisban keres meg minden `company_id`-s táblát/RPC-t, és bukik, ha bármelyik hiányzik a manifestből, vagy ha bármelyik kereszt-bérlős próba átmenne. Így a jelenlegi, egycéges kód mergelhető marad, de a következő (adatmodell) kör csak akkor, ha a manifest a sémával együtt, teljesen bővül. A branch protection GitHubon még nincs bekapcsolva (a felhasználó feladata, lépések a PR-hoz fűzött üzenetben). Létrejött egy **staging Supabase projekt** (Frankfurt régió) a kézi, éleshez hasonló próbákhoz – **nem** azonos a CI-ban használt eldobható helyi Docker stackkel: URL `https://fbkcjvplcsnenjgsirfx.supabase.co`, publishable key `sb_publishable_Vca2NmMEeQ0vn_Q2Q0_Z2w_sCi08QCG`. Ezt még sehol nem használja kód – akkor kerül majd be (pl. egy `CONFIG`-választó vagy külön staging build), amikor a többbérlős migrációt staging ellen először próbáljuk ki.

## Ütemterv
- **Következő nagy lépés: a többbérlős átállás** – lásd „Többbérlős SaaS – terv” szakasz, ott van fázisokra bontva (adatmodell+RLS+kereszt-teszt → bejelentkezés/szerepkör-UI → rendszergazda-felület → licenc). A helyszín-korlátozott szerepkör tudatosan NEM része ennek a körnek (lásd „Szerepkörök” a tervben, miért). Ez felülírja/pontosítja az alábbi listát ott, ahol átfedés van (pl. a "szerepkörök" már nem különálló 3. körös ötlet, hanem a többbérlős terv része).
- **2. kör** (a jelenlegi, egycéges funkciók közül):
  - offline mód (a `p_event_time` paraméter már elő van készítve)
- **3. kör:**
  - megrendeléshez kötés és utókalkuláció
  - NFC kártya (a PIN képernyő már fogad billentyűzetes bevitelt, így az USB-s NFC olvasó is működni fog)

## Munkamódszer
- A magyarázatok magyarul szóljanak, de a menü- és beállításneveket angolul írd, mert az eszközök angol nyelvű felületet használnak.
- Módosítás után DEMÓ módban ellenőrizd a fő folyamatot: PIN → kezdés → váltás darabszámmal → elakadás → lezárás. Emellett az élő nézet és a heti terv működjön.
- Törzsadat-módosításnál ellenőrizd a törlést mindkét ágon: új (esemény nélküli) dolgozó/feladat → végleges törlés; meglévő (eseményes, pl. Kovács Gábor) → archiválás, és utána a korábbi nap élő nézetében a neve még látszik, de a mai listákból/heti tervből eltűnt.
- Rajz/leírás módosításnál ellenőrizd: új beosztás létrehozása leírással + rajzzal, meglévő chip szerkesztése (leírás módosítás, rajz hozzáadás/törlés/megnyitás), „Egész hétre” és „Előző hét másolása” átviszi-e mindkettőt, és hogy egy beosztás törlése után a rajz csak akkor tűnik el a tárhelyről, ha más beosztás már nem hivatkozik rá. Tableten nézd meg a kártyát kezdés előtt és munka közben is, nyisd meg a rajzot (kép: pinch zoom; PDF: lapozás), és ellenőrizd, hogy nyitott rajznál nem 45 mp, hanem 10 perc után áll csak vissza a PIN képernyőre.
- Riportoknál ellenőrizd: mind a négy alfül tölt adatot minden időszak-preset mellett (különösen „Ez a hónap”/„Előző hónap”, ahol a demó több hetes mintaadata van), a szűrők (csapat/helyszín/dolgozó) DB-hívás nélkül, azonnal szűrnek, egy lezáratlan műszak pirossal jelenik meg és nincs beleszámítva az időszaki összesítőbe, a jövőbeli napok nem jelennek meg hamis „nem jelent meg” sorként a Terv és tény fülön, és az Excel letöltés helyes .xlsx-et ad (riportonként külön munkalap, órák két tizedessel, magyar dátumformátum).
- DEMÓ mód teszteléséhez a `CONFIG` két Supabase mezőjét ideiglenesen ürítsd ki (élesben ne maradjon úgy). DEMÓ módban a rajzok a böngésző memóriájában élnek, újratöltéskor elvesznek.
