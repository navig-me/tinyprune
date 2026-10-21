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
