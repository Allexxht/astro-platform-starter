-- =====================================================================
--  002 – Leírás és rajz csatolása a kiosztott munkához
--
--  Mit ad hozzá:
--   • mk_assignments.details oszlop – többsoros leírás/tudnivaló a beosztáshoz
--     (a mostani "note" rövid megjegyzés mellett, attól függetlenül).
--   • mk_attachments – feltöltött fájlok (PDF/JPG/PNG) nyilvántartása. Egy fájlt
--     nem kell duplán feltölteni: több beosztás is hivatkozhat ugyanarra a sorra.
--   • mk_assignment_attachments – beosztás ↔ csatolmány kapcsolótábla.
--   • privát "mk-rajzok" Storage bucket + policyk: csak authenticated (iroda)
--     tölthet fel/nyithat meg/törölhet közvetlenül. A tablet (anon) nem kap
--     Storage policyt, csak az alábbi RPC-n és egy szerver oldali (Netlify)
--     végponton keresztül, rövid lejáratú signed URL-lel érhet el egy rajzot.
--   • mk_terminal_attachment_path(p_terminal, p_pin, p_attachment) – security
--     definer függvény: ugyanúgy ellenőrzi a tablet + PIN párost, mint a többi
--     mk_terminal_* függvény, és csak akkor adja vissza a tárolási útvonalat,
--     ha a rajz az azonosított dolgozó MAI beosztásához tartozik.
--   • mk_terminal_identify bővítve: minden mai beosztásnál adja vissza a
--     "details" mezőt és a hozzá tartozó rajzok listáját (id, fájlnév, típus,
--     méret – tárolási útvonal nélkül, azt csak a fenti RPC adja ki).
--
--  Futtatás: Supabase Dashboard → SQL Editor → New query → beillesztés → Run
--  Idempotens: többször is lefuttatható.
--  (Ugyanez benne van a db/supabase-setup.sql friss verziójában is.)
-- =====================================================================

alter table public.mk_assignments add column if not exists details text;


-- ---------------------------------------------------------------------
-- Csatolmányok
-- ---------------------------------------------------------------------
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

alter table public.mk_attachments             enable row level security;
alter table public.mk_assignment_attachments  enable row level security;

do $$
declare t text;
begin
  foreach t in array array['mk_attachments','mk_assignment_attachments'] loop
    execute format('drop policy if exists office_all on public.%I', t);
    execute format('create policy office_all on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- Storage: privát "mk-rajzok" bucket, csak az iroda (authenticated) éri el
-- közvetlenül. A tablet (anon) sosem kap Storage policyt – lásd a
-- mk_terminal_attachment_path függvényt és a Netlify végpontot.
-- ---------------------------------------------------------------------
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


-- ---------------------------------------------------------------------
-- Tablet: melyik rajzot nyithatja meg. Csak a mai beosztásához tartozó
-- csatolmány útvonalát adja vissza, egyébként hibát dob. A tényleges,
-- rövid lejáratú linket a Netlify végpont állítja elő a service role
-- kulccsal, ez a függvény csak jogosultságot ellenőriz.
-- ---------------------------------------------------------------------
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


-- mk_terminal_identify cseréje: a beosztásoknál "details" és "attachments" is.
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
