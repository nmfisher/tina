// Node smoke test for the compiled Dart module (no workerd involved):
// compile the wasm from bytes (dart2wasm's own loader — it supplies the
// `dart2wasm` import namespace itself), run Dart main, call the exported
// fetch handler with a fake Request.
import { readFileSync } from 'node:fs';
import { compile, instantiate, invoke } from '../build/main.mjs';

const bytes = readFileSync(new URL('../build/main.wasm', import.meta.url));
const app = await compile(bytes);
const instance = await instantiate(app);
invoke(instance); // runs Dart main → installs globalThis.__dart_fetch

const fakeRequest = {
  url: 'https://spike.invalid/health',
  method: 'GET',
};
const res = await globalThis.__dart_fetch(fakeRequest, {}, {});
console.log('dart handler said: ' + (await res.text()));
