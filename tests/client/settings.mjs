// Böngészős próba: a Beállítások fül (téma, animációk, sűrűség) – DEMÓ módban.
//
// Amit őriz (lásd CLAUDE.md, „Dizájn” és „Állapot”, 2026. szeptember 25.):
//   • az alapértelmezés a sötét téma, a rendszer szerinti mozgás és a normál
//     sűrűség; a választás azonnal él, a böngészőben tárolódik, és újratöltéskor
//     már az első kirajzolás előtt érvényes (nem villan fel a sötét);
//   • a világos témában minden szöveg kontrasztja legalább 4,5:1 (nagy szövegnél
//     3:1) – az élő nézetben, a heti tervben, a törzsadatokban, a riportokban,
//     a felugró ablakban, a licenc- és a séma-sávban, a bejelentkező képernyőn;
//     a feladatszín-minták legalább 3:1 a panelen; a jelzőlámpák ugyanazok,
//     mint a sötét témában;
//   • a tablet NEM követi a beállításokat: kioszk módban mindig sötét, és az
//     irodai Tablet fül előnézete világos témában is sötét;
//   • az animáció-beállítás mindkét irányba felülírja a rendszert, a CSS- és a
//     JS-animációkra egyaránt;
//   • a tömör sűrűség ténylegesen több sort ad;
//   • ha a böngésző nem enged tárolni, a beállítás akkor is érvényes, hiba nélkül.
//
// Futtatás: node tests/client/settings.mjs (a környezeti változók: harness.mjs)
import { openDemo, open, check, finish } from './harness.mjs';
import { auditText, colorRatios } from './contrast.mjs';

const htmlAttrs = (page) => page.evaluate(() => {
  const d = document.documentElement;
  return { theme: d.getAttribute('data-theme'), density: d.getAttribute('data-density'), motion: d.getAttribute('data-motion'),
    bg: getComputedStyle(document.body).backgroundColor };
});
const DARK_BG = 'rgb(38, 45, 51)', LIGHT_BG = 'rgb(236, 239, 241)';
// Egy szakasz elbukása (pl. a régi kódon nincs Beállítások fül) ne állítsa meg
// a többit: hibaként kerüljön a listába, és a próba menjen tovább.
async function section(fn) {
  try { await fn(); } catch (e) { check(false, 'a szakasz nem futott végig: ' + String(e.message || e).split('\n')[0]); }
}

// 1) Alapértelmezés, választás, megmaradás
await section(async () => {
  const { page, context, errors } = await openDemo('#live');
  let a = await htmlAttrs(page);
  check(a.theme === 'dark' && !a.density && !a.motion && a.bg === DARK_BG, 'alapból sötét téma, rendszer szerinti mozgás, normál sűrűség', a);
  check(Boolean(await page.$('#bar [data-nav="settings"]')), 'az irodai fejlécben ott a Beállítások fül');
  await page.click('#bar [data-nav="settings"]');
  await page.waitForSelector('.settings');
  await page.click('input[name="theme"][value="light"]');
  a = await htmlAttrs(page);
  const stored = await page.evaluate(() => localStorage.getItem('mk-prefs'));
  check(a.theme === 'light' && a.bg === LIGHT_BG && /"theme":"light"/.test(stored), 'a Világos választása azonnal él, és a böngészőben tárolódik', { a, stored });
  // Újratöltés: a téma már a DOM felépülésekor világos legyen, az app indulása előtt.
  const early = page.waitForEvent('domcontentloaded').then(() => page.evaluate(() => [document.documentElement.getAttribute('data-theme'), getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()]));
  await page.reload();
  const [t0, bg0] = await early;
  check(t0 === 'light' && bg0 === '#eceff1', 'újratöltéskor már az első kirajzolás előtt világos (nem villan fel a sötét)', { t0, bg0 });
  await page.waitForSelector('#bar:not([hidden])');
  await page.click('#bar [data-nav="settings"]');
  await page.waitForSelector('.settings');
  const checked = await page.$eval('input[name="theme"]:checked', (el) => el.value);
  check(checked === 'light', 'a Beállítások oldalon a tárolt választás látszik', checked);
  check(errors.length === 0, 'nincs JS hiba', errors);
  await context.close();
});

