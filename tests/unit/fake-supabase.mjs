// Memóriabeli Supabase-utánzat a cégkezelő logika (src/lib/mk-admin-core.ts)
// egységtesztjeihez: REST (PostgREST), Auth Admin API és Storage – annyi, amennyit
// a kód használ, a valódi szolgáltatások viselkedése szerint (a Storage mappákat
// id nélkül ad vissza és oldalanként lapoz, egy törlés legfeljebb 1000 útvonalat
// fogad, a fiók törlése a profilt is viszi stb.). Bármelyik hívás szándékosan
// elrontható (`failWhen`), hogy a hibaágak is próbára kerüljenek.

export function createFake() {
  const db = {
    mk_companies: [],
    mk_profiles: [],
    mk_platform_admins: [],
    mk_events: [], mk_assignment_attachments: [], mk_attachments: [], mk_assignments: [], mk_pins: [],
    mk_pin_failures: [], mk_employees: [], mk_tasks: [], mk_terminals: [], mk_teams: [], mk_locations: [],
  };
  const users = new Map();            // auth.users: id -> { id, email }
  const objects = new Set();          // storage: teljes útvonalak a bucketben
  const calls = [];                   // minden hívás naplója
  const rules = [];                   // szándékos hibák
  let clock = 0;

  const json = (data, status = 200, headers = {}) =>
    new Response(status === 204 ? null : JSON.stringify(data), { status, headers: { 'content-type': 'application/json', ...headers } });

  function parse(path) {
    const [table, qs = ''] = path.split('?');
    const params = new URLSearchParams(qs);
    const filters = [];
    for (const [k, v] of params) {
      if (['select', 'order', 'limit', 'offset'].includes(k)) continue;
      if (v.startsWith('eq.')) filters.push(r => String(r[k]) === v.slice(3));
      else if (v.startsWith('in.(')) { const set = new Set(v.slice(4, -1).split(',')); filters.push(r => set.has(String(r[k]))); }
      else if (v === 'is.null') filters.push(r => r[k] == null);
    }
    return { table, params, match: r => filters.every(f => f(r)) };
  }

  function failing(kind, method, path) {
    for (const r of rules) {
      if (r.kind === kind && (!r.method || r.method === method) && r.path.test(path) && (r.times === undefined || r.times-- > 0)) {
        return json({ message: r.message || 'szándékos hiba' }, r.status || 500);
      }
    }
    return null;
  }

  async function rest(path, init = {}) {
    const method = (init.method || 'GET').toUpperCase();
    calls.push({ kind: 'rest', method, path });
    const f = failing('rest', method, path); if (f) return f;
    const { table, params, match } = parse(path);
    if (!(table in db)) return json({ message: `nincs ilyen tábla: ${table}` }, 404);
    const all = db[table];
    const hit = all.filter(match);
    const prefer = (init.headers && (init.headers.prefer || init.headers.Prefer)) || '';
    if (method === 'GET') {
      let out = [...hit];
      if (params.get('order') === 'created_at') out.sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
      if (params.get('limit')) out = out.slice(0, Number(params.get('limit')));
      return json(out);
    }
    if (method === 'HEAD') return new Response(null, { status: 200, headers: { 'content-range': `*/${hit.length}` } });
    if (method === 'PATCH') {
      const patch = JSON.parse(init.body || '{}');
      hit.forEach(r => Object.assign(r, patch));
      return /representation/.test(prefer) ? json(hit.map(r => ({ ...r }))) : json(null, 204);
    }
    if (method === 'DELETE') {
      if (table === 'mk_companies' && hit.some(c => db.mk_profiles.some(p => p.company_id === c.id))) {
        return json({ message: 'update or delete on table "mk_companies" violates foreign key constraint' }, 409);
      }
      db[table] = all.filter(r => !match(r));
      return /representation/.test(prefer) ? json(hit.map(r => ({ ...r }))) : json(null, 204);
    }
    return json({ message: 'nem támogatott' }, 405);
  }

  async function auth(path, init = {}) {
    const method = (init.method || 'GET').toUpperCase();
    calls.push({ kind: 'auth', method, path });
    const f = failing('auth', method, path); if (f) return f;
    const m = path.match(/^admin\/users\/([^/?]+)$/);
    if (method === 'DELETE' && m) {
      const id = decodeURIComponent(m[1]);
      if (!users.has(id)) return json({ code: 404, error_code: 'user_not_found', msg: 'User not found' }, 404);
      users.delete(id);
      db.mk_profiles = db.mk_profiles.filter(p => p.user_id !== id);           // on delete cascade
      db.mk_platform_admins = db.mk_platform_admins.filter(p => p.user_id !== id);
      return json({});
    }
    return json({ message: 'nem támogatott' }, 405);
  }

  async function storage(path, init = {}) {
    const method = (init.method || 'GET').toUpperCase();
    const body = init.body ? JSON.parse(init.body) : {};
    calls.push({ kind: 'storage', method, path, body });
    const f = failing('storage', method, path); if (f) return f;
    if (method === 'POST' && path === 'object/list/mk-rajzok') {
      let prefix = body.prefix || '';
      if (prefix && !prefix.endsWith('/')) prefix += '/';
      const entries = new Map();
      for (const o of objects) {
        if (!o.startsWith(prefix)) continue;
        const rest = o.slice(prefix.length);
        const i = rest.indexOf('/');
        if (i < 0) entries.set(rest, { name: rest, id: `id-${o}` });
        else if (!entries.has(rest.slice(0, i))) entries.set(rest.slice(0, i), { name: rest.slice(0, i), id: null });
      }
      const list = [...entries.values()].sort((a, b) => a.name.localeCompare(b.name));
      const limit = Math.min(body.limit ?? 100, 1000);
      return json(list.slice(body.offset || 0, (body.offset || 0) + limit));
    }
    if (method === 'DELETE' && path === 'object/mk-rajzok') {
      const list = body.prefixes || [];
      if (!list.length || list.length > 1000) return json({ message: 'prefixes: 1..1000 elem' }, 400);
      const deleted = list.filter(p => objects.delete(p)).map(name => ({ name }));
      return json(deleted);
    }
    return json({ message: 'nem támogatott' }, 405);
  }

  return {
    db, users, objects, calls,
    io: { rest, auth, storage, now: () => clock },
    tick(ms) { clock += ms; },
    failWhen(rule) { rules.push(rule); },
    clearFailures() { rules.length = 0; },
  };
}

