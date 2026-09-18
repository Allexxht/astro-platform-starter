-- =====================================================================
--  004 – Licenc-kikényszerítés + felhasználókezeléshez szükséges mezők
--
--  Mit ad hozzá (lásd CLAUDE.md "Többbérlős SaaS – terv" → "Licenc" és
--  "Szerepkörök"):
--   • mk_profiles.username / contact_email – a bejelentkezési név és a
--     valódi e-mail cím (utóbbi a jövőbeli MFA-tartalékhoz kell, de a
--     mezőt már az onboarding űrlap kitölti).
--   • mk_company_active() / mk_write_allowed() / mk_is_platform_admin()
--     segédfüggvények.
--   • A licenc kikényszerítése ADATBÁZIS SZINTEN: lejárt vagy kikapcsolt
--     licencnél az iroda semmilyen üzleti adatot nem írhat (insert,
--     update ÉS delete sem), de mindent LÁT és riportot tud letölteni.
--     Ez egy BEFORE triggerrel történik, nem RLS-feltétellel – az utóbbi
--     UPDATE/DELETE esetén nem hibát adna, hanem csendben nulla sort
--     érintene (lásd a 3. szakasz indoklását).
--   • A tablet RPC-i szintén kézzel ellenőriznek (security definer, ezért
--     az RLS rájuk nem vonatkozik): a katalógus jelzi a lejáratot (ebből
--     tudja a tablet a "Lejárt előfizetés" képernyőt megjeleníteni), az
--     esemény-rögzítés pedig hibát dob.
--
--  Szándékosan NEM blokkolja a licenc-lejárat: a cég nevének javítását és
--  a felhasználó-kezelést (mk_profiles). Ezek számlázási/adminisztratív
--  műveletek – egy lejárt előfizetésnél is kell tudni hozzáférést elvenni
--  vagy a cégadatot javítani, ugyanúgy, ahogy egy lejárt SaaS-előfizetésnél
--  a fiókbeállítások elérhetők maradnak.
--
--  Futtatás: Supabase Dashboard → SQL Editor → New query → beillesztés → Run.
--  Idempotens: többször is lefuttatható. Egy tranzakcióban fut.
--  Visszaállítás: db/migrations/rollback/004_licenc_felhasznalok_rollback.sql.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1) mk_profiles: bejelentkezési név + valódi e-mail cím
--    mk_companies: cégenkénti bejelentkezési domain
-- ---------------------------------------------------------------------
alter table public.mk_profiles add column if not exists username      text;
alter table public.mk_profiles add column if not exists contact_email text;

-- A bejelentkezési nevet a kliens e-maillé alakítja egy kitalált domainnel
-- (ma: bremat.local, lásd CLAUDE.md "Biztonság"). Az auth.users e-mail
-- egyedi, tehát két cég azonos felhasználóneve ütközne – ezért a domain
-- cégenkénti. A meglévő (első) cég a mai domaint kapja, így a BREMAT
-- felhasználók UX-e egyáltalán nem változik.
-- Írni csak service_role tudja: a mk_companies-en a 003 óta oszlop-szintű
-- GRANT van, és az kizárólag a name oszlopra szól.
alter table public.mk_companies add column if not exists login_domain text;
update public.mk_companies set login_domain = 'bremat.local'
 where login_domain is null
   and id = (select id from public.mk_companies order by created_at limit 1);

-- Az owner a kollégája szerepkörét és kapcsolattartási e-mailjét írhatja.
-- A username NEM írható a kliensből: az a bejelentkezési azonosító, amit az
-- auth.users sorral együtt kizárólag a szerveroldali (service role) végpont
-- hoz létre – különben a felület és a tényleges bejelentkezési név szétcsúszna.
revoke update on public.mk_profiles from authenticated;
grant update (role, contact_email) on public.mk_profiles to authenticated;


-- ---------------------------------------------------------------------
-- 1b) CSAPAT- ÉS HELYSZÍNNÉV EGYEDISÉGE: globálisról cégen belülire
-- ---------------------------------------------------------------------
-- A 003 a PIN-egyediséget cégen belülire vitte, de a mk_teams.name és a
-- mk_locations.name GLOBÁLISAN egyedi maradt. Egy cégnél ez nem tűnik fel,
-- a második cégnél viszont azonnal falnak megy: nem tudna "Raktár" nevű
-- helyszínt vagy "Hegesztők" csapatot felvenni, ha egy MÁSIK cégnél már
-- van ilyen. Mivel ebben a körben épül az új cég létrehozása, ezt itt kell
-- rendbe tenni.
alter table public.mk_teams     drop constraint if exists mk_teams_name_key;
alter table public.mk_locations drop constraint if exists mk_locations_name_key;

