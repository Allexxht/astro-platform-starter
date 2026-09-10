-- =====================================================================
--  MUNKAKÖVETÉS – MVP adatbázis (Supabase / PostgreSQL)
--
--  Futtatás: Supabase Dashboard → SQL Editor → New query → beillesztés → Run
--  A script többször is lefuttatható, a meglévő adatokat nem törli.
--  Minden tábla "mk_" előtagot kap, így nem ütközik a projekt más tábláival
--  (pl. a Valk logbook táblákkal).
--
--  Jogosultságok röviden:
--   • Iroda  = bejelentkezett Supabase felhasználó (authenticated): mindent lát,
--              beoszt, törzsadatot szerkeszt, műszakot zárhat.
--   • Tablet = nincs bejelentkezés. Csak a lenti mk_terminal_* függvényeket
--              hívhatja, és csak érvényes tablet-azonosítóval + PIN-nel.
--   • A PIN-ek tábláját (mk_pins) senki nem olvashatja közvetlenül.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;


-- ---------------------------------------------------------------------
-- 1) TÖRZSADATOK
-- ---------------------------------------------------------------------

-- Csapat / szakma: kihez tartozik a dolgozó (hegesztők, lakatosok, raktár, iroda)
create table if not exists public.mk_teams (
  id    uuid primary key default gen_random_uuid(),
  name  text not null unique check (length(trim(name)) > 0),
  sort  int  not null default 0
);

-- Helyszín: hol folyik a munka (1-es, 2-es, 3-as csarnok, raktár, iroda)
create table if not exists public.mk_locations (
  id    uuid primary key default gen_random_uuid(),
  name  text not null unique check (length(trim(name)) > 0),
  sort  int  not null default 0
);

create table if not exists public.mk_employees (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  team_id     uuid references public.mk_teams(id) on delete set null,
  has_pin     boolean not null default false,
  active      boolean not null default true,
  archived_at timestamptz,                 -- kitöltve = archivált: eltűnik a listákból, de a napló megőrzi a nevét
  created_at  timestamptz not null default now()
);

-- PIN kódok külön táblában, hash-elve. Nincs rá policy → csak a függvények érik el.
create table if not exists public.mk_pins (
  employee_id  uuid primary key references public.mk_employees(id) on delete cascade,
  pin_hash     text not null unique,
  updated_at   timestamptz not null default now()
);

create table if not exists public.mk_tasks (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(trim(name)) > 0),
  location_id   uuid references public.mk_locations(id) on delete set null,
  color         text not null default '#9aa7b0',
  description   text,                       -- a tableten a feladat alatt jelenik meg
  ask_quantity  boolean not null default false,  -- váltáskor / műszak végén kérdezzen darabszámot
  active        boolean not null default true,
  archived_at   timestamptz,                 -- kitöltve = archivált: eltűnik a listákból, de a napló megőrzi a nevét
  sort          int not null default 0,
  created_at    timestamptz not null default now()
);

-- Falra szerelt tabletek. Az id a tablet titkos linkjének része.
create table if not exists public.mk_terminals (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (length(trim(name)) > 0),
  location_id  uuid references public.mk_locations(id) on delete set null,
  active       boolean not null default true
);

-- Utólagos oszlopok meglévő adatbázishoz (idempotens – a fenti create table csak új projektben fut le).
-- Lásd: db/migrations/001_archive_columns.sql
alter table public.mk_employees add column if not exists archived_at timestamptz;
alter table public.mk_tasks     add column if not exists archived_at timestamptz;


-- ---------------------------------------------------------------------
-- 2) HETI BEOSZTÁS
-- ---------------------------------------------------------------------
create table if not exists public.mk_assignments (
  id           uuid primary key default gen_random_uuid(),
  work_date    date not null,
  employee_id  uuid not null references public.mk_employees(id) on delete cascade,
  task_id      uuid not null references public.mk_tasks(id) on delete cascade,
  sort         int  not null default 0,
  note         text,                         -- pl. rendelésszám, konténer azonosító
  created_at   timestamptz not null default now(),
  unique (work_date, employee_id, task_id)
);
create index if not exists mk_assignments_date_idx on public.mk_assignments (work_date);


