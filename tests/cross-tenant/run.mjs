#!/usr/bin/env node
// Kereszt-teszt (cross-tenant isolation test).
// Lásd CLAUDE.md "Többbérlős SaaS – terv" → "Kereszt-teszt: valódi kapu, nem emlékezet".
//
// Ez a script a GitHub Actions workflow-ból fut (.github/workflows/cross-tenant-test.yml),
// egy eldobható, helyi Supabase CLI dev stack ellen (`supabase start`), miután a séma
// (db/supabase-setup.sql + db/migrations/*.sql) alkalmazva lett rá.
//
// Két üzemmód van, hogy a check ne zárja be a repót azelőtt, hogy a többbérlős
// adatmodell egyáltalán létezne:
//
//   1) BOOTSTRAP (public.mk_companies tábla NEM létezik): a teszt ZÖLDEN fut le,
//      jól látható üzenettel, hogy jelenleg nincs többbérlős séma, ezért semmit
//      nem vizsgált. Ez a mai állapot.
//
//   2) SZIGORÚ (public.mk_companies LÉTEZIK): innentől a teszt már nem "kegyelmi
//      időszak". Végigmegy az adatbázison, és megkeres minden company_id oszlopos
//      táblát és minden company_id-t használó security definer függvényt – ha
//      bármelyik hiányzik a tests/cross-tenant/manifest.mjs-ből, BUKÁS (a manifest
//      teljességét a séma dönti el, nem az emlékezetünk). Ha a manifest üres,
//      BUKÁS. Utána két próba-céget/felhasználót hoz létre, és A cég session-jével
//      megpróbál hozzáférni B cég adataihoz minden regisztrált táblán/RPC-n – ha
//      bármelyik átmegy, BUKÁS.

import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { TENANT_TABLES, TENANT_RPCS } from './manifest.mjs';

function fail(message) {
  console.error('\n============================================================');
  console.error('KERESZT-TESZT: BUKÁS');
  console.error('============================================================\n');
  console.error(message);
  process.exit(1);
}

function pass(message) {
  console.log('\n============================================================');
  console.log('KERESZT-TESZT: OK');
  console.log('============================================================\n');
  console.log(message);
  process.exit(0);
}

const DB_URL = process.env.DB_URL || process.env.SUPABASE_DB_URL;
if (!DB_URL) {
  fail(
    'Nincs DB_URL (vagy SUPABASE_DB_URL) környezeti változó.\n' +
      'Ez a script egy futó helyi Supabase CLI dev stacket vár (`supabase start`),\n' +
      'és a `supabase status -o env` kimenetét betöltve a környezetbe. Lokálisan:\n' +
      '  supabase start\n' +
      '  eval "$(supabase status -o env | sed \'s/^/export /\')"\n' +
      '  node tests/cross-tenant/run.mjs'
  );
}

function psql(sql) {
  return execFileSync('psql', [DB_URL, '-t', '-A', '-c', sql], { encoding: 'utf8' }).trim();
}

function psqlRows(sql) {
  const out = psql(sql);
  return out === '' ? [] : out.split('\n');
}

// --- 1. alapfeltétel: létezik-e a többbérlős séma gerince (mk_companies) ---
let hasCompanies;
try {
  hasCompanies = psql(`select to_regclass('public.mk_companies') is not null;`);
} catch (err) {
  fail('Nem sikerült csatlakozni az adatbázishoz psql-lel: ' + err.message);
}

if (hasCompanies !== 't') {
  pass(
    'A public.mk_companies tábla nem létezik ebben a sémában – jelenleg nincs\n' +
      'többbérlős adatmodell (lásd CLAUDE.md "Cégazonosítás az adatmodellben"),\n' +
      'ezért ez a teszt NEM VIZSGÁLT SEMMIT. Ez a bootstrap állapot: ez a check\n' +
      'attól kezdve válik szigorúvá (és attól kezdve tud ténylegesen szivárgást\n' +
      'kiszűrni), hogy a public.mk_companies tábla megjelenik a sémában.'
  );
}

// --- SZIGORÚ MÓD innentől ---

// --- 2. az adatbázis a forrás igazság: melyik táblának van company_id oszlopa, ---
//        és melyik security definer függvény dolgozik company_id-val
const discoveredTables = psqlRows(
  `select table_name from information_schema.columns ` +
    `where table_schema='public' and column_name='company_id' ` +
    `order by table_name;`
);

// Kihagyjuk a trigger-függvényeket (nem hívhatók RPC-ként) és a nulla
// paraméterű "ki vagyok" segédfüggvényeket (pl. mk_current_company()) –
// ezeknek nincs "másik cég azonosítója", amivel egy kereszt-bérlős próbát
// egyáltalán értelmes lenne rájuk futtatni, mindig csak a hívó saját
// kontextusát adják vissza.
const discoveredRpcs = psqlRows(
  `select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace ` +
    `where n.nspname='public' and p.prosecdef and p.prosrc ilike '%company_id%' ` +
    `and p.prorettype <> 'trigger'::regtype and p.pronargs > 0 ` +
    `order by p.proname;`
);

