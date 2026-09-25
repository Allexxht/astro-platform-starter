// A cégkezelő logika (src/lib/mk-admin-core.ts) egységtesztjei – futtatás:
//   node --test tests/unit/
// Minden hibaág itt kerül próbára, szándékosan elrontott válaszokkal: a
// cégtörlés korábban minden eredményt figyelmen kívül hagyott, és a tárhely
// listázásának hibáját „nincs fájl”-nak vette (lásd CLAUDE.md, 2026. szeptember 25.).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  authCreateError, deleteCompany, listCompanies, listFiles, shapeCompany, DELETE_STEPS, COMPANY_LIST_QUERY,
} from '../../src/lib/mk-admin-core.ts';
import { createFake, seedCompanies } from './fake-supabase.mjs';

const del = (fake, A, extra = {}) =>
  deleteCompany(fake.io, { companyId: A, confirmName: 'Próba Kft', callerId: 'u-caller', budgetMs: 1e9, ...extra });
const filesOf = (fake, id) => [...fake.objects].filter(o => o.startsWith(`${id}/`));
const rowsOf = (fake, id) => Object.entries(fake.db).filter(([t]) => t !== 'mk_companies' && t !== 'mk_platform_admins')
  .reduce((n, [, rows]) => n + rows.filter(r => r.company_id === id).length, 0);

// ---------------------------------------------------------------------------
test('sikeres törlés: minden elvész, ami a cégé, semmi, ami másé', async () => {
  const fake = createFake();
  const { A, B } = seedCompanies(fake, { files: 2600, folders: 1300 });
  const r = await del(fake, A);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.deleted, { company: 'Próba Kft', users: 3, files: 2600 });
  assert.equal(fake.db.mk_companies.some(c => c.id === A), false, 'a cég sora törlődött');
  assert.equal(filesOf(fake, A).length, 0, 'a cég összes rajza törlődött');
  assert.equal(rowsOf(fake, A), 0, 'a cég összes sora törlődött');
  assert.equal(filesOf(fake, B).length, 1, 'a szomszéd cég rajza megmaradt');
  assert.equal(rowsOf(fake, B), 8, 'a szomszéd cég adatai megmaradtak');
  assert.equal(fake.users.has('u-a1') || fake.users.has('u-a2'), false, 'a cég fiókjai törlődtek');
  assert.equal(fake.users.has('u-admin'), true, 'a rendszergazda fiókja megmaradt, csak a céges profilja ment el');
});

test('1000 fájl fölött: a listázás lapoz, a törlés 1000 alatti adagokban megy', async () => {
  const fake = createFake();
  const { A } = seedCompanies(fake, { files: 2600, folders: 1300 });
  await del(fake, A);
  const lists = fake.calls.filter(c => c.kind === 'storage' && c.method === 'POST' && c.body.prefix === `${A}/`);
  assert.ok(lists.some(c => c.body.offset === 1000), 'a mappák második oldala is lekérdezésre került');
  const deletes = fake.calls.filter(c => c.kind === 'storage' && c.method === 'DELETE');
  assert.ok(deletes.every(c => c.body.prefixes.length <= 500), 'egy törlés legfeljebb 500 fájl');
  assert.equal(deletes.reduce((n, c) => n + c.body.prefixes.length, 0), 2600);
});

test('listFiles: a mappák 1000-es oldalanként és mappánként is lapozva, hiánytalanul', async () => {
  const fake = createFake();
  const { A } = seedCompanies(fake, { files: 0 });
  for (let i = 0; i < 1500; i++) fake.objects.add(`${A}/sok/${String(i).padStart(4, '0')}.pdf`);   // 1500 fájl EGY mappában
  for (let i = 0; i < 1200; i++) fake.objects.add(`${A}/m${String(i).padStart(4, '0')}/x.pdf`);   // 1200 mappa
  const files = await listFiles(fake.io, `${A}/`);
  assert.equal(files.length, 2700);
  assert.equal(new Set(files).size, 2700);
});

// ---------------------------------------------------------------------------
test('a tárhely listázása már az elején hibázik: semmihez nem nyúl', async () => {
  const fake = createFake();
  const { A } = seedCompanies(fake);
  fake.failWhen({ kind: 'storage', method: 'POST', path: /object\/list/, status: 503 });
  const r = await del(fake, A);
  assert.equal(r.status, 502);
  assert.match(r.body.error, /semmihez nem nyúltam/);
  assert.equal(fake.db.mk_companies.find(c => c.id === A).active, true, 'a cég nincs felfüggesztve');
  assert.equal(fake.users.has('u-a1'), true, 'a fiókok megmaradtak');
  assert.equal(filesOf(fake, A).length, 3);
});