-- ---------------------------------------------------------------------
-- 3) ESEMÉNYNAPLÓ – minden riport ebből számolódik
--    start  = munka kezdése / feladatváltás      pause  = szünet
--    resume = folytatás (szünet, elakadás után)  block  = elakadt
--    end    = műszak vége                         qty    = darabszám jelentés
-- ---------------------------------------------------------------------
create table if not exists public.mk_events (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references public.mk_employees(id) on delete restrict,
  terminal_id  uuid references public.mk_terminals(id) on delete set null,
  type         text not null check (type in ('start','pause','resume','block','end','qty')),
  task_id      uuid references public.mk_tasks(id) on delete restrict,
  off_plan     boolean not null default false,   -- nem a beosztott feladatot kezdte
  reason       text,                             -- terven kívüli munka vagy elakadás oka
  quantity     numeric check (quantity is null or quantity >= 0),
  note         text,                             -- pl. "irodai lezárás"
  event_time   timestamptz not null default now(),
  created_at   timestamptz not null default now()
);
create index if not exists mk_events_time_idx on public.mk_events (event_time);
create index if not exists mk_events_emp_time_idx on public.mk_events (employee_id, event_time);

-- Hibás PIN próbálkozások (percenkénti korláthoz)
create table if not exists public.mk_pin_failures (
  id           bigint generated always as identity primary key,
  terminal_id  uuid,
  at           timestamptz not null default now()
);
create index if not exists mk_pin_failures_idx on public.mk_pin_failures (terminal_id, at);


-- ---------------------------------------------------------------------
-- 4) SOR SZINTŰ JOGOSULTSÁG (RLS)
-- ---------------------------------------------------------------------
alter table public.mk_teams        enable row level security;
alter table public.mk_locations    enable row level security;
alter table public.mk_employees    enable row level security;
alter table public.mk_pins         enable row level security;
alter table public.mk_tasks        enable row level security;
alter table public.mk_terminals    enable row level security;
alter table public.mk_assignments  enable row level security;
alter table public.mk_events       enable row level security;
alter table public.mk_pin_failures enable row level security;

-- Iroda: teljes hozzáférés a törzsadatokhoz és a beosztáshoz
do $$
declare t text;
begin
  foreach t in array array['mk_teams','mk_locations','mk_employees','mk_tasks','mk_terminals','mk_assignments'] loop
    execute format('drop policy if exists office_all on public.%I', t);
    execute format('create policy office_all on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- Eseménynapló: az iroda olvashat és rögzíthet (pl. elfelejtett kijelentkezés lezárása),
-- de módosítani és törölni senki nem tud – a napló csak bővül.
drop policy if exists office_read on public.mk_events;
create policy office_read on public.mk_events for select to authenticated using (true);
drop policy if exists office_insert on public.mk_events;
create policy office_insert on public.mk_events for insert to authenticated with check (true);

-- mk_pins és mk_pin_failures: szándékosan nincs policy.


-- ---------------------------------------------------------------------
-- 5) FÜGGVÉNYEK
-- ---------------------------------------------------------------------

