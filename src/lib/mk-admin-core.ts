// AndonWork – a rendszergazda- és felhasználókezelő végpontok hálózatfüggetlen
// logikája: cégek listája, cégtörlés, a bejelentkezési rendszer (GoTrue)
// hibáinak értelmezése.
//
// Miért külön fájl: a hálózati hívásokat (REST, Auth, Storage) a hívó adja át
// (`Io`), ezért ugyanez a kód fut élesben (Netlify function, lásd mk-admin.ts),
// a CI-ban a helyi Supabase stack ellen (tests/cross-tenant/company-admin.mjs),
// és egységtesztben szándékosan elrontott válaszokkal (tests/unit/). Emiatt
// nincs benne import és környezeti változó, és csak olyan TypeScript van
// benne, amit a Node a típusok lehántásával közvetlenül futtatni tud.

export type Io = {
    rest(path: string, init?: RequestInit): Promise<Response>;
    auth(path: string, init?: RequestInit): Promise<Response>;
    storage(path: string, init?: RequestInit): Promise<Response>;
    /** Időforrás a törlés időkeretéhez – tesztben felülírható. */
    now?(): number;
};

export type Result = { status: number; body: any };

const enc = (v: string) => encodeURIComponent(v);

async function snippet(res: Response): Promise<string> {
    const text = await res.text().catch(() => '');
    return text ? `: ${text.slice(0, 200)}` : '';
}

async function rows(io: Io, path: string): Promise<any[]> {
    const res = await io.rest(path);
    if (!res.ok) throw new Error(`az adatbázis-lekérdezés nem sikerült (${res.status}${await snippet(res)})`);
    const data = await res.json();
    if (!Array.isArray(data)) throw new Error('az adatbázis értelmezhetetlen választ adott');
    return data;
}

// ---------------------------------------------------------------------------
// A bejelentkezési rendszer (GoTrue) hibái új fiók létrehozásakor
// ---------------------------------------------------------------------------

const WEAK_PASSWORD_REASONS: Record<string, string> = {
    length: 'túl rövid',
    characters: 'hiányzik belőle egy kötelező karaktertípus',
    pwned: 'szerepel az ismert, kiszivárgott jelszavak között'
};

/**
 * A GoTrue 422-es (és egyéb) hibájának lefordítása érthető üzenetre. Korábban
 * minden 422-t „foglalt e-mail cím”-nek írtunk ki, pedig a GoTrue ugyanezzel a
 * kóddal jelzi a gyenge jelszót is – a rendszergazda így rossz dolgot javított.
 * Új GoTrue: { error_code: 'email_exists', msg }, régebbi: { code, message }.
 */
export function authCreateError(status: number, body: any): { status: number; error: string } {
    const code = String(
        (typeof body?.error_code === 'string' && body.error_code) || (typeof body?.code === 'string' && body.code) || ''
    ).toLowerCase();
    const msg = String(body?.msg || body?.message || body?.error_description || '');

    if (code === 'email_exists' || code === 'user_already_exists' || /already (been )?(registered|exists)/i.test(msg)) {
        return { status: 409, error: 'Ezzel az e-mail címmel már van fiók.' };
    }
    if (code === 'weak_password' || (!code && status === 422 && /password/i.test(msg))) {
        const reasons: string[] = Array.isArray(body?.weak_password?.reasons) ? body.weak_password.reasons : [];
        const why = reasons.map((r) => WEAK_PASSWORD_REASONS[r] || r).join(', ');
        return {
            status: 400,
            error: `A bejelentkezési rendszer túl gyengének találta a jelszót${why ? ` (${why})` : ''}. Adj meg erősebbet.`
        };
    }
    if (code === 'email_address_invalid' || code === 'email_address_not_authorized' || code === 'validation_failed') {
        return { status: 400, error: `Ezt az e-mail címet a bejelentkezési rendszer nem fogadta el${msg ? ` (${msg})` : ''}.` };
    }
    return {
        status: 502,
        error: `Nem sikerült létrehozni a fiókot (a bejelentkezési rendszer válasza: ${status}${msg ? `, ${msg}` : ''}).`
    };
}

// ---------------------------------------------------------------------------
// Cégek listája – EGY lekérdezésben
// ---------------------------------------------------------------------------