// --- 3. a manifest üres-e ---
if (TENANT_TABLES.length === 0 && TENANT_RPCS.length === 0) {
  fail(
    'A public.mk_companies tábla létezik, de a tests/cross-tenant/manifest.mjs\n' +
      'TENANT_TABLES / TENANT_RPCS listája még üres.\n\n' +
      'Szabály: minden company_id-t kapó tábla és minden security definer RPC\n' +
      '(mk_terminal_*, mk_archive_*, mk_set_pin) ugyanabban a pull requestben kerül\n' +
      'be a manifestbe, amelyikben a séma bővül. Vedd fel a manifestbe, mielőtt ez\n' +
      'a teszt zöldet adhatna.\n\n' +
      `Az adatbázisban jelenleg company_id oszloppal rendelkező táblák: ${discoveredTables.join(', ') || '(egy sem)'}\n` +
      `company_id-t használó security definer függvények: ${discoveredRpcs.join(', ') || '(egy sem)'}`
  );
}

// --- 4. a manifest teljessége: a séma dönt, nem az emlékezetünk ---
const manifestTableNames = new Set(TENANT_TABLES.map((t) => t.table));
const manifestRpcNames = new Set(TENANT_RPCS.map((r) => r.name));

const missingTables = discoveredTables.filter((t) => !manifestTableNames.has(t));
const missingRpcs = discoveredRpcs.filter((r) => !manifestRpcNames.has(r));

if (missingTables.length || missingRpcs.length) {
  fail(
    'Az adatbázisban vannak company_id-s táblák/RPC-k, amik nincsenek felvéve a\n' +
      'tests/cross-tenant/manifest.mjs-be:\n' +
      (missingTables.length ? `\nHiányzó táblák (TENANT_TABLES):\n - ${missingTables.join('\n - ')}\n` : '') +
      (missingRpcs.length ? `\nHiányzó RPC-k (TENANT_RPCS):\n - ${missingRpcs.join('\n - ')}\n` : '') +
      '\nVedd fel ezeket a manifestbe (a hozzájuk tartozó kereszt-bérlős próba ' +
      'leírásával együtt), mielőtt ez a teszt zöldet adhatna.'
  );
}

// --- 5. tábla-szintű ellenőrzés: minden manifestben szereplő táblának tényleg ---
//        legyen company oszlopa (elgépelt/elavult manifest-bejegyzés ellen)
const schemaProblems = [];
for (const t of TENANT_TABLES) {
  const col = t.companyColumn ?? 'company_id';
  const exists = psql(
    `select exists (select 1 from information_schema.columns ` +
      `where table_schema='public' and table_name='${t.table}' and column_name='${col}');`
  );
  if (exists !== 't') schemaProblems.push(`${t.table}.${col} hiányzik`);
}
if (schemaProblems.length) {
  fail(
    'A manifestben regisztrált táblák közül néhánynak hiányzik a company oszlopa ' +
      '(vagy elgépelt a tábla/oszlopnév a manifestben):\n - ' +
      schemaProblems.join('\n - ')
  );
}