do $$
begin
  alter table public.mk_teams add constraint mk_teams_company_name_key unique (company_id, name);
exception when duplicate_object or duplicate_table then null;
end $$;

do $$
begin
  alter table public.mk_locations add constraint mk_locations_company_name_key unique (company_id, name);
exception when duplicate_object or duplicate_table then null;
end $$;


-- ---------------------------------------------------------------------
-- 2) LICENC-SEGÉDFÜGGVÉNYEK
-- ---------------------------------------------------------------------
-- Egy cég akkor írhat, ha kézzel be van kapcsolva ÉS nincs lejárva.
-- A lejárat utáni állapot nem "kizárás", hanem csak-olvasható türelmi
-- időszak: a bejelentkezés és minden lekérdezés változatlanul működik.
create or replace function public.mk_company_active(p_company uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(c.active and (c.license_expires_at is null or c.license_expires_at >= now()), false)
    from public.mk_companies c
   where c.id = p_company;
$$;
-- Közvetlenül nem hívható a kliensből: egy idegen cég azonosítójával hívva
-- elárulná, hogy az a cég aktív-e. Csak a lenti (security definer)
-- függvények és az RPC-k használják, azok a definer jogán érik el.
revoke all on function public.mk_company_active(uuid) from public;
revoke all on function public.mk_company_active(uuid) from anon, authenticated;

-- Ezt hívják az RLS policy-k. A hívó saját cégére válaszol, tehát nem
-- szivárogtat semmit, és a kliens is lekérdezheti (ebből tudja a felület
-- kiírni a lejárt-licenc bannert).
create or replace function public.mk_write_allowed()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.mk_company_active(public.mk_current_company());
$$;

-- Platform admin-e a hívó. Külön táblából olvas (mk_platform_admins), hogy a
-- rendszergazda-jog sose keveredjen a céges szerepkör-logikával.
create or replace function public.mk_is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.mk_platform_admins where user_id = auth.uid());
$$;


-- ---------------------------------------------------------------------
-- 3) LICENC-KIKÉNYSZERÍTÉS TRIGGERREL AZ ÜZLETI TÁBLÁKON
-- ---------------------------------------------------------------------
-- Miért trigger, és miért nem RLS-feltétel?
-- Az RLS a licenc-feltételt csak "szűrésként" tudja alkalmazni: egy UPDATE
-- vagy DELETE ilyenkor nem hibázik, hanem CSENDBEN nulla sort érint. A
-- felhasználó azt látná, hogy sikerült, közben semmi nem történt – ezt
-- helyi Postgres ellen ki is próbáltuk, pontosan így viselkedett. Egy
-- BEFORE trigger ezzel szemben érthető hibaüzenetet dob, amit a felület
-- meg tud jeleníteni, és ugyanúgy megkerülhetetlen (a PostgREST-en át sem
-- lehet kikerülni).
--
-- A feltétel szándékosan csak akkor fut le, ha a hívónak VAN cége
-- (bejelentkezett irodai felhasználó). Ha nincs (anon, a tablet security
-- definer RPC-in keresztül), a triggernek nincs mihez mérnie – ott maga az
-- RPC ellenőrzi a licencet. Ugyanez a minta, mint a mk_set_company_id()
-- triggernél a 003-ban.
create or replace function public.mk_require_license()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.mk_current_company() is not null and not public.mk_write_allowed() then
    raise exception 'Lejárt előfizetés: az adatok módosítása nem lehetséges. Keresse az irodát.'
      using errcode = 'check_violation';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

do $$
declare t text;
begin
  foreach t in array array['mk_teams','mk_locations','mk_employees','mk_tasks','mk_terminals',
                            'mk_assignments','mk_attachments','mk_assignment_attachments',
                            'mk_events'] loop
    execute format('drop trigger if exists mk_require_license_trg on public.%I', t);
    execute format('create trigger mk_require_license_trg before insert or update or delete on public.%I
                      for each row execute function public.mk_require_license()', t);
  end loop;
end $$;

-- Az RLS-ben is ott a licenc-feltétel a beszúrásnál (kettős védelem: ha a
-- trigger bármiért nem futna, az insert akkor is elbukik). Az update/delete
-- policy-ba szándékosan NEM kerül bele, mert ott épp a fenti csendes
-- nulla-soros viselkedést okozná a hibaüzenet helyett.
do $$
declare t text;
begin
  foreach t in array array['mk_teams','mk_locations','mk_employees','mk_tasks','mk_terminals',
                            'mk_assignments','mk_attachments','mk_assignment_attachments'] loop
    execute format('drop policy if exists office_all on public.%I', t);
    execute format('drop policy if exists office_company on public.%I', t);
    execute format($f$create policy office_company on public.%I
                        for all to authenticated
                        using (company_id = public.mk_current_company())
                        with check (company_id = public.mk_current_company() and public.mk_write_allowed())$f$, t);
  end loop;
end $$;

drop policy if exists office_insert on public.mk_events;
create policy office_insert on public.mk_events for insert to authenticated
  with check (company_id = public.mk_current_company() and public.mk_write_allowed());


-- ---------------------------------------------------------------------
-- 4) SECURITY DEFINER RPC-K: a licenc kézi ellenőrzése
--    Ezek megkerülik az RLS-t, ezért a fenti policy-k rájuk nem hatnak –
--    ugyanaz az ok, mint a company_id-szűrésnél a 003-ban.
-- ---------------------------------------------------------------------

