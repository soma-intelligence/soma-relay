import type { EngineFactory } from './engine'
import { MockEngineFactory } from './mockEngine'
import { loadWasmFactory } from './wasmEngine'

/**
 * WasmEngine when ./pkg exists and loads, else the MockEngine.
 * `?engine=mock` forces the mock (UI work only).
 */
export async function loadEngineFactory(): Promise<EngineFactory> {
  const forced = new URLSearchParams(location.search).get('engine')
  if (forced !== 'mock') {
    const wasm = await loadWasmFactory()
    if (wasm) return wasm
  }
  return MockEngineFactory
}
