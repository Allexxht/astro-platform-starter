-- =====================================================================
--  VISSZAÁLLÍTÁS a 004_licenc_felhasznalok.sql migrációhoz.
--
--  Mit állít vissza:
--   • Leszedi a licenc-kikényszerítő triggert az üzleti táblákról.
--   • A policy-kat és az érintett RPC-ket visszaállítja a 003 szerinti
--     (licenc-ellenőrzés nélküli) állapotra – a függvénytörzsek a
--     003_multitenant.sql-ből átemelt, változatlan másolatok.
--   • Eldobja a licenc-segédfüggvényeket és a mk_profiles két új oszlopát.
--
--  FIGYELEM: a mk_profiles.username / contact_email oszlopok eldobásával a
--  bennük tárolt adat elvész. A username újraszámolható az auth.users
--  e-mailekből (a 004 is így tölti fel), a contact_email viszont NEM –
--  azt a felhasználók adják meg. Ha már van benne valódi adat, mentsd ki
--  előbb:  select user_id, contact_email from public.mk_profiles;
--
--  Egy tranzakcióban fut: vagy teljesen lefut, vagy semmi nem változik.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0) ELŐELLENŐRZÉS: csapat-/helyszínnév-ütközés cégek között
--    A 004 a mk_teams.name és mk_locations.name egyediségét cégen belülire
--    szűkítette. Ha azóta két cég azonos nevű csapatot/helyszínt vett fel,
--    a globális egyediség visszaállítása elbukna – ezt előre, olvasható
--    üzenettel jelezzük, és nem csinálunk semmit, amíg ez fennáll.
--    (Ugyanaz a minta, mint a 003 rollback PIN-ütközés-ellenőrzése.)
-- ---------------------------------------------------------------------
do $$
declare v_teams text; v_locs text;
begin
  select string_agg(name, ', ') into v_teams
    from (select name from public.mk_teams group by name having count(distinct company_id) > 1) x;
  select string_agg(name, ', ') into v_locs
    from (select name from public.mk_locations group by name having count(distinct company_id) > 1) y;

  if v_teams is not null or v_locs is not null then
    raise exception E'A visszaállítás nem futtatható: több cégnél is létezik ugyanaz a név, a globális egyediség visszaállítása elbukna.\nÜtköző csapatok: %\nÜtköző helyszínek: %\nElőbb nevezd át az egyiket, majd futtasd újra.',
      coalesce(v_teams, '(nincs)'), coalesce(v_locs, '(nincs)');
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1) LICENC-TRIGGER LESZEDÉSE
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['mk_teams','mk_locations','mk_employees','mk_tasks','mk_terminals',
                            'mk_assignments','mk_attachments','mk_assignment_attachments',
                            'mk_events'] loop
    execute format('drop trigger if exists mk_require_license_trg on public.%I', t);
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- 2) POLICY-K VISSZAÁLLÍTÁSA A 003 SZERINTI ALAKRA
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['mk_teams','mk_locations','mk_employees','mk_tasks','mk_terminals',
                            'mk_assignments','mk_attachments','mk_assignment_attachments'] loop
    execute format('drop policy if exists office_company on public.%I', t);
    execute format('create policy office_company on public.%I for all to authenticated using (company_id = public.mk_current_company()) with check (company_id = public.mk_current_company())', t);
  end loop;
end $$;

drop policy if exists office_insert on public.mk_events;
create policy office_insert on public.mk_events for insert to authenticated
  with check (company_id = public.mk_current_company());


-- ---------------------------------------------------------------------
-- 3) RPC-K VISSZAÁLLÍTÁSA (a 003_multitenant.sql változatlan törzsei)
-- ---------------------------------------------------------------------
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
-- 4) SEGÉDFÜGGVÉNYEK ELDOBÁSA
--    Csak a fenti policy-csere UTÁN, mert a 004-es policy-k hivatkoztak rájuk.
-- ---------------------------------------------------------------------
drop function if exists public.mk_require_license();
drop function if exists public.mk_write_allowed();
drop function if exists public.mk_is_platform_admin();
drop function if exists public.mk_company_active(uuid);


-- ---------------------------------------------------------------------
-- 5) mk_profiles OSZLOPOK ELDOBÁSA + AZ EREDETI OSZLOP-JOG VISSZAÁLLÍTÁSA
-- ---------------------------------------------------------------------
alter table public.mk_profiles drop column if exists username;
alter table public.mk_profiles drop column if exists contact_email;
alter table public.mk_companies drop column if exists login_domain;


-- ---------------------------------------------------------------------
-- 6) CSAPAT-/HELYSZÍNNÉV EGYEDISÉGE VISSZA GLOBÁLISRA
--    (a 0) pont már ellenőrizte, hogy ez nem ütközik)
-- ---------------------------------------------------------------------
alter table public.mk_teams     drop constraint if exists mk_teams_company_name_key;
alter table public.mk_locations drop constraint if exists mk_locations_company_name_key;

do $$
begin
  alter table public.mk_teams add constraint mk_teams_name_key unique (name);
exception when duplicate_object or duplicate_table then null;
end $$;

do $$
begin
  alter table public.mk_locations add constraint mk_locations_name_key unique (name);
exception when duplicate_object or duplicate_table then null;
end $$;

revoke update on public.mk_profiles from authenticated;
grant update (role) on public.mk_profiles to authenticated;

commit;

select 'ROLLBACK KÉSZ (004)' as done;
