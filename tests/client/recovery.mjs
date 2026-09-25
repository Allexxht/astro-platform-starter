// Böngészős próba: jelszó-visszaállítás a kliensben (public/munkakovetes/index.html).
//
// A supabase-js helyett egy teszt-kliens fut (ugyanazzal a felülettel), ami a
// valódi viselkedést utánozza: a régi, PKCE-s levélből hozott kód a kliens
// indulása közben váltódik be, és ekkor jön a PASSWORD_RECOVERY esemény; a
// verifyOtp csak jó tokennel ad munkamenetet. Minden hívást naplóz, így
// ellenőrizhető, hogy mentés előtt ki és mivel igazolta magát.
//
// Amit őriz (lásd CLAUDE.md, 2026. szeptember 25.):
//   • egy meglévő munkamenet + ?recovery=1 NEM nyitja meg az új-jelszó képernyőt
//     (korábban így egy nyitva hagyott gépen bárki átvehette a fiókot);
//   • a token_hash-es link bármelyik böngészőben működik, és a jelszó csak a
//     token SIKERES ellenőrzése után mentődik – rossz tokennél akkor sem, ha
//     épp be van jelentkezve valaki;
//   • a tokent nem az oldal betöltése, hanem a felhasználó kattintása váltja be
//     (a levelezők linkellenőrzője nem „használhatja el”).
//
// Futtatás: node tests/client/recovery.mjs (a környezeti változók: harness.mjs)
import { open, check, finish, BASE } from './harness.mjs';

// 1) BIZTONSÁG: meglévő munkamenet + ?recovery=1 → nincs új-jelszó képernyő
for (const q of ['?recovery=1', '?recovery=1#type=recovery', '#type=recovery']) {
  const t = await open(q, { session: true });
  const s = await t.state();
  check(s.screen === 'app' && !s.calls.some((c) => c[0] === 'updateUser'),
    `bejelentkezett gépen a „${q}” NEM nyitja meg az új-jelszó képernyőt (a fiók nem vehető át)`, s);
  await t.page.close();
}

// 2) Új levél, más eszköz: token_hash, munkamenet nélkül
{
  const t = await open('?token_hash=jo-token&type=recovery', { session: false, validToken: 'jo-token' });
  let s = await t.state();
  check(s.screen === 'new-password', 'a token_hash-es link más böngészőben is az új-jelszó képernyőre visz', s);
  check(!s.url.includes('token_hash'), 'a token azonnal eltűnik a címsorból', s.url);
  check(!s.calls.some((c) => c[0] === 'verifyOtp'), 'a tokent az oldal betöltése még nem váltja be (linkellenőrzők ellen)', s.calls);
  await t.submitPassword();
  s = await t.state();
  const vi = s.calls.findIndex((c) => c[0] === 'verifyOtp' && c[1] === 'jo-token' && c[2] === 'recovery');
  const ui = s.calls.findIndex((c) => c[0] === 'updateUser' && c[1] === 'u-rec');
  check(vi >= 0 && ui > vi && s.screen === 'app', 'mentéskor előbb a token ellenőrzése, csak utána a jelszó – és belép', s);
  await t.page.close();
}

// 3) Rossz token, miközben a böngészőben más be van jelentkezve → semmi nem mentődik
{
  const t = await open('?token_hash=rossz&type=recovery', { session: true, validToken: 'jo-token' });
  await t.submitPassword();
  const s = await t.state();
  check(s.calls.some((c) => c[0] === 'verifyOtp') && !s.calls.some((c) => c[0] === 'updateUser') && /érvénytelen|lejárt/.test(s.err),
    'rossz tokennél a jelszó NEM mentődik a meglévő munkamenetre, és érthető hibaüzenet jön', s);
  if (await t.page.$('#l-back')) await t.page.click('#l-back');
  await t.page.waitForTimeout(200);
  const after = await t.page.evaluate(() => window.__calls || []);
  check(!after.some((c) => c[0] === 'signOut'), 'Mégse egy ellenőrizetlen tokennél nem jelentkezteti ki a gép másik felhasználóját', after);
  await t.page.close();
}

// 4) Régi (PKCE) levél a kérő böngészőben: a kódcsere eseménye nyitja meg
{
  const t = await open('?code=abc&recovery=1', { session: false, pkceVerifier: true });
  let s = await t.state();
  check(s.screen === 'new-password' && !s.url.includes('code='), 'régi levél a kérő böngészőben: a friss kódcsere megnyitja a képernyőt', s);
  await t.submitPassword();
  s = await t.state();
  check(s.calls.some((c) => c[0] === 'updateUser' && c[1] === 'u-rec') && !s.calls.some((c) => c[0] === 'verifyOtp') && s.screen === 'app',
    'régi levél: a jelszó a visszaállító munkamenetre mentődik', s);
  await t.page.close();
}

// 5) Régi (PKCE) levél MÁS böngészőben: érthető üzenet, nem néma kudarc
{
  const t = await open('?code=abc&recovery=1', { session: false, pkceVerifier: false });
  const s = await t.state();
  check(s.screen === 'login' && /nem sikerült belépni/.test(s.err), 'régi levél más böngészőben: a bejelentkező képernyő megmondja, mi a baj és mit tegyen', s);
  await t.page.close();
}

// 6) A kért levél visszatérési címe lekérdezés nélküli (a sablon fűzi hozzá a tokent)
{
  const t = await open('', { session: false });
  await t.page.click('#l-forgot');
  await t.page.fill('#l-user', 'valaki@example.com');
  await t.page.click('#l-send');
  await t.page.waitForTimeout(200);
  const s = await t.state();
  const call = s.calls.find((c) => c[0] === 'resetPasswordForEmail');
  check(call && call[2] === BASE, 'a visszaállító levél kérése a lekérdezés nélküli címre irányít vissza', call);
  check(t.errors.length === 0, 'nincs JS hiba', t.errors);
  await t.page.close();
}

await finish();
