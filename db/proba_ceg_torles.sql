-- =====================================================================
--  PRÓBA-CÉG TELJES TÖRLÉSE (a végigkattintós forgatókönyv 8. lépése)
--
--  FIGYELEM: ez visszafordíthatatlan. Töröl minden adatot, a bejelentkezési
--  fiókokat is. Az első (legrégebbi) céget – a BREMAT-ot – SZÁNDÉKOSAN nem
--  engedi törölni: a script leáll, ha arra irányulna.
--
--  A felületen NINCS cégtörlés gomb (2026. szeptember 18.), ezért megy ez
--  SQL-ből. Ha rendszeresen kell majd próba-ügyfeleket takarítani, érdemes
--  megépíteni a rendszergazda-végponton.
--
--  ELŐTTE: a Storage fájlokat kézzel töröld a Dashboard → Storage →
--  mk-rajzok bucketben, a cég azonosítójával megegyező nevű mappát. Az SQL
--  csak az adatbázis-sorokat viszi, a feltöltött fájlokat nem.
-- =====================================================================

do $$
declare
  -- ↓↓↓ ÍRD IDE A TÖRLENDŐ CÉG NEVÉT (pontosan úgy, ahogy a Cégek listában áll) ↓↓↓
  v_nev      text := 'Kovács Fémipari Kft.';

  v_id       uuid;
  v_legelso  uuid;
  v_users    int;
begin
  select id into v_id      from public.mk_companies where name = v_nev;
  select id into v_legelso from public.mk_companies order by created_at limit 1;

  if v_id is null then
    raise exception 'Nincs ilyen nevű cég: "%". Ellenőrizd a nevet (pontosan kell egyeznie).', v_nev;
  end if;
  if v_id = v_legelso then
    raise exception 'VÉDELEM: "%" a legelső cég (a BREMAT). Ezt ez a script nem törli.', v_nev;
  end if;

  select count(*) into v_users from public.mk_profiles where company_id = v_id;
  raise notice 'Törlés indul: % (azonosító: %, % felhasználói fiókkal)', v_nev, v_id, v_users;

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
  -- elviszi (on delete cascade), így nem marad árva profil.
  delete from auth.users u
   where exists (select 1 from public.mk_profiles p where p.user_id = u.id and p.company_id = v_id);

  delete from public.mk_profiles where company_id = v_id;   -- védőháló, ha maradt volna
  delete from public.mk_companies where id = v_id;

  raise notice 'Kész: a(z) "%" cég és minden adata törölve.', v_nev;
end $$;

-- Ellenőrzés: mi maradt
select c.name                                        as megmaradt_ceg,
       c.login_domain,
       (select count(*) from public.mk_employees e where e.company_id = c.id) as dolgozo,
       (select count(*) from public.mk_profiles p where p.company_id = c.id)  as felhasznalo
  from public.mk_companies c
 order by c.created_at;
