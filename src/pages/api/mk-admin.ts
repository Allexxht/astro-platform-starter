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
import { authCreateError, deleteCompany, listCompanies, type Io } from '../../lib/mk-admin-core';

export const prerender = false;

// A service role kulccsal hívott REST/Auth/Storage – a cégkezelés logikája
// (mk-admin-core.ts) ezen keresztül éri el a Supabase-t.
const serviceIo = (key: string): Io => ({
    rest: (path, init) => adminRest(key, path, init),
    auth: (path, init) => adminAuth(key, path, init),
    storage: (path, init) => adminStorage(key, path, init)
});

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
        if (action === 'list_companies') {
            const r = await listCompanies(serviceIo(key));
            return json(r.body, r.status);
        }
        if (action === 'create_company') return await createCompany(key, body);
        if (action === 'update_license') return await updateLicense(key, body);
        if (action === 'delete_company') {
            const r = await deleteCompany(serviceIo(key), {
                companyId: typeof body?.company_id === 'string' ? body.company_id : '',
                confirmName: typeof body?.confirm_name === 'string' ? body.confirm_name.trim() : '',
                callerId: caller.userId
            });
            return json(r.body, r.status);
        }
        return json({ error: 'Ismeretlen művelet.' }, 400);
    } catch (e: any) {
        return json({ error: e?.message || 'Nem sikerült végrehajtani a műveletet.' }, 500);
    }
};

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
        const err = authCreateError(createRes.status, await createRes.json().catch(() => null));
        return json({ error: `Az első felhasználónál: ${err.error}` }, err.status);
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
