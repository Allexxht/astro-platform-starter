# AndonWork – új ügyfél beállítása, végigkattintós forgatókönyv

Ez egy **próba-forgatókönyv**: egy kitalált céggel végigmegy az egész úton, a cég
létrehozásától a törlésig. Két célja van:

1. kiderüljön, hogy **egy ember, egyedül, végig tudja-e vinni** egy új ügyfél beállítását;
2. mérhető legyen, **mennyi idő** valójában – ez lesz az alapja a valódi ügyfélnek ígért határidőnek.

A próba-cég: **Kovács Fémipari Kft.**, 12 dolgozó, 2 csarnok.

> **A meglévő ügyfél (a BREMAT, az AndonWork első ügyfele) adataihoz ez a
> forgatókönyv nem nyúl.** Te rendszergazdaként lépsz be (a Cégek nézet onnan érhető
> el), és a 8. lépés törlése – a felületen és a tartalék SQL-scriptben is –
> beépítetten megtagadja a legelső cég törlését.

Menet közben jegyezd fel az időt lépésenként – a végén van hozzá egy táblázat.

---

## 0. Mielőtt elkezded (5 perc)

| Ellenőrzés | Hol | Mit kell látnod |
|---|---|---|
| A friss kliens él-e | Netlify → a projekt (ma még `bremat` néven) → Deploys | A legutolsó deploy **Published**, a bejelentkező képernyőn **AndonWork** felirat és **E-mail cím** mező |
| Service role kulcs | Netlify → Site configuration → Environment variables | `MK_SUPABASE_SERVICE_ROLE_KEY` szerepel a listában |

⚠️ **Itt el fogsz akadni, ha a service role kulcs hiányzik.** Nemcsak a tabletes
rajzmegnyitás (5. lépés) bukna el, hanem **az egész 1. lépés is**: az új cég
létrehozása ezen a kulcson keresztül megy. Ha nincs beállítva, a „Létrehozás"
gomb azt írja: *A szerver nincs beállítva (hiányzik a Supabase service role kulcs).*

Nyiss **két böngészőt** (vagy egy normál + egy privát ablakot):
- **A ablak** – te, rendszergazdaként, a saját e-mail címeddel.
- **B ablak** – a Kovács Kft. fiókja. Ezt majd a 2. lépésben nyitod meg.

---

## 1. Új cég létrehozása (3 perc) — *A ablak*

1. Lépj be a saját e-mail címeddel. A fejlécben ott a neved, mellette a
   **rendszergazda** felirat (ha a BREMAT-nál is van fiókod, a **tulajdonos** is).
2. Kattints a **Cégek** fülre. Egy sort látsz: a BREMAT-ot, a felhasználóival és
   a használati számokkal (dolgozók, események).
3. **Új cég** gomb. Töltsd ki:
   - Cégnév: `Kovács Fémipari Kft.`
   - Licenc lejárata: **mai dátum + 1 év**
   - Első felhasználó e-mail címe: egy **valódi, általad olvasott** cím (pl. egy
     `+kovacs` alias a sajátodhoz: `nev+kovacs@gmail.com`) – ezzel lépsz be a
     2. lépésben, és ide jön a jelszó-visszaállító levél is
   - Neve: `Kovács Iroda` (nem kötelező)
   - Jelszava: **legalább 12 karakter, betűvel és számmal** (pl. `KovacsProba2026`)
   - ☑ **Példa törzsadatok betöltése** – pipáld be
4. **Létrehozás**.

**Amit látnod kell:** a lista két sorra bővül, a Kovács Kft. sorában a felhasználók
oszlopban `Kovács Iroda (tul.)` és alatta az e-mail cím, a licencnél a megadott dátum.

⚠️ **Itt akadhatsz el, ha rövid jelszót vagy hibás e-mail címet adsz meg.** Az
űrlap azonnal jelzi (*A jelszó legyen legalább 12 karakter* / *Add meg az első
felhasználó e-mail címét*).

