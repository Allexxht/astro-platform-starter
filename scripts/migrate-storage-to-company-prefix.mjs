#!/usr/bin/env node
// Munkakövetés – a mk-rajzok Storage bucket meglévő fájljainak áthelyezése a
// <company_id>/ prefix alá, a db/migrations/003_multitenant.sql-lel együtt.
//
// A DB-migráció önmagában NEM mozgatja a Storage-ban lévő fájlokat (az nem
// SQL-lel, hanem a Storage API move() hívásával megy) – emiatt a storage
// bucket policy a migráció után a <company_id>/ prefixet várja, de a régi
// (uuid/fájlnév alakú) fájlok addig NEM érhetők el közvetlenül az irodából,
// amíg ez a script le nem fut.
//
// FUTTATÁS SORRENDJE: 1) db/migrations/003_multitenant.sql, 2) EZ A SCRIPT,
// ugyanazon a Supabase projekten (staging, majd külön menetben éles).
//
// Mit csinál:
//   1. Lekéri az mk_attachments minden sorát (id, storage_path, company_id).
//   2. Amelyiknek a storage_path-ja MÉG NEM "<company_id>/..." alakú, azt a
//      Storage API move() hívásával áthelyezi oda, majd frissíti az
//      mk_attachments.storage_path oszlopot ugyanarra az útvonalra.
//   3. Idempotens: egy már átköltöztetett sort (storage_path már a saját
//      company_id-jével kezdődik) kihagy – nyugodtan újra lefuttatható.
//
// Használat:
//   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/migrate-storage-to-company-prefix.mjs [--dry-run]
//
// --dry-run: csak kiírja, mit tenne, ténylegesen semmit nem mozgat/módosít.

import { createClient } from '@supabase/supabase-js';

const DRY_RUN = process.argv.includes('--dry-run');
const BUCKET = 'mk-rajzok';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
  console.error(
    'Hiányzó SUPABASE_URL vagy SUPABASE_SERVICE_ROLE_KEY környezeti változó.\n' +
      'Használat:\n' +
      '  SUPABASE_URL=https://xxxx.supabase.co SUPABASE_SERVICE_ROLE_KEY=... \\\n' +
      '    node scripts/migrate-storage-to-company-prefix.mjs [--dry-run]\n\n' +
      'A SUPABASE_SERVICE_ROLE_KEY a Supabase Dashboard → Project Settings → API\n' +
      'oldalon található ("service_role" kulcs). Csak ideiglenesen, a terminálban\n' +
      'add meg – ne írd fájlba, ne commitold.'
  );
  process.exit(1);
}

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

async function main() {
  const { data: attachments, error } = await admin
    .from('mk_attachments')
    .select('id, storage_path, company_id');
  if (error) {
    console.error('Nem sikerült lekérni az mk_attachments sorait: ' + error.message);
    process.exit(1);
  }

  console.log(`${attachments.length} csatolmány sor találva.`);
  if (DRY_RUN) console.log('(--dry-run: semmi nem fog ténylegesen módosulni)\n');

  let moved = 0;
  let skipped = 0;
  let failed = 0;

  for (const att of attachments) {
    if (!att.company_id) {
      console.error(`KIHAGYVA (nincs company_id, futtasd előbb a DB-migrációt): ${att.id} / ${att.storage_path}`);
      failed++;
      continue;
    }

    const prefix = `${att.company_id}/`;
    if (att.storage_path.startsWith(prefix)) {
      skipped++;
      continue;
    }

    const newPath = `${prefix}${att.storage_path}`;
    console.log(`${DRY_RUN ? '[dry-run] ' : ''}${att.storage_path}  ->  ${newPath}`);

    if (DRY_RUN) {
      moved++;
      continue;
    }

    const { error: moveError } = await admin.storage.from(BUCKET).move(att.storage_path, newPath);
    if (moveError) {
      console.error(`  HIBA a Storage move()-nál (${att.id}): ${moveError.message}`);
      failed++;
      continue;
    }

    const { error: updateError } = await admin
      .from('mk_attachments')
      .update({ storage_path: newPath })
      .eq('id', att.id);
    if (updateError) {
      console.error(
        `  HIBA: a Storage-ban átmozgatva, de az mk_attachments.storage_path frissítése ` +
          `elbukott (${att.id}): ${updateError.message}. A fájl most a Storage-ban ${newPath}-n ` +
          `van, de az adatbázis még a régi útvonalat tudja – ezt kézzel kell javítani.`
      );
      failed++;
      continue;
    }

    moved++;
  }

  console.log(`\nKész. Áthelyezve: ${moved}, már rendben volt: ${skipped}, hiba: ${failed}.`);
  if (failed > 0) {
    console.error('Voltak hibák – nézd át a fenti sorokat, mielőtt továbblépnél.');
    process.exit(1);
  }
}

main();