-- Törzsadat archiválása = írás, tehát lejárt licenccel nem megy.
-- A törzs a 003-as verzió változatlan másolata, egyetlen új ellenőrzéssel.
create or replace function public.mk_archive_employee(p_employee uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_company uuid := public.mk_current_company();
  v_emp_company uuid;
begin
  if auth.uid() is null or v_company is null then
    raise exception 'Archiválni csak bejelentkezett irodai felhasználó tud.';
  end if;
  if not public.mk_company_active(v_company) then
    raise exception 'Lejárt előfizetés: az adatok módosítása nem lehetséges. Keresse az irodát.';
  end if;

  select company_id into v_emp_company from public.mk_employees where id = p_employee;
  if v_emp_company is null or v_emp_company <> v_company then
    raise exception 'Nincs ilyen dolgozó.';
  end if;

  update public.mk_employees
     set active = false, archived_at = coalesce(archived_at, now()), has_pin = false
   where id = p_employee;
  delete from public.mk_pins        where employee_id = p_employee;
  delete from public.mk_assignments where employee_id = p_employee;
end $$;

create or replace function public.mk_archive_task(p_task uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_company uuid := public.mk_current_company();
  v_task_company uuid;
begin
  if auth.uid() is null or v_company is null then
    raise exception 'Archiválni csak bejelentkezett irodai felhasználó tud.';
  end if;
  if not public.mk_company_active(v_company) then
    raise exception 'Lejárt előfizetés: az adatok módosítása nem lehetséges. Keresse az irodát.';
  end if;

  select company_id into v_task_company from public.mk_tasks where id = p_task;
  if v_task_company is null or v_task_company <> v_company then
    raise exception 'Nincs ilyen feladat.';
  end if;

  update public.mk_tasks
     set active = false, archived_at = coalesce(archived_at, now())
   where id = p_task;
  delete from public.mk_assignments where task_id = p_task;
end $$;

-- PIN kiadása = írás. A törzs a 003-as verzió változatlan másolata,
-- egyetlen új ellenőrzéssel.
create or replace function public.mk_set_pin(p_employee uuid, p_pin text default null)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_company uuid := public.mk_current_company();
  v_emp_company uuid;
  v_pin text := nullif(trim(p_pin), '');
  v_try int  := 0;
begin
  if auth.uid() is null or v_company is null then
    raise exception 'PIN-t csak bejelentkezett irodai felhasználó állíthat.';
  end if;
  if not public.mk_company_active(v_company) then
    raise exception 'Lejárt előfizetés: az adatok módosítása nem lehetséges. Keresse az irodát.';
  end if;

  select company_id into v_emp_company from public.mk_employees where id = p_employee;
  if v_emp_company is null or v_emp_company <> v_company then
    raise exception 'Nincs ilyen dolgozó.';
  end if;

  if v_pin is not null then
    if v_pin !~ '^[0-9]{4}$' then
      raise exception 'A PIN 4 számjegyből álljon.';
    end if;
    if exists (select 1 from public.mk_pins
                where company_id = v_company
                  and pin_hash = encode(digest(v_pin, 'sha256'), 'hex')
                  and employee_id <> p_employee) then
      raise exception 'Ez a PIN már foglalt, válassz másikat.';
    end if;
  else
    loop
      v_try := v_try + 1;
      v_pin := lpad((floor(random() * 10000))::int::text, 4, '0');
      exit when not exists (select 1 from public.mk_pins
                             where company_id = v_company
                               and pin_hash = encode(digest(v_pin, 'sha256'), 'hex')
                               and employee_id <> p_employee);
      if v_try > 500 then
        raise exception 'Nem találtam szabad PIN kódot.';
      end if;
    end loop;
  end if;

  insert into public.mk_pins (employee_id, company_id, pin_hash, updated_at)
  values (p_employee, v_company, encode(digest(v_pin, 'sha256'), 'hex'), now())
  on conflict (employee_id) do update
    set pin_hash = excluded.pin_hash, company_id = excluded.company_id, updated_at = now();

  update public.mk_employees set has_pin = true where id = p_employee;
  return v_pin;
end $$;

-- Tablet katalógus: a válaszban jelezzük a licenc állapotát, hogy a tablet
-- meg tudja jeleníteni a "Lejárt előfizetés" képernyőt PIN bekérése előtt.
create or replace function public.mk_terminal_catalog(p_terminal uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_term public.mk_terminals%rowtype;
begin
  select * into v_term from public.mk_terminals where id = p_terminal and active;
  if not found then
    raise exception 'Ismeretlen vagy kikapcsolt tablet.';
  end if;

  return jsonb_build_object(
    'terminal', jsonb_build_object('id', v_term.id, 'name', v_term.name, 'location_id', v_term.location_id),
    'license_ok', public.mk_company_active(v_term.company_id),
    'locations', coalesce((
        select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'sort', l.sort) order by l.sort, l.name)
          from public.mk_locations l
         where l.company_id = v_term.company_id), '[]'::jsonb),
    'tasks', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', t.id, 'name', t.name, 'location_id', t.location_id, 'color', t.color,
                 'description', t.description, 'ask_quantity', t.ask_quantity,
                 'active', t.active, 'sort', t.sort) order by t.sort, t.name)
          from public.mk_tasks t
         where t.company_id = v_term.company_id and t.archived_at is null), '[]'::jsonb)
  );