⚠️ **Ha a cím már foglalt** (egy korábbi próbából maradt fiók), *Ezzel az e-mail
címmel már van fiók* üzenetet kapsz – használj új aliast, vagy töröld a régi próba-céget.

---

## 2. Belépés a Kovács Kft. fiókjával (2 perc) — *B ablak*

Nyisd meg ugyanazt a címet a **B ablakban**, és lépj be az 1. lépésben megadott
**e-mail címmel** és jelszóval.

> Korábban ez volt a forgatókönyv legvalószínűbb buktatója: a belépés felhasználónévvel
> ment, a kliens egy beégetett domaint (`bremat.local`) tett mögé, így a 2. ügyfél
> felhasználója az első ügyfél fiókjába próbált volna belépni. Az e-mailes belépéssel
> (2026. szeptember 18.) ez megszűnt: a cím önmagában megmondja, melyik céghez tartozol.
>
> 🧪 **Érdemes egyszer kipróbálni az „Elfelejtett jelszó" gombot is.** A levél csak
> akkor jön meg, ha a Resend már be van kötve a Supabase-be (lásd CLAUDE.md
> „Bejelentkezés és MFA"); ha nem jön, az nem az app hibája, hanem a beállítás hiányzik.

**Amit látnod kell a B ablakban:**
- A fejlécben `Kovács Iroda · tulajdonos`, és a **Kijelentkezés** gomb.
- **Nincs Cégek fül** (az csak rendszergazdának jár, te itt csak cégtulajdonos vagy).
- Törzsadatok → a példa-adatok ott vannak: 4 csapat, 4 helyszín, 5 feladat, 2 tablet.
- Dolgozók: **üres** (a példa-adatok szándékosan nem tartalmaznak dolgozót).

---

## 3. Törzsadatok feltöltése (25–35 perc) — *B ablak*

**3.1 Helyszínek (2 perc).** Törzsadatok → Helyszínek. A példa-adatból marad
`1-es csarnok` és `2-es csarnok`; a `Raktár` és `Iroda` maradhat vagy törölhető.

**3.2 Csapatok (2 perc).** Hagyd meg a `Hegesztők` és `Lakatosok` csapatot,
a többit töröld.

**3.3 Feladatok (5 perc).** Nevezd át/bővítsd 4–5 feladatra, mindegyiknél
helyszín + szín. Egynél kapcsold be a **darabszám kérése** opciót – az 5. lépésben
ezt fogjuk próbálni.

**3.4 Dolgozók PIN-nel (15–25 perc) — ez a leghosszabb rész.**
Vegyél fel **12 dolgozót**, mindegyiknél csapatot választva, és mindegyiknek adj PIN-t.

> ⚠️ **Itt fogsz a legtöbb időt tölteni, és itt fog a legjobban hiányozni egy funkció.**
> Nincs tömeges import (se CSV, se beillesztés) – 12 dolgozó = 12 külön ablak
> megnyitása, kitöltése, mentése, majd 12 külön PIN-kiadás. Ez egyetlen
> 12 fős cégnél még elmegy, de **egy 60 fős ügyfélnél ez önmagában egy fél nap**,
> és a bevezetés legdrágább része lesz.
>
> 📝 **Mérd meg külön ennek a pontnak az idejét** – ez az egyetlen szám, ami
> lineárisan nő a cég méretével, a többi lépés nagyjából állandó.

📝 **Írj fel 2 dolgozót névvel és PIN-nel** – az 5. lépéshez kell.

---

## 4. Heti beosztás leírással és rajzzal (5 perc) — *B ablak*

1. **Heti terv** fül. Győződj meg róla, hogy **az aktuális hét** látszik.
2. A felírt dolgozód **mai napi** cellájában kattints a **+** gombra.
3. Válassz feladatot (azt, amelyiknél bekapcsoltad a darabszámot).
4. Írj be egy **rendelésszámot** és egy többsoros **leírást**.
5. Tölts fel egy **rajzot** (bármilyen PDF vagy JPG).
6. Mentés.

**Amit látnod kell:** a cellában megjelenik a feladat chipje, a leírás és a rajz
a chipre kattintva visszanézhető.

> ⚠️ **Ha nem a MAI napra teszed a beosztást, az 5. lépés nem fog működni.**
> A tablet kizárólag az aznapi beosztást mutatja (Europe/Budapest szerint).
> Ez logikus, de könnyű elrontani, mert a heti tervben a hét bármelyik napjára
> tudsz kattintani.

---

## 5. Tablet: PIN, kezdés, szünet, feladatváltás, műszak vége (10 perc)

1. *B ablak*: Törzsadatok → **Tabletek** → az egyik tabletnél **Link másolása**.
2. Nyisd meg a linket egy **új fülön** (ez a kioszk nézet).

**Amit látnod kell:** a tablet neve, a mai dátum, és a PIN-képernyő.

3. Írd be a felírt dolgozó PIN-jét. → Megjelenik a neve és a mai beosztása,
   a leírással és a **Rajz megnyitása** gombbal.
4. **Rajz megnyitása** → teljes képernyős nézet (képnél pinch-zoom, PDF-nél lapozás).
   Zárd be.

> ⚠️ **Itt akadsz el, ha a `MK_SUPABASE_SERVICE_ROLE_KEY` nincs beállítva.**
> Az irodai rajzmegnyitás akkor is működik, a tabletes viszont nem – az egy
> szerveroldali végponton keresztül kér rövid lejáratú linket.

5. **Kezdés** a beosztott feladaton.
6. **Szünet**, majd **Folytatás**.
7. **Feladatváltás** egy másik feladatra – itt kérnie kell **darabszámot** az előzőhöz
   (ezért kapcsoltad be a 3.3-ban).
8. **Műszak vége**.

📝 Ha van rá időd, csináld végig egy **második dolgozóval** is – a riport így lesz életszerű.

---

## 6. Élő nézet és riport (5 perc) — *B ablak*

1. **Élő nézet**: a dolgozó(k) megjelennek állapottal, helyszínnel, eltelt idővel.
   Ha a tablet fülön még nyitva van a munkamenet, az élő nézet **magától frissül**
   (Realtime) – ezt érdemes külön megnézni: indíts a tableten valamit, és nézd,
   hogy az élő nézet frissül-e kattintás nélkül.
2. **Riportok** fül → időszak: **Ma**. Nézd meg mind a négy alfület
   (Jelenlét, Feladatonként, Terv és tény, Rendelésszám szerint).
3. **Excel letöltés** → nyisd meg a fájlt.

**Amit látnod kell:** riportonként külön munkalap, órák két tizedessel, magyar dátum.

> ⚠️ **Két dolog, ami itt elromolhat:** a lezáratlan műszak pirossal jelenik meg és
> nem számít bele az összesítőbe (ez szándékos); az Excel a SheetJS könyvtárat
> CDN-ről tölti, tehát **szigorúan szűrt céges hálón elbukhat**. Ha nem indul a
> letöltés, próbáld másik hálózatról.

---

## 7. Licenc lejáratra állítása, majd vissza (5 perc)

**7.1** *A ablak* (rendszergazda) → **Cégek** → a Kovács Kft. sorában **Licenc** →
állítsd a lejáratot **tegnapra** → Mentés.

**7.2** *B ablak* → **töltsd újra az oldalt** (F5).

**Amit látnod kell:**
- Sárgás **csak olvasható** banner a Heti terv és a Törzsadatok tetején.
- Az „Előző hét másolása" gomb **letiltva**.
- Új beosztás mentése **érthető hibaüzenettel** elutasítva (*Lejárt előfizetés…*).
- A riportok és minden lista **továbbra is működik** (ez a lényeg: lát, de nem ír).
- A **tablet** fülön frissítve: „Lejárt előfizetés" képernyő, PIN bekérése nélkül.

**7.3** *A ablak* → Licenc → töröld a dátumot (vagy állítsd jövőbelire) → Mentés.
**7.4** *B ablak* → F5 → minden visszaáll.

> ⚠️ **Itt bukott el élesben a licenc-mentés** (*Cannot coerce the result to a single
> JSON object*), és itt derül ki, hogy a javítás tényleg él-e. Ha újra ezt a hibát
> látod: nem futott le a deploy, vagy a böngésző a régi kliens gyorsítótárazott
> verzióját tölti – **Ctrl+Shift+R**.

---

## 8. A próba-cég teljes törlése (3 perc) — *A ablak*

**8.1** Cégek → a Kovács Kft. sorában **Törlés**. A megerősítő ablak kiírja, mit visz
el (dolgozók, események, bejelentkezési fiókok, feltöltött rajzok), és **be kell
gépelni a cég pontos nevét**. **Végleges törlés**.

**Amit látnod kell:** a lista újra egy sor, a BREMAT, változatlan dolgozó- és
felhasználószámmal. A legelső céghez (és a saját cégedhez) szándékosan nincs Törlés
gomb.

**8.2** *B ablak* → F5 → a Kovács Kft. fiókja már nem tud belépni.

**Tartalék, ha a felület valamiért nem törölne:** Supabase → **Storage** → `mk-rajzok`
→ a cég azonosítójával megegyező mappa törlése, majd **SQL Editor** →
`db/proba_ceg_torles.sql` (a cégnév a script elején állítható; a legelső cég
törlését ez is megtagadja).

---

## A mérés: töltsd ki menet közben

| # | Lépés | Becsült | Tényleges | Hol volt nehézkes |
|---|---|---|---|---|
| 0 | Előkészítés | 5 p | | |
| 1 | Cég létrehozása | 3 p | | |
| 2 | Belépés az új fiókkal | 2 p | | |
| 3.1–3.3 | Helyszín, csapat, feladat | 9 p | | |
| 3.4 | **12 dolgozó + PIN** | 15–25 p | | |
| 4 | Beosztás rajzzal | 5 p | | |
| 5 | Tablet végigjátszás | 10 p | | |
| 6 | Élő nézet + riport + Excel | 5 p | | |
| 7 | Licenc oda-vissza | 5 p | | |
| 8 | Törlés | 3 p | | |
| | **Összesen** | **62–72 p** | | |

### Amit a végén érdemes külön feljegyezni

1. **A 3.4 tényleges ideje osztva 12-vel** → ennyi egy dolgozó felvétele. Szorozd
   be a valódi ügyfél létszámával; ez adja a bevezetés legnagyobb tételét.
2. **Hányszor kellett SQL-hez nyúlni?** A cél az, hogy egy valódi ügyfélnél **nulla**
   legyen – a cégtörlés óta a forgatókönyv SQL nélkül végigvihető.
3. **Hányszor akadtál el olyanon, amit nem a forgatókönyvből tudtál?** Ami itt
   kiderül, az egy valódi ügyfélnél támogatási kérdés lesz.

---

## Előre látott akadályok, összegezve

Ezeket a kód ismeretében jelzem előre, nem a próba után:

| Hol | Mi | Súly |
|---|---|---|
| ~~2. lépés~~ | ~~Beégetett bejelentkezési domain~~ – **megoldva** (e-mailes belépés, 2026. 09. 18.) | – |
| ~~8. lépés~~ | ~~Nincs cégtörlés a felületen~~ – **megoldva** (Cégek → Törlés, 2026. 09. 18.) | – |
| 2. lépés | Az „Elfelejtett jelszó" levél a Resend bekötéséig nem megy ki. | Konfigurációs függőség |
| 3.4 | Nincs tömeges dolgozó-import. | Idő, lineárisan a létszámmal |
| 0. és 5. | A service role kulcs hiánya a cég-létrehozást ÉS a tabletes rajzot is megfogja. | Konfigurációs csapda |
| 4. | Ha nem mai napra szól a beosztás, a tablet üres. | Könnyű elrontani |
| 6. | Az Excel CDN-ről tölt – szűrt hálón elbukhat. | Környezetfüggő |
