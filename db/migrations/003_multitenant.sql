-- =====================================================================
--  003 – Többbérlős adatmodell: cégazonosítás + RLS
--
--  Mit ad hozzá (lásd CLAUDE.md "Többbérlős SaaS – terv"):
--   • mk_companies, mk_profiles, mk_platform_admins táblák.
--   • company_id oszlop MINDEN meglévő mk_ táblán, denormalizáltan.
--   • Az első futáskor egy "BREMAT" mk_companies sor jön létre, minden
--     meglévő sor és minden meglévő auth.users felhasználó (role='owner')
--     ehhez a céghez kerül. Új cég felvétele innentől NEM ebből a scriptből
--     történik (az a jövőbeli rendszergazda-felület feladata).
--   • RLS minden táblán: company_id = mk_current_company(). A company_id-t
--     egy trigger mindig felülírja, a kliens sose adhatja meg/módosíthatja.
--   • mk_profiles / mk_companies írási joga a tervben leírt, szűk kör
--     szerint (owner a saját cégén, saját sora nélkül; licenc-mezőket
--     authenticated egyáltalán nem írhatja).
--   • A security definer RPC-k (mk_terminal_*, mk_archive_*, mk_set_pin)
--     kettős védelemmel: a lekérdezés eleve company_id-vel szűrt, ÉS a
--     visszaadás előtt egy explicit ellenőrzés van.
--   • PIN-egyediség globálisról cégen belülire vált.
--   • Storage: a mk-rajzok bucket policy-ja a <company_id>/ prefixet nézi.
--
--  Futtatás: Supabase Dashboard → SQL Editor → New query → beillesztés → Run.
--  Idempotens: többször is lefuttatható, a meglévő adatot nem törli.
--  Ugyanez a tartalom a db/supabase-setup.sql friss verziójában is benne van.
--
--  Az egész script EGY tranzakcióban fut (begin/commit): ha bármelyik lépés
--  hibázik, semmi nem marad félig alkalmazva – a script vagy teljesen
--  lefut, vagy semmi nem változik.
--
--  Visszaállítás: db/migrations/rollback/003_multitenant_rollback.sql.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1) ÚJ TÁBLÁK
-- ---------------------------------------------------------------------
create table if not exists public.mk_companies (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null check (length(trim(name)) > 0),
  license_expires_at  timestamptz,
  active              boolean not null default true,
  created_at          timestamptz not null default now()
);

create table if not exists public.mk_profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  company_id  uuid not null references public.mk_companies(id),
  role        text not null check (role in ('owner','office')),
  created_at  timestamptz not null default now()
);
create index if not exists mk_profiles_company_idx on public.mk_profiles (company_id);

-- Szándékosan KÜLÖN tábla, nem a mk_profiles-ban, hogy a rendszergazda-jog
-- sose keveredjen a céges szerepkör-logikával.
create table if not exists public.mk_platform_admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);


-- ---------------------------------------------------------------------
-- 2) company_id OSZLOP MINDEN TÖBBI mk_ TÁBLÁN (egyelőre nullable)
-- ---------------------------------------------------------------------
alter table public.mk_teams                  add column if not exists company_id uuid;
alter table public.mk_locations              add column if not exists company_id uuid;
alter table public.mk_employees              add column if not exists company_id uuid;
alter table public.mk_pins                   add column if not exists company_id uuid;
alter table public.mk_tasks                  add column if not exists company_id uuid;
alter table public.mk_terminals              add column if not exists company_id uuid;
alter table public.mk_assignments            add column if not exists company_id uuid;
alter table public.mk_attachments            add column if not exists company_id uuid;
alter table public.mk_assignment_attachments add column if not exists company_id uuid;
alter table public.mk_events                 add column if not exists company_id uuid;
alter table public.mk_pin_failures           add column if not exists company_id uuid;


-- ---------------------------------------------------------------------
-- 3) BREMAT MINT ELSŐ CÉG + BACKFILL
-- ---------------------------------------------------------------------
insert into public.mk_companies (name)
select 'BREMAT'
where not exists (select 1 from public.mk_companies);

