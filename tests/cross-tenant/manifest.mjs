// Kereszt-teszt manifest – lásd tests/cross-tenant/run.mjs és CLAUDE.md
// "Többbérlős SaaS – terv" → "Kereszt-teszt: valódi kapu, nem emlékezet".
//
// SZABÁLY: minden company_id-t kapó tábla és minden security definer RPC
// (mk_terminal_*, mk_archive_*, mk_set_pin, stb.) EBBEN A FÁJLBAN kerül
// felvételre, UGYANABBAN a pull requestben, amelyik a táblát/RPC-t bevezeti
// vagy company_id-val bővíti. A run.mjs nem az emlékezetünkre hagyatkozik:
// magában az adatbázisban keresi meg a company_id oszlopos táblákat és a
// company_id-t használó security definer függvényeket (trigger- és
// nulla-paraméterű "ki vagyok" segédfüggvények nélkül), és amint a
// public.mk_companies tábla létezik, BUKÁS lesz, ha bármelyiket nem találja
// itt (vagy ha ez a két lista még teljesen üres).

/**
 * @typedef {Object} TenantTable
 * @property {string} table          - a tábla neve (pl. "mk_teams")
 * @property {string} [companyColumn] - a company oszlop neve, alapértelmezetten "company_id"
 */

/** @type {TenantTable[]} */
export const TENANT_TABLES = [
  { table: 'mk_teams' },
  { table: 'mk_locations' },
  { table: 'mk_employees' },
  { table: 'mk_tasks' },
  { table: 'mk_terminals' },
  { table: 'mk_assignments' },
  { table: 'mk_attachments' },
  { table: 'mk_assignment_attachments' },
  { table: 'mk_events' },
  { table: 'mk_pins' },
  { table: 'mk_pin_failures' },
  { table: 'mk_profiles' },
];

/**
 * @typedef {Object} TenantRpc
 * @property {string} name
 *   Az RPC neve (pl. "mk_terminal_catalog").
 * @property {(companyA: Fixture) => Object} baseArgs
 *   Az A cég SAJÁT, érvényes próba-adataival kitöltött argumentumok.
 * @property {string} crossTenantArg
 *   Melyik argumentum nevét kell B cég azonosítójára cserélni.
 * @property {(companyB: Fixture) => any} otherTenantValue
 *   Visszaadja azt az értéket (pl. B cég terminal/employee/task/attachment
 *   id-ja), amit A cég session-jével/próba-adataival kombinálva próbálunk
 *   elérni.
 * @property {'error'|'null'|((data: any, companyA: Fixture, companyB: Fixture) => boolean)} [expect]
 *   Mit jelent "nincs szivárgás" ennél az RPC-nél – nem minden RPC-nél ez
 *   ugyanaz:
 *     - 'error' (alapértelmezett): a hívásnak hibával KELL elutasítania
 *       (RAISE EXCEPTION a függvényben).
 *     - 'null': a hívásnak hiba NÉLKÜL, de null/üres adattal kell
 *       visszatérnie – ez a tervezett, biztonságos válasz pl. rossz PIN-nél
 *       (mk_terminal_identify), hogy a tablet meg tudja különböztetni "rossz
 *       PIN"-t egy szerverhibától.
 *     - függvény: van olyan RPC (mk_terminal_catalog), ami SZÁNDÉKOSAN
 *       sikerrel tér vissza más cég terminal-id-jára is – a terminal id maga
 *       a "titkos kulcs" (lásd CLAUDE.md "Biztonság"), nem a hívó cége dönti
 *       el, mit lát. Ilyenkor a valódi ellenőrzés az, hogy a visszaadott
 *       adat KIZÁRÓLAG a hívott terminál saját cégéhez tartozzon, sose
 *       keveredjen bele a másik cég adata – ezt a függvény dönti el.
 */

