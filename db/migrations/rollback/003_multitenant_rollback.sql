-- =====================================================================
--  003 ROLLBACK – Többbérlős adatmodell visszaállítása
--
--  A db/migrations/003_multitenant.sql VISSZAÁLLÍTÁSA: eltávolítja a
--  company_id oszlopokat, a hozzájuk tartozó triggereket/RLS-t/FK-kat, a
--  mk_companies/mk_profiles/mk_platform_admins táblákat, és visszaállítja a
--  security definer RPC-k és a storage policy-k EREDETI (egycéges) verzióját.
--
--  MIKOR NE FUTTASD: ha már 2+ cég adata él a rendszerben – ez a script
--  egyetlen (BREMAT-szerű) céget feltételez, és a PIN-egyediséget vissza
--  akarja tenni globálisra, ami hibát dob, ha időközben két cégnél
--  ténylegesen ütköző PIN jött létre (lásd a 0) pont ellenőrzését lent).
--
--  Futtatás: Supabase Dashboard → SQL Editor → New query → beillesztés → Run.
--  Idempotens: többször is lefuttatható.
--
--  Az egész script EGY tranzakcióban fut (begin/commit): ha a 0) pont
--  ütközést talál (vagy bármi más hibázik), semmi nem marad félig
--  visszaállítva – a script vagy teljesen lefut, vagy semmi nem változik.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0) ELŐZETES ELLENŐRZÉS: nincs-e cégek közötti PIN-ütközés
--    (ha van, a globális unique constraint visszaállítása hibát dobna –
--    itt előre, olvasható üzenettel jelezzük, mielőtt bármi mást tennénk)
-- ---------------------------------------------------------------------
do $$
declare v_collisions int;
begin
  if to_regclass('public.mk_pins') is null or not exists (
       select 1 from information_schema.columns
        where table_schema='public' and table_name='mk_pins' and column_name='company_id') then
    return; -- a 003-as migráció még nem futott (vagy már vissza lett állítva) - nincs mit ellenőrizni
  end if;

  select count(*) into v_collisions
    from (select pin_hash from public.mk_pins group by pin_hash having count(distinct company_id) > 1) x;

  if v_collisions > 0 then
    raise exception 'A visszaállítás megállt: % PIN-hash ütközik cégek között (a PIN-egyediség cégen belülire vált a 003-as migrációval, és azóta legalább két cégnél ugyanaz a PIN jött létre). Ezt kézzel kell feloldani (az egyik cégnél PIN-t cserélni), mielőtt a globális PIN-egyediség visszaállítható.', v_collisions;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1) RÉGI RLS POLICY-K VISSZAÁLLÍTÁSA (a company_id oszlop törlése előtt kell,
--    mert amíg egy policy hivatkozik rá, a DROP COLUMN hibát dobna)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['mk_teams','mk_locations','mk_employees','mk_tasks','mk_terminals',
                            'mk_assignments','mk_attachments','mk_assignment_attachments'] loop
    execute format('drop policy if exists office_company on public.%I', t);
    execute format('drop policy if exists office_all on public.%I', t);
    execute format('create policy office_all on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

drop policy if exists office_read on public.mk_events;
create policy office_read on public.mk_events for select to authenticated using (true);
drop policy if exists office_insert on public.mk_events;
create policy office_insert on public.mk_events for insert to authenticated with check (true);

drop policy if exists mk_office_storage_select on storage.objects;
create policy mk_office_storage_select on storage.objects for select to authenticated
  using (bucket_id = 'mk-rajzok');
drop policy if exists mk_office_storage_insert on storage.objects;
create policy mk_office_storage_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'mk-rajzok');
drop policy if exists mk_office_storage_delete on storage.objects;
create policy mk_office_storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'mk-rajzok');
-- FIGYELEM: ez a policy-visszaállítás nem mozgatja vissza a Storage-ban már
-- <company_id>/ prefix alá került fájlokat – ha a storage-migráló script
-- (scripts/migrate-storage-to-company-prefix.mjs) már lefutott, a fájlok
-- fizikai útvonalát (és a mk_attachments.storage_path értékeket) is kézzel
-- kell visszaállítani, ha a rollback ezen is túlmutat.


-- ---------------------------------------------------------------------
-- 2) RÉGI RPC-K VISSZAÁLLÍTÁSA (egycéges verzió)
-- ---------------------------------------------------------------------
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
-- 3) PIN-EGYEDISÉG VISSZA GLOBÁLISRA
-- ---------------------------------------------------------------------
alter table public.mk_pins drop constraint if exists mk_pins_company_pin_key;
do $$
begin
  alter table public.mk_pins add constraint mk_pins_pin_hash_key unique (pin_hash);
exception when duplicate_object or duplicate_table then null;
end $$;


-- ---------------------------------------------------------------------
-- 4) TRIGGEREK ÉS TRIGGER-FÜGGVÉNYEK ELTÁVOLÍTÁSA
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['mk_teams','mk_locations','mk_employees','mk_pins','mk_tasks','mk_terminals',
                            'mk_assignments','mk_attachments','mk_assignment_attachments','mk_events',
                            'mk_pin_failures','mk_profiles'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists mk_set_company_id_trg on public.%I', t);
      execute format('drop trigger if exists mk_lock_company_id_trg on public.%I', t);
    end if;
  end loop;
end $$;

drop function if exists public.mk_set_company_id();
drop function if exists public.mk_lock_company_id();


-- ---------------------------------------------------------------------
-- 5) company_id OSZLOPOK ELTÁVOLÍTÁSA (viszi a rajtuk lévő indexet és a
--    mk_companies(id)-re mutató FK-t is – EZÉRT kell ennek megelőznie a
--    mk_companies tábla eldobását, különben a FK-k miatt az hibázna)
-- ---------------------------------------------------------------------
alter table public.mk_teams                  drop column if exists company_id;
alter table public.mk_locations              drop column if exists company_id;
alter table public.mk_employees              drop column if exists company_id;
alter table public.mk_pins                   drop column if exists company_id;
alter table public.mk_tasks                  drop column if exists company_id;
alter table public.mk_terminals              drop column if exists company_id;
alter table public.mk_assignments            drop column if exists company_id;
alter table public.mk_attachments            drop column if exists company_id;
alter table public.mk_assignment_attachments drop column if exists company_id;
alter table public.mk_events                 drop column if exists company_id;
alter table public.mk_pin_failures           drop column if exists company_id;


-- ---------------------------------------------------------------------
-- 6) ÚJ TÁBLÁK ÉS SEGÉDFÜGGVÉNYEK ELTÁVOLÍTÁSA
-- ---------------------------------------------------------------------
drop table if exists public.mk_profiles;
drop table if exists public.mk_platform_admins;
drop table if exists public.mk_companies;

drop function if exists public.mk_current_company();
drop function if exists public.mk_is_owner();

-- A séma-nyilvántartásból (006) is kivesszük, hogy a kliens jelezze: ez a
-- migráció most nincs érvényben ezen az adatbázison.
do $$
begin
  if to_regclass('public.mk_schema_versions') is not null then
    delete from public.mk_schema_versions where version = 3;
  end if;
end $$;

commit;

select 'ROLLBACK KÉSZ' as done;
