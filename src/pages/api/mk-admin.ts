// AndonWork – rendszergazda (platform admin) végpont: cégek listája, új cég
// létrehozása az első felhasználójával, és a licenc állítása.
//
// Miért kell ehhez szerver:
//   • új auth.users fiók létrehozása csak service role kulccsal lehetséges;
//   • a mk_companies INSERT-re és a license_expires_at/active oszlopokra
//     szándékosan NINCS jogosultsága az authenticated szerepkörnek (oszlop-
//     szintű GRANT, lásd CLAUDE.md) – ezeket kizárólag service_role írhatja.
//
// A hívó platform admin voltát a saját Bearer tokenjéből ellenőrizzük, a
// mk_platform_admins táblából – NEM a kérés törzséből, és nem a céges
// szerepkörből (a kettő szándékosan külön tábla).
import type { APIRoute } from 'astro';
import {
    adminAuth,
    adminRest,
    adminRestJson,
    adminStorage,
    badEmail,
    badPassword,
    identifyCaller,
    isPlatformAdmin,
    json,
    normalizeEmail,
    serviceKey
} from '../../lib/mk-supabase';

export const prerender = false;

export const POST: APIRoute = async ({ request }) => {
    const key = serviceKey();
    if (!key) return json({ error: 'A szerver nincs beállítva (hiányzik a Supabase service role kulcs).' }, 500);

    let body: any;
    try {
        body = await request.json();
    } catch {
        return json({ error: 'Hibás kérés.' }, 400);
    }

    const caller = await identifyCaller(request);
    if (!caller) return json({ error: 'Nincs bejelentkezve.' }, 401);

    let admin = false;
    try {
        admin = await isPlatformAdmin(key, caller.userId);
    } catch {
        return json({ error: 'Nem sikerült elérni a szervert.' }, 502);
    }
    if (!admin) return json({ error: 'Ehhez rendszergazda jogosultság kell.' }, 403);

    const action = typeof body?.action === 'string' ? body.action : '';
    try {
        if (action === 'list_companies') return await listCompanies(key);
        if (action === 'create_company') return await createCompany(key, body);
        if (action === 'update_license') return await updateLicense(key, body);
        if (action === 'delete_company') return await deleteCompany(key, caller.userId, body);
        return json({ error: 'Ismeretlen művelet.' }, 400);
    } catch (e: any) {
        return json({ error: e?.message || 'Nem sikerült végrehajtani a műveletet.' }, 500);
    }
};

async function listCompanies(key: string): Promise<Response> {
    const companies = await adminRestJson<any[]>(
        key,
        'mk_companies?select=id,name,login_domain,license_expires_at,active,created_at&order=created_at'
    );
    const profiles = await adminRestJson<any[]>(key, 'mk_profiles?select=company_id,role,username,email');
    // Mennyi adata van a cégnek – ebből látszik, hogy egy cég tényleg
    // használja-e a rendszert, és mennyit vinne el egy törlés. Cégenként pár
    // kérés, a cégek száma kicsi.
    const enriched = await Promise.all(
        companies.map(async (c) => {
            const [employeeCount, eventCount, lastEvent] = await Promise.all([
                countRows(key, `mk_employees?company_id=eq.${c.id}&archived_at=is.null`),
                countRows(key, `mk_events?company_id=eq.${c.id}`),
                adminRestJson<any[]>(
                    key,
                    `mk_events?company_id=eq.${c.id}&select=event_time&order=event_time.desc&limit=1`
                )
            ]);
            return {
                ...c,
                users: profiles
                    .filter((p) => p.company_id === c.id)
                    .map((p) => ({ username: p.username, email: p.email, role: p.role })),
                employee_count: employeeCount,
                event_count: eventCount,
                last_event_at: lastEvent.length ? lastEvent[0].event_time : null
            };
        })
    );
    return json({ companies: enriched });
}