-- Belső segédfüggvény: tablet + PIN ellenőrzése, percenként max. 10 hibás próbálkozás tabletenként.
create or replace function public.mk__pin_employee(p_terminal uuid, p_pin text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_emp uuid;
begin
  if not exists (select 1 from public.mk_terminals where id = p_terminal and active) then
    raise exception 'Ismeretlen vagy kikapcsolt tablet.';
  end if;

  if (select count(*) from public.mk_pin_failures
       where terminal_id = p_terminal and at > now() - interval '1 minute') >= 10 then
    raise exception 'Túl sok hibás PIN. Várj egy percet, és próbáld újra.';
  end if;

  select e.id into v_emp
    from public.mk_pins p
    join public.mk_employees e on e.id = p.employee_id
   where p.pin_hash = encode(digest(coalesce(p_pin, ''), 'sha256'), 'hex')
     and e.active;

  if v_emp is null then
    insert into public.mk_pin_failures (terminal_id) values (p_terminal);
    delete from public.mk_pin_failures where at < now() - interval '1 day';
  end if;

  return v_emp;
end $$;

revoke all on function public.mk__pin_employee(uuid, text) from public, anon, authenticated;


-- PIN beállítása (csak iroda). Üres p_pin esetén egyedi, véletlen 4 jegyű kódot generál.
-- A kódot egyszer adja vissza, utána csak a hash-e marad meg.
create or replace function public.mk_set_pin(p_employee uuid, p_pin text default null)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_pin text := nullif(trim(p_pin), '');
  v_try int  := 0;
begin
  if auth.uid() is null then
    raise exception 'PIN-t csak bejelentkezett irodai felhasználó állíthat.';
  end if;
  if not exists (select 1 from public.mk_employees where id = p_employee) then
    raise exception 'Nincs ilyen dolgozó.';
  end if;

  if v_pin is not null then
    if v_pin !~ '^[0-9]{4}$' then
      raise exception 'A PIN 4 számjegyből álljon.';
    end if;
    if exists (select 1 from public.mk_pins
                where pin_hash = encode(digest(v_pin, 'sha256'), 'hex')
                  and employee_id <> p_employee) then
      raise exception 'Ez a PIN már foglalt, válassz másikat.';
    end if;
  else
    loop
      v_try := v_try + 1;
      v_pin := lpad((floor(random() * 10000))::int::text, 4, '0');
      exit when not exists (select 1 from public.mk_pins
                             where pin_hash = encode(digest(v_pin, 'sha256'), 'hex')
                               and employee_id <> p_employee);
      if v_try > 500 then
        raise exception 'Nem találtam szabad PIN kódot.';
      end if;
    end loop;
  end if;

  insert into public.mk_pins (employee_id, pin_hash, updated_at)
  values (p_employee, encode(digest(v_pin, 'sha256'), 'hex'), now())
  on conflict (employee_id) do update
    set pin_hash = excluded.pin_hash, updated_at = now();

  update public.mk_employees set has_pin = true where id = p_employee;
  return v_pin;
end $$;

revoke all on function public.mk_set_pin(uuid, text) from public, anon;
grant execute on function public.mk_set_pin(uuid, text) to authenticated;


-- Dolgozó archiválása (csak iroda). Akkor hívjuk, ha a dolgozóhoz már tartozik esemény,
-- ezért véglegesen nem törölhető. Kikapcsolja, PIN-jét törli, a jövőbeli beosztásait eltávolítja.
-- A neve az mk_events soraiban megmarad, így a múltbeli napok naplója olvasható marad.
create or replace function public.mk_archive_employee(p_employee uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if auth.uid() is null then
    raise exception 'Archiválni csak bejelentkezett irodai felhasználó tud.';
  end if;
  if not exists (select 1 from public.mk_employees where id = p_employee) then
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


-- Feladat archiválása (csak iroda). Ugyanaz az elv, mint a dolgozónál: kikapcsol, a beosztásokat törli,
-- a név az mk_events soraiban megmarad a riportokhoz.
create or replace function public.mk_archive_task(p_task uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if auth.uid() is null then
    raise exception 'Archiválni csak bejelentkezett irodai felhasználó tud.';
  end if;
  if not exists (select 1 from public.mk_tasks where id = p_task) then
    raise exception 'Nincs ilyen feladat.';
  end if;

  update public.mk_tasks
     set active = false, archived_at = coalesce(archived_at, now())
   where id = p_task;
  delete from public.mk_assignments where task_id = p_task;
end $$;

revoke all on function public.mk_archive_task(uuid) from public, anon;
grant execute on function public.mk_archive_task(uuid) to authenticated;


-- Tablet indulásakor: a tablet adatai, helyszínek és feladatok listája.
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
          from public.mk_locations l), '[]'::jsonb),
    'tasks', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', t.id, 'name', t.name, 'location_id', t.location_id, 'color', t.color,
                 'description', t.description, 'ask_quantity', t.ask_quantity,
                 'active', t.active, 'sort', t.sort) order by t.sort, t.name)
          from public.mk_tasks t
         where t.archived_at is null), '[]'::jsonb)
  );
end $$;


-- PIN beírása után: ki ő, mi a mai beosztása, és mi történt vele ma eddig.
-- Hibás PIN esetén null-t ad vissza.
create or replace function public.mk_terminal_identify(p_terminal uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_emp_id uuid;
  v_name   text;
  v_today  date        := (now() at time zone 'Europe/Budapest')::date;
  v_from   timestamptz := (v_today::timestamp at time zone 'Europe/Budapest');
begin
  v_emp_id := public.mk__pin_employee(p_terminal, p_pin);
  if v_emp_id is null then
    return null;
  end if;
  select name into v_name from public.mk_employees where id = v_emp_id;

  return jsonb_build_object(
    'employee', jsonb_build_object('id', v_emp_id, 'name', v_name),
    'assignments', coalesce((
        select jsonb_agg(jsonb_build_object('task_id', a.task_id, 'note', a.note) order by a.sort, a.created_at)
          from public.mk_assignments a
         where a.employee_id = v_emp_id and a.work_date = v_today), '[]'::jsonb),
    'events', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'type', ev.type, 'task_id', ev.task_id, 'event_time', ev.event_time,
                 'reason', ev.reason, 'off_plan', ev.off_plan, 'quantity', ev.quantity) order by ev.event_time)
          from public.mk_events ev
         where ev.employee_id = v_emp_id and ev.event_time >= v_from), '[]'::jsonb)
  );
end $$;


-- Gombnyomás a tableten: esemény rögzítése. Opcionálisan darabszám az előző feladathoz.
-- p_event_time: az offline módhoz előkészítve (később a tablet sorba állíthatja az eseményeket);
-- jövőbeli vagy 24 óránál régebbi időpontot nem fogad el.
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
  v_emp  uuid;
  v_time timestamptz;