test('a tárhely listázása menet közben hibázik: NEM veszi üres listának, megáll és jelent', async () => {
  const fake = createFake();
  const { A } = seedCompanies(fake, { files: 40 });
  // az első listázás (elérhetőség-próba) még megy, a következők nem
  let n = 0;
  const orig = fake.io.storage;
  fake.io.storage = async (path, init) => (/object\/list/.test(path) && n++ > 0 ? new Response('{"message":"kiesés"}', { status: 500 }) : orig(path, init));
  const r = await del(fake, A);
  assert.equal(r.status, 502);
  assert.equal(r.body.partial.failed, 'feltöltött rajzok');
  assert.match(r.body.error, /félbemaradt/);
  assert.equal(filesOf(fake, A).length, 40, 'a rajzok megvannak – de a cég sem tűnt el');
  assert.ok(fake.db.mk_companies.some(c => c.id === A), 'a cég sora megmaradt, így újra lehet próbálni');
  assert.ok(fake.db.mk_events.some(e => e.company_id === A), 'az üzleti adat sem törlődött a rajzok előtt');
  // újrapróbálás, most már működő tárhellyel: onnan folytatja, és végez
  fake.io.storage = orig;
  const again = await del(fake, A);
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(filesOf(fake, A).length, 0);
});

test('egy tábla törlése hibázik: pontos jelentés, a cég sora marad, újrapróbálva befejeződik', async () => {
  const fake = createFake();
  const { A } = seedCompanies(fake);
  fake.failWhen({ kind: 'rest', method: 'DELETE', path: /^mk_tasks\?/, status: 500, times: 1 });
  const r = await del(fake, A);
  assert.equal(r.status, 502);
  assert.equal(r.body.partial.failed, 'feladatok');
  assert.ok(r.body.partial.done.includes('események'), 'a korábbi lépések a kész listán');
  assert.deepEqual(r.body.partial.remaining, DELETE_STEPS.slice(DELETE_STEPS.indexOf('feladatok')));
  assert.match(r.body.error, /Hátravan: feladatok, tabletek/);
  const c = fake.db.mk_companies.find(x => x.id === A);
  assert.ok(c && c.active === false, 'a cég felfüggesztve a listában marad');
  const again = await del(fake, A);
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(rowsOf(fake, A), 0);
});

test('egy fiók törlése hibázik: a profilját NEM törli külön (nem marad profil nélküli fiók)', async () => {
  const fake = createFake();
  const { A } = seedCompanies(fake);
  fake.failWhen({ kind: 'auth', method: 'DELETE', path: /u-a2/, status: 500 });
  const r = await del(fake, A);
  assert.equal(r.status, 502);
  assert.equal(r.body.partial.failed, 'bejelentkezési fiókok');
  assert.match(r.body.error, /iroda@proba\.hu/);
  assert.equal(fake.users.has('u-a2'), true);
  assert.ok(fake.db.mk_profiles.some(p => p.user_id === 'u-a2'), 'a profilja megmaradt a fiókja mellett');
  assert.ok(fake.db.mk_companies.some(x => x.id === A));
  assert.equal(filesOf(fake, A).length, 3, 'a rajzokhoz még nem nyúlt');
});

test('a tárhely „sikert” mond, de nem töröl: hiba, nem végtelen ciklus és nem hamis siker', async () => {
  const fake = createFake();
  const { A } = seedCompanies(fake);
  const orig = fake.io.storage;
  fake.io.storage = async (path, init) => (init && init.method === 'DELETE' ? new Response('[]', { status: 200 }) : orig(path, init));
  const r = await del(fake, A);
  assert.equal(r.status, 502);
  assert.equal(r.body.partial.failed, 'feltöltött rajzok');
  assert.match(r.body.error, /nem törölt/);
});

test('az ellenőrző számolás nem jön le: hiba, NEM nulla', async () => {
  const fake = createFake();
  const { A } = seedCompanies(fake);
  fake.failWhen({ kind: 'rest', method: 'HEAD', path: /^mk_pins\?/, status: 500 });
  const r = await del(fake, A);
  assert.equal(r.status, 502);
  assert.equal(r.body.partial.failed, 'ellenőrzés');
  assert.ok(fake.db.mk_companies.some(x => x.id === A), 'ellenőrzés nélkül a cég sora nem törlődik');
});

test('a cég sorának törlése hibázik: nem jelent sikert', async () => {
  const fake = createFake();
  const { A } = seedCompanies(fake);
  fake.failWhen({ kind: 'rest', method: 'DELETE', path: /^mk_companies\?/, status: 500 });
  const r = await del(fake, A);
  assert.equal(r.status, 502);
  assert.equal(r.body.partial.failed, 'a cég sora');
});

