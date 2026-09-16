// Kereszt-teszt manifest – lásd tests/cross-tenant/run.mjs és CLAUDE.md
// "Többbérlős SaaS – terv" → "Kereszt-teszt: valódi kapu, nem emlékezet".
//
// SZABÁLY: minden company_id-t kapó tábla és minden security definer RPC
// (mk_terminal_*, mk_archive_*, mk_set_pin, stb.) EBBEN A FÁJLBAN kerül
// felvételre, UGYANABBAN a pull requestben, amelyik a táblát/RPC-t bevezeti
// vagy company_id-val bővíti. A run.mjs nem az emlékezetünkre hagyatkozik:
// magában az adatbázisban keresi meg a company_id oszlopos táblákat és a
// company_id-t használó security definer függvényeket, és amint a
// public.mk_companies tábla létezik, BUKÁS lesz, ha bármelyiket nem találja
// itt (vagy ha ez a két lista még teljesen üres).

/**
 * @typedef {Object} TenantTable
 * @property {string} table          - a tábla neve (pl. "mk_teams")
 * @property {string} [companyColumn] - a company oszlop neve, alapértelmezetten "company_id"
 */

/** @type {TenantTable[]} */
export const TENANT_TABLES = [
  // { table: 'mk_teams' },
  // { table: 'mk_locations' },
  // { table: 'mk_employees' },
  // { table: 'mk_tasks' },
  // { table: 'mk_terminals' },
  // { table: 'mk_assignments' },
  // { table: 'mk_attachments' },
  // { table: 'mk_events' },
  // ... minden további mk_ tábla, ahogy company_id oszlopot kap
];

/**
 * @typedef {Object} TenantRpc
 * @property {string} name             - az RPC neve (pl. "mk_terminal_catalog")
 * @property {Object} baseArgs         - az A cég próba-adataival kitöltött argumentumok
 * @property {string} crossTenantArg   - melyik argumentum nevét kell B cég azonosítójára cserélni
 * @property {(companyB: {id: string, [k: string]: any}) => any} otherTenantValue
 *   - visszaadja azt az értéket (pl. B cég egy terminal/task/attachment id-ja),
 *     amit A cég session-jével próbálunk meg elérni; ennek minden esetben
 *     hibával kell elutasítódnia
 */

/** @type {TenantRpc[]} */
export const TENANT_RPCS = [
  // {
  //   name: 'mk_terminal_catalog',
  //   baseArgs: {},
  //   crossTenantArg: 'p_terminal',
  //   otherTenantValue: (companyB) => companyB.sampleTerminalId,
  // },
  // {
  //   name: 'mk_terminal_identify',
  //   baseArgs: { p_pin: '0000' },
  //   crossTenantArg: 'p_terminal',
  //   otherTenantValue: (companyB) => companyB.sampleTerminalId,
  // },
  // ... mk_terminal_event, mk_terminal_attachment_path, mk_archive_employee,
  //     mk_archive_task, mk_set_pin, stb.
];