/** Sorok száma egy PostgREST szűrőre, a válasz Content-Range fejlécéből. */
async function countRows(key: string, path: string): Promise<number> {
    const res = await adminRest(key, `${path}&select=id`, {
        method: 'HEAD',
        headers: { prefer: 'count=exact' }
    });
    const range = res.headers.get('content-range') || '';
    const total = Number(range.split('/')[1]);
    return Number.isFinite(total) ? total : 0;
}

async function createCompany(key: string, body: any): Promise<Response> {
    const name = typeof body?.name === 'string' ? body.name.trim() : '';
    const licenseExpiresAt = body?.license_expires_at || null;
    // Az első felhasználó a saját, valódi e-mail címével jön létre – ez a
    // bejelentkezési azonosítója is (005). Bejelentkezési domain már nincs.
    const email = normalizeEmail(body?.email);
    const password = body?.password;
    const userName = typeof body?.user_name === 'string' ? body.user_name.trim() : '';
    const withSample = body?.sample_data === true;

    if (!name) return json({ error: 'A cégnév kötelező.' }, 400);
    const emailErr = badEmail(email);
    if (emailErr) return json({ error: `Az első felhasználónál: ${emailErr.toLowerCase()}` }, 400);
    const pwErr = badPassword(password);
    if (pwErr) return json({ error: pwErr }, 400);

    const username = userName || email.split('@')[0];

    const companies = await adminRestJson<any[]>(key, 'mk_companies', {
        method: 'POST',
        headers: { prefer: 'return=representation' },
        body: JSON.stringify({ name, license_expires_at: licenseExpiresAt, active: true })
    });
    const company = companies[0];

    const createRes = await adminAuth(key, 'admin/users', {
        method: 'POST',
        body: JSON.stringify({ email, password, email_confirm: true })
    });
    if (!createRes.ok) {
        // A cég sorát visszavonjuk: felhasználó nélkül senki nem tudna belépni,
        // és egy félkész cég csak zavart okozna a listában.
        await adminRest(key, `mk_companies?id=eq.${company.id}`, { method: 'DELETE' }).catch(() => null);
        const err: any = await createRes.json().catch(() => null);
        const msg = (err && (err.msg || err.message)) || '';
        if (/already/i.test(msg) || createRes.status === 422) {
            return json({ error: 'Ezzel az e-mail címmel már van fiók.' }, 409);
        }
        return json({ error: 'Nem sikerült létrehozni az első felhasználót.' }, 500);
    }
    const created: any = await createRes.json();

    const profileRes = await adminRest(key, 'mk_profiles', {
        method: 'POST',
        body: JSON.stringify({
            user_id: created.id,
            company_id: company.id,
            role: 'owner',
            username,
            email,
            contact_email: email
        })
    });
    if (!profileRes.ok) {
        await adminAuth(key, `admin/users/${created.id}`, { method: 'DELETE' }).catch(() => null);
        await adminRest(key, `mk_companies?id=eq.${company.id}`, { method: 'DELETE' }).catch(() => null);
        return json({ error: 'Nem sikerült létrehozni az első profilt, a cég visszavonva.' }, 500);
    }

    if (withSample) await seedSampleData(key, company.id);

    return json({ ok: true, company, first_user: { username, email } });
}

async function updateLicense(key: string, body: any): Promise<Response> {
    const companyId = typeof body?.company_id === 'string' ? body.company_id : '';
    if (!companyId) return json({ error: 'Hiányzó cég.' }, 400);

    const patch: Record<string, unknown> = {};
    if ('license_expires_at' in body) patch.license_expires_at = body.license_expires_at || null;
    if ('active' in body) patch.active = body.active === true;
    if (!Object.keys(patch).length) return json({ error: 'Nincs mit módosítani.' }, 400);

    const rows = await adminRestJson<any[]>(key, `mk_companies?id=eq.${encodeURIComponent(companyId)}`, {
        method: 'PATCH',
        headers: { prefer: 'return=representation' },
        body: JSON.stringify(patch)
    });
    if (!rows.length) return json({ error: 'Nincs ilyen cég.' }, 404);
    return json({ ok: true, company: rows[0] });
}