/** Egy tipikus felállás: az első cég (BREMAT), a törlendő „Próba Kft” és egy harmadik cég, akinek semmije nem veszhet el. */
export function seedCompanies(fake, { files = 3, folders } = {}) {
  const A = 'aaaaaaaa-0000-0000-0000-000000000001';
  const B = 'bbbbbbbb-0000-0000-0000-000000000002';
  const BREMAT = '00000000-0000-0000-0000-000000000000';
  fake.db.mk_companies.push(
    { id: BREMAT, name: 'BREMAT', active: true, created_at: '2026-01-01' },
    { id: A, name: 'Próba Kft', active: true, created_at: '2026-02-01' },
    { id: B, name: 'Szomszéd Kft', active: true, created_at: '2026-03-01' },
  );
  const user = (id, email, company, role = 'owner') => {
    fake.users.set(id, { id, email });
    fake.db.mk_profiles.push({ user_id: id, email, company_id: company, role });
  };
  user('u-a1', 'tulaj@proba.hu', A);
  user('u-a2', 'iroda@proba.hu', A, 'office');
  user('u-admin', 'admin@andonwork.com', A);            // rendszergazda, akinek céges profilja is van
  fake.db.mk_platform_admins.push({ user_id: 'u-admin' });
  user('u-b1', 'tulaj@szomszed.hu', B);
  user('u-caller', 'rendszergazda@andonwork.com', BREMAT);
  for (const [table] of [['mk_events'], ['mk_assignments'], ['mk_employees'], ['mk_tasks'], ['mk_teams'], ['mk_locations'], ['mk_pins']]) {
    fake.db[table].push({ id: `${table}-a`, company_id: A }, { id: `${table}-b`, company_id: B });
  }
  const nFolders = folders ?? files;
  for (let i = 0; i < files; i++) fake.objects.add(`${A}/${String(i % nFolders).padStart(5, '0')}/rajz-${i}.pdf`);
  fake.objects.add(`${B}/f1/szomszed-rajza.pdf`);
  return { A, B, BREMAT };
}