end $$;

-- Tablet esemény-rögzítés: lejárt licencnél hibát dob. Ez a tényleges védelmi
-- határ – a katalógus license_ok mezője csak a képernyő megjelenítéséhez kell.
create or replace function public.mk_terminal_event(
  p_terminal   uuid,
  p_pin        text,
  p_type       text,
  p_task       uuid        default null,
  p_off_plan   boolean     default false,
  p_reason     text        default null,
  p_qty_task   uuid        default null,
  p_quantity   numeric     default null,
  p_event_time timestamptz default null
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_term_company uuid;
  v_emp  uuid;
  v_emp_company uuid;
  v_time timestamptz;
begin
  select company_id into v_term_company from public.mk_terminals where id = p_terminal and active;
  if v_term_company is null then
    raise exception 'Ismeretlen vagy kikapcsolt tablet.';
  end if;

  if not public.mk_company_active(v_term_company) then
    raise exception 'Lejárt előfizetés: keresse az irodát.';
  end if;

  v_emp := public.mk__pin_employee(p_terminal, p_pin);
  if v_emp is null then
    raise exception 'Hibás PIN.';
  end if;

  select company_id into v_emp_company from public.mk_employees where id = v_emp;
  if v_emp_company is distinct from v_term_company then
    raise exception 'Belső hiba: cégek közötti hozzáférés.';
  end if;

  if p_type is null or p_type not in ('start','pause','resume','block','end') then
    raise exception 'Ismeretlen esemény: %', p_type;
  end if;
  if p_type = 'start' and p_task is null then
    raise exception 'A kezdéshez feladatot kell választani.';
  end if;
  if p_quantity is not null and p_quantity < 0 then
    raise exception 'A darabszám nem lehet negatív.';
  end if;

  v_time := greatest(least(coalesce(p_event_time, now()), now()), now() - interval '24 hours');

  if p_quantity is not null and p_qty_task is not null then
    insert into public.mk_events (employee_id, terminal_id, type, task_id, quantity, event_time, company_id)
    values (v_emp, p_terminal, 'qty', p_qty_task, p_quantity, v_time - interval '1 millisecond', v_term_company);
  end if;

  insert into public.mk_events (employee_id, terminal_id, type, task_id, off_plan, reason, event_time, company_id)
  values (v_emp, p_terminal, p_type, p_task, coalesce(p_off_plan, false), nullif(trim(p_reason), ''), v_time, v_term_company);

  return jsonb_build_object('ok', true, 'event_time', v_time);
end $$;


-- ---------------------------------------------------------------------
-- 5) A MEGLÉVŐ FELHASZNÁLÓK username MEZŐJÉNEK FELTÖLTÉSE
--    A bejelentkezési név az e-mail @ előtti része (lásd CLAUDE.md
--    "Biztonság" → irodai belépés felhasználónévvel).
-- ---------------------------------------------------------------------
update public.mk_profiles p
   set username = split_part(u.email, '@', 1)
  from auth.users u
 where u.id = p.user_id
   and p.username is null;

commit;
