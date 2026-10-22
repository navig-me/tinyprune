export const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const bytes = value => value == null ? 'Not measured' : value >= 1073741824 ? `${(value / 1073741824).toFixed(1)} GB` : value >= 1048576 ? `${(value / 1048576).toFixed(1)} MB` : `${value} B`;
export const date = value => value == null ? 'Not applicable / unavailable' : new Date(value * 1000).toLocaleString(undefined, {month:'short',day:'numeric',hour:'numeric',minute:'2-digit'});
export function readRule(form, existing = {}) {
  const values = new FormData(form);
  return { id: existing.id ?? crypto.randomUUID(), name: String(values.get('name')).trim(), scope: {path: String(values.get('path')).trim(),recursive:values.has('recursive')}, matcher: {itemKind:values.get('kind'),exactNames:existing.matcher?.exactNames ?? [],globPatterns:[...(String(values.get('glob')).trim() ? [String(values.get('glob')).trim()] : []),...(existing.matcher?.globPatterns.slice(1) ?? [])]}, expiryBasis:values.get('basis'),lifetime:Number(values.get('days'))*86400,gracePeriod:existing.gracePeriod ?? null,action:existing.action ?? 'trashItem',state:'preview',matchMode:existing.matchMode ?? 'scoped' };
}
export function sparklineDays(days, today = Math.floor(Date.now()/86400000)*86400) {
  const byDay = new Map(days.map(day => [day.day,day.bytes]));
  return Array.from({length:14},(_,i)=>({day:today-(13-i)*86400,bytes:byDay.get(today-(13-i)*86400)??0}));
}
// Interprets the stdout of `tinyprune update check --json` (tinyprune-update cli.rs) for the Settings page.
// The updater, not the UI, verifies the signed feed; this only turns its answer into plain wording.
const UPDATE_ERRORS = {
  unavailable: 'Could not reach the update server. Check your internet connection and try again. Nothing was changed.',
  feedRejected: 'The update information could not be verified, so it was ignored. Nothing was changed.',
  stateUnavailable: 'The update state on this computer could not be read or saved. Nothing was changed.',
};
export function interpretUpdateCheck(raw) {
  let result;
  try { result = JSON.parse(raw); } catch { result = null; }
  if (!result || typeof result !== 'object') return { state: 'error', message: 'The update check gave an answer TinyPrune could not read. Nothing was changed.' };
  switch (result.status) {
    case 'upToDate': return { state: 'upToDate', message: result.installedVersion ? `TinyPrune ${result.installedVersion} is up to date.` : 'TinyPrune is up to date.' };
    case 'available': return { state: 'available', version: String(result.version), build: result.build, sizeBytes: result.sizeBytes ?? null, notesUrl: result.notesUrl ?? null, installCommand: result.installCommand ?? null, message: `TinyPrune ${result.version} is available.` };
    case 'unsupported': return { state: 'unsupported', message: 'No update is published for this platform yet.' };
    case 'disabled': return { state: 'disabled', message: `Updates are turned off for this copy. ${result.message ?? ''}`.trim() };
    default: return { state: 'error', message: UPDATE_ERRORS[result.code] ?? result.message ?? 'The update check failed. Nothing was changed.' };
  }
}
