// Munkakövetés – a tablet (anon) ezen keresztül kér rövid lejáratú linket egy csatolt rajzhoz.
//
// A rajzok privát Supabase Storage bucketben vannak (mk-rajzok), a tabletnek nincs bejelentkezése,
// ezért nem tud közvetlenül signed URL-t kérni a Storage-tól. Ehelyett:
//   1) a public Supabase anon kulccsal meghívjuk az mk_terminal_attachment_path RPC-t, ami a
//      tablet-azonosítót és a PIN-t ugyanúgy ellenőrzi, mint a többi mk_terminal_* függvény, és
//      csak akkor ad vissza tárolási útvonalat, ha a rajz az adott dolgozó mai beosztásához tartozik;
//   2) az így kapott útvonalra a Supabase SERVICE ROLE kulcsával (csak itt, szerver oldalon) kérünk
//      10 perces signed URL-t.
//
// A service role kulcs kizárólag a Netlify környezeti változóban (MK_SUPABASE_SERVICE_ROLE_KEY) él,
// a kódba és a repóba nem kerül be.
import type { APIRoute } from 'astro';

export const prerender = false;

const SUPABASE_URL = 'https://nuufcwpbjfimykumufgi.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_PkHro-X1yYxPxCO_FzDo-g__OIojxJ8';
const BUCKET = 'mk-rajzok';
const SIGNED_URL_TTL_SECONDS = 600;

function json(data: unknown, status = 200): Response {
    return new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json' } });
}

export const POST: APIRoute = async ({ request }) => {
    let body: any;
    try {
        body = await request.json();
    } catch {
        return json({ error: 'Hibás kérés.' }, 400);
    }

    const terminal = typeof body?.terminal === 'string' ? body.terminal : '';
    const pin = typeof body?.pin === 'string' ? body.pin : '';
    const attachment = typeof body?.attachment === 'string' ? body.attachment : '';
    if (!terminal || !pin || !attachment) {
        return json({ error: 'Hiányzó adatok.' }, 400);
    }

    const serviceKey = process.env.MK_SUPABASE_SERVICE_ROLE_KEY;
    if (!serviceKey) {
        return json({ error: 'A szerver nincs beállítva (hiányzik a Supabase service role kulcs).' }, 500);
    }

    try {
        const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/mk_terminal_attachment_path`, {
            method: 'POST',
            headers: {
                'content-type': 'application/json',
                apikey: SUPABASE_ANON_KEY,
                authorization: `Bearer ${SUPABASE_ANON_KEY}`
            },
            body: JSON.stringify({ p_terminal: terminal, p_pin: pin, p_attachment: attachment })
        });
        if (!rpcRes.ok) {
            const errBody: any = await rpcRes.json().catch(() => null);
            return json({ error: (errBody && errBody.message) || 'A rajz nem érhető el.' }, 403);
        }
        const path = await rpcRes.json();
        if (!path || typeof path !== 'string') {
            return json({ error: 'A rajz nem érhető el.' }, 403);
        }

        const encodedPath = path.split('/').map(encodeURIComponent).join('/');
        const signRes = await fetch(`${SUPABASE_URL}/storage/v1/object/sign/${BUCKET}/${encodedPath}`, {
            method: 'POST',
            headers: {
                'content-type': 'application/json',
                apikey: serviceKey,
                authorization: `Bearer ${serviceKey}`
            },
            body: JSON.stringify({ expiresIn: SIGNED_URL_TTL_SECONDS })
        });
        if (!signRes.ok) {
            return json({ error: 'Nem sikerült létrehozni a linket.' }, 500);
        }
        const signed: any = await signRes.json().catch(() => null);
        if (!signed?.signedURL) {
            return json({ error: 'Nem sikerült létrehozni a linket.' }, 500);
        }
        return json({ url: `${SUPABASE_URL}/storage/v1${signed.signedURL}` });
    } catch {
        return json({ error: 'Nem sikerült elérni a szervert.' }, 502);
    }
};
