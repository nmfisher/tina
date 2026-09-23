// JS glue between Cloudflare Workers and the dart2wasm module.
//
// workerd loads this file as the worker's ES module entry. The wasm is
// imported as a pre-compiled WebAssembly.Module (wrangler `CompiledWasm`
// rule — workerd compiles it at startup; runtime WebAssembly.compile is
// disallowed in the embedder). dart2wasm's `instantiate()` accepts a
// compiled module, links the `dart2wasm` imports + js-string polyfill
// itself, and Dart main installs `__dart_fetch` on the global.
import { instantiate, invoke } from '../build/main.mjs';
import dartModule from '../build/main.wasm';

const instance = await instantiate(dartModule);
invoke(instance);

export default {
  async fetch(request, env, ctx) {
    return globalThis.__dart_fetch(request, env, ctx);
  },
};