// A rajzok privát Storage bucketje. A fájlok NEM a Postgresben vannak, ezért
// egy cég törlésekor külön, a Storage API-n keresztül kell elvinni őket –
// SQL-lel nem lehet (lásd CLAUDE.md, "Migráció" 4. pont ugyanerről).
const BUCKET = 'mk-rajzok';

// A cég üzleti tábláinak törlési sorrendje (idegenkulcs-függés szerint).
// Ugyanaz a sorrend, mint a db/proba_ceg_torles.sql-ben.
const COMPANY_TABLES = [
    'mk_events',
    'mk_assignment_attachments',
    'mk_attachments',
    'mk_assignments',
    'mk_pins',
    'mk_pin_failures',
    'mk_employees',
    'mk_tasks',
    'mk_terminals',
    'mk_teams',
    'mk_locations'
];

/**
 * Egy cég és MINDEN adatának végleges törlése. Visszafordíthatatlan.
 *
 * Három védelem, mielőtt bármit törölnénk:
 *   1) a hívónak be kell gépelnie a cég pontos nevét (confirm_name),
 *   2) a saját cégét nem törölheti (nem lőheti ki maga alól a hozzáférést),
 *   3) a legelső (legrégebbi) céget nem törli – az a BREMAT, az első éles ügyfél.
 *      Ha valaha tényleg azt kell törölni, az tudatos, kézi művelet legyen
 *      (db/proba_ceg_torles.sql), ne egy elgépelt kattintás következménye.
 *
 * Ez egyben a GDPR szerinti végleges törlés alapja is (lásd CLAUDE.md
 * "Adatmegőrzés és törlés a szerződés végén").
 */
async function deleteCompany(key: string, callerId: string, body: any): Promise<Response> {
    const companyId = typeof body?.company_id === 'string' ? body.company_id : '';
    const confirmName = typeof body?.confirm_name === 'string' ? body.confirm_name.trim() : '';
    if (!companyId) return json({ error: 'Hiányzó cég.' }, 400);

    const rows = await adminRestJson<any[]>(
        key,
        `mk_companies?id=eq.${encodeURIComponent(companyId)}&select=id,name,created_at`
    );
    if (!rows.length) return json({ error: 'Nincs ilyen cég.' }, 404);
    const company = rows[0];

    if (confirmName !== company.name) {
        return json({ error: 'A megerősítéshez pontosan a cég nevét kell beírni.' }, 400);
    }

    const oldest = await adminRestJson<any[]>(key, 'mk_companies?select=id&order=created_at&limit=1');
    if (oldest.length && oldest[0].id === company.id) {
        return json(
            { error: 'A legelső cég (az éles ügyfél) törlése a felületről szándékosan nem lehetséges.' },
            403
        );
    }

    const profiles = await adminRestJson<any[]>(
        key,
        `mk_profiles?company_id=eq.${encodeURIComponent(companyId)}&select=user_id`
    );
    if (profiles.some((p) => p.user_id === callerId)) {
        return json({ error: 'A saját cégedet nem törölheted.' }, 400);
    }

    // 1) Storage: a <company_id>/ prefix alatti összes fájl.
    const files = await listStorageFiles(key, `${companyId}/`);
    if (files.length) {
        const res = await adminStorage(key, `object/${BUCKET}`, {
            method: 'DELETE',
            body: JSON.stringify({ prefixes: files })
        });
        if (!res.ok) {
            return json(
                { error: 'A feltöltött rajzokat nem sikerült törölni, ezért a cég adatait sem töröltem.' },
                502
            );
        }
    }

    // 2) Üzleti adat, idegenkulcs-sorrendben.
    for (const table of COMPANY_TABLES) {
        await adminRest(key, `${table}?company_id=eq.${encodeURIComponent(companyId)}`, { method: 'DELETE' });
    }

    // 3) Bejelentkezési fiókok. Az auth.users törlése az mk_profiles sort is
    //    elviszi (on delete cascade), így nem marad árva profil.
    for (const p of profiles) {
        await adminAuth(key, `admin/users/${encodeURIComponent(p.user_id)}`, { method: 'DELETE' }).catch(
            () => null
        );
    }
    await adminRest(key, `mk_profiles?company_id=eq.${encodeURIComponent(companyId)}`, { method: 'DELETE' });

    // 4) Maga a cég.
    await adminRest(key, `mk_companies?id=eq.${encodeURIComponent(companyId)}`, { method: 'DELETE' });

    return json({ ok: true, deleted: { company: company.name, users: profiles.length, files: files.length } });
}