do $$
declare v_company uuid;
begin
  select id into v_company from public.mk_companies order by created_at limit 1;

  update public.mk_teams                  set company_id = v_company where company_id is null;
  update public.mk_locations              set company_id = v_company where company_id is null;
  update public.mk_employees              set company_id = v_company where company_id is null;
  update public.mk_pins                   set company_id = v_company where company_id is null;
  update public.mk_tasks                  set company_id = v_company where company_id is null;
  update public.mk_terminals              set company_id = v_company where company_id is null;
  update public.mk_assignments            set company_id = v_company where company_id is null;
  update public.mk_attachments            set company_id = v_company where company_id is null;
  update public.mk_assignment_attachments set company_id = v_company where company_id is null;
  update public.mk_events                 set company_id = v_company where company_id is null;
  update public.mk_pin_failures           set company_id = v_company where company_id is null;

  -- Minden meglévő irodai felhasználó owner lesz ennél az (egyetlen) cégnél.
  insert into public.mk_profiles (user_id, company_id, role)
  select u.id, v_company, 'owner'
    from auth.users u
   where not exists (select 1 from public.mk_profiles p where p.user_id = u.id);
end $$;


-- ---------------------------------------------------------------------
-- 4) NOT NULL + FK + INDEX
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['mk_teams','mk_locations','mk_employees','mk_pins','mk_tasks','mk_terminals',
                            'mk_assignments','mk_attachments','mk_assignment_attachments','mk_events',
                            'mk_pin_failures'] loop
    execute format('alter table public.%I alter column company_id set not null', t);
    execute format('create index if not exists %I on public.%I (company_id)', t || '_company_idx', t);
    begin
      execute format('alter table public.%I add constraint %I foreign key (company_id) references public.mk_companies(id)',
                      t, t || '_company_id_fkey');
    exception when duplicate_object then null;
    end;
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- 5) SEGÉDFÜGGVÉNYEK: ki vagyok, melyik céghez tartozom, owner vagyok-e
-- ---------------------------------------------------------------------
create or replace function public.mk_current_company()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select company_id from public.mk_profiles where user_id = auth.uid();
$$;

create or replace function public.mk_is_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.mk_profiles where user_id = auth.uid() and role = 'owner');
$$;

grant execute on function public.mk_current_company() to authenticated;
grant execute on function public.mk_is_owner() to authenticated;


-- ---------------------------------------------------------------------
-- 6) TRIGGEREK: a company_id-t a kliens sose adhatja meg/módosíthatja
-- ---------------------------------------------------------------------
-- Beszúráskor: ha a hívónak van cégprofilja (irodai, PostgREST-en át), a
-- trigger MINDIG felülírja a company_id-t azzal. Ha nincs (anon, a tablet
-- security definer RPC-in keresztül fut), a triggernek nincs mit
-- felülírnia – ilyenkor a company_id-t magának az RPC-nek KELL explicit
-- módon megadnia (lásd lejjebb); ha az is elmarad, a trigger hibát dob.
create or replace function public.mk_set_company_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.mk_current_company() is not null then
    new.company_id := public.mk_current_company();
  elsif new.company_id is null then
    raise exception 'Hiányzó company_id.';
  end if;
  return new;
end $$;

-- Módosításkor: a company_id egyszer beállítva véglegesen zárolva van.
create or replace function public.mk_lock_company_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.company_id is not null then
    new.company_id := old.company_id;
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['mk_teams','mk_locations','mk_employees','mk_pins','mk_tasks','mk_terminals',
                            'mk_assignments','mk_attachments','mk_assignment_attachments','mk_events',
                            'mk_pin_failures','mk_profiles'] loop
    execute format('drop trigger if exists mk_set_company_id_trg on public.%I', t);
    execute format('create trigger mk_set_company_id_trg before insert on public.%I for each row execute function public.mk_set_company_id()', t);
    execute format('drop trigger if exists mk_lock_company_id_trg on public.%I', t);
    execute format('create trigger mk_lock_company_id_trg before update on public.%I for each row execute function public.mk_lock_company_id()', t);
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- 7) RLS CSERE: company_id = mk_current_company() mindenhol
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['mk_teams','mk_locations','mk_employees','mk_tasks','mk_terminals',
                            'mk_assignments','mk_attachments','mk_assignment_attachments'] loop
    execute format('drop policy if exists office_all on public.%I', t);
    execute format('drop policy if exists office_company on public.%I', t);
    execute format('create policy office_company on public.%I for all to authenticated using (company_id = public.mk_current_company()) with check (company_id = public.mk_current_company())', t);
  end loop;
