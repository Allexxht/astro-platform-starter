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
  details      text,                         -- többsoros leírás, tudnivaló a dolgozónak
  created_at   timestamptz not null default now(),
  unique (work_date, employee_id, task_id)
);
create index if not exists mk_assignments_date_idx on public.mk_assignments (work_date);
alter table public.mk_assignments add column if not exists details text;

-- Csatolt rajzok (PDF/JPG/PNG). Egy fájlt több beosztás is használhat, ezért
-- külön táblában van a fájl (mk_attachments) és a beosztáshoz kötése
-- (mk_assignment_attachments) – lásd db/migrations/002_attachments.sql.
create table if not exists public.mk_attachments (
  id            uuid primary key default gen_random_uuid(),
  storage_path  text not null unique,
  file_name     text not null,
  mime_type     text,
  size_bytes    bigint,
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now()
);

create table if not exists public.mk_assignment_attachments (
  assignment_id  uuid not null references public.mk_assignments(id) on delete cascade,
  attachment_id  uuid not null references public.mk_attachments(id) on delete restrict,
  created_at     timestamptz not null default now(),
  primary key (assignment_id, attachment_id)
);
create index if not exists mk_assignment_attachments_att_idx on public.mk_assignment_attachments (attachment_id);


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
alter table public.mk_teams                  enable row level security;
alter table public.mk_locations              enable row level security;
alter table public.mk_employees              enable row level security;
alter table public.mk_pins                   enable row level security;
alter table public.mk_tasks                  enable row level security;
alter table public.mk_terminals              enable row level security;
alter table public.mk_assignments            enable row level security;
alter table public.mk_attachments            enable row level security;
alter table public.mk_assignment_attachments enable row level security;
alter table public.mk_events                 enable row level security;
alter table public.mk_pin_failures           enable row level security;

-- Iroda: teljes hozzáférés a törzsadatokhoz, a beosztáshoz és a csatolmányokhoz
do $$
declare t text;
begin
  foreach t in array array['mk_teams','mk_locations','mk_employees','mk_tasks','mk_terminals','mk_assignments','mk_attachments','mk_assignment_attachments'] loop
    execute format('drop policy if exists office_all on public.%I', t);
    execute format('create policy office_all on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- Storage: privát "mk-rajzok" bucket a rajzoknak. Csak az iroda (authenticated)
-- éri el közvetlenül. A tablet (anon) sosem kap Storage policyt – csak az
-- mk_terminal_attachment_path függvényen és egy Netlify végponton keresztül,
-- rövid lejáratú signed URL-lel nyithat meg egy rajzot (lásd lejjebb).
insert into storage.buckets (id, name, public)
values ('mk-rajzok', 'mk-rajzok', false)
on conflict (id) do nothing;

drop policy if exists mk_office_storage_select on storage.objects;
create policy mk_office_storage_select on storage.objects for select to authenticated
  using (bucket_id = 'mk-rajzok');

drop policy if exists mk_office_storage_insert on storage.objects;
create policy mk_office_storage_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'mk-rajzok');

drop policy if exists mk_office_storage_delete on storage.objects;
create policy mk_office_storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'mk-rajzok');

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
        select jsonb_agg(jsonb_build_object(
                 'task_id', a.task_id, 'note', a.note, 'details', a.details,
                 'attachments', coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'id', att.id, 'file_name', att.file_name,
                              'mime_type', att.mime_type, 'size_bytes', att.size_bytes)
                            order by att.created_at)
                       from public.mk_assignment_attachments aa
                       join public.mk_attachments att on att.id = aa.attachment_id
                      where aa.assignment_id = a.id), '[]'::jsonb)
               ) order by a.sort, a.created_at)
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


-- Tablet: melyik rajzot nyithatja meg. Csak a mai beosztásához tartozó csatolmány
-- tárolási útvonalát adja vissza, egyébként hibát dob. A tényleges, rövid lejáratú
-- linket egy Netlify végpont állítja elő a service role kulccsal; ez a függvény
-- csak a jogosultságot ellenőrzi (ugyanúgy, mint a többi mk_terminal_* függvény).
create or replace function public.mk_terminal_attachment_path(p_terminal uuid, p_pin text, p_attachment uuid)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_emp   uuid;
  v_today date := (now() at time zone 'Europe/Budapest')::date;
  v_path  text;
begin
  v_emp := public.mk__pin_employee(p_terminal, p_pin);
  if v_emp is null then
    raise exception 'Hibás PIN.';
  end if;

  select att.storage_path into v_path
    from public.mk_attachments att
    join public.mk_assignment_attachments aa on aa.attachment_id = att.id
    join public.mk_assignments a on a.id = aa.assignment_id
   where att.id = p_attachment
     and a.employee_id = v_emp
     and a.work_date = v_today
   limit 1;

  if v_path is null then
    raise exception 'A rajz nem érhető el.';
  end if;
  return v_path;
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
-- 7) TÖBBBÉRLŐS ADATMODELL (lásd CLAUDE.md "Többbérlős SaaS – terv")
--    Ugyanaz a tartalom, mint a db/migrations/003_multitenant.sql-ben –
--    itt azért van megismételve (nem hivatkozásként), hogy ez a fájl
--    önmagában is a teljes, friss sémát adja egy új projekthez.
--    Visszaállítás: db/migrations/rollback/003_multitenant_rollback.sql.
-- ---------------------------------------------------------------------

