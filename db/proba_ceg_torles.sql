-- =====================================================================
--  EGY CÉG TELJES TÖRLÉSE SQL-BŐL – vésztartalék
--
--  FIGYELEM: ez visszafordíthatatlan. Töröl minden adatot, a bejelentkezési
--  fiókokat is. Az első (legrégebbi) céget – a BREMAT-ot – SZÁNDÉKOSAN nem
--  engedi törölni: a script leáll, ha arra irányulna.
--
--  Rendes úton a cégtörlés a felületről megy (Cégek → Törlés): az a feltöltött
--  rajzokat is törli, lépésenként ellenőriz, és félbemaradás esetén megmondja,
--  mi van hátra. Ez a script arra az esetre van, ha a felület nem használható.
--
--  A cég AZONOSÍTÓJA alapján töröl, nem a neve alapján: a cégnév nem egyedi,
--  két azonos nevű ügyfélnél név alapján a rossz cég is törlődhetne. A nevet
--  megerősítésnek kéri – ha nem egyezik az azonosítóhoz tartozó névvel, a
--  script semmit nem töröl.
--
--  1) Keresd ki a cég azonosítóját:
--       select id, name, created_at from public.mk_companies order by created_at;
--  2) A feltöltött rajzok NEM az adatbázisban vannak, az SQL nem viszi el őket.
--     Előtte töröld őket a Dashboard → Storage → mk-rajzok bucketben (a cég
--     azonosítójával megegyező nevű mappa). Ellenőrzés:
--       select count(*) from storage.objects
--        where bucket_id = 'mk-rajzok' and name like '<AZONOSÍTÓ>/%';
--  3) Írd be lent az azonosítót és a nevet, és futtasd.
--
--  Az egész egy tranzakcióban fut: ha bármelyik lépés hibázik, semmi nem
--  törlődik.
-- =====================================================================

do $$
declare
  -- ↓↓↓ A TÖRLENDŐ CÉG AZONOSÍTÓJA (az 1. lépés lekérdezéséből) ↓↓↓
  v_id       uuid := null;
  -- ↓↓↓ ÉS A NEVE, megerősítésnek (pontosan úgy, ahogy a Cégek listában áll) ↓↓↓
  v_nev      text := 'Kovács Fémipari Kft.';

  v_valodi   text;
  v_legelso  uuid;
  v_users    int;
  v_n        int;
begin
  if v_id is null then
    raise exception 'Add meg a törlendő cég azonosítóját (v_id). A cégek azonosítói: select id, name, created_at from public.mk_companies order by created_at;';
  end if;

  select name into v_valodi from public.mk_companies where id = v_id;
  if not found then
    raise exception 'Nincs ilyen azonosítójú cég: %.', v_id;
  end if;
  if v_valodi is distinct from v_nev then
    raise exception 'A megadott név („%”) nem egyezik a(z) % azonosítójú cég nevével („%”). Ellenőrizd, hogy tényleg ezt a céget akarod-e törölni.',
      v_nev, v_id, v_valodi;
  end if;

  select id into v_legelso from public.mk_companies order by created_at limit 1;
  if v_id = v_legelso then
    raise exception 'VÉDELEM: „%” a legelső cég (a BREMAT). Ezt ez a script nem törli.', v_valodi;
  end if;

  select count(*) into v_users from public.mk_profiles where company_id = v_id;
  raise notice 'Törlés indul: % (azonosító: %, % felhasználói fiókkal)', v_valodi, v_id, v_users;

  -- Üzleti adat, idegenkulcs-sorrendben
  delete from public.mk_events                 where company_id = v_id;
  delete from public.mk_assignment_attachments where company_id = v_id;
  delete from public.mk_attachments            where company_id = v_id;
  delete from public.mk_assignments            where company_id = v_id;
  delete from public.mk_pins                   where company_id = v_id;
  delete from public.mk_pin_failures           where company_id = v_id;
  delete from public.mk_employees              where company_id = v_id;
  delete from public.mk_tasks                  where company_id = v_id;
  delete from public.mk_terminals              where company_id = v_id;
  delete from public.mk_teams                  where company_id = v_id;
  delete from public.mk_locations              where company_id = v_id;

  -- A bejelentkezési fiókok. Az auth.users törlése az mk_profiles sort is
  -- elviszi (on delete cascade). A rendszergazdák fiókja kivétel: az nem ehhez
  -- a céghez tartozik, csak a céges profiljukat vesszük el.
  delete from auth.users u
   where exists (select 1 from public.mk_profiles p where p.user_id = u.id and p.company_id = v_id)
     and not exists (select 1 from public.mk_platform_admins a where a.user_id = u.id);
  delete from public.mk_profiles where company_id = v_id;

  delete from public.mk_companies where id = v_id;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'A cég sora nem törlődött (% sor) – semmi nem változott.', v_n;
  end if;

  raise notice 'Kész: a(z) „%” cég és minden adata törölve.', v_valodi;
end $$;

-- Ellenőrzés: mi maradt
select c.id, c.name                                  as megmaradt_ceg,
       (select count(*) from public.mk_employees e where e.company_id = c.id) as dolgozo,
       (select count(*) from public.mk_profiles p where p.company_id = c.id)  as felhasznalo
  from public.mk_companies c
 order by c.created_at;