/** @type {TenantRpc[]} */
export const TENANT_RPCS = [
  {
    // Teljesen le van tiltva authenticated/anon/public számára (csak más
    // security definer függvények hívják belülről) – ez a próba azt
    // igazolja, hogy ez a lezárás tényleg áll.
    name: 'mk__pin_employee',
    baseArgs: (companyA) => ({ p_pin: companyA.pin }),
    crossTenantArg: 'p_terminal',
    otherTenantValue: (companyB) => companyB.terminalId,
    expect: 'error',
  },
  {
    name: 'mk_archive_employee',
    baseArgs: () => ({}),
    crossTenantArg: 'p_employee',
    otherTenantValue: (companyB) => companyB.employeeId,
    expect: 'error',
  },
  {
    name: 'mk_archive_task',
    baseArgs: () => ({}),
    crossTenantArg: 'p_task',
    otherTenantValue: (companyB) => companyB.taskId,
    expect: 'error',
  },
  {
    name: 'mk_set_pin',
    baseArgs: () => ({ p_pin: '9999' }),
    crossTenantArg: 'p_employee',
    otherTenantValue: (companyB) => companyB.employeeId,
    expect: 'error',
  },
  {
    // A saját, érvényes terminál+PIN párosával próbál B egy csatolmányához
    // hozzáférni – az igazi kockázat (a saját tabletjéről próbálgat más cég
    // csatolmány-azonosítókat).
    name: 'mk_terminal_attachment_path',
    baseArgs: (companyA) => ({ p_terminal: companyA.terminalId, p_pin: companyA.pin }),
    crossTenantArg: 'p_attachment',
    otherTenantValue: (companyB) => companyB.attachmentId,
    expect: 'error',
  },
  {
    // B terminálja (érvényes) + A PIN-je (B cégén belül nem létezik) ->
    // biztonságos null, nem hiba (lásd fent).
    name: 'mk_terminal_identify',
    baseArgs: (companyA) => ({ p_pin: companyA.pin }),
    crossTenantArg: 'p_terminal',
    otherTenantValue: (companyB) => companyB.terminalId,
    expect: 'null',
  },
  {
    // B terminálja (érvényes) + A PIN-je -> "Hibás PIN." hiba.
    name: 'mk_terminal_event',
    baseArgs: (companyA) => ({ p_pin: companyA.pin, p_type: 'start' }),
    crossTenantArg: 'p_terminal',
    otherTenantValue: (companyB) => companyB.terminalId,
    expect: 'error',
  },
  {
    // Szándékosan NEM 'error': bárki, aki ismeri egy terminál id-ját, látja
    // a katalógusát (ez a mai, változatlan modell - lásd CLAUDE.md
    // "Biztonság" a mk_terminal_catalog-ról). A valódi ellenőrzés: B
    // terminálja SOSE adja vissza A feladatát, és a saját feladatát igen.
    name: 'mk_terminal_catalog',
    baseArgs: () => ({}),
    crossTenantArg: 'p_terminal',
    otherTenantValue: (companyB) => companyB.terminalId,
    expect: (data, companyA, companyB) => {
      const tasks = Array.isArray(data?.tasks) ? data.tasks : [];
      const leaksA = tasks.some((t) => t.id === companyA.taskId);
      const hasOwnB = tasks.some((t) => t.id === companyB.taskId);
      return !leaksA && hasOwnB;
    },
  },
  {
    // 004: a licenc-állapot lekérdezése egy TETSZŐLEGES cégre. A függvényről
    // szándékosan vissza van vonva a végrehajtási jog (revoke execute), mert
    // egy idegen cég azonosítójával hívva elárulná, hogy az a cég aktív-e.
    // A saját cégére a kliens a paraméter nélküli mk_write_allowed()-ot hívja.
    name: 'mk_company_active',
    baseArgs: () => ({}),
    crossTenantArg: 'p_company',
    otherTenantValue: (companyB) => companyB.id,
    expect: 'error',
  },
];