/**
 * Korábban cégenként 3 külön kérés ment (dolgozószám, eseményszám, utolsó
 * esemény), vagyis a Cégek nézet a cégek számával arányosan lassult. A PostgREST
 * beágyazott count-ja és cégenkénti limitje ugyanezt egy kérésben adja vissza.
 */
export const COMPANY_LIST_QUERY =
    'mk_companies?select=' +
    [
        'id',
        'name',
        'license_expires_at',
        'active',
        'created_at',
        'users:mk_profiles(username,email,role)',
        'employees:mk_employees(count)',
        'events:mk_events(count)',
        'last_event:mk_events(event_time)'
    ].join(',') +
    '&employees.archived_at=is.null&last_event.order=event_time.desc&last_event.limit=1&order=created_at';

function countOf(x: any): number | null {
    const n = Array.isArray(x) && x[0] ? Number(x[0].count) : NaN;
    return Number.isFinite(n) ? n : null;
}

export function shapeCompany(r: any): any {
    return {
        id: r.id,
        name: r.name,
        license_expires_at: r.license_expires_at ?? null,
        active: r.active,
        created_at: r.created_at,
        users: (Array.isArray(r.users) ? r.users : []).map((p: any) => ({
            username: p.username,
            email: p.email,
            role: p.role
        })),
        // null = nem tudjuk (a kliens „ismeretlen”-t ír) – SOHA nem 0, mert a
        // cégtörlés megerősítése ezekből a számokból mondja meg, mi vész el.
        employee_count: countOf(r.employees),
        event_count: countOf(r.events),
        last_event_at: Array.isArray(r.last_event) && r.last_event[0] ? r.last_event[0].event_time : null
    };
}

export async function listCompanies(io: Io): Promise<Result> {
    const res = await io.rest(COMPANY_LIST_QUERY);
    if (res.ok) {
        const data = await res.json();
        return { status: 200, body: { companies: (Array.isArray(data) ? data : []).map(shapeCompany) } };
    }
    // Ha a statisztika nem jön le, a lista ettől még kell (licenc, törlés):
    // ilyenkor a számok ismeretlenek, és ezt ki is mondjuk.
    const companies = await rows(io, 'mk_companies?select=id,name,license_expires_at,active,created_at&order=created_at');
    const profiles = await rows(io, 'mk_profiles?select=company_id,username,email,role');
    return {
        status: 200,
        body: {
            companies: companies.map((c) =>
                shapeCompany({ ...c, users: profiles.filter((p) => p.company_id === c.id) })
            ),
            stats_error: 'A használati adatok (dolgozók, események) most nem kérdezhetők le.'
        }
    };
}

// ---------------------------------------------------------------------------
// Tárhely: a cég fájljainak listázása (lapozva, mappákba lépve)
// ---------------------------------------------------------------------------

export const BUCKET = 'mk-rajzok';
/** A Storage list API egy kérésben ennyit ad vissza – fölötte lapozni kell. */
export const LIST_PAGE = 1000;
/** Ennyi fájlt törlünk egy körben (a Storage egy kérésben legfeljebb 1000-et fogad). */
export const DELETE_BATCH = 500;
const LIST_CONCURRENCY = 16;

async function listLevel(io: Io, prefix: string, maxPages = Infinity): Promise<any[]> {
    const out: any[] = [];
    for (let page = 0, offset = 0; page < maxPages; page++, offset += LIST_PAGE) {
        const res = await io.storage(`object/list/${BUCKET}`, {
            method: 'POST',
            body: JSON.stringify({ prefix, limit: LIST_PAGE, offset, sortBy: { column: 'name', order: 'asc' } })
        });
        if (!res.ok) throw new Error(`a tárhely listázása nem sikerült (${res.status}${await snippet(res)})`);
        const items = await res.json().catch(() => null);
        if (!Array.isArray(items)) throw new Error('a tárhely listázása értelmezhetetlen választ adott');
        out.push(...items);
        if (items.length < LIST_PAGE) break;
    }
    return out;
}

async function mapLimit<T>(items: T[], limit: number, fn: (item: T) => Promise<void>): Promise<void> {
    let next = 0;
    const worker = async () => {
        while (next < items.length) await fn(items[next++]);
    };
    await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
}

