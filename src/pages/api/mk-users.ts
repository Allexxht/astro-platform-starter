// Munkakövetés – a cég saját felhasználóinak felvétele és törlése (owner jogkör).
//
// Miért kell ehhez szerver: egy bejelentkezési fiók létrehozása és törlése az
// auth.users táblát érinti, amihez KIZÁRÓLAG a service role kulcs elég – a
// kliensből ez elvi okból sem lehetséges (lásd CLAUDE.md, mk_profiles INSERT:
// „kliensoldalról soha").
//
// A szerepkör átállítása és a kollégák listázása szándékosan NEM itt van: azt a
// kliens közvetlenül, RLS mögött végzi (mk_profiles select/update policy), mert
// ott nincs szükség service role-ra. Itt csak az van, amihez tényleg kell.
//
// Minden művelet előtt két kapu:
//   1) ki a hívó (a saját Bearer tokenjéből, nem a kérés törzséből!),
//   2) owner-e a SAJÁT cégében – és a célpont is ugyanabban a cégben van-e.
import type { APIRoute } from 'astro';
import {
    adminAuth,
    adminRest,
    adminRestJson,
    badPassword,
    identifyCaller,
    json,
    loadProfile,
    serviceKey,
    usernameToEmail
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

    let me;
    try {
        me = await loadProfile(key, caller.userId);
    } catch {
        return json({ error: 'Nem sikerült elérni a szervert.' }, 502);
    }
    if (!me) return json({ error: 'Nincs cégprofil ehhez a fiókhoz.' }, 403);
    if (me.role !== 'owner') return json({ error: 'Ehhez tulajdonosi jogosultság kell.' }, 403);

    const action = typeof body?.action === 'string' ? body.action : '';

    try {
        if (action === 'create') return await createUser(key, me.company_id, body);
        if (action === 'delete') return await deleteUser(key, me.company_id, caller.userId, body);
        return json({ error: 'Ismeretlen művelet.' }, 400);
    } catch (e: any) {
        return json({ error: e?.message || 'Nem sikerült végrehajtani a műveletet.' }, 500);
    }
};

async function createUser(key: string, companyId: string, body: any): Promise<Response> {
    const username = typeof body?.username === 'string' ? body.username.trim() : '';
    const password = body?.password;
    const role = body?.role === 'owner' ? 'owner' : 'office';
    const contactEmail = typeof body?.contact_email === 'string' ? body.contact_email.trim() : '';

    if (!username) return json({ error: 'A felhasználónév kötelező.' }, 400);
    const pwErr = badPassword(password);
    if (pwErr) return json({ error: pwErr }, 400);

    const companies = await adminRestJson<any[]>(
        key,
        `mk_companies?id=eq.${encodeURIComponent(companyId)}&select=login_domain`
    );
    const domain = (companies && companies[0] && companies[0].login_domain) || 'bremat.local';
    const email = usernameToEmail(username, domain);

    const createRes = await adminAuth(key, 'admin/users', {
        method: 'POST',
        body: JSON.stringify({ email, password, email_confirm: true })
    });
    if (!createRes.ok) {
        const err: any = await createRes.json().catch(() => null);
        const msg = (err && (err.msg || err.message)) || '';
        if (/already/i.test(msg) || createRes.status === 422) {
            return json({ error: 'Ez a felhasználónév már foglalt.' }, 409);
        }
        return json({ error: 'Nem sikerült létrehozni a fiókot.' }, 500);
    }
    const created: any = await createRes.json();

    // A profil beszúrása a fiók létrehozása UTÁN megy. Ha ez elbukik, a fiókot
    // azonnal töröljük: egy profil nélküli fiók be tudna lépni, de üres/hibás
    // képernyőt kapna (lásd db/verify-auth-profiles.sql) – ezt az állapotot
    // nem szabad itt előállítani.
    const profileRes = await adminRest(key, 'mk_profiles', {
        method: 'POST',
        headers: { prefer: 'return=representation' },
        body: JSON.stringify({
            user_id: created.id,
            company_id: companyId,
            role,
            username,
            contact_email: contactEmail || null
        })
    });
    if (!profileRes.ok) {
        await adminAuth(key, `admin/users/${created.id}`, { method: 'DELETE' }).catch(() => null);
        return json({ error: 'Nem sikerült létrehozni a profilt, a fiók visszavonva.' }, 500);
    }

    return json({ ok: true, user_id: created.id, email, username, role });
}

async function deleteUser(key: string, companyId: string, callerId: string, body: any): Promise<Response> {
    const userId = typeof body?.user_id === 'string' ? body.user_id : '';
    if (!userId) return json({ error: 'Hiányzó felhasználó.' }, 400);
    if (userId === callerId) return json({ error: 'Saját magadat nem törölheted.' }, 400);

    // A célpont a SAJÁT cégben legyen – e nélkül egy owner más cég
    // felhasználóját is törölhetné, mert a service role megkerüli az RLS-t.
    const target = await loadProfile(key, userId);
    if (!target || target.company_id !== companyId) {
        return json({ error: 'Nincs ilyen felhasználó ebben a cégben.' }, 404);
    }

    // Az auth.users törlése a mk_profiles sort is elviszi (on delete cascade),
    // így nem marad árva profil és árva fiók sem.
    const res = await adminAuth(key, `admin/users/${encodeURIComponent(userId)}`, { method: 'DELETE' });
    if (!res.ok) return json({ error: 'Nem sikerült törölni a fiókot.' }, 500);

    return json({ ok: true });
}