end $$;

drop policy if exists office_read on public.mk_events;
create policy office_read on public.mk_events for select to authenticated
  using (company_id = public.mk_current_company());
drop policy if exists office_insert on public.mk_events;
create policy office_insert on public.mk_events for insert to authenticated
  with check (company_id = public.mk_current_company());

-- mk_pins és mk_pin_failures: változatlanul nincs policy (csak a security
-- definer függvények érik el, azok bypasselik az RLS-t).

-- mk_companies / mk_profiles / mk_platform_admins: lásd 8) pont.


-- ---------------------------------------------------------------------
-- 8) mk_companies / mk_profiles / mk_platform_admins JOGOSULTSÁGOK
--    Ez a legkritikusabb pont – lásd CLAUDE.md a pontos indoklásért.
-- ---------------------------------------------------------------------
alter table public.mk_companies       enable row level security;
alter table public.mk_profiles        enable row level security;
alter table public.mk_platform_admins enable row level security;

-- mk_companies: mindenki csak a saját cégét látja.
drop policy if exists mk_companies_select on public.mk_companies;
create policy mk_companies_select on public.mk_companies for select to authenticated
  using (id = public.mk_current_company());

-- mk_companies UPDATE: csak owner, csak a saját cégén, és a license_expires_at/
-- active oszlopot authenticated EGYÁLTALÁN nem tudja írni (oszlop-szintű
-- GRANT/REVOKE, nem csak RLS) – azt kizárólag service_role módosíthatja.
revoke update on public.mk_companies from authenticated;
grant update (name) on public.mk_companies to authenticated;
drop policy if exists mk_companies_update on public.mk_companies;
create policy mk_companies_update on public.mk_companies for update to authenticated
  using (id = public.mk_current_company() and public.mk_is_owner())
  with check (id = public.mk_current_company() and public.mk_is_owner());
-- INSERT/DELETE: nincs policy authenticated-nek -> RLS miatt default deny.
-- Új cég létrehozása/törlése csak service_role-lal (jövőbeli rendszergazda-végpont).

-- mk_profiles: mindenki a saját cége profiljait látja.
drop policy if exists mk_profiles_select on public.mk_profiles;
create policy mk_profiles_select on public.mk_profiles for select to authenticated
  using (company_id = public.mk_current_company());

-- mk_profiles UPDATE: csak owner, csak a saját cégén, KIZÁRVA a saját sorát
-- (egy owner nem tudja saját magát átminősíteni/áthelyezni). A company_id és
-- user_id oszlopot authenticated egyáltalán nem tudja írni.
revoke update on public.mk_profiles from authenticated;
grant update (role) on public.mk_profiles to authenticated;
drop policy if exists mk_profiles_update on public.mk_profiles;
create policy mk_profiles_update on public.mk_profiles for update to authenticated
  using (company_id = public.mk_current_company() and public.mk_is_owner() and user_id <> auth.uid())
  with check (company_id = public.mk_current_company() and public.mk_is_owner() and user_id <> auth.uid());

-- mk_profiles DELETE: csak owner, csak a saját cégén, saját sora nélkül.
drop policy if exists mk_profiles_delete on public.mk_profiles;
create policy mk_profiles_delete on public.mk_profiles for delete to authenticated
  using (company_id = public.mk_current_company() and public.mk_is_owner() and user_id <> auth.uid());
-- INSERT: nincs policy authenticated-nek -> RLS miatt default deny. Minden
-- felhasználó (első owner és minden kolléga is) auth.users létrehozásán megy
-- át, ami csak service role-lal lehetséges (jövőbeli rendszergazda-felület /
-- "kolléga meghívása" végpont).

-- mk_platform_admins: szándékosan nincs egyetlen policy sem -> authenticated
-- és anon számára is teljesen zárt, csak service_role / security definer
-- függvény érheti el.


-- ---------------------------------------------------------------------
-- 9) PIN-EGYEDISÉG: globálisról cégen belülire
-- ---------------------------------------------------------------------
alter table public.mk_pins drop constraint if exists mk_pins_pin_hash_key;
do $$
begin
  alter table public.mk_pins add constraint mk_pins_company_pin_key unique (company_id, pin_hash);
exception when duplicate_object or duplicate_table then null;
end $$;