begin
  v_emp := public.mk__pin_employee(p_terminal, p_pin);
  if v_emp is null then
    raise exception 'Hibás PIN.';
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
    insert into public.mk_events (employee_id, terminal_id, type, task_id, quantity, event_time)
    values (v_emp, p_terminal, 'qty', p_qty_task, p_quantity, v_time - interval '1 millisecond');
  end if;

  insert into public.mk_events (employee_id, terminal_id, type, task_id, off_plan, reason, event_time)
  values (v_emp, p_terminal, p_type, p_task, coalesce(p_off_plan, false), nullif(trim(p_reason), ''), v_time);

  return jsonb_build_object('ok', true, 'event_time', v_time);
end $$;


-- ---------------------------------------------------------------------
-- 6) REALTIME – az élő nézet és a heti terv azonnal frissül
-- ---------------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table public.mk_events;
  exception
    when duplicate_object then null;
    when undefined_object then raise notice 'A supabase_realtime publikáció nem létezik – a Realtime-ot a Dashboardon kell bekapcsolni.';
  end;
  begin
    alter publication supabase_realtime add table public.mk_assignments;
  exception
    when duplicate_object then null;
    when undefined_object then null;
  end;
end $$;


-- ---------------------------------------------------------------------
-- 7) KEZDŐ ADATOK – nyugodtan írd át őket a Törzsadatok oldalon
-- ---------------------------------------------------------------------
insert into public.mk_teams (name, sort) values
  ('Hegesztők', 1), ('Lakatosok', 2), ('Raktár', 3), ('Iroda', 4)
on conflict (name) do nothing;

insert into public.mk_locations (name, sort) values
  ('1-es csarnok', 1), ('2-es csarnok', 2), ('3-as csarnok', 3), ('Raktár', 4), ('Iroda', 5)
on conflict (name) do nothing;

-- Feladatok: csak akkor, ha a tábla még üres
insert into public.mk_tasks (name, location_id, color, ask_quantity, sort)
select v.name, l.id, v.color, v.ask_qty, v.sort
  from (values
    ('Konténerhegesztés',      '2-es csarnok', '#ff8f3d', false, 1),
    ('Összeállítás, fűzés',    '1-es csarnok', '#5aa9ff', true,  2),
    ('Csiszolás, utómunka',    '2-es csarnok', '#c9a27a', true,  3),
    ('Lakatos munka',          '1-es csarnok', '#49b6d6', false, 4),
    ('Robotcella kiszolgálás', '3-as csarnok', '#a98bff', true,  5),
    ('Anyagmozgatás',          'Raktár',       '#e58bd1', false, 6),
    ('Raktári pakolás',        'Raktár',       '#8fb0c8', false, 7),
    ('Karbantartás',           null,           '#9aa7b0', false, 8),
    ('Irodai munka',           'Iroda',        '#c7cdd1', false, 9)
  ) as v(name, loc, color, ask_qty, sort)
  left join public.mk_locations l on l.name = v.loc
 where not exists (select 1 from public.mk_tasks);

-- Tabletek: csak akkor, ha még nincs egy sem
insert into public.mk_terminals (name, location_id)
select v.name, l.id
  from (values ('1-es csarnok tablet', '1-es csarnok'),
               ('2-es csarnok tablet', '2-es csarnok'),
               ('Raktár tablet',       'Raktár')) as v(name, loc)
  left join public.mk_locations l on l.name = v.loc
 where not exists (select 1 from public.mk_terminals);

-- Tesztdolgozó a tablet kipróbálásához (PIN: 1111). Élesítés előtt kapcsold ki a Törzsadatokban.
insert into public.mk_employees (name, team_id, has_pin)
select 'Teszt Elek', t.id, true
  from public.mk_teams t
 where t.name = 'Hegesztők'
   and not exists (select 1 from public.mk_employees where name = 'Teszt Elek');

insert into public.mk_pins (employee_id, pin_hash)
select e.id, encode(extensions.digest('1111', 'sha256'), 'hex')
  from public.mk_employees e
 where e.name = 'Teszt Elek'
on conflict do nothing;


-- ---------------------------------------------------------------------
-- Kész. Az alábbi lista a tabletek azonosítóit mutatja – a tablet linkje:
--   https://<a-te-oldalad>/munkakovetes/?terminal=<terminal_id>
-- (Ugyanez a link a felületen is kimásolható: Törzsadatok → Tabletek.)
-- ---------------------------------------------------------------------
select name as tablet, id as terminal_id from public.mk_terminals order by name;
