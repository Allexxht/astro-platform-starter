// Rendszergazda-műveletek próbája a VALÓDI helyi Supabase stack ellen (a CI-ban a
// kereszt-teszt után fut, ugyanazon a stacken):
//
//   A) db/proba_ceg_torles.sql: azonosító alapján töröl, a név csak megerősítés –
//      két AZONOS NEVŰ cégnél is csak a megadott törlődik, a másik érintetlen.
//   B) Cégek lista (mk-admin-core listCompanies): EGY kérés, és a beágyazott
//      számok (dolgozó archiváltak nélkül, esemény, utolsó esemény) helyesek a
//      valódi PostgREST-en.
//   C) Cégtörlés (mk-admin-core deleteCompany) a valódi Storage, Auth és REST
//      ellen: 1100 rajz (több mint egy listázási oldal), egy szándékosan elrontott
//      lépés → pontos „félbemaradt” jelentés, újrapróbálva befejeződik; a
//      szomszéd cég rajza és adatai megmaradnak.
//
// Környezet: DB_URL, API_URL, SERVICE_ROLE_KEY (a workflow a `supabase status`
// kimenetéből tölti be). Helyi próbához a C rész kihagyható: ONLY=A,B.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { deleteCompany, listCompanies, COMPANY_LIST_QUERY } from '../../src/lib/mk-admin-core.ts';

const DB_URL = process.env.DB_URL;
const API_URL = process.env.API_URL;
const KEY = process.env.SERVICE_ROLE_KEY;
const REST_URL = process.env.REST_URL || (API_URL && `${API_URL}/rest/v1`);
const ONLY = new Set((process.env.ONLY || 'A,B,C').split(','));

const results = [];
const ok = (m) => results.push(`✅ ${m}`);
const bad = (m) => results.push(`❌ ${m}`);
const check = (cond, m, extra) => (cond ? ok(m) : bad(m + (extra !== undefined ? ` – ${typeof extra === 'string' ? extra : JSON.stringify(extra)}` : '')));

const psql = (sql) => execFileSync('psql', [DB_URL, '-v', 'ON_ERROR_STOP=1', '-t', '-A', '-q', '-c', sql], { encoding: 'utf8' }).trim();
const headers = { 'content-type': 'application/json', ...(KEY ? { apikey: KEY, authorization: `Bearer ${KEY}` } : {}) };
const io = {
  rest: (p, init = {}) => fetch(`${REST_URL}/${p}`, { ...init, headers: { ...headers, ...(init.headers || {}) } }),
  auth: (p, init = {}) => fetch(`${API_URL}/auth/v1/${p}`, { ...init, headers: { ...headers, ...(init.headers || {}) } }),
  storage: (p, init = {}) => fetch(`${API_URL}/storage/v1/${p}`, { ...init, headers: { ...headers, ...(init.headers || {}) } }),
};
const COMPANY_TABLES = ['mk_events', 'mk_assignment_attachments', 'mk_attachments', 'mk_assignments', 'mk_pins', 'mk_pin_failures',
  'mk_employees', 'mk_tasks', 'mk_terminals', 'mk_teams', 'mk_locations', 'mk_profiles'];
const rowsOf = (id) => COMPANY_TABLES.reduce((n, t) => n + Number(psql(`select count(*) from public.${t} where company_id = '${id}'`)), 0);

/** Egy próba-cég nyers SQL-lel (a CI-ban és helyben is megy, nem kell hozzá Auth). */
function sqlCompany(name, { withUser = true } = {}) {
  const id = randomUUID();
  psql(`insert into public.mk_companies (id, name) values ('${id}', '${name}')`);
  const team = randomUUID();
  psql(`insert into public.mk_teams (id, name, company_id) values ('${team}', 'Csapat ${id.slice(0, 6)}', '${id}')`);
  const emp = randomUUID();
  psql(`insert into public.mk_employees (id, name, team_id, company_id) values ('${emp}', 'Dolgozó', '${team}', '${id}')`);
  psql(`insert into public.mk_events (employee_id, type, company_id) values ('${emp}', 'start', '${id}')`);
  if (withUser) {
    const uid = randomUUID();
    psql(`insert into auth.users (id, email) values ('${uid}', 'u-${uid.slice(0, 8)}@example.invalid')`);
    psql(`insert into public.mk_profiles (user_id, company_id, role) values ('${uid}', '${id}', 'owner')`);
    return { id, uid };
  }
  return { id };
}

