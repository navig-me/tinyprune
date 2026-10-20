import { createMock } from './mock.js';
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