// --- 5b. forrás-ellenőrzés: a kliens a SAJÁT profilját user_id-re szűrve kérje ---
//
// Egy valódi éles hiba miatt van itt (2026. szeptember 18.): a loadMe() szűrés
// nélkül hívott .single()-t az mk_profiles-on. Az RLS a cég ÖSSZES profilját
// visszaadja, tehát a második felhasználó felvételétől kezdve a lekérdezés
// elbukott ("Cannot coerce the result to a single JSON object"), és vele a
// licenc-mentés, a szerepkörös fülek és a rajzfeltöltés is. Egycéges,
// egyfelhasználós rendszerben ez sosem derül ki magától – ezért forrásból
// ellenőrizzük, nem csak viselkedésből.
{
  const clientSource = readFileSync(new URL('../../public/munkakovetes/index.html', import.meta.url), 'utf8');
  const profileSelects = clientSource
    .split('\n')
    .filter((line) => /T\('profiles'\)\)\.select\(/.test(line));

  if (!profileSelects.length) {
    fail('Nem találom a kliensben az mk_profiles lekérdezést – változott a kód szerkezete, nézd át ezt az ellenőrzést.');
  }
  const bad = profileSelects.filter(
    (line) => /\.(single|maybeSingle)\(/.test(line) && !/\.eq\('user_id'/.test(line)
  );
  if (bad.length) {
    fail(
      'A kliens egyetlen sorra szűkítve (.single()/.maybeSingle()) kérdezi le az\n' +
        'mk_profiles táblát, DE nem szűr user_id-re. Az RLS a cég összes profilját\n' +
        'visszaadja, tehát ez a második felhasználótól kezdve elbukik:\n - ' +
        bad.map((l) => l.trim()).join('\n - ') +
        '\n\nTegyél .eq(\'user_id\', <bejelentkezett user id>) szűrést a lekérdezésre.'
    );
  }
}

// --- 5c. forrás-ellenőrzés: a bejelentkezés NE fűzzön domaint a beírt névhez ---
//
// Korábban a kliens minden puszta felhasználónév mögé egy kódba írt domaint
// tett (CONFIG.LOGIN_DOMAIN = 'bremat.local'). Ez a 2. ügyfélnél nem csak
// kényelmetlen lett volna: egy másik cég felhasználója puszta névvel a BREMAT
// fiókjába próbált volna belépni, és ha ott létezik ilyen nevű fiók, rossz cég
// adatait láthatta volna. A bejelentkezés azóta e-mail cím + jelszó, ezért a
// kód NEM tartalmazhat ilyen kiegészítést – forrásból is őrizzük, nehogy
// visszaszivárogjon.
{
  const clientSource = readFileSync(new URL('../../public/munkakovetes/index.html', import.meta.url), 'utf8');
  const offenders = clientSource
    .split('\n')
    .map((line, i) => ({ line: line.trim(), no: i + 1 }))
    .filter(({ line }) => /LOGIN_DOMAIN/.test(line) || /@\$\{/.test(line) || /\+\s*'@'\s*\+/.test(line));
  if (offenders.length) {
    fail(
      'A kliens a bejelentkezésnél domaint fűz a beírt értékhez (vagy maradt\n' +
        'LOGIN_DOMAIN hivatkozás). A belépés e-mail címmel megy, a címet nem\n' +
        'alakítjuk át:\n - ' +
        offenders.map(({ no, line }) => `${no}. sor: ${line}`).join('\n - ')
    );
  }
}

// --- 5d. séma-nyilvántartás (006): a kód, a migrációk és a setup egyezzen ---
//
// 2026. szeptember 24-én kiderült, hogy a 005 kódja már élesben futott, a
// migrációja viszont nem – és semmi nem jelezte. Azóta a kliens induláskor
// összeveti, milyen migrációt vár (SCHEMA_MIGRATIONS az index.html-ben) azzal,
// ami az adatbázisban nyilvántartva van (mk_schema_state()). Ez csak akkor ér
// valamit, ha a három hely – a kliens listája, a db/migrations mappa és a
// supabase-setup.sql – nem csúszik el egymástól, és minden migráció
// bejegyzi magát. Ezt itt forrásból ellenőrizzük, mert a hiba tünete (a
// figyelmeztetés hiányzik vagy tévesen jelez) csak élesben látszana.
{
  const readRepo = rel => readFileSync(new URL('../../' + rel, import.meta.url), 'utf8');
  const clientSource = readRepo('public/munkakovetes/index.html');
  const setupSource = readRepo('db/supabase-setup.sql');
  const migrationFiles = readdirSync(new URL('../../db/migrations/', import.meta.url))
    .filter(f => /^\d{3}_.+\.sql$/.test(f)).sort();
  const rollbackFiles = new Set(readdirSync(new URL('../../db/migrations/rollback/', import.meta.url)));
  const problems = [];

  const listMatch = clientSource.match(/const SCHEMA_MIGRATIONS = \[([\s\S]*?)\];/);
  if (!listMatch) {
    fail('Nem találom a kliensben a SCHEMA_MIGRATIONS listát – változott a kód szerkezete, nézd át ezt az ellenőrzést.');
  }
  const clientList = [...listMatch[1].matchAll(/\{\s*version:\s*(\d+),\s*file:\s*'([^']+)'\s*\}/g)]
    .map(m => ({ version: Number(m[1]), file: m[2] }));
  const clientFiles = clientList.map(m => m.file).join(', ');
  if (clientFiles !== migrationFiles.join(', ')) {
    problems.push(
      'A kliens SCHEMA_MIGRATIONS listája nem egyezik a db/migrations mappával.\n' +
        `     kliens:  ${clientFiles || '(üres)'}\n     mappa:   ${migrationFiles.join(', ')}`
    );
  }
  for (const m of clientList) {
    if (Number(m.file.slice(0, 3)) !== m.version) problems.push(`A kliens listájában a(z) ${m.file} sorszáma hibás (${m.version}).`);
  }

  for (const file of migrationFiles) {
    const version = Number(file.slice(0, 3));
    const name = file.replace(/\.sql$/, '');
    const entry = new RegExp(`\\(\\s*${version}\\s*,\\s*'${name}'\\s*\\)`);
    const src = readRepo('db/migrations/' + file);
    if (!/mk_schema_versions/.test(src) || !entry.test(src)) {
      problems.push(`A(z) ${file} nem jegyzi be magát az mk_schema_versions táblába (várt bejegyzés: (${version}, '${name}')).`);
    }
    if (!entry.test(setupSource)) {
      problems.push(`A db/supabase-setup.sql séma-nyilvántartás szakaszából hiányzik: (${version}, '${name}').`);
    }
    const rb = `${name}_rollback.sql`;
    if (rollbackFiles.has(rb) && !/mk_schema_versions/.test(readRepo('db/migrations/rollback/' + rb))) {
      problems.push(`A(z) rollback/${rb} nem veszi ki a(z) ${version}. migrációt az mk_schema_versions táblából.`);
    }
  }

  // Az adatbázis maga: a setup + az összes migráció után minden várt sorszám
  // nyilvántartva van.
  let dbState;
  try {
    dbState = psql('select array_to_string(public.mk_schema_state(), \',\')');
  } catch (err) {
    dbState = `hiba: ${String(err.message).split('\n').find(l => /ERROR/.test(l)) || err.message}`;
  }
  const expected = clientList.map(m => m.version).join(',');
  if (dbState !== expected) {
    problems.push(`Az mk_schema_state() a setup + minden migráció után ezt adja: {${dbState}}, a kliens ezt várja: {${expected}}.`);
  }

  if (problems.length) {
    fail(
      'A séma-nyilvántartás (006) nem egyezik a kóddal – a kliens „le van maradva" figyelmeztetése\n' +
        'így tévesen jelezne vagy hallgatna. Új migrációnál: a fájl jegyezze be magát, a rollbackje\n' +
        'vegye ki, és kerüljön be a kliens SCHEMA_MIGRATIONS listájába és a supabase-setup.sql-be.\n - ' +
        problems.join('\n - ')
    );
  }
}

// --- 6. a tényleges kereszt-bérlős próba: két próba-cég + felhasználó, ---
//        A cég session-jével B cég adataira/RPC-ire
await runCrossTenantProbe();

async function createTestCompany(admin, name) {
  // FIGYELEM: ezt a helyet kell módosítani, ha a végleges mk_companies oszlopnevei
  // (a CLAUDE.md tervben: name, license_expires_at, active) eltérnek ettől.
  const { data, error } = await admin
    .from('mk_companies')
    .insert({ name })
    .select('id')
    .single();
  if (error) fail(`Nem sikerült próba-céget létrehozni (${name}): ${error.message}`);
  return { id: data.id, name };
}

// Egy teljes, önmagában is életszerű próba-cég: terminál, dolgozó (PIN-nel),
// feladat, mai beosztás, csatolmány – ezek adják az RPC-próbákhoz szükséges
// valós id-kat (lásd manifest.mjs TENANT_RPCS baseArgs/otherTenantValue).
// A `pin` szándékosan cégenként EGYEDI (a hívó adja meg), hogy egy "A PIN-je
// B terminálján" próba tényleg ne találjon semmit B cégén belül.
async function createTestFixture(admin, name, pin) {
  const company = await createTestCompany(admin, name);
  const companyId = company.id;

  const insertScoped = async (table, row) => {
    const { data, error } = await admin.from(table).insert({ ...row, company_id: companyId }).select('id').single();
    if (error) fail(`Nem sikerült próba-sort létrehozni (${table}, ${name}): ${error.message}`);
    return data.id;
  };

  const terminalId = await insertScoped('mk_terminals', { name: `${name} terminál` });
  const employeeId = await insertScoped('mk_employees', { name: `${name} dolgozó` });
  const taskId = await insertScoped('mk_tasks', { name: `${name} feladat` });

  const { createHash } = await import('node:crypto');
  const pinHash = createHash('sha256').update(pin).digest('hex');
  const { error: pinError } = await admin
    .from('mk_pins')
    .insert({ employee_id: employeeId, company_id: companyId, pin_hash: pinHash });
  if (pinError) fail(`Nem sikerült próba-PIN-t létrehozni (${name}): ${pinError.message}`);

  const today = new Date().toISOString().slice(0, 10);
  const assignmentId = await insertScoped('mk_assignments', { employee_id: employeeId, task_id: taskId, work_date: today });

  const storagePath = `${companyId}/crosstenant-test/${assignmentId}.pdf`;
  const attachmentId = await insertScoped('mk_attachments', { storage_path: storagePath, file_name: 'test.pdf' });
  const { error: linkError } = await admin
    .from('mk_assignment_attachments')
    .insert({ assignment_id: assignmentId, attachment_id: attachmentId, company_id: companyId });
  if (linkError) fail(`Nem sikerült próba-csatolmányt hozzákapcsolni (${name}): ${linkError.message}`);

  return { id: companyId, name, terminalId, employeeId, taskId, assignmentId, attachmentId, pin };
}

async function createTestUser(admin, companyId, role) {
  const email = `crosstenant-test-${companyId}-${role}@example.invalid`;
  const password = `Test-${Math.random().toString(36).slice(2)}-Aa1!`;
  const { data: userData, error: userError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (userError) fail(`Nem sikerült próba-felhasználót létrehozni (${email}): ${userError.message}`);

  // FIGYELEM: a terv szerint mk_profiles INSERT sose megy kliensről – itt a
  // service role kulcs a "rendszergazda-felület" szerepét játssza a próba-adatok
  // felvitelekor, ez szándékosan más út, mint amit egy valódi kliens használhatna.
  const { error: profileError } = await admin
    .from('mk_profiles')
    .insert({ user_id: userData.user.id, company_id: companyId, role, email, username: email.split('@')[0] });
  if (profileError) fail(`Nem sikerült próba-profilt létrehozni (${email}): ${profileError.message}`);

  return { email, password, id: userData.user.id };
}

/**
 * Célzott próbák: saját company_id / szerepkör átírása, licenc-mező írása, és
 * hogy lejárt licencnél az írás ADATBÁZIS szinten bukik-e el (nem csak a
 * felületen). Minden talált gond a `leaks` tömbbe kerül, hogy egy futásból
 * kiderüljön az összes, ne csak az első.
 */
async function runPrivilegeProbes(admin, clientA, companyA, companyB, userA, leaks) {
  // 1) A saját cégét ne tudja átírni (a company_id oszlopra nincs is GRANT-ja,
  //    és a policy sem engedné a saját sorát módosítani).
  const { error: selfCompanyError } = await clientA
    .from('mk_profiles')
    .update({ company_id: companyB.id })
    .eq('user_id', userA.id);
  if (!selfCompanyError) {
    const { data } = await admin.from('mk_profiles').select('company_id').eq('user_id', userA.id).single();
    if (data?.company_id !== companyA.id) {
      leaks.push('mk_profiles: a felhasználó ÁT TUDTA ÍRNI a saját company_id-jét egy másik cégre');
    }
  }

  // 2) A saját szerepkörét ne tudja átírni (a policy kizárja a saját sorát).
  //    userA owner, ezért a próba VALÓDI változtatás: 'office'-ra állítani.
  //    Ha ez sikerülne, egy owner le tudná magát fokozni – vagy fordítva, egy
  //    irodai felhasználó fel tudná magát minősíteni ugyanezen az úton.
  const { data: roleBefore } = await admin.from('mk_profiles').select('role').eq('user_id', userA.id).single();
  await clientA.from('mk_profiles').update({ role: 'office' }).eq('user_id', userA.id);
  const { data: roleAfter } = await admin.from('mk_profiles').select('role').eq('user_id', userA.id).single();
  if (roleBefore?.role !== roleAfter?.role) {
    leaks.push(
      `mk_profiles: a felhasználó ÁT TUDTA ÍRNI a saját szerepkörét (${roleBefore?.role} → ${roleAfter?.role})`
    );
  }

  // 3) A licenc-mezőkhöz authenticated EGYÁLTALÁN ne nyúlhasson (oszlop-szintű
  //    GRANT/REVOKE, nem csak RLS – ezért ennek hibát KELL adnia).
  const { error: licError } = await clientA
    .from('mk_companies')
    .update({ license_expires_at: new Date(Date.now() + 31536000000).toISOString() })
    .eq('id', companyA.id);
  if (!licError) {
    leaks.push('mk_companies: az irodai felhasználó ÁT TUDTA ÍRNI a license_expires_at mezőt (csak platform adminnak szabadna)');
  }
  const { error: activeError } = await clientA.from('mk_companies').update({ active: true }).eq('id', companyA.id);
  if (!activeError) {
    leaks.push('mk_companies: az irodai felhasználó át tudta írni az active mezőt (csak platform adminnak szabadna)');
  }

  // 4) Lejárt licencnél az írás a DB-ben bukjon el. A licencet service role-lal
  //    állítjuk múltbelire (ahogy a valódi rendszergazda-végpont tenné), majd
  //    ugyanazzal a bejelentkezett klienssel próbálunk írni.
  await admin
    .from('mk_companies')
    .update({ license_expires_at: new Date(Date.now() - 86400000).toISOString() })
    .eq('id', companyA.id);

  const { error: expiredInsert } = await clientA.from('mk_tasks').insert({ name: 'lejart-licenc-proba' });
  if (!expiredInsert) leaks.push('licenc: lejárt előfizetéssel SIKERÜLT új feladatot beszúrni');

  const { error: expiredUpdate, count: updatedCount } = await clientA
    .from('mk_tasks')
    .update({ name: 'lejart-licenc-atiras' }, { count: 'exact' })
    .eq('id', companyA.taskId);
  if (!expiredUpdate && (updatedCount ?? 0) > 0) {
    leaks.push('licenc: lejárt előfizetéssel SIKERÜLT feladatot módosítani');
  }

  const { error: expiredDelete, count: deletedCount } = await clientA
    .from('mk_assignments')
    .delete({ count: 'exact' })
    .eq('id', companyA.assignmentId);
  if (!expiredDelete && (deletedCount ?? 0) > 0) {
    leaks.push('licenc: lejárt előfizetéssel SIKERÜLT beosztást törölni');
  }

  // A tablet útja is: az esemény-rögzítésnek hibát kell dobnia.
  const { error: expiredEvent } = await clientA.rpc('mk_terminal_event', {
    p_terminal: companyA.terminalId,
    p_pin: companyA.pin,
    p_type: 'start',
    p_task: companyA.taskId,
  });
  if (!expiredEvent) leaks.push('licenc: lejárt előfizetéssel a tablet MÉGIS tudott eseményt rögzíteni');

  // Visszaállítás, hogy a további próbák ne egy lejárt cégen fussanak.
  await admin.from('mk_companies').update({ license_expires_at: null }).eq('id', companyA.id);

  // 5) TÖBB FELHASZNÁLÓS CÉG – ez a 2026. szeptember 18-i éles hiba regressziós
  //    próbája. A kliens a bejelentkezés után lekéri a saját profilját; ha ezt
  //    NEM szűri user_id-re, az RLS a cég összes profilját visszaadja, és egy
  //    .single() a MÁSODIK felhasználótól kezdve elbukik. Élesben ez a
  //    licenc-mentést, a szerepkörös füleket és a rajzfeltöltést is megölte.
  const colleague = await createTestUser(admin, companyA.id, 'office');

  const { data: allProfiles } = await clientA.from('mk_profiles').select('user_id');
  if ((allProfiles?.length ?? 0) < 2) {
    leaks.push(
      `több felhasználós próba: a cégnek 2 profilja kellene legyen, de a bejelentkezett kliens ${allProfiles?.length ?? 0}-t lát ` +
        '(a próba maga romlott el, nem a termék)'
    );
  }

  const { data: ownProfile, error: ownProfileError } = await clientA
    .from('mk_profiles')
    .select('user_id,company_id,role')
    .eq('user_id', userA.id)
    .maybeSingle();
  if (ownProfileError) {
    leaks.push(`több felhasználós próba: a saját profil lekérése hibázott: ${ownProfileError.message}`);
  } else if (!ownProfile || ownProfile.user_id !== userA.id) {
    leaks.push('több felhasználós próba: a saját profil lekérése nem a bejelentkezett felhasználó sorát adta vissza');
  }

  const { data: ownCompany, error: ownCompanyError } = await clientA
    .from('mk_companies')
    .select('id,name,license_expires_at,active')
    .maybeSingle();
  if (ownCompanyError || !ownCompany || ownCompany.id !== companyA.id) {
    leaks.push(
      'több felhasználós próba: a saját cég lekérése nem egyetlen, helyes sort adott ' +
        `(${ownCompanyError ? ownCompanyError.message : JSON.stringify(ownCompany)})`
    );
  }

  // 6) A LICENC MENTÉSÉNEK ÚTJA. A felületen ez a rendszergazda-végponton megy,
  //    az pedig service role-lal ír – itt ezt a DB-műveletet próbáljuk ki, és azt
  //    is, hogy az érték tényleg megmarad. A termék egyik legfontosabb funkciója:
  //    ha a licenc nem állítható, nem lehet ügyfelet kezelni.
  const ujLejarat = new Date(Date.now() + 30 * 86400000).toISOString();
  const { error: adminLicError } = await admin
    .from('mk_companies')
    .update({ license_expires_at: ujLejarat, active: true })
    .eq('id', companyA.id);
  if (adminLicError) {
    leaks.push(`licenc-mentés: a rendszergazda útján (service role) NEM sikerült írni: ${adminLicError.message}`);
  } else {
    const { data: after } = await admin
      .from('mk_companies')
      .select('license_expires_at')
      .eq('id', companyA.id)
      .maybeSingle();
    if (!after || !after.license_expires_at) {
      leaks.push('licenc-mentés: a rendszergazda útján lefutott az írás, de az érték nem maradt meg');
    }
  }

  // A kolléga takarítása, hogy a próba ne hagyjon maga után plusz fiókot.
  await admin.auth.admin.deleteUser(colleague.id).catch(() => null);
  await admin.from('mk_companies').update({ license_expires_at: null }).eq('id', companyA.id);
}

async function runCrossTenantProbe() {
  const API_URL = process.env.API_URL;
  const ANON_KEY = process.env.ANON_KEY;
  const SERVICE_ROLE_KEY = process.env.SERVICE_ROLE_KEY;
  if (!API_URL || !ANON_KEY || !SERVICE_ROLE_KEY) {
    fail(
      'Hiányzó API_URL / ANON_KEY / SERVICE_ROLE_KEY környezeti változó a tényleges\n' +
        'kereszt-bérlős próbához. A workflow ezeket a `supabase status -o env`\n' +
        'kimenetéből tölti be – ellenőrizd, hogy az a lépés lefutott-e előtte.'
    );
  }

  const { createClient } = await import('@supabase/supabase-js');
  const admin = createClient(API_URL, SERVICE_ROLE_KEY);

  const companyA = await createTestFixture(admin, 'Kereszt-teszt A cég', '1357');
  const companyB = await createTestFixture(admin, 'Kereszt-teszt B cég', '2468');
  const userA = await createTestUser(admin, companyA.id, 'owner');
  const userB = await createTestUser(admin, companyB.id, 'owner');

  const clientA = createClient(API_URL, ANON_KEY);
  const { error: signInError } = await clientA.auth.signInWithPassword({
    email: userA.email,
    password: userA.password,
  });
  if (signInError) {
    fail('Nem sikerült bejelentkezni az A cég próba-felhasználójával: ' + signInError.message);
  }

  const leaks = [];

  for (const t of TENANT_TABLES) {
    const col = t.companyColumn ?? 'company_id';
    const { data, error } = await clientA.from(t.table).select('*').eq(col, companyB.id);
    if (!error && (data?.length ?? 0) > 0) {
      leaks.push(`${t.table}: SELECT B cég ${col}-jára ${data.length} sort adott vissza (0-nak kellene lennie)`);
    }
  }

  for (const r of TENANT_RPCS) {
    const base = r.baseArgs ? r.baseArgs(companyA) : {};
    const args = { ...base, [r.crossTenantArg]: r.otherTenantValue(companyB) };
    const { data, error } = await clientA.rpc(r.name, args);
    const expect = r.expect ?? 'error';

    if (expect === 'error') {
      if (!error) leaks.push(`${r.name}: nem adott hibát B cég adatával hívva (pedig el kellett volna utasítania)`);
    } else if (expect === 'null') {
      const empty = data == null || (Array.isArray(data) && data.length === 0);
      if (!error && !empty) leaks.push(`${r.name}: hiba nélkül, NEM üres/null adatot adott vissza (${JSON.stringify(data)})`);
      if (error) leaks.push(`${r.name}: hibával tért vissza, pedig csendes null választ vártunk (${error.message})`);
    } else if (typeof expect === 'function') {
      if (error) leaks.push(`${r.name}: váratlan hiba a tartalom-ellenőrzésnél (${error.message})`);
      else if (!expect(data, companyA, companyB)) leaks.push(`${r.name}: a válasz tartalma nem felel meg az elvárt cég-elhatárolásnak (${JSON.stringify(data)})`);
    }
  }

  // ---------------------------------------------------------------------
  // Célzott jogosultsági próbák (CLAUDE.md "Cégazonosítás az adatmodellben"
  // → "Ki írhatja az mk_profiles és mk_companies táblákat" + "Licenc").
  // Ezek nem "másik cég adatára" irányulnak, hanem arra a három dologra,
  // amit a terv a legkritikusabbnak nevez: a saját cég/szerepkör átírása és
  // a licenc-mezőhöz nyúlás. Ezért kapnak külön próbát, nem a fenti ciklusban.
  // ---------------------------------------------------------------------
  await runPrivilegeProbes(admin, clientA, companyA, companyB, userA, leaks);

  // ---------------------------------------------------------------------
  // E-MAILES BEJELENTKEZÉS (005). A belépés azonosítója maga az e-mail cím,
  // és éppen ez zárja ki, hogy valaki rossz céghez kerüljön: az
  // auth.users.email globálisan egyedi. Amit itt bizonyítunk:
  //   • A cég e-mailes session-je B cég egyetlen adatához sem fér hozzá
  //     (a fenti tábla-ciklus a company_id-ra szűr, ez a felhasználó
  //     azonosítója, vagyis az e-mail felől közelít ugyanahhoz);
  //   • B felhasználójának e-mail címe A számára nem látszik.
  // ---------------------------------------------------------------------
  const { data: bProfiles } = await clientA.from('mk_profiles').select('user_id,email').eq('user_id', userB.id);
  if ((bProfiles?.length ?? 0) > 0) {
    leaks.push('mk_profiles: A cég bejelentkezett felhasználója LÁTJA B cég felhasználójának profilját/e-mail címét');
  }
  const { data: visibleEmails } = await clientA.from('mk_profiles').select('email');
  if ((visibleEmails ?? []).some((r) => r.email === userB.email)) {
    leaks.push(`mk_profiles: B cég bejelentkezési címe (${userB.email}) látszik A cég felhasználójának`);
  }
  const { data: visibleCompanies } = await clientA.from('mk_companies').select('id');
  if ((visibleCompanies ?? []).some((c) => c.id === companyB.id)) {
    leaks.push('mk_companies: A cég bejelentkezett felhasználója LÁTJA B cég sorát');
  }

  // Ugyanaz a jelszó, de B felhasználójának címével: A cég adataihoz ezzel sem
  // szabad hozzáférni – a session a CÍMHEZ tartozó céget kapja, nem ahhoz, amit
  // a kliens hisz róla.
  const clientB = createClient(API_URL, ANON_KEY);
  const { error: signInBError } = await clientB.auth.signInWithPassword({
    email: userB.email,
    password: userB.password,
  });
  if (signInBError) {
    leaks.push('B cég felhasználója nem tudott bejelentkezni a saját e-mail címével: ' + signInBError.message);
  } else {
    const { data: aRowsForB } = await clientB.from('mk_employees').select('id').eq('company_id', companyA.id);
    if ((aRowsForB?.length ?? 0) > 0) {
      leaks.push('mk_employees: B cég e-mailes session-je LÁTJA A cég dolgozóit');
    }
    const { data: bCompany } = await clientB.from('mk_companies').select('id').maybeSingle();
    if (!bCompany || bCompany.id !== companyB.id) {
      leaks.push('mk_companies: B cég e-mailes session-je nem a saját cégét kapta vissza (' + JSON.stringify(bCompany) + ')');
    }
  }

  // ---------------------------------------------------------------------
  // PROFIL NÉLKÜLI RENDSZERGAZDA (2026. szeptember 24.). Egy tiszta platform
  // adminnak szándékosan nincs mk_profiles sora. Élesben egy ilyen fióknál
  // eltűnt a Cégek fül; a kliens oldali ok a hibák egybefogása volt (lásd
  // CLAUDE.md), itt az adatbázis-oldali feltételeket rögzítjük: a
  // rendszergazda-jelzés IGAZ, a saját profil lekérdezése hiba nélkül üres,
  // cégadatot pedig nem lát (sem A, sem B cégét).
  {
    const email = `crosstenant-admin-${Date.now()}@example.invalid`;
    const password = `Test-${Math.random().toString(36).slice(2)}-Aa1!`;
    const { data: created, error: createErr } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
    if (createErr) fail('Nem sikerült próba-rendszergazdát létrehozni: ' + createErr.message);
    const adminId = created.user.id;
    const { error: paErr } = await admin.from('mk_platform_admins').insert({ user_id: adminId });
    if (paErr) fail('Nem sikerült a próba-rendszergazdát felvenni: ' + paErr.message);

    const clientAdmin = createClient(API_URL, ANON_KEY);
    const { error: siErr } = await clientAdmin.auth.signInWithPassword({ email, password });
    if (siErr) fail('A próba-rendszergazda nem tudott bejelentkezni: ' + siErr.message);

    const { data: isAdmin, error: isAdminErr } = await clientAdmin.rpc('mk_is_platform_admin');
    if (isAdminErr || isAdmin !== true) {
      leaks.push(`profil nélküli rendszergazda: mk_is_platform_admin() nem igazat adott (${isAdminErr ? isAdminErr.message : isAdmin})`);
    }
    const { data: ownProfile, error: ownErr } = await clientAdmin
      .from('mk_profiles').select('user_id,company_id,role,username,email,contact_email').eq('user_id', adminId).maybeSingle();
    if (ownErr) leaks.push('profil nélküli rendszergazda: a saját profil lekérdezése hibát adott: ' + ownErr.message);
    else if (ownProfile) leaks.push('profil nélküli rendszergazda: váratlanul van profilja');
    const { error: waErr } = await clientAdmin.rpc('mk_write_allowed');
    if (waErr) leaks.push('profil nélküli rendszergazda: mk_write_allowed() hibát adott: ' + waErr.message);
    for (const c of [companyA, companyB]) {
      const { data: rows } = await clientAdmin.from('mk_employees').select('id').eq('company_id', c.id);
      if ((rows?.length ?? 0) > 0) leaks.push(`profil nélküli rendszergazda: LÁTJA a(z) ${c.name} dolgozóit`);
    }
    await admin.auth.admin.deleteUser(adminId).catch(() => null);
  }

  // Séma-nyilvántartás (006): a bejelentkező képernyő bejelentkezés NÉLKÜL
  // kérdezi le – anon kulccsal hívhatónak kell lennie, és csak sorszámokat
  // adhat; magát a táblát anon közvetlenül nem olvashatja.
  {
    const anonClient = createClient(API_URL, ANON_KEY);
    const { data: state, error: stateErr } = await anonClient.rpc('mk_schema_state');
    if (stateErr || !Array.isArray(state) || state.length === 0) {
      fail('Az mk_schema_state() bejelentkezés nélkül nem hívható, vagy üres listát ad: ' + (stateErr ? stateErr.message : JSON.stringify(state)));
    }
    const { data: rawRows } = await anonClient.from('mk_schema_versions').select('version');
    if ((rawRows?.length ?? 0) > 0) leaks.push('anon közvetlenül olvassa az mk_schema_versions táblát');
  }

  if (leaks.length) {
    fail('KERESZT-BÉRLŐS SZIVÁRGÁS ÉSZLELVE:\n - ' + leaks.join('\n - '));
  }

  pass(
    `${TENANT_TABLES.length} tábla és ${TENANT_RPCS.length} RPC mindegyike helyesen ` +
      'elutasította (vagy a tervezettnek megfelelően korlátozta) a másik cég adatára ' +
      'irányuló hozzáférést, és a manifest lefedi az adatbázisban talált összes ' +
      'company_id-s táblát/RPC-t.'
  );
}
