import { createMock, mockUpdateCheck, MOCK_UI_VERSION } from './mock.js';
export function createApi({ search = globalThis.location?.search ?? '', invoke = globalThis.__TAURI__?.core?.invoke } = {}) {
  const params = new URLSearchParams(search);
  const mock = params.get('mock') === '1' ? createMock(params.get('state')) : null;
  return async function request(operation, args) {
    if (mock) return mock(operation, args);
    if (!invoke) throw new Error('Agent not connected. Open the desktop application with the local agent running. Browser development requires ?mock=1.');
    const response = await invoke('agent_request', { request: { operation, ...(args === undefined ? {} : { arguments: args }) } });
    if (response.type === 'failure') throw new Error(response.data.message);
    return response.data;
  };
}
export const api = createApi();
export const isMock = new URLSearchParams(globalThis.location?.search ?? '').get('mock') === '1';
// Version and update-check commands. The shell runs the sibling `tinyprune update check --json` CLI (a user-initiated GET only).
export function createUpdates({ search = globalThis.location?.search ?? '', invoke = globalThis.__TAURI__?.core?.invoke, delay = 400 } = {}) {
  const params = new URLSearchParams(search);
  const kind = params.get('mock') === '1' ? (params.get('update') ?? 'current') : null;
  const pause = () => new Promise(resolve => setTimeout(resolve, delay));
  const missing = () => new Error('Update checks need the desktop application.');
  return {
    async version() { if (kind) return MOCK_UI_VERSION; if (!invoke) throw missing(); return invoke('ui_version'); },
    async check() { if (kind) { await pause(); return mockUpdateCheck(kind); } if (!invoke) throw missing(); return invoke('update_check'); },
  };
}
export const updates = createUpdates();