// 2) Világos téma: kontraszt minden irodai nézetben
await section(async () => {
  const { page, context, errors } = await openDemo('#live', { prefs: { theme: 'light' } });
  const bad = {};
  for (const v of ['#live', '#plan', '#admin', '#reports', '#terminal', '#companies', '#settings']) {
    await page.evaluate((h) => { location.hash = h; }, v);
    await page.waitForTimeout(350);
    const b = await auditText(page);
    if (b.length) bad[v] = b.slice(0, 5);
  }
  // Élő nézet lenyitott naplóval, felugró ablak, licenc- és séma-sáv
  await page.evaluate(() => { location.hash = '#live'; });
  await page.waitForTimeout(300);
  const toggle = await page.$('.row button.btn');
  if (toggle) { await toggle.click(); await page.waitForTimeout(300); }
  const b1 = await auditText(page); if (b1.length) bad['live+napló'] = b1.slice(0, 5);
  await page.evaluate(() => {
    const v = document.getElementById('view');
    v.insertAdjacentHTML('afterbegin', `<div class="license-banner" role="status"><strong>Csak olvasható mód.</strong> Az előfizetés lejárt.</div>
      <div id="schema-alert"><h2>Az adatbázis le van maradva</h2><p>Futtasd: <code>db/migrations/007_valami.sql</code></p></div>
      <p class="form-err">Hibaüzenet</p><p class="warn-line">Figyelmeztetés</p><span class="tag tag-warn">Nem zárta le</span><span class="tag tag-offplan">Terven kívül</span>`);
  });
  const b2 = await auditText(page); if (b2.length) bad['sávok'] = b2.slice(0, 5);
  await page.evaluate(() => { location.hash = '#plan'; });
  await page.waitForSelector('.cell-add');
  await page.click('.pcell .cell-add');
  await page.waitForSelector('.modal');
  await page.waitForTimeout(300);
  const b3 = await auditText(page); if (b3.length) bad['ablak'] = b3.slice(0, 5);
  check(Object.keys(bad).length === 0, 'világos téma: minden szöveg legalább 4,5:1 (nagy szövegnél 3:1) – nézetek, napló, ablak, sávok', bad);
  await page.keyboard.press('Escape');
  await page.waitForTimeout(200);

  const sw = await colorRatios(page, '.chip', 'borderLeftColor', '#f8f9fa');
  const weak = sw.filter((x) => x.ratio < 3);
  check(sw.length > 0 && weak.length === 0, `világos téma: a feladatszín-csíkok mind legalább 3:1 a panelen (${sw.length} db, a leggyengébb ${Math.min(...sw.map((x) => x.ratio))}:1)`, weak.slice(0, 3));

  await page.evaluate(() => { location.hash = '#live'; });
  await page.waitForSelector('.row .stack');
  const lamps = await page.evaluate(() => ({
    go: getComputedStyle(document.querySelector('.st-work .stack .l-green')).backgroundColor,
    housing: getComputedStyle(document.querySelector('.stack')).backgroundColor,
    brand: [...document.querySelectorAll('.brand-mark i')].map((i) => getComputedStyle(i).backgroundColor),
  }));
  check(lamps.go === 'rgb(53, 196, 106)' && lamps.housing === 'rgb(29, 35, 39)' && lamps.brand.join() === 'rgb(255, 75, 62),rgb(255, 201, 51),rgb(53, 196, 106)',
    'világos témában is ugyanazok a jelzőlámpák: sötét ház, élénk fény, piros–sárga–zöld sorrend', lamps);

  // Tablet fül: az előnézet sötét marad
  await page.evaluate(() => { location.hash = '#terminal'; });
  await page.waitForSelector('.term');
  const term = await page.evaluate(() => { const t = document.querySelector('.term'); const cs = getComputedStyle(t); return { bg: cs.backgroundColor, color: cs.color }; });
  check(term.bg === DARK_BG && term.color === 'rgb(236, 238, 232)', 'világos témában az irodai Tablet fül előnézete sötét marad (sötét alap, világos szöveg)', term);
  const termBad = await auditText(page, { skipDark: false });
  check(termBad.filter((x) => /key|term|t-/.test(x.cls || '') && x.ratio < 3).length === 0, 'az előnézet szövegei a sötét szigeten is olvashatók', termBad.slice(0, 3));
  check(errors.length === 0, 'nincs JS hiba (világos téma)', errors);
  await context.close();
});

// 3) A tablet kioszk módban nem követi a beállításokat
await section(async () => {
  const { page, context } = await openDemo('?terminal=nincs-ilyen', { prefs: { theme: 'light', density: 'compact', motion: 'on' } });
  const a = await htmlAttrs(page);
  const bar = await page.$eval('#bar', (el) => el.hidden || getComputedStyle(el).display === 'none');
  check(!a.theme && !a.density && !a.motion && a.bg === DARK_BG && bar, 'kioszk módban a tárolt világos/tömör/mozgás beállítás sem hat: sötét, fejléc és Beállítások fül nélkül', { a, bar });
  await context.close();
});