begin;


-- ---------------------------------------------------------------------
-- 7.1) ÚJ TÁBLÁK
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
-- 7.2) company_id OSZLOP MINDEN TÖBBI mk_ TÁBLÁN (egyelőre nullable)
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
-- 7.3) BREMAT MINT ELSŐ CÉG + BACKFILL
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
-- 7.4) NOT NULL + FK + INDEX
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
-- 7.5) SEGÉDFÜGGVÉNYEK: ki vagyok, melyik céghez tartozom, owner vagyok-e
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
-- 7.6) TRIGGEREK: a company_id-t a kliens sose adhatja meg/módosíthatja
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
-- 7.7) RLS CSERE: company_id = mk_current_company() mindenhol
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
-- 7.8) mk_companies / mk_profiles / mk_platform_admins JOGOSULTSÁGOK
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
-- 7.9) PIN-EGYEDISÉG: globálisról cégen belülire
-- ---------------------------------------------------------------------
alter table public.mk_pins drop constraint if exists mk_pins_pin_hash_key;
do $$
begin
  alter table public.mk_pins add constraint mk_pins_company_pin_key unique (company_id, pin_hash);
exception when duplicate_object or duplicate_table then null;
end $$;


-- ---------------------------------------------------------------------
-- 7.10) SECURITY DEFINER RPC-K ÚJRAÍRÁSA KETTŐS VÉDELEMMEL
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
-- 7.11) STORAGE: mk-rajzok bucket policy a <company_id>/ prefixre
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




-- ---------------------------------------------------------------------
-- 8) LICENC-KIKÉNYSZERÍTÉS + FELHASZNÁLÓ-MEZŐK
--    Ugyanaz a tartalom, mint a db/migrations/004_licenc_felhasznalok.sql-ben.
--    Visszaállítás: db/migrations/rollback/004_licenc_felhasznalok_rollback.sql.
--    A 9) kezdő adatok ELÉ kell kerülnie, mert ez a szakasz cseréli le a
--    mk_teams.name / mk_locations.name globális egyediségét cégen belülire,
--    és a kezdő adatok on conflict hivatkozása már az ÚJ megszorításra szól
--    (különben a fájl második futtatása elbukna).
-- ---------------------------------------------------------------------

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


-- ---------------------------------------------------------------------
-- 9) KEZDŐ ADATOK – nyugodtan írd át őket a Törzsadatok oldalon
--    (a company_id mindenhol explicit, mert ez a szakasz a 7) után fut,
--    tehát a mk_set_company_id_trg trigger már fel van kötve, és ebben a
--    kontextusban (SQL Editor, nincs bejelentkezett felhasználó) a trigger
--    nem tudná magától kitalálni, melyik céghez tartozik egy új sor)
-- ---------------------------------------------------------------------
insert into public.mk_teams (name, sort, company_id)
select v.name, v.sort, (select id from public.mk_companies order by created_at limit 1)
  from (values ('Hegesztők', 1), ('Lakatosok', 2), ('Raktár', 3), ('Iroda', 4)) as v(name, sort)
on conflict (company_id, name) do nothing;

insert into public.mk_locations (name, sort, company_id)
select v.name, v.sort, (select id from public.mk_companies order by created_at limit 1)
  from (values ('1-es csarnok', 1), ('2-es csarnok', 2), ('3-as csarnok', 3), ('Raktár', 4), ('Iroda', 5)) as v(name, sort)
on conflict (company_id, name) do nothing;

-- Feladatok: csak akkor, ha a tábla még üres
insert into public.mk_tasks (name, location_id, color, ask_quantity, sort, company_id)
select v.name, l.id, v.color, v.ask_qty, v.sort, (select id from public.mk_companies order by created_at limit 1)
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
insert into public.mk_terminals (name, location_id, company_id)
select v.name, l.id, (select id from public.mk_companies order by created_at limit 1)
  from (values ('1-es csarnok tablet', '1-es csarnok'),
               ('2-es csarnok tablet', '2-es csarnok'),
               ('Raktár tablet',       'Raktár')) as v(name, loc)
  left join public.mk_locations l on l.name = v.loc
 where not exists (select 1 from public.mk_terminals);

-- Tesztdolgozó a tablet kipróbálásához (PIN: 1111). Élesítés előtt kapcsold ki a Törzsadatokban.
insert into public.mk_employees (name, team_id, has_pin, company_id)
select 'Teszt Elek', t.id, true, (select id from public.mk_companies order by created_at limit 1)
  from public.mk_teams t
 where t.name = 'Hegesztők'
   and not exists (select 1 from public.mk_employees where name = 'Teszt Elek');

insert into public.mk_pins (employee_id, pin_hash, company_id)
select e.id, encode(extensions.digest('1111', 'sha256'), 'hex'), (select id from public.mk_companies order by created_at limit 1)
  from public.mk_employees e
 where e.name = 'Teszt Elek'
on conflict do nothing;


-- ---------------------------------------------------------------------
-- Kész. Az alábbi lista a tabletek azonosítóit mutatja – a tablet linkje:
--   https://<a-te-oldalad>/munkakovetes/?terminal=<terminal_id>
-- (Ugyanez a link a felületen is kimásolható: Törzsadatok → Tabletek.)
-- ---------------------------------------------------------------------
select name as tablet, id as terminal_id from public.mk_terminals order by name;