/** A bucket összes fájlja egy prefix alatt, rekurzívan (a mappák maguk nem fájlok). */
async function listStorageFiles(key: string, prefix: string): Promise<string[]> {
    const res = await adminStorage(key, `object/list/${BUCKET}`, {
        method: 'POST',
        body: JSON.stringify({ prefix, limit: 1000, offset: 0, sortBy: { column: 'name', order: 'asc' } })
    });
    if (!res.ok) return [];
    const entries: any[] = await res.json().catch(() => []);

    const files: string[] = [];
    for (const entry of entries) {
        if (!entry || !entry.name) continue;
        // A Storage a mappákat is visszaadja, id nélkül – azokba lépni kell.
        if (entry.id) files.push(`${prefix}${entry.name}`);
        else files.push(...(await listStorageFiles(key, `${prefix}${entry.name}/`)));
    }
    return files;
}

// Opcionális minta-törzsadat egy új cégnek (egy tipikus hegesztőüzem mintája, az
// ügyfél átnevezheti). Ha a kapcsoló nincs bejelölve, a cég üresen indul.
async function seedSampleData(key: string, companyId: string): Promise<void> {
    const teams = ['Hegesztők', 'Lakatosok', 'Raktár', 'Iroda'].map((name, i) => ({
        name,
        sort: i + 1,
        company_id: companyId
    }));
    const locationNames = ['1-es csarnok', '2-es csarnok', 'Raktár', 'Iroda'];
    const locations = locationNames.map((name, i) => ({ name, sort: i + 1, company_id: companyId }));

    await adminRest(key, 'mk_teams', { method: 'POST', body: JSON.stringify(teams) });
    const createdLocations = await adminRestJson<any[]>(key, 'mk_locations', {
        method: 'POST',
        headers: { prefer: 'return=representation' },
        body: JSON.stringify(locations)
    });
    const locId = (name: string) => (createdLocations.find((l) => l.name === name) || {}).id || null;

    const tasks = [
        { name: 'Összeállítás, fűzés', loc: '1-es csarnok', color: '#5aa9ff', ask_quantity: true },
        { name: 'Hegesztés', loc: '2-es csarnok', color: '#ff8f3d', ask_quantity: false },
        { name: 'Csiszolás, utómunka', loc: '2-es csarnok', color: '#c9a27a', ask_quantity: true },
        { name: 'Anyagmozgatás', loc: 'Raktár', color: '#e58bd1', ask_quantity: false },
        { name: 'Irodai munka', loc: 'Iroda', color: '#c7cdd1', ask_quantity: false }
    ].map((t, i) => ({
        name: t.name,
        location_id: locId(t.loc),
        color: t.color,
        ask_quantity: t.ask_quantity,
        sort: i + 1,
        company_id: companyId
    }));
    await adminRest(key, 'mk_tasks', { method: 'POST', body: JSON.stringify(tasks) });

    const terminals = [
        { name: '1-es csarnok tablet', location_id: locId('1-es csarnok'), company_id: companyId },
        { name: '2-es csarnok tablet', location_id: locId('2-es csarnok'), company_id: companyId }
    ];
    await adminRest(key, 'mk_terminals', { method: 'POST', body: JSON.stringify(terminals) });
}
