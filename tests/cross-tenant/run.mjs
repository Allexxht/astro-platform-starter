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

const discoveredRpcs = psqlRows(
  `select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace ` +
    `where n.nspname='public' and p.prosecdef and p.prosrc ilike '%company_id%' ` +
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
    .insert({ user_id: userData.user.id, company_id: companyId, role });
  if (profileError) fail(`Nem sikerült próba-profilt létrehozni (${email}): ${profileError.message}`);

  return { email, password, id: userData.user.id };
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

  const companyA = await createTestCompany(admin, 'Kereszt-teszt A cég');
  const companyB = await createTestCompany(admin, 'Kereszt-teszt B cég');
  const userA = await createTestUser(admin, companyA.id, 'owner');
  await createTestUser(admin, companyB.id, 'owner');

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
    const args = { ...r.baseArgs, [r.crossTenantArg]: r.otherTenantValue(companyB) };
    const { error } = await clientA.rpc(r.name, args);
    if (!error) {
      leaks.push(`${r.name}: B cég azonosítójával hívva NEM adott hibát (pedig el kellett volna utasítania)`);
    }
  }

  if (leaks.length) {
    fail('KERESZT-BÉRLŐS SZIVÁRGÁS ÉSZLELVE:\n - ' + leaks.join('\n - '));
  }

  pass(
    `${TENANT_TABLES.length} tábla és ${TENANT_RPCS.length} RPC mindegyike helyesen ` +
      'elutasította a másik cég adatára irányuló hozzáférést, és a manifest lefedi ' +
      'az adatbázisban talált összes company_id-s táblát/RPC-t.'
  );
}