function runScript(id, name) {
  let sql = readFileSync(new URL('../../db/proba_ceg_torles.sql', import.meta.url), 'utf8');
  sql = sql.replace(/v_id\s+uuid := [^;]+;/, `v_id uuid := ${id ? `'${id}'` : 'null'};`)
           .replace(/v_nev\s+text := '[^']*';/, `v_nev text := '${name.replace(/'/g, "''")}';`);
  try {
    execFileSync('psql', [DB_URL, '-v', 'ON_ERROR_STOP=1', '-q'], { input: sql, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
    return { ok: true };
  } catch (e) {
    return { ok: false, err: String(e.stderr || e.message) };
  }
}

// ---------------------------------------------------------------------------
if (ONLY.has('A')) {
  const x = sqlCompany('Iker Kft');
  const y = sqlCompany('Iker Kft');                               // ugyanaz a név, másik ügyfél
  const bremat = psql('select id from public.mk_companies order by created_at limit 1');
  const before = rowsOf(x.id) + rowsOf(y.id);

  let r = runScript(null, 'Iker Kft');
  check(!r.ok && /azonosítóját/.test(r.err) && rowsOf(x.id) + rowsOf(y.id) === before,
    'proba_ceg_torles.sql: azonosító nélkül (csak névvel) nem töröl semmit', r.err);
  r = runScript(x.id, 'Iker Kft.');
  check(!r.ok && /nem egyezik/.test(r.err) && rowsOf(x.id) + rowsOf(y.id) === before,
    'proba_ceg_torles.sql: ha a név nem egyezik az azonosítóval, nem töröl semmit', r.err);
  r = runScript(bremat, psql(`select name from public.mk_companies where id = '${bremat}'`));
  check(!r.ok && /VÉDELEM/.test(r.err), 'proba_ceg_torles.sql: a legelső cég (BREMAT) védett', r.err);
  r = runScript(x.id, 'Iker Kft');
  const xLeft = Number(psql(`select count(*) from public.mk_companies where id = '${x.id}'`));
  const yLeft = Number(psql(`select count(*) from public.mk_companies where id = '${y.id}'`));
  check(r.ok && xLeft === 0 && rowsOf(x.id) === 0 && Number(psql(`select count(*) from auth.users where id = '${x.uid}'`)) === 0,
    'proba_ceg_torles.sql: azonosítóval a megadott cég minden adatával és fiókjával törlődik', r.err);
  check(yLeft === 1 && rowsOf(y.id) > 0 && Number(psql(`select count(*) from auth.users where id = '${y.uid}'`)) === 1,
    'proba_ceg_torles.sql: az azonos nevű másik cég érintetlen marad');
  runScript(y.id, 'Iker Kft');                                   // takarítás
}

// ---------------------------------------------------------------------------
if (ONLY.has('B')) {
  const c = sqlCompany('Számláló Kft', { withUser: false });
  const team = psql(`select id from public.mk_teams where company_id = '${c.id}'`);
  const e2 = randomUUID();
  psql(`insert into public.mk_employees (id, name, team_id, company_id) values ('${e2}', 'Második', '${team}', '${c.id}')`);
  psql(`insert into public.mk_employees (name, team_id, company_id, archived_at) values ('Archivált', '${team}', '${c.id}', now())`);
  psql(`insert into public.mk_events (employee_id, type, company_id, event_time) values ('${e2}', 'end', '${c.id}', '2026-09-22 14:00+00')`);
  psql(`insert into public.mk_events (employee_id, type, company_id, event_time) values ('${e2}', 'start', '${c.id}', '2026-09-21 06:00+00')`);

  let requests = 0;
  const counting = { ...io, rest: (p, i) => { requests++; return io.rest(p, i); } };
  const r = await listCompanies(counting);
  const got = (r.body.companies || []).find((x) => x.id === c.id);
  const lastEvent = psql(`select to_char(max(event_time) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS') from public.mk_events where company_id = '${c.id}'`);
  check(r.status === 200 && !r.body.stats_error && requests === 1,
    `Cégek lista: egyetlen kérés (${requests}), statisztika-hiba nélkül`, r.body.stats_error);
  check(got && got.employee_count === 2 && got.event_count === 3 && String(got.last_event_at).startsWith(lastEvent),
    'Cégek lista: dolgozó (archivált nélkül) 2, esemény 3, utolsó esemény helyes – a valódi PostgREST-en', got);
  const res = await io.rest(COMPANY_LIST_QUERY);
  check(res.ok, 'a beágyazott lekérdezés szintaxisát a PostgREST elfogadja', res.status);
  psql(`delete from public.mk_events where company_id = '${c.id}'; delete from public.mk_employees where company_id = '${c.id}'; delete from public.mk_teams where company_id = '${c.id}'; delete from public.mk_companies where id = '${c.id}'`);
}

// ---------------------------------------------------------------------------
if (ONLY.has('C')) {
  const json = async (res) => (res.ok ? res.json() : Promise.reject(new Error(`${res.status} ${await res.text()}`)));
  const mkCompany = async (name) => (await json(await io.rest('mk_companies', { method: 'POST', headers: { prefer: 'return=representation' }, body: JSON.stringify({ name }) })))[0];
  const mkUser = async (companyId, email) => {
    const u = await json(await io.auth('admin/users', { method: 'POST', body: JSON.stringify({ email, password: `Pr0ba-${randomUUID()}`, email_confirm: true }) }));
    await json(await io.rest('mk_profiles', { method: 'POST', headers: { prefer: 'return=representation' }, body: JSON.stringify({ user_id: u.id, company_id: companyId, role: 'owner', email }) }));
    return u.id;
  };
  const upload = (path) => fetch(`${API_URL}/storage/v1/object/mk-rajzok/${path}`, {
    method: 'POST', headers: { apikey: KEY, authorization: `Bearer ${KEY}`, 'content-type': 'application/pdf' }, body: '%PDF-1.4 próba',
  }).then(async (r) => { if (!r.ok) throw new Error(`feltöltés ${path}: ${r.status} ${await r.text()}`); });
  const mapLimit = async (items, n, fn) => { let i = 0; await Promise.all(Array.from({ length: n }, async () => { while (i < items.length) await fn(items[i++]); })); };
  const storageCount = async (prefix) => Number(psql(`select count(*) from storage.objects where bucket_id = 'mk-rajzok' and name like '${prefix}%'`));

  const tag = randomUUID().slice(0, 8);
  const C = await mkCompany(`Törlendő Kft ${tag}`);
  const D = await mkCompany(`Szomszéd Kft ${tag}`);
  const u1 = await mkUser(C.id, `tulaj-${tag}@example.invalid`);
  const u2 = await mkUser(C.id, `iroda-${tag}@example.invalid`);
  const admin = await mkUser(C.id, `admin-${tag}@example.invalid`);
  await json(await io.rest('mk_platform_admins', { method: 'POST', headers: { prefer: 'return=representation' }, body: JSON.stringify({ user_id: admin }) }));
  const d1 = await mkUser(D.id, `szomszed-${tag}@example.invalid`);
  for (const co of [C, D]) {
    const team = randomUUID(), emp = randomUUID(), task = randomUUID();
    psql(`insert into public.mk_teams (id, name, company_id) values ('${team}', 'Csapat ${tag}', '${co.id}')`);
    psql(`insert into public.mk_employees (id, name, team_id, company_id) values ('${emp}', 'Dolgozó', '${team}', '${co.id}')`);
    psql(`insert into public.mk_tasks (id, name, company_id) values ('${task}', 'Feladat ${tag}', '${co.id}')`);
    psql(`insert into public.mk_events (employee_id, type, task_id, company_id) values ('${emp}', 'start', '${task}', '${co.id}')`);
  }
  const N = 1100;                                               // több, mint egy listázási oldal (1000)
  await mapLimit(Array.from({ length: N }, (_, i) => `${C.id}/${String(i).padStart(5, '0')}/rajz.pdf`), 24, upload);
  await upload(`${D.id}/f1/szomszed.pdf`);
  check(await storageCount(`${C.id}/`) === N, `előkészítés: ${N} rajz a törlendő cégnél`);

  // 1) Szándékosan elrontott lépés: a feladatok törlése egyszer 500-at ad.
  let broken = true;
  const flaky = { ...io, rest: (p, i) => (broken && i && i.method === 'DELETE' && p.startsWith('mk_tasks?')
    ? Promise.resolve(new Response('{"message":"szándékos hiba"}', { status: 500 })) : io.rest(p, i)) };
  const args = { companyId: C.id, confirmName: C.name, callerId: randomUUID() };
  let r, rounds = 0, files = 0;
  do { r = await deleteCompany(flaky, args); rounds++; files += (r.body.progress || {}).files || 0; } while (r.status === 202 && rounds < 40);
  check(r.status === 502 && r.body.partial && r.body.partial.failed === 'feladatok' && /Hátravan: feladatok/.test(r.body.error),
    'hibás lépésnél 502 és pontos jelentés (mi kész, mi van hátra)', r.body);
  check(Number(psql(`select count(*) from public.mk_companies where id = '${C.id}' and active = false`)) === 1,
    'félbemaradás után a cég felfüggesztve a listában marad (újra lehet próbálni)');
  check(await storageCount(`${C.id}/`) === 0, `a rajzok addigra mind törlődtek (${N} db, lapozva, ${rounds} körben)`);

  // 2) Újrapróbálás: onnan folytatja, és végez.
  broken = false;
  rounds = 0;
  do { r = await deleteCompany(io, args); rounds++; } while (r.status === 202 && rounds < 40);
  check(r.status === 200 && r.body.ok, 'újrapróbálva a törlés befejeződik', r.body);
  check(Number(psql(`select count(*) from public.mk_companies where id = '${C.id}'`)) === 0 && rowsOf(C.id) === 0,
    'a cégnek nem maradt sora egyik táblában sem');
  const gone = async (id) => (await io.auth(`admin/users/${id}`)).status === 404;
  check(await gone(u1) && await gone(u2), 'a cég bejelentkezési fiókjai törlődtek');
  check(!(await gone(admin)) && Number(psql(`select count(*) from public.mk_profiles where user_id = '${admin}'`)) === 0,
    'a rendszergazda fiókja megmaradt, csak a céges profilja ment el');
  check(await storageCount(`${D.id}/`) === 1 && rowsOf(D.id) > 0 && !(await gone(d1)),
    'a szomszéd cég rajza, adatai és fiókja érintetlen');

  // takarítás
  await deleteCompany(io, { companyId: D.id, confirmName: D.name, callerId: randomUUID() });
  await io.auth(`admin/users/${admin}`, { method: 'DELETE' });
}

console.log(results.join('\n'));
const failed = results.filter((l) => l.startsWith('❌')).length;
console.log(failed ? `\n${failed} ellenőrzés elbukott.` : `\nMind a ${results.length} ellenőrzés rendben.`);
process.exit(failed ? 1 : 0);
