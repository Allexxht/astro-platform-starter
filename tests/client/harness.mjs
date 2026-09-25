// Közös böngészős próbakörnyezet a kliens (public/munkakovetes/index.html)
// teszteléséhez: egy kis HTTP-szerver szolgálja ki az appot a /munkakovetes/
// útvonalon, és a supabase-js helyett egy teszt-kliens fut, ugyanazzal a
// felülettel. A teszt-kliens a valódi viselkedést utánozza (a régi, PKCE-s
// levél kódja a kliens indulása közben váltódik be, és ekkor jön a
// PASSWORD_RECOVERY esemény; a verifyOtp csak jó tokennel ad munkamenetet), és
// minden hívást naplóz a window.__calls tömbbe.
//
//   CHROME_PATH=/út/a/chrome – ha nincs megadva, a rendszer Chrome-ja (channel: chrome)
//   INDEX_FILE=... – másik index.html próbája (pl. a régi változaté, hogy a teszt tényleg megfogja a hibát)
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { chromium } from 'playwright-core';

const INDEX = readFileSync(process.env.INDEX_FILE || new URL('../../public/munkakovetes/index.html', import.meta.url));

const STUB = `
const st = () => window.__stub;
const calls = () => (window.__calls = window.__calls || []);
const delay = ms => new Promise(r => setTimeout(r, ms));
function builder(table) {
  const b = { one: false };
  const self = new Proxy(b, { get(t, k) {
    if (k === 'then') return (res, rej) => {
      let data = t.one ? null : [];
      if (t.one && table === 'mk_profiles') data = { user_id: 'u1', company_id: 'c1', role: 'owner', username: 'Iroda', email: 'iroda@example.com' };
      if (t.one && table === 'mk_companies') data = { id: 'c1', name: 'Próba Kft', license_expires_at: null, active: true };
      return Promise.resolve({ data, error: null }).then(res, rej);
    };
    if (k === 'maybeSingle' || k === 'single') return () => { t.one = true; return self; };
    return () => self;
  } });
  return self;
}
export function createClient() {
  const listeners = [];
  const user = id => ({ user: { id, email: id + '@example.com' }, access_token: 'tok-' + id });
  let session = st().session ? user('u1') : null;
  const emit = ev => listeners.forEach(cb => cb(ev, session));
  const params = new URLSearchParams(location.search);
  // „Indulás”: a régi levél PKCE-kódját a kliens maga váltja be, ha a kérő
  // böngésző tárolt hozzá párt (st().pkceVerifier). Siker esetén az esemény
  // azonnal és egy kör múlva is kimegy – mint a valódi supabase-js-ben.
  const init = (async () => {
    await delay(5);
    if (params.has('code') && st().pkceVerifier) {
      session = user('u-rec');
      emit('PASSWORD_RECOVERY');
      setTimeout(() => emit('PASSWORD_RECOVERY'), 0);
    }
  })();
  return {
    auth: {
      async getSession() { await init; return { data: { session } }; },
      async getUser() { await init; return { data: { user: session && session.user } }; },
      onAuthStateChange(cb) { listeners.push(cb); return { data: { subscription: { unsubscribe() {} } } }; },
      async verifyOtp(p) {
        calls().push(['verifyOtp', p.token_hash, p.type]);
        if (p.type === 'recovery' && p.token_hash === st().validToken) {
          session = user('u-rec');
          emit('PASSWORD_RECOVERY');
          return { data: { session, user: session.user }, error: null };
        }
        return { data: { session: null, user: null }, error: { message: 'Token has expired or is invalid' } };
      },
      async updateUser() { calls().push(['updateUser', session && session.user.id]); return session ? { data: {}, error: null } : { data: {}, error: { message: 'Auth session missing!' } }; },
      async resetPasswordForEmail(email, o) { calls().push(['resetPasswordForEmail', email, o && o.redirectTo]); return { data: {}, error: null }; },
      async signInWithPassword() { return { error: null }; },
      async signOut() { calls().push(['signOut']); session = null; return { error: null }; },
    },
    from: t => builder(t),
    async rpc(name) {
      // a séma-ellenőrzés „hálózati” késése: a régi kód emiatt kötötte be túl későn a figyelőt
      if (name === 'mk_schema_state') { await delay(40); return { data: [1, 2, 3, 4, 5, 6], error: null }; }
      if (name === 'mk_write_allowed') return { data: true, error: null };
      if (name === 'mk_is_platform_admin') return { data: Boolean(st().admin), error: null };
      return { data: null, error: null };
    },
    channel() { const c = { on() { return c; }, subscribe() { return c; } }; return c; },
    removeChannel() {},
    storage: { from() { return {}; } },
  };
}`;

