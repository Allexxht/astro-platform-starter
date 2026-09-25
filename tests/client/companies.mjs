// Böngészős próba: a Cégek nézet és a cégtörlés ablaka (public/munkakovetes/index.html).
//
// A szerver (/api/mk-admin) válaszait a teszt adja, pontosan olyan alakban, ahogy
// a src/lib/mk-admin-core.ts küldi: nagy cégnél 202 + continue, félbemaradásnál
// 502 + többsoros jelentés (mi kész, mi van hátra), a végén 200.
//
// Amit őriz (lásd CLAUDE.md, 2026. szeptember 25.):
//   • ha a szerver nem tudja megszámolni a cég dolgozóit/eseményeit, a felület
//     „ismeretlen”-t ír, nem 0-t – a törlés megerősítése ebből mondja meg, mi vész el;
//   • a törlés addig folytatódik, amíg a szerver azt kéri (continue), és közben
//     kiírja, hol tart;
//   • félbemaradáskor az ablak nyitva marad, és a teljes jelentés olvasható
//     (soronként), a lista frissül; egy újabb Törlés befejezi.
//
// Futtatás: node tests/client/companies.mjs (a környezeti változók: harness.mjs)
import { open, check, finish } from './harness.mjs';

const partialError =
  'A törlés félbemaradt ennél a lépésnél: feladatok (a törlés nem sikerült: 500).\n' +
  'Elkészült: a cég felfüggesztve, 2 bejelentkezési fiók, 1200 feltöltött rajz, események.\n' +
  'Hátravan: feladatok, tabletek, csapatok, helyszínek, ellenőrzés, a cég sora.\n' +
  'A cég felfüggesztve a listában marad. Nyomd meg újra a Törlést – onnan folytatja, ahol abbamaradt.';
const deleteReplies = [
  [202, { ok: false, continue: true, progress: { users: 2, files: 500 } }],
  [202, { ok: false, continue: true, progress: { users: 0, files: 700 } }],
  [502, { error: partialError, partial: { failed: 'feladatok' }, retry: true }],
  [200, { ok: true, deleted: { company: 'Próba Kft', users: 0, files: 0 } }],
];
const calls = { list: 0, del: 0 };
let active = true;

async function api(route) {
  const body = JSON.parse(route.request().postData() || '{}');
  if (body.action === 'list_companies') {
    calls.list++;
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({
      companies: [
        { id: 'c0', name: 'BREMAT', active: true, created_at: '2026-01-01', users: [], employee_count: 12, event_count: 800, last_event_at: null },
        { id: 'c2', name: 'Próba Kft', active, created_at: '2026-02-01', users: [{ username: 'Tulaj', email: 't@proba.hu', role: 'owner' }, { username: 'Iroda', email: 'i@proba.hu', role: 'office' }],
          employee_count: null, event_count: null, last_event_at: null },
      ],
      stats_error: 'A használati adatok (dolgozók, események) most nem kérdezhetők le.',
    }) });
  }
  if (body.action === 'delete_company') {
    const [status, reply] = deleteReplies[calls.del++] || [500, { error: 'váratlan hívás' }];
    if (status === 502) active = false;
    await new Promise((r) => setTimeout(r, 60));
    return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(reply) });
  }
  return route.fulfill({ status: 400, contentType: 'application/json', body: '{"error":"ismeretlen"}' });
}

const t = await open('#companies', { session: true, admin: true }, { api });
await t.page.waitForSelector('[data-act="company-del"]');
const view = await t.page.textContent('#view');
check(/ismeretlen számú dolgozó/.test(view) && /ismeretlen számú esemény/.test(view) && !/\b0 dolgozó/.test(view),
  'ismeretlen szám esetén „ismeretlen számú dolgozó/esemény”, nem 0', view.slice(0, 400));
check(/most nem kérdezhetők le/.test(view), 'a lista megmondja, hogy a használati adatok most nem jöttek le');

await t.page.click('[data-act="company-del"]');
await t.page.waitForSelector('.modal #f-confirm');
const modalText = await t.page.textContent('.modal');
check(/ismeretlen számú dolgozó, ismeretlen számú esemény/.test(modalText) && /2 bejelentkezési fiók/.test(modalText),
  'a törlés megerősítése sem ír 0-t ismeretlen számra', modalText.slice(0, 300));

await t.page.fill('#f-confirm', 'Próba Kft');
const progressSeen = t.page.waitForFunction(() => /Törlés folyamatban… eddig 500 rajz/.test((document.getElementById('f-del-progress') || {}).textContent || ''), null, { timeout: 5000 })
  .then(() => true, () => false);
await t.page.click('.modal-foot .btn-primary');
check(await progressSeen, 'folytatás közben kiírja, hol tart (eddig hány rajz és fiók)');
await t.page.waitForSelector('.modal .form-err:not([hidden])', { timeout: 5000 }).catch(() => null);
const err = await t.page.$eval('.modal .form-err', (el) => ({ text: el.textContent, ws: getComputedStyle(el).whiteSpace, lines: el.getClientRects().length && Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight || 20)) })).catch(() => ({ text: '(nincs hibaüzenet – az ablak bezárult)' }));
check(err.text === partialError && err.ws === 'pre-line' && err.lines >= 4,
  'félbemaradáskor az ablak nyitva marad, a jelentés teljes és soronként olvasható', err);
check(calls.del === 3, 'addig kérte a folytatást, amíg a szerver azt mondta (2× continue, majd a hiba)', calls);
check(calls.list >= 2 && /felfüggesztve/.test(await t.page.textContent('#view')), 'a lista frissült: a félbemaradt cég felfüggesztve látszik');

if (await t.page.$('.modal-foot .btn-primary')) await t.page.click('.modal-foot .btn-primary');
await t.page.waitForFunction(() => !document.querySelector('#modal-root .backdrop:not(.is-leaving)'), null, { timeout: 5000 }).catch(() => null);
const toast = await t.page.textContent('#toast');
check(calls.del === 4 && /Cég törölve/.test(toast), 'újra megnyomva befejeződik, az ablak bezárul', { calls, toast });
check(t.errors.length === 0, 'nincs JS hiba', t.errors);
await t.page.close();
await finish();