-- ---------------------------------------------------------------------
-- 10) SECURITY DEFINER RPC-K ÚJRAÍRÁSA KETTŐS VÉDELEMMEL
--     (a tablet security definer RPC-i megkerülik az RLS-t – itt KÉZZEL
--     kell a company_id szűrés, ez a legkritikusabb kockázati pont)
-- ---------------------------------------------------------------------

-- Belső segédfüggvény: tablet + PIN ellenőrzése, cégen belül, percenként
-- max. 10 hibás próbálkozás tabletenként.
create or replace function public.mk__pin_employee(p_terminal uuid, p_pin text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_company uuid;
  v_emp     uuid;
  v_emp_company uuid;
begin
  select company_id into v_company from public.mk_terminals where id = p_terminal and active;
  if v_company is null then
    raise exception 'Ismeretlen vagy kikapcsolt tablet.';
  end if;

  if (select count(*) from public.mk_pin_failures
       where terminal_id = p_terminal and at > now() - interval '1 minute') >= 10 then
    raise exception 'Túl sok hibás PIN. Várj egy percet, és próbáld újra.';
  end if;

  select e.id, e.company_id into v_emp, v_emp_company
    from public.mk_pins p
    join public.mk_employees e on e.id = p.employee_id
   where p.company_id = v_company
     and p.pin_hash = encode(digest(coalesce(p_pin, ''), 'sha256'), 'hex')
     and e.active;

  -- kettős védelem: a talált dolgozó tényleg a tablet cégéhez tartozzon
  if v_emp is not null and v_emp_company is distinct from v_company then
    raise exception 'Belső hiba: cégek közötti hozzáférés.';
  end if;

  if v_emp is null then
    insert into public.mk_pin_failures (terminal_id, company_id) values (p_terminal, v_company);
    delete from public.mk_pin_failures where at < now() - interval '1 day';
  end if;

  return v_emp;
end $$;

revoke all on function public.mk__pin_employee(uuid, text) from public, anon, authenticated;


-- PIN beállítása (csak iroda, csak a saját cége dolgozójának).
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

revoke all on function public.mk_set_pin(uuid, text) from public, anon;
grant execute on function public.mk_set_pin(uuid, text) to authenticated;


-- Dolgozó archiválása (csak iroda, csak a saját cége dolgozójának).
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

revoke all on function public.mk_archive_employee(uuid) from public, anon;
grant execute on function public.mk_archive_employee(uuid) to authenticated;


-- Feladat archiválása (csak iroda, csak a saját cége feladatának).
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

  select company_id into v_task_company from public.mk_tasks where id = p_task;
  if v_task_company is null or v_task_company <> v_company then
    raise exception 'Nincs ilyen feladat.';
  end if;

  update public.mk_tasks
     set active = false, archived_at = coalesce(archived_at, now())
   where id = p_task;
  delete from public.mk_assignments where task_id = p_task;
end $$;

revoke all on function public.mk_archive_task(uuid) from public, anon;
grant execute on function public.mk_archive_task(uuid) to authenticated;


-- Tablet indulásakor: a tablet adatai, a SAJÁT CÉGÉNEK helyszínei és feladatai.
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


-- PIN beírása után: ki ő, mi a mai beosztása, és mi történt vele ma eddig.
-- Kettős védelem: a mk__pin_employee már cégen belül keres, itt még egyszer
-- explicit ellenőrizzük, hogy a dolgozó és a beosztás a tablet cégéhez tartozik.
create or replace function public.mk_terminal_identify(p_terminal uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_term_company uuid;
  v_emp_id   uuid;
  v_emp_company uuid;
  v_name     text;
  v_today    date        := (now() at time zone 'Europe/Budapest')::date;
  v_from     timestamptz := (v_today::timestamp at time zone 'Europe/Budapest');
begin
  select company_id into v_term_company from public.mk_terminals where id = p_terminal and active;
  if v_term_company is null then
    raise exception 'Ismeretlen vagy kikapcsolt tablet.';
  end if;

  v_emp_id := public.mk__pin_employee(p_terminal, p_pin);
  if v_emp_id is null then
    return null;
  end if;

  select name, company_id into v_name, v_emp_company from public.mk_employees where id = v_emp_id;
  if v_emp_company is distinct from v_term_company then
    raise exception 'Belső hiba: cégek közötti hozzáférés.';
  end if;

  return jsonb_build_object(
    'employee', jsonb_build_object('id', v_emp_id, 'name', v_name),
    'assignments', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'task_id', a.task_id, 'note', a.note, 'details', a.details,
                 'attachments', coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'id', att.id, 'file_name', att.file_name,
                              'mime_type', att.mime_type, 'size_bytes', att.size_bytes)
                            order by att.created_at)
                       from public.mk_assignment_attachments aa
                       join public.mk_attachments att on att.id = aa.attachment_id
                      where aa.assignment_id = a.id and att.company_id = v_term_company), '[]'::jsonb)
               ) order by a.sort, a.created_at)
          from public.mk_assignments a
         where a.employee_id = v_emp_id and a.work_date = v_today and a.company_id = v_term_company), '[]'::jsonb),
    'events', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'type', ev.type, 'task_id', ev.task_id, 'event_time', ev.event_time,
                 'reason', ev.reason, 'off_plan', ev.off_plan, 'quantity', ev.quantity) order by ev.event_time)
          from public.mk_events ev
         where ev.employee_id = v_emp_id and ev.event_time >= v_from and ev.company_id = v_term_company), '[]'::jsonb)
  );