/**
 * Egy prefix alatti fájlok teljes útvonala, legfeljebb `max` darab. A Storage a
 * mappákat is visszaadja (id nélkül) – azokba belépünk. Hiba esetén KIVÉTELT
 * dob: egy üres lista azt jelentené, hogy nincs fájl, és a törlés továbbmenne,
 * miközben a rajzok a tárhelyen maradnak (ez volt a korábbi hiba).
 */
export async function listFiles(io: Io, prefix: string, max = Infinity): Promise<string[]> {
    const files: string[] = [];
    const folders: string[] = [];
    for (const e of await listLevel(io, prefix)) {
        if (!e || !e.name) continue;
        if (e.id) files.push(prefix + e.name);
        else folders.push(`${prefix}${e.name}/`);
    }
    await mapLimit(folders, LIST_CONCURRENCY, async (folder) => {
        if (files.length >= max) return;
        files.push(...(await listFiles(io, folder, max - files.length)));
    });
    return files.slice(0, max);
}

// ---------------------------------------------------------------------------
// Cégtörlés
// ---------------------------------------------------------------------------

/** A cég üzleti táblái idegenkulcs-sorrendben (ugyanaz, mint a db/proba_ceg_torles.sql-ben). */
export const COMPANY_TABLES: [string, string][] = [
    ['mk_events', 'események'],
    ['mk_assignment_attachments', 'rajz–beosztás kapcsolatok'],
    ['mk_attachments', 'rajzok nyilvántartása'],
    ['mk_assignments', 'beosztások'],
    ['mk_pins', 'PIN-kódok'],
    ['mk_pin_failures', 'PIN-próbálkozások'],
    ['mk_employees', 'dolgozók'],
    ['mk_tasks', 'feladatok'],
    ['mk_terminals', 'tabletek'],
    ['mk_teams', 'csapatok'],
    ['mk_locations', 'helyszínek']
];

const STEP_LOCK = 'a cég zárolása';
const STEP_USERS = 'bejelentkezési fiókok';
const STEP_FILES = 'feltöltött rajzok';
const STEP_VERIFY = 'ellenőrzés';
const STEP_COMPANY = 'a cég sora';
export const DELETE_STEPS = [STEP_LOCK, STEP_USERS, STEP_FILES, ...COMPANY_TABLES.map(([, l]) => l), STEP_VERIFY, STEP_COMPANY];

/** Egy nem-lekérdezés (PATCH/DELETE) eredményének ellenőrzése. */
async function mustOk(res: Response, what: string): Promise<void> {
    if (!res.ok) throw new Error(`${what}: ${res.status}${await snippet(res)}`);
}

/** Sorok száma a Content-Range fejlécből; null, ha nem derül ki (NEM 0!). */
export async function countRows(io: Io, path: string): Promise<number | null> {
    const res = await io.rest(path, { method: 'HEAD', headers: { prefer: 'count=exact' } });
    if (!res.ok) return null;
    const total = Number((res.headers.get('content-range') || '').split('/')[1]);
    return Number.isFinite(total) ? total : null;
}

export type DeleteArgs = { companyId: string; confirmName: string; callerId: string; budgetMs?: number };

/**
 * Egy cég és MINDEN adatának végleges törlése. Visszafordíthatatlan.
 *
 * Előfeltételek (ezek után sem nyúlunk semmihez, ha bármelyik nem teljesül):
 * a cég nevét pontosan be kell gépelni; a saját cégét senki nem törölheti; a
 * legelső cég (az első éles ügyfél, a BREMAT) a felületről nem törölhető; és a
 * tárhelynek elérhetőnek kell lennie.
 *
 * A lépések sorrendje: a cég zárolása (felfüggesztés, hogy közben senki ne
 * írhasson) → bejelentkezési fiókok → feltöltött rajzok → üzleti táblák
 * idegenkulcs-sorrendben → ellenőrzés → a cég sora legvégül.
 *
 * Minden lépés eredményét ellenőrizzük. Ha egy elbukik, a törlés ott megáll,
 * és a válasz pontosan megmondja, mi készült el és mi van hátra. A cég sora
 * ilyenkor megmarad (felfüggesztve), a listában továbbra is látszik, és mert
 * minden lépés megismételhető, egy újabb Törlés onnan folytatja, ahol
 * abbamaradt. Korábban minden eredményt figyelmen kívül hagytunk, és a
 * felület akkor is „Cég törölve”-t írt, ha közben valami elbukott.
 *
 * Nagy cégnél a munka egy hívásban nem fér bele a function időkeretébe: ha az
 * idő (`budgetMs`) elfogy, a válasz 202 + `continue: true`, és a kliens
 * ugyanezzel a kéréssel folytatja.
 */
