# Munkakövetés modul – projektjegyzet

## Mi ez
Munkakövető rendszer (MES-lite) a hegesztőüzemnek. Két felülete van:
- **Tablet (csarnok):** falra szerelt Android tablet kioszk módban. A dolgozó PIN-nel azonosít, látja a mai beosztását, és gombokkal jelez: Kezdés, Feladatváltás, Szünet, Elakadtam (okkal), Műszak vége.
- **Iroda:** heti beosztás (dolgozó × nap rács), élő nézet (ki mit csinál, hol, mióta), törzsadatok.

A bevezetés ütemekben halad. Most az MVP kész, és az ötletek menet közben alakulnak át: ami nem válik be, azt kivesszük.

## Fájlok
- `munkakovetes/index.html` – egyfájlos app (vanilla JS, nincs build lépés, CSS és JS inline, kommentfejlécekkel tagolva). A script elején van a `CONFIG`. Üres Supabase kulcsokkal DEMÓ módban fut, memóriában tárolt mintaadatokkal.
- `supabase-setup.sql` – séma, RLS, függvények, kezdő adatok. Többször is futtatható (idempotens). A Supabase Dashboard SQL Editorában kell futtatni.

## Architektúra
- Stack: Netlify (GitHub CI/CD), Supabase (Postgres, Auth, Realtime). A supabase-js ESM-ként töltődik a jsdelivr CDN-ről, dinamikus importtal.
- Adatréteg: `createDemoAdapter()` és `createSupabaseAdapter()` ugyanazzal az interfésszel. Új funkciót mindkettőbe be kell építeni.
- Minden tábla `mk_` előtagot kap, mert ugyanabban a Supabase projektben él, mint a Valk logbook.
- URL-ek: iroda `/munkakovetes/`, tablet `/munkakovetes/?terminal=<mk_terminals.id>`.

## Adatmodell
- `mk_teams` (csapat/szakma) és `mk_locations` (helyszín/csarnok): szándékosan két külön dimenzió.
- `mk_employees`, `mk_tasks` (helyszín, szín, leírás, `ask_quantity`), `mk_terminals` (az id a tablet titkos kulcsa).
- `mk_assignments`: `work_date` + dolgozó + feladat egyedi. A `note` mezőbe kerül most a rendelésszám.
- `mk_events`: csak bővülő eseménynapló. Típusai: `start`, `pause`, `resume`, `block`, `end`, `qty`.
- Az állapotot és a munkaidőt mindig az eseménynaplóból számoljuk (`summarize()` a kliensben), külön állapotmezőt nem tárolunk.

## Biztonság
- Iroda = bármely `authenticated` felhasználó (MVP). A nyilvános regisztráció legyen kikapcsolva.
- Tablet = `anon`, csak RPC-t hívhat: `mk_terminal_catalog`, `mk_terminal_identify`, `mk_terminal_event`. A PIN minden hívással megy.
- Hibás PIN esetén tabletenként legfeljebb 10 próbálkozás engedett percenként.
- `mk_pins`: sha256 hash, RLS policy nélkül, csak security definer függvények érik el. `mk_set_pin` csak `authenticated` jogosultsággal hívható, `mk__pin_employee` belső függvény.
- `mk_events` táblára nincs update/delete policy.
- A „ma” a Europe/Budapest időzóna szerint számolódik.

## Dizájn
- Színek: sötét acélszürke alap, izzó narancs a márkához és a fókuszhoz.
- Andon színek csak állapotot jelölnek: zöld = dolgozik, sárga = szünet, piros = elakadt. Feladatszínnek ezeket ne használd.
- Betűk: Barlow / Barlow Condensed. Minden UI-szöveg magyar.
- Tablet: kesztyűs kézre méretezett gombok, egy művelet legfeljebb 2–3 érintés. 45 mp tétlenség után visszaáll a PIN képernyőre.

## Állapot (2026. szeptember 10.)
- Az MVP kész. A demó mód összes folyamatát automatikus teszt játszotta végig. Az SQL-t PostgreSQL 16-on, Supabase-szerű szerepkörökkel teszteltük.
- Még nincs kipróbálva: az élő Supabase-kapcsolat és a Realtime frissítés.
- Nyitott kérdések: mely ötletek nem tetszettek; a valódi törzsadatok (dolgozók, csapatok, csarnokok, feladatok); a tabletek száma.

## Ütemterv
- **2. kör:**
  - dokumentumtár rajzverzió-kezeléssel (Supabase Storage)
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
