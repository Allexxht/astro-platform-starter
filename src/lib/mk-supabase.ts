// AndonWork – közös szerveroldali segédek a service role-t használó végpontokhoz.
//
// Miért egy helyen: a CLAUDE.md „Mit kerüljünk el MOST" 2. és 3. pontja szerint a
// service role kulcs ne legyen több helyre szórva, és a Supabase URL se legyen
// hardkódolva szanaszét – ha egyszer cégenkénti projektre váltanánk, elég ezt az
// egy modult paraméterezhetővé tenni, az endpointokat nem kell átírni.
//
// A service role kulcs kizárólag Netlify környezeti változóban él
// (MK_SUPABASE_SERVICE_ROLE_KEY), a repóban soha.

export const SUPABASE_URL = process.env.MK_SUPABASE_URL || 'https://nuufcwpbjfimykumufgi.supabase.co';
export const SUPABASE_ANON_KEY =
    process.env.MK_SUPABASE_ANON_KEY || 'sb_publishable_PkHro-X1yYxPxCO_FzDo-g__OIojxJ8';

export function json(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json' } });
}

export function serviceKey(): string | null {
    return process.env.MK_SUPABASE_SERVICE_ROLE_KEY || null;
}

function adminHeaders(key: string): Record<string, string> {
    return {
        'content-type': 'application/json',
        apikey: key,
        authorization: `Bearer ${key}`
    };
}

/** REST hívás a service role kulccsal (megkerüli az RLS-t – csak ellenőrzött hívó után!). */
export async function adminRest(key: string, path: string, init: RequestInit = {}): Promise<Response> {
    return fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
        ...init,
        headers: { ...adminHeaders(key), ...(init.headers as Record<string, string> | undefined) }
    });
}

export async function adminRestJson<T = any>(key: string, path: string, init: RequestInit = {}): Promise<T> {
    const res = await adminRest(key, path, init);
    if (!res.ok) {
        const body = await res.text().catch(() => '');
        throw new Error(`Supabase hiba (${res.status}): ${body.slice(0, 300)}`);
    }
    if (res.status === 204) return undefined as T;
    return (await res.json()) as T;
}

/** Auth Admin API (felhasználó létrehozása/törlése) – szintén csak service role-lal. */
export async function adminAuth(key: string, path: string, init: RequestInit = {}): Promise<Response> {
    return fetch(`${SUPABASE_URL}/auth/v1/${path}`, {
        ...init,
        headers: { ...adminHeaders(key), ...(init.headers as Record<string, string> | undefined) }
    });
}

/** Storage API. A feltöltött rajzok NEM SQL-lel törölhetők (a fájlok nem a
 *  Postgresben vannak), ezért a cégtörlésnek ezen az úton kell mennie. */
export async function adminStorage(key: string, path: string, init: RequestInit = {}): Promise<Response> {
    return fetch(`${SUPABASE_URL}/storage/v1/${path}`, {
        ...init,
        headers: { ...adminHeaders(key), ...(init.headers as Record<string, string> | undefined) }
    });
}

export type Caller = { userId: string };

/**
 * A hívó azonosítása a saját Bearer tokenjéből. Ez az első kapu minden
 * végponton: amíg ez nem ad vissza felhasználót, semmilyen service role-os
 * műveletet nem szabad elindítani.
 */
export async function identifyCaller(request: Request): Promise<Caller | null> {
    const auth = request.headers.get('authorization') || '';
    const token = auth.toLowerCase().startsWith('bearer ') ? auth.slice(7).trim() : '';
    if (!token) return null;

    const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
        headers: { apikey: SUPABASE_ANON_KEY, authorization: `Bearer ${token}` }
    });
    if (!res.ok) return null;
    const user: any = await res.json().catch(() => null);
    return user && typeof user.id === 'string' ? { userId: user.id } : null;
}

export type Profile = { user_id: string; company_id: string; role: string };

export async function loadProfile(key: string, userId: string): Promise<Profile | null> {
    const rows = await adminRestJson<Profile[]>(
        key,
        `mk_profiles?user_id=eq.${encodeURIComponent(userId)}&select=user_id,company_id,role`
    );
    return rows && rows.length ? rows[0] : null;
}

export async function isPlatformAdmin(key: string, userId: string): Promise<boolean> {
    const rows = await adminRestJson<any[]>(
        key,
        `mk_platform_admins?user_id=eq.${encodeURIComponent(userId)}&select=user_id`
    );
    return Array.isArray(rows) && rows.length > 0;
}

/**
 * Bejelentkezési e-mail cím normalizálása. A 005 óta az e-mail MAGA a
 * bejelentkezési azonosító – nincs többé felhasználónév + kitalált domain,
 * mert az auth.users.email globálisan egyedi, tehát önmagában megmondja,
 * melyik céghez tartozik a belépő (lásd CLAUDE.md, e-mailes bejelentkezés).
 * Csak a felesleges szóközt vesszük le és kisbetűsítünk – a címet magát
 * NEM alakítjuk át, mert az a felhasználó valódi postafiókja.
 */
export function normalizeEmail(raw: unknown): string {
    return typeof raw === 'string' ? raw.trim().toLowerCase() : '';
}

/** Egyszerű alaki ellenőrzés; a tényleges kézbesíthetőséget a levélküldés dönti el. */
export function badEmail(raw: unknown): string | null {
    const email = normalizeEmail(raw);
    if (!email) return 'Az e-mail cím kötelező.';
    if (!/^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/.test(email)) return 'Ez nem érvényes e-mail cím.';
    return null;
}

export function badPassword(pw: unknown): string | null {
    if (typeof pw !== 'string' || pw.length < 12) {
        return 'A jelszó legyen legalább 12 karakter.';
    }
    if (!/[a-zA-ZÁÉÍÓÖŐÚÜŰáéíóöőúüű]/.test(pw) || !/[0-9]/.test(pw)) {
        return 'A jelszó tartalmazzon betűt és számot is.';
    }
    return null;
}
