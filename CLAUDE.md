# Munkakövetés modul – projektjegyzet

## Mi ez
Munkakövető rendszer (MES-lite) a hegesztőüzemnek. Két felülete van:
- **Tablet (csarnok):** falra szerelt Android tablet kioszk módban. A dolgozó PIN-nel azonosít, látja a mai beosztását, és gombokkal jelez: Kezdés, Feladatváltás, Szünet, Elakadtam (okkal), Műszak vége.
- **Iroda:** heti beosztás (dolgozó × nap rács), élő nézet (ki mit csinál, hol, mióta), törzsadatok.

A bevezetés ütemekben halad. Most az MVP kész, és az ötletek menet közben alakulnak át: ami nem válik be, azt kivesszük.

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

## Adatmodell
- `mk_teams` (csapat/szakma) és `mk_locations` (helyszín/csarnok): szándékosan két külön dimenzió.
- `mk_employees`, `mk_tasks` (helyszín, szín, leírás, `ask_quantity`), `mk_terminals` (az id a tablet titkos kulcsa).
- `mk_employees.archived_at` és `mk_tasks.archived_at`: kitöltve = archivált. Az archivált elem eltűnik a törzsadatokból, a heti tervből és a tabletről (a listák `archived_at is null` / kliensoldali szűréssel), de a neve az `mk_events` soraiban megmarad, így a múltbeli napok élő nézete olvasható.
- `mk_assignments`: `work_date` + dolgozó + feladat egyedi. A `note` mezőbe kerül most a rendelésszám, a `details` mezőbe a többsoros leírás/tudnivaló.
- `mk_attachments`: feltöltött rajz (PDF/JPG/PNG) – `storage_path`, fájlnév, típus, méret. `mk_assignment_attachments`: beosztás ↔ csatolmány kapcsolótábla (több beosztás is hivatkozhat ugyanarra a fájlra). Csatolmány törlésekor (kliensoldali logika, `deleteAttachmentIfOrphan`) csak akkor törlődik a Storage-ból és az `mk_attachments`-ből, ha már semmilyen beosztás nem hivatkozik rá.
- `mk_events`: csak bővülő eseménynapló. Típusai: `start`, `pause`, `resume`, `block`, `end`, `qty`.
- Az állapotot és a munkaidőt mindig az eseménynaplóból számoljuk (`summarize()` a kliensben), külön állapotmezőt nem tárolunk.

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

## Állapot (2026. szeptember 11.)
- Az MVP élesben fut: Netlify (`bremat.netlify.app`) + saját Supabase projekt (`nuufcwpbjfimykumufgi`). A `CONFIG`-ban be van írva a Supabase URL és a publishable key.
- Deploy: az `Allexxht/astro-platform-starter` repo, az app a `public/munkakovetes/` alatt.
- Azóta bekerült változások:
  - **Irodai belépés felhasználónévvel** e-mail helyett (`CONFIG.LOGIN_DOMAIN`, lásd Biztonság). A fejlécben a név a `@bremat.local` rész nélkül jelenik meg.
  - **Törlés a törzsadatoknál** minden fülön, megerősítéssel. A Kikapcsolás megmarad átmeneti állapotnak. Tablet: mindig végleges törlés (a link megszűnik). Dolgozó/feladat: esemény nélkül végleges törlés (beosztásokkal együtt), egyébként archiválás (`archived_at`). Helyszín/csapat: törlés, a megerősítő ablak kiírja, hány elemet érint.
  - **Leírás és rajz csatolása a beosztáshoz.** Heti tervben a beosztás ablaka (+ gomb, vagy egy meglévő chipre kattintva) most többsoros leírást és rajz(ok) feltöltését is kéri (PDF/JPG/PNG, max. 20 MB/fájl, több is). „Egész hétre” és „Előző hét másolása” a leírást és a rajzokat is átviszi, fájlonként csak egyszer töltve fel (`mk_attachments` + `mk_assignment_attachments`, lásd Adatmodell). A tabletkártyán (beosztott munka, kezdés előtt és munka közben is) teljes hosszban látszik a beosztás leírása és a feladat általános leírása, és minden rajzhoz van egy „Rajz megnyitása” gomb, ami a fenti teljes képernyős nézőt nyitja meg. Biztonsági modell: lásd Biztonság → Rajzok.
- Még nincs kipróbálva éles Supabase ellen: a Realtime frissítés, a törlés/archiválás végigkattintása, és ez az új rajz-funkció (a `002_attachments.sql` migráció futtatása + a `MK_SUPABASE_SERVICE_ROLE_KEY` Netlify env var beállítása szükséges hozzá).
- Nyitott kérdések: mely ötletek nem tetszettek; a valódi törzsadatok (dolgozók, csapatok, csarnokok, feladatok); a tabletek száma.

## Ütemterv
- **2. kör:**
  - ~~dokumentumtár rajzverzió-kezeléssel (Supabase Storage)~~ – az alap (leírás + rajz csatolása, biztonságos megnyitás a tableten) elkészült; a rajzverzió-kezelés (több verzió, előzmény) még nincs
  - riportok Excel-exporttal
  - értesítés elakadáskor
  - offline mód (a `p_event_time` paraméter már elő van készítve)
  - hibabejelentés fotóval
- **3. kör:**
  - megrendeléshez kötés és utókalkuláció
  - NFC kártya (a PIN képernyő már fogad billentyűzetes bevitelt, így az USB-s NFC olvasó is működni fog)
  - szerepkörök

## Munkamódszer
- A magyarázatok magyarul szóljanak, de a menü- és beállításneveket angolul írd, mert az eszközök angol nyelvű felületet használnak.
- Módosítás után DEMÓ módban ellenőrizd a fő folyamatot: PIN → kezdés → váltás darabszámmal → elakadás → lezárás. Emellett az élő nézet és a heti terv működjön.
- Törzsadat-módosításnál ellenőrizd a törlést mindkét ágon: új (esemény nélküli) dolgozó/feladat → végleges törlés; meglévő (eseményes, pl. Kovács Gábor) → archiválás, és utána a korábbi nap élő nézetében a neve még látszik, de a mai listákból/heti tervből eltűnt.
- Rajz/leírás módosításnál ellenőrizd: új beosztás létrehozása leírással + rajzzal, meglévő chip szerkesztése (leírás módosítás, rajz hozzáadás/törlés/megnyitás), „Egész hétre” és „Előző hét másolása” átviszi-e mindkettőt, és hogy egy beosztás törlése után a rajz csak akkor tűnik el a tárhelyről, ha más beosztás már nem hivatkozik rá. Tableten nézd meg a kártyát kezdés előtt és munka közben is, nyisd meg a rajzot (kép: pinch zoom; PDF: lapozás), és ellenőrizd, hogy nyitott rajznál nem 45 mp, hanem 10 perc után áll csak vissza a PIN képernyőre.
- DEMÓ mód teszteléséhez a `CONFIG` két Supabase mezőjét ideiglenesen ürítsd ki (élesben ne maradjon úgy). DEMÓ módban a rajzok a böngésző memóriájában élnek, újratöltéskor elvesznek.