test('időkeret: nagy cégnél 202 + continue, a folytatások együtt mindent törölnek', async () => {
  const fake = createFake();
  const { A } = seedCompanies(fake, { files: 1800, folders: 900 });
  const orig = fake.io.storage;
  fake.io.storage = async (path, init) => { fake.tick(1000); return orig(path, init); };  // minden tárhely-hívás „1 mp”
  let total = 0, rounds = 0, r;
  do {
    r = await deleteCompany(fake.io, { companyId: A, confirmName: 'Próba Kft', callerId: 'u-caller', budgetMs: 3000 });
    rounds++;
    total += (r.body.progress || r.body.deleted || {}).files || 0;
    if (r.status === 202) assert.equal(r.body.continue, true);
  } while (r.status === 202 && rounds < 50);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(rounds > 1, 'több körben ment');
  assert.equal(total, 1800);
  assert.equal(filesOf(fake, A).length, 0);
});

test('előfeltételek: rossz név, legelső cég, saját cég – semmi nem változik', async () => {
  const fake = createFake();
  const { A, BREMAT } = seedCompanies(fake);
  const before = JSON.stringify(fake.db) + fake.objects.size + fake.users.size;
  assert.equal((await deleteCompany(fake.io, { companyId: A, confirmName: 'Próba', callerId: 'u-caller' })).status, 400);
  assert.equal((await deleteCompany(fake.io, { companyId: BREMAT, confirmName: 'BREMAT', callerId: 'u-a1' })).status, 403);
  assert.equal((await deleteCompany(fake.io, { companyId: A, confirmName: 'Próba Kft', callerId: 'u-a1' })).status, 400);
  assert.equal((await deleteCompany(fake.io, { companyId: 'nincs', confirmName: 'x', callerId: 'u-caller' })).status, 404);
  assert.equal(JSON.stringify(fake.db) + fake.objects.size + fake.users.size, before);
});

// ---------------------------------------------------------------------------
test('GoTrue hibák: a 422 nem mindig „foglalt e-mail”', () => {
  assert.deepEqual(authCreateError(422, { code: 422, error_code: 'email_exists', msg: 'A user with this email address has already been registered' }).status, 409);
  assert.equal(authCreateError(422, { msg: 'User already registered' }).status, 409);
  const weak = authCreateError(422, { error_code: 'weak_password', msg: 'Password is known to be weak', weak_password: { reasons: ['pwned', 'length'] } });
  assert.equal(weak.status, 400);
  assert.match(weak.error, /túl gyengének/);
  assert.match(weak.error, /kiszivárgott/);
  assert.doesNotMatch(weak.error, /már van fiók/);
  assert.equal(authCreateError(422, { code: 422, msg: 'Password should be at least 12 characters.' }).status, 400);
  assert.match(authCreateError(400, { error_code: 'email_address_invalid', msg: 'Email address is invalid' }).error, /nem fogadta el/);
  const other = authCreateError(500, { msg: 'Database error creating new user' });
  assert.equal(other.status, 502);
  assert.match(other.error, /500/);
});

test('Cégek lista: egy kérés, a számok ismeretlenek (null), ha nem jönnek le – sosem 0', async () => {
  const fake = createFake();
  const calls = [];
  fake.io.rest = async (path) => {
    calls.push(path);
    if (path === COMPANY_LIST_QUERY) {
      return new Response(JSON.stringify([{ id: 'c1', name: 'X', active: true, created_at: '2026', users: [{ username: 'a', email: 'a@x.hu', role: 'owner' }],
        employees: [{ count: 4 }], events: [{ count: 12 }], last_event: [{ event_time: '2026-09-20T06:00:00Z' }] }]), { status: 200 });
    }
    return new Response('[]', { status: 200 });
  };
  const ok = await listCompanies(fake.io);
  assert.equal(calls.length, 1, 'egyetlen kérés, a cégek számától függetlenül');
  assert.deepEqual(ok.body.companies[0], { id: 'c1', name: 'X', license_expires_at: null, active: true, created_at: '2026',
    users: [{ username: 'a', email: 'a@x.hu', role: 'owner' }], employee_count: 4, event_count: 12, last_event_at: '2026-09-20T06:00:00Z' });

  fake.io.rest = async (path) => (path === COMPANY_LIST_QUERY
    ? new Response('{"message":"hiba"}', { status: 500 })
    : new Response(JSON.stringify(path.startsWith('mk_companies') ? [{ id: 'c1', name: 'X', active: true }] : [{ company_id: 'c1', username: 'a', email: 'a@x.hu', role: 'owner' }]), { status: 200 }));
  const fb = await listCompanies(fake.io);
  assert.equal(fb.body.companies[0].employee_count, null);
  assert.equal(fb.body.companies[0].event_count, null);
  assert.equal(fb.body.companies[0].users.length, 1);
  assert.ok(fb.body.stats_error);
  assert.equal(shapeCompany({ id: 'x', employees: 'furcsa' }).employee_count, null);
});