// DEMÓ mód: ugyanaz az app, üres Supabase-kulcsokkal (memóriabeli mintaadat,
// élő nézet, heti terv, tablet) – a /demo/munkakovetes/ útvonalon.
const DEMO_INDEX = String(INDEX)
  .replace(/SUPABASE_URL: '[^']*'/, "SUPABASE_URL: ''")
  .replace(/SUPABASE_ANON_KEY: '[^']*'/, "SUPABASE_ANON_KEY: ''");

const server = http.createServer((req, res) => {
  if (req.url.startsWith('/munkakovetes/')) { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(INDEX); return; }
  if (req.url.startsWith('/demo/munkakovetes/')) { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(DEMO_INDEX); return; }
  res.writeHead(404); res.end();
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
export const BASE = `http://127.0.0.1:${server.address().port}/munkakovetes/`;
export const DEMO_BASE = `http://127.0.0.1:${server.address().port}/demo/munkakovetes/`;

export const browser = await chromium.launch(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : { channel: 'chrome' });

export async function open(query, stub, { api, prefs } = {}) {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.route('**/supabase-js@2/+esm', (r) => r.fulfill({ contentType: 'text/javascript', body: STUB }));
  await page.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  if (api) await page.route('**/api/mk-admin', api);
  await page.addInitScript((s) => { window.__stub = s; }, stub);
  if (prefs) await page.addInitScript((p) => { localStorage.setItem('mk-prefs', JSON.stringify(p)); }, prefs);
  await page.goto(BASE + query);
  await page.waitForSelector('#l-save, #l-go, #bar:not([hidden])', { timeout: 10000 });
  await page.waitForTimeout(150);
  const state = async () => page.evaluate(() => ({
    screen: document.getElementById('l-save') ? 'new-password' : document.getElementById('l-go') ? 'login' : !document.getElementById('bar').hidden ? 'app' : '?',
    url: location.search + location.hash,
    calls: window.__calls || [],
    err: (document.querySelector('.login-box .form-err') || {}).textContent || '',
  }));
  // Ha nincs új-jelszó képernyő, nincs mit beküldeni – a hívó ellenőrzése ezt hibaként rögzíti.
  const submitPassword = async (pw = 'UjJelszo12345') => {
    if (!(await page.$('#l-save'))) return false;
    await page.fill('#l-pass', pw);
    await page.fill('#l-pass2', pw);
    await page.click('#l-save');
    await page.waitForTimeout(300);
    return true;
  };
  return { page, state, submitPassword, errors };
}

// DEMÓ mód megnyitása. prefs: a böngészőben „előre elmentett” megjelenési
// beállítások (localStorage), media: a rendszer beállításai (colorScheme,
// reducedMotion), viewport: ablakméret, noStorage: a böngésző nem enged
// tárolni (mint egy privát ablak tiltott tárolással – minden hívás kivételt dob).
export async function openDemo(query = '', { prefs, media, viewport, noStorage } = {}) {
  const context = await browser.newContext({ viewport: viewport || { width: 1400, height: 900 }, ...(media || {}) });
  const page = await context.newPage();
  page.setDefaultTimeout(5000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  if (prefs) await page.addInitScript((p) => { try { localStorage.setItem('mk-prefs', JSON.stringify(p)); } catch (e) { /* nincs tárolás */ } }, prefs);
  if (noStorage) {
    await page.addInitScript(() => {
      const deny = () => { throw new DOMException('A tárolás le van tiltva', 'SecurityError'); };
      Object.defineProperty(window, 'localStorage', { configurable: true, get: deny });
    });
  }
  await page.goto(DEMO_BASE + query);
  await page.waitForSelector(query.includes('terminal=') ? '.term' : '#bar:not([hidden])', { timeout: 10000 });
  await page.waitForTimeout(150);
  return { page, context, errors };
}

export const results = [];
export const check = (cond, m, extra) => results.push(`${cond ? '✅' : '❌'} ${m}${!cond && extra !== undefined ? ` – ${JSON.stringify(extra)}` : ''}`);
export async function finish() {
  await browser.close();
  server.close();
  console.log(results.join('\n'));
  const failed = results.filter((l) => l.startsWith('❌')).length;
  console.log(failed ? `\n${failed} ellenőrzés elbukott.` : `\nMind a ${results.length} ellenőrzés rendben.`);
  process.exit(failed ? 1 : 0);
}