export async function deleteCompany(io: Io, args: DeleteArgs): Promise<Result> {
    const now = io.now ? () => io.now!() : () => Date.now();
    const started = now();
    const budget = args.budgetMs ?? 5000;
    const overBudget = () => now() - started > budget;
    const { companyId, confirmName, callerId } = args;
    if (!companyId) return { status: 400, body: { error: 'Hiányzó cég.' } };
    const id = enc(companyId);
    const prefix = `${companyId}/`;

    // --- Előfeltételek: csak olvasás ---
    const found = await rows(io, `mk_companies?id=eq.${id}&select=id,name,created_at,active`);
    if (!found.length) return { status: 404, body: { error: 'Nincs ilyen cég.' } };
    const company = found[0];
    if (confirmName !== company.name) {
        return { status: 400, body: { error: 'A megerősítéshez pontosan a cég nevét kell beírni.' } };
    }
    const oldest = await rows(io, 'mk_companies?select=id&order=created_at&limit=1');
    if (oldest.length && oldest[0].id === company.id) {
        return {
            status: 403,
            body: { error: 'A legelső cég (az éles ügyfél) törlése a felületről szándékosan nem lehetséges.' }
        };
    }
    const profiles = await rows(io, `mk_profiles?company_id=eq.${id}&select=user_id,email`);
    if (profiles.some((p) => p.user_id === callerId)) {
        return { status: 400, body: { error: 'A saját cégedet nem törölheted.' } };
    }
    try {
        await listLevel(io, prefix, 1);
    } catch (e: any) {
        return {
            status: 502,
            body: { error: `A tárhely most nem érhető el (${e.message}), ezért semmihez nem nyúltam. Próbáld újra később.` }
        };
    }

    // --- Törlés, lépésenként ellenőrizve ---
    const done: string[] = [];
    let usersRemoved = 0;
    let filesDeleted = 0;
    const failAt = (step: string, reason: string): Result => {
        const remaining = DELETE_STEPS.slice(DELETE_STEPS.indexOf(step));
        return {
            status: 502,
            body: {
                error:
                    `A törlés félbemaradt ennél a lépésnél: ${step} (${reason}).\n` +
                    `Elkészült: ${done.length ? done.join(', ') : 'semmi'}.\n` +
                    `Hátravan: ${remaining.join(', ')}.\n` +
                    'A cég felfüggesztve a listában marad. Nyomd meg újra a Törlést – onnan folytatja, ahol abbamaradt.',
                partial: { done, failed: step, remaining },
                retry: true
            }
        };
    };
    const keepGoing = (): Result => ({
        status: 202,
        body: { ok: false, continue: true, progress: { users: usersRemoved, files: filesDeleted, done } }
    });

    // 1) Zárolás: felfüggesztett cégnél a tablet és az iroda nem ír több adatot.
    try {
        const res = await io.rest(`mk_companies?id=eq.${id}`, {
            method: 'PATCH',
            headers: { prefer: 'return=representation' },
            body: JSON.stringify({ active: false })
        });
        await mustOk(res, 'a felfüggesztés nem sikerült');
        const locked = await res.json();
        if (!Array.isArray(locked) || locked.length !== 1) throw new Error('a cég sora nem módosult');
    } catch (e: any) {
        return failAt(STEP_LOCK, e.message);
    }
    done.push('a cég felfüggesztve');

    // 2) Bejelentkezési fiókok. A fiók törlése a profilt is viszi (on delete
    //    cascade). Profilt KÜLÖN nem törlünk: ha egy fiók törlése elbukik, a
    //    profilja maradjon meg – egy profil nélküli fiók be tudna lépni, de
    //    üres/hibás képernyőt kapna. Kivétel a rendszergazda: az ő fiókja nem
    //    ehhez a céghez tartozik, csak a céges profilját vesszük el.
    if (profiles.length) {
        let admins = new Set<string>();
        try {
            const list = await rows(
                io,
                `mk_platform_admins?user_id=in.(${profiles.map((p) => enc(p.user_id)).join(',')})&select=user_id`
            );
            admins = new Set(list.map((a) => a.user_id));
        } catch (e: any) {
            return failAt(STEP_USERS, e.message);
        }
        for (const p of profiles) {
            if (overBudget()) return keepGoing();
            const who = p.email || p.user_id;
            try {
                if (admins.has(p.user_id)) {
                    await mustOk(
                        await io.rest(`mk_profiles?user_id=eq.${enc(p.user_id)}`, { method: 'DELETE' }),
                        `${who} céges profilja nem törlődött`
                    );
                } else {
                    const res = await io.auth(`admin/users/${enc(p.user_id)}`, { method: 'DELETE' });
                    // 404: a fiók már nincs meg (egy korábbi, félbemaradt törlés vitte el).
                    if (!res.ok && res.status !== 404) await mustOk(res, `${who} fiókja nem törlődött`);
                }
            } catch (e: any) {
                return failAt(STEP_USERS, e.message);
            }
            usersRemoved++;
        }
        let left: any[];
        try {
            left = await rows(io, `mk_profiles?company_id=eq.${id}&select=user_id`);
        } catch (e: any) {
            return failAt(STEP_USERS, e.message);
        }
        if (left.length) return failAt(STEP_USERS, `${left.length} profil megmaradt`);
    }
    done.push(`${usersRemoved} bejelentkezési fiók`);

    // 3) Feltöltött rajzok: körönként legfeljebb DELETE_BATCH fájl, amíg a
    //    <company_id>/ prefix alatt van mit törölni. A kör végén újra listázunk –
    //    így a végén a tárhely ténylegesen üres, nem csak „elküldtük a törlést”.
    //    Csak a saját prefix alatt törlünk: az mk_attachments útvonalaiban nem
    //    bízunk, mert azt a kliens írja, és egy idegen útvonal másik cég rajzát
    //    vinné el.
    for (;;) {
        if (overBudget()) return keepGoing();
        let batch: string[];
        try {
            batch = await listFiles(io, prefix, DELETE_BATCH);
        } catch (e: any) {
            return failAt(STEP_FILES, e.message);
        }
        if (!batch.length) break;
        let deleted: any;
        try {
            const res = await io.storage(`object/${BUCKET}`, {
                method: 'DELETE',
                body: JSON.stringify({ prefixes: batch })
            });
            await mustOk(res, 'a tárhely nem törölte a fájlokat');
            deleted = await res.json().catch(() => null);
        } catch (e: any) {
            return failAt(STEP_FILES, e.message);
        }
        const n = Array.isArray(deleted) ? deleted.length : 0;
        if (!n) return failAt(STEP_FILES, `${batch.length} fájlt a tárhely nem törölt`);
        filesDeleted += n;
    }
    done.push(`${filesDeleted} feltöltött rajz`);

    // 4) Üzleti adat, idegenkulcs-sorrendben.
    for (const [table, label] of COMPANY_TABLES) {
        if (overBudget()) return keepGoing();
        try {
            await mustOk(await io.rest(`${table}?company_id=eq.${id}`, { method: 'DELETE' }), 'a törlés nem sikerült');
        } catch (e: any) {
            return failAt(label, e.message);
        }
        done.push(label);
    }

    // 5) Ellenőrzés: tényleg nem maradt semmi. Egy ki nem olvasható szám hiba,
    //    nem nulla.
    for (const [table, label] of [...COMPANY_TABLES, ['mk_profiles', 'profilok'] as [string, string]]) {
        const n = await countRows(io, `${table}?company_id=eq.${id}&select=company_id`);
        if (n === null) return failAt(STEP_VERIFY, `a(z) ${label} száma nem kérdezhető le`);
        if (n > 0) return failAt(STEP_VERIFY, `${n} sor maradt: ${label}`);
    }

    // 6) Legvégül a cég sora – ha ez megvan, a cég eltűnik a listából.
    try {
        const res = await io.rest(`mk_companies?id=eq.${id}`, {
            method: 'DELETE',
            headers: { prefer: 'return=representation' }
        });
        await mustOk(res, 'a törlés nem sikerült');
        const gone = await res.json();
        if (!Array.isArray(gone) || gone.length !== 1) throw new Error('a cég sora nem törlődött');
    } catch (e: any) {
        return failAt(STEP_COMPANY, e.message);
    }

    return { status: 200, body: { ok: true, deleted: { company: company.name, users: usersRemoved, files: filesDeleted } } };
}
