-- =====================================================================
--  001 – Archiválás: mk_employees és mk_tasks archived_at oszlop
--        + mk_archive_employee / mk_archive_task függvények
--
--  Mit ad hozzá:
--   • archived_at oszlop a dolgozókhoz és a feladatokhoz. Kitöltve = archivált:
--     az elem eltűnik a törzsadatokból, a heti tervből és a tabletről, de a neve
--     az mk_events soraiban megmarad, így a múltbeli napok naplója olvasható marad.
--   • két security definer függvény, amit az iroda hív, ha az elemhez már tartozik
--     esemény, ezért véglegesen nem törölhető.
--
--  Futtatás: Supabase Dashboard → SQL Editor → New query → beillesztés → Run
--  Idempotens: többször is lefuttatható.
--  (Ugyanez benne van a db/supabase-setup.sql friss verziójában is.)
-- =====================================================================

alter table public.mk_employees add column if not exists archived_at timestamptz;
alter table public.mk_tasks     add column if not exists archived_at timestamptz;


-- Dolgozó archiválása (csak iroda): kikapcsol, PIN-t töröl, jövőbeli beosztásokat töröl.
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


-- Feladat archiválása (csak iroda): kikapcsol, a beosztásait törli.
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