// 4) Animációk: mindkét irányba felülírja a rendszert (CSS és JS is)
async function motionProbe(prefs, media) {
  const { page, context } = await openDemo('#plan', { prefs, media });
  await page.waitForSelector('.chip-x');
  // JS-animáció: a törölt beosztás összecsukódása (Web Animations API)
  await page.hover('.chip');
  await page.click('.chip-x');
  const js = await page.evaluate(() => document.getAnimations().filter((x) => !(x instanceof CSSAnimation) && !(x instanceof CSSTransition)).length);
  await page.waitForTimeout(400);
  // CSS-animáció: a felugró ablak beúszása
  await page.click('.pcell .cell-add');
  const css = await page.evaluate(() => document.getAnimations().filter((x) => x instanceof CSSAnimation).length);
  await context.close();
  return { js, css };
}
await section(async () => {
  const sysReduce = { reducedMotion: 'reduce' };
  const a = await motionProbe(undefined, sysReduce);
  check(a.js === 0 && a.css === 0, 'rendszer szerint + mozgáscsökkentés: semmi nem mozog', a);
  const b = await motionProbe({ motion: 'on' }, sysReduce);
  check(b.js > 0 && b.css > 0, '„Be”: mozgáscsökkentés mellett is mozog (CSS és JS is)', b);
  const c = await motionProbe({ motion: 'off' }, { reducedMotion: 'no-preference' });
  check(c.js === 0 && c.css === 0, '„Ki”: a rendszer engedné, mégsem mozog semmi (CSS és JS sem)', c);
  const d = await motionProbe(undefined, { reducedMotion: 'no-preference' });
  check(d.js > 0 && d.css > 0, 'rendszer szerint, mozgáscsökkentés nélkül: mozog', d);
});

// 5) Tömör sűrűség: ugyanaz a heti terv és élő nézet kevesebb helyen
async function heights(prefs) {
  const { page, context } = await openDemo('#plan', { prefs });
  await page.waitForSelector('.pgrid');
  const plan = await page.$eval('.pgrid', (el) => el.getBoundingClientRect().height);
  await page.evaluate(() => { location.hash = '#live'; });
  await page.waitForSelector('.row');
  const row = await page.$eval('.row', (el) => el.getBoundingClientRect().height);
  await context.close();
  return { plan: Math.round(plan), row: Math.round(row) };
}
await section(async () => {
  const n = await heights({ density: 'normal' });
  const c = await heights({ density: 'compact' });
  check(c.plan < n.plan * 0.8 && c.row < n.row * 0.85, `tömör sűrűség: a heti terv ${Math.round(100 - 100 * c.plan / n.plan)}%-kal, egy élő nézeti sor ${Math.round(100 - 100 * c.row / n.row)}%-kal alacsonyabb`, { n, c });
});

// 6) Rendszer szerinti téma: követi a számítógépet
await section(async () => {
  const { page, context } = await openDemo('#settings', { prefs: { theme: 'system' }, media: { colorScheme: 'light' } });
  let a = await htmlAttrs(page);
  const label = await page.textContent('[data-desc="theme-system"]');
  check(a.theme === 'light' && /most: világos/.test(label), 'rendszer szerint: világos rendszerben világos, és a leírás is ezt mondja', { a, label });
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.waitForTimeout(150);
  a = await htmlAttrs(page);
  check(a.theme === 'dark' && /most: sötét/.test(await page.textContent('[data-desc="theme-system"]')), 'a rendszer átállításakor újratöltés nélkül vált', a);
  await context.close();
});

// 7) Ha a böngésző nem enged tárolni: a beállítás él, hiba nélkül, és ezt ki is írja
await section(async () => {
  const { page, context, errors } = await openDemo('#settings', { prefs: undefined, media: undefined, viewport: undefined, noStorage: true });
  await page.click('input[name="density"][value="compact"]');
  const a = await htmlAttrs(page);
  const note = await page.textContent('#set-note');
  check(a.density === 'compact' && /nem menthető/.test(note) && errors.length === 0, 'tárolás nélkül is érvényes a választás, és a felület megmondja, hogy nem marad meg', { a, note, errors });
  await context.close();
});

// 8) A bejelentkező képernyő is követi a témát, és ott is rendben a kontraszt
await section(async () => {
  const t = await open('', { session: false }, { prefs: { theme: 'light' } });
  const a = await htmlAttrs(t.page);
  const bad = await auditText(t.page);
  check(a.theme === 'light' && bad.length === 0, 'a bejelentkező képernyő világos témában is olvasható', { a, bad: bad.slice(0, 3) });
  await t.page.close();
});

await finish();
