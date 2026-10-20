// Development fixtures only. No filesystem, real rules, or cleanup execution.
const now = Math.floor(Date.now() / 1000);
export const sampleRule = { id: 'downloads', name: 'Downloads, gently', scope: { path: '/home/alex/Downloads', recursive: true }, matcher: { itemKind: 'file', exactNames: [], globPatterns: [] }, expiryBasis: 'firstObserved', lifetime: 1209600, gracePeriod: 86400, action: 'trashItem', state: 'active', matchMode: 'scoped' };
const developerRule = { ...sampleRule, id: 'developer', name: 'Developer dependencies', scope: { path: '/home/alex/Developer', recursive: true }, matcher: { itemKind: 'directory', exactNames: ['node_modules'], globPatterns: [] }, expiryBasis: 'projectActivity', lifetime: 2592000, state: 'preview' };
function explanation(path, rule, offset) { return { item: { volumeIdentifier: 'fixture-volume', resourceIdentifier: path, pathHint: path, creationTime: now - 2000000, generation: null, isPersistent: true }, scheduledAt: now + offset, eligibleAt: now + offset - 86400, rule, basis: rule.expiryBasis, basisDate: now - rule.lifetime + offset, projectContext: rule.id === 'developer' ? { identity: { volumeIdentifier: 'fixture-volume', resourceIdentifier: 'project', pathHint: '/home/alex/Developer/old-portfolio', creationTime: null, generation: null, isPersistent: true }, lastActivity: now - 3000000 } : null, itemOverride: null, suppressionReason: rule.state === 'preview' ? 'previewOnly' : null, disposition: rule.state === 'preview' ? 'preview' : 'active', globallyPaused: false }; }
export function createMock(state) {
  let policy = { rules: [structuredClone(sampleRule), structuredClone(developerRule)], overrides: [], managedRoots: [{ id: 'downloads', name: 'Downloads', path: '/home/alex/Downloads' }, { id: 'developer', name: 'Developer', path: '/home/alex/Developer' }], globallyPaused: false, pausedUntil: null, revision: 1 };
  let settings = { defaultGracePeriodSeconds: 86400, protectHiddenFiles: true, activityRetentionDays: 90 };
  const items = [['field-notes-export.zip', 3600], ['design-review.pdf', 7200], ['old-installer.exe', 86400], ['reference-images.zip', 172800], ['weekend-export.csv', 259200]].map(([name, offset]) => ({ explanation: explanation(`/home/alex/Downloads/${name}`, sampleRule, offset) }));
  items.splice(1, 0, { explanation: explanation('/home/alex/Developer/old-portfolio/node_modules', developerRule, 86400) });
  if (state === 'empty') { policy.rules = []; policy.managedRoots = []; items.length = 0; }
  const reclaimed = { lifetimeItems: 38, lifetimeBytes: 2348810240, itemsWithKnownSize: 34, firstMovedAt: now - 1209600, lastMovedAt: now - 86400, days: Array.from({length:14},(_,i)=>({ day: Math.floor(now/86400)*86400-(13-i)*86400, bytes:[0,12,35,8,0,54,18,9,30,0,16,45,26,7][i]*1048576,items:2})), weekItems: 12, weekBytes: 531628032 };
  return async (operation, args) => {
    if (state === 'error') throw new Error('Could not read the agent database. No changes were made. Check agent logs and reconnect.');
    if (state === 'offline') throw new Error('Agent is not running. Start tinyprune-daemon, then reconnect.');
    switch (operation) {
      case 'loadOverview': return structuredClone({ policy, upcoming: items.slice(0,3), rootStatuses: policy.managedRoots.map(root=>({rootId:root.id,path:root.path,state:'watching',detail:null})), reclaimed: state === 'empty' ? null : reclaimed, deadlineSummary: state === 'empty' ? {active:0,preview:0,activeSoon:0} : {active:5,preview:1,activeSoon:2}, ruleStats:[], indexedItems:state === 'empty' ? 0 : 412,databaseBytes:8192 });
      case 'loadPolicy': return structuredClone(policy);
      case 'loadSettings': return structuredClone(settings);
      case 'loadUpcoming': { const filtered = items.filter(item => (!args.ruleId || item.explanation.rule.id === args.ruleId) && (!args.disposition || item.explanation.disposition === args.disposition)); const offset = args.after ? Number(args.after.identityKey) : 0; return structuredClone({ items:filtered.slice(offset,offset+args.limit),nextCursor:offset+args.limit<filtered.length?{scheduledAt:now,identityKey:String(offset+args.limit)}:null,totalCount:filtered.length }); }
      case 'loadActivity': return state === 'empty' ? [] : [{id:'event-1',occurredAt:now-3600,kind:'movedToTrash',identity:items[0].explanation.item,ruleId:sampleRule.id,detail:'Moved to OS Trash. Space is not freed until it is emptied.',bytes:48234496,itemCount:1,explanation:items[0].explanation},{id:'event-2',occurredAt:now-7200,kind:'ruleCreated',detail:'Developer dependencies saved in Preview.',explanation:null}];
      case 'previewRule': return { matches: state==='empty'?0:3, eligibleNow:1, estimatedBytes:120586240,scannedEntries:94,truncated:false,durationSeconds:.04,samples:state==='empty'?[]:[{explanation:explanation('/home/alex/Downloads/field-notes-export.zip',args,3600),bytes:48234496}] };
      case 'saveRule': if (args.revision !== policy.revision) throw new Error('Policy changed. Reload before saving.'); policy.rules = [...policy.rules.filter(r=>r.id!==args.rule.id),structuredClone(args.rule)]; policy.revision++; return {revision:policy.revision,auditEventIds:['fixture-audit']};
      case 'setGlobalPause': policy.globallyPaused=args.paused; policy.revision++; return {revision:policy.revision,auditEventIds:['fixture-pause']};
      case 'updateSettings': settings=structuredClone(args); return {revision:policy.revision,auditEventIds:['fixture-settings']};
      default: throw new Error(`Mock operation not implemented: ${operation}`);
    }
  };
}