end $$;


-- Tablet: melyik rajzot nyithatja meg. Kettős védelem: a lekérdezés eleve
-- a tablet cégére szűrt, ÉS a visszaadott útvonalnak a cég mappájából KELL
-- jönnie, különben hibát dobunk ahelyett, hogy visszaadnánk.
create or replace function public.mk_terminal_attachment_path(p_terminal uuid, p_pin text, p_attachment uuid)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_term_company uuid;
  v_emp   uuid;
  v_today date := (now() at time zone 'Europe/Budapest')::date;
  v_path  text;
begin
  select company_id into v_term_company from public.mk_terminals where id = p_terminal and active;
  if v_term_company is null then
    raise exception 'Ismeretlen vagy kikapcsolt tablet.';
  end if;

  v_emp := public.mk__pin_employee(p_terminal, p_pin);
  if v_emp is null then
    raise exception 'Hibás PIN.';
  end if;

  select att.storage_path into v_path
    from public.mk_attachments att
    join public.mk_assignment_attachments aa on aa.attachment_id = att.id
    join public.mk_assignments a on a.id = aa.assignment_id
    join public.mk_employees e on e.id = a.employee_id
   where att.id = p_attachment
     and a.employee_id = v_emp
     and a.work_date = v_today
     and att.company_id = v_term_company
     and a.company_id = v_term_company
     and e.company_id = v_term_company
   limit 1;

  if v_path is null then
    raise exception 'A rajz nem érhető el.';
  end if;

  -- explicit ellenőrzés visszaadás előtt: az útvonal a cég mappájából jöjjön
  if v_path !~ ('^' || v_term_company::text || '/') then
    raise exception 'Belső hiba: cégek közötti hozzáférés.';
  end if;

  return v_path;
end $$;


-- Gombnyomás a tableten: esemény rögzítése, a tablet cégéhez kötve.
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
-- 11) STORAGE: mk-rajzok bucket policy a <company_id>/ prefixre
-- ---------------------------------------------------------------------
drop policy if exists mk_office_storage_select on storage.objects;
create policy mk_office_storage_select on storage.objects for select to authenticated
  using (bucket_id = 'mk-rajzok' and (storage.foldername(name))[1] = public.mk_current_company()::text);

drop policy if exists mk_office_storage_insert on storage.objects;
create policy mk_office_storage_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'mk-rajzok' and (storage.foldername(name))[1] = public.mk_current_company()::text);

drop policy if exists mk_office_storage_delete on storage.objects;
create policy mk_office_storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'mk-rajzok' and (storage.foldername(name))[1] = public.mk_current_company()::text);

-- FONTOS: a meglévő, feltöltött fájlok fizikai útvonala ettől a policy-cserétől
-- még NEM változik meg magától (a Storage nem SQL-lel, hanem a Storage API
-- move() hívásával mozgatható) – lásd scripts/migrate-storage-to-company-prefix.mjs.
-- Amíg az a script le nem fut, a meglévő (régi útvonalú) fájlokat az iroda a
-- fenti policy szerint NEM éri el közvetlenül a Storage-ból (a <company_id>/
-- prefix hiányzik) – ezért a scriptet erre a migrációra közvetlenül rá kell
-- futtatni, ugyanazon a projekten.

commit;
