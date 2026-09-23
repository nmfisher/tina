# Findings: dart2wasm output runs on Cloudflare Workers

Status: spike result (verified locally against the real runtime; not yet
deployed to production). Artifact: `spikes/dart_wasm_worker/`.
Date: 2026-09-23. Companion to `docs/tina-wasm-proposal.md` (different
question — see §7).

---

## 1. Verdict

**Yes.** A Dart program compiled with `dart compile wasm` (Dart 3.12.2)
runs inside Cloudflare's Workers runtime (workerd 4.136.3 via
`wrangler dev --port 8787`, the same runtime production uses) and serves
HTTP requests:

```
$ curl http://127.0.0.1:8787/health
Hello from Dart (dart2wasm) inside Cloudflare Workers!
method: GET
url:    http://127.0.0.1:8787/health
```

The request is handled entirely by Dart: JS glue forwards the Workers
`fetch` event into a Dart function, Dart reads the request and builds the
`Response`, and the result is awaited across the JS↔wasm boundary
asynchronously.

## 2. Environment

| Component | Version |
|---|---|
| Dart SDK | 3.12.2 (stable, linux_x64) |
| wrangler | 4.136.3 (via `npx --yes wrangler@latest`, no install) |
| workerd | bundled with wrangler (local mode, no Cloudflare account) |
| Node | 22.21.1 (host for the non-workerd smoke test only) |

`wrangler dev` runs the actual workerd binary locally, so everything below
exercises production's runtime. No Cloudflare account or network access to
Cloudflare was needed.

## 3. Findings

### 3.1 workerd forbids runtime wasm code generation

The first wiring — fetch the `.wasm` as bytes, then `WebAssembly.compile()`
inside the worker — fails hard:

```
CompileError: WebAssembly.compile(): Wasm code generation disallowed by embedder
```

Consequences:

- A worker must receive its wasm as an **already-compiled
  `WebAssembly.Module`**, produced by the embedder at startup.
- **Deferred/dynamic wasm modules do not work** on Workers; a deploy is one
  static module. For the "dispatch a compiled tina instance" idea this is
  actually the right shape: the instance *is* the module, baked at
  bundle time, not data fetched at run time.

### 3.2 The working wiring is small: `CompiledWasm` + dart2wasm's own loader

`wrangler.toml`:

```toml
rules = [{ type = "CompiledWasm", globs = ["**/*.wasm"] }]
```

wrangler's `CompiledWasm` module rule imports the `.wasm` file as a
`WebAssembly.Module` that **workerd itself compiled at startup** (using its
own codegen permission, which is allowed there). The import arrives in the
worker's JS as a standard module object.

It happens that dart2wasm's generated init file (`main.mjs`) accepts a
pre-compiled module: its `instantiate(module)` takes
`WebAssembly.Module | Response | ArrayBuffer`, and it supplies the entire
`dart2wasm` import namespace (JS glue functions) plus the
`wasm:js-string` builtins polyfill itself. So the whole worker entry is:

```js
import { instantiate, invoke } from '../build/main.mjs';
import dartModule from '../build/main.wasm';

const instance = await instantiate(dartModule);
invoke(instance); // runs Dart main()

export default {
  async fetch(request, env, ctx) {
    return globalThis.__dart_fetch(request, env, ctx);
  },
};
```

(That `instantiate` export is marked DEPRECATED in favor of
`compile(bytes)` + `instantiate(compiledApp)` — but `compile()` calls
`WebAssembly.compile`, which is exactly what the embedder forbids. The
deprecated path is the sanctioned one under workerd; worth re-checking on
Dart upgrades.)

### 3.3 Async handlers need a sync `JSPromise` shim

`Function.toJS` rejects Dart function types containing `Future<T>`:

```
Error: Function converted via 'toJS' contains invalid types in its function
signature: '*Future<Response>* Function(Request, JSObject, JSObject)'
```

The pattern: export a synchronous shim whose signature uses only JS-safe
types, returning `JSPromise`; convert the real async handler with the
`.toJS` extension on `Future<JSAny?>` (note: there is no
`JSPromise.fromFuture` — the conversion lives on the Future):

```dart
Future<Response> _handler(Request request, JSObject env, JSObject ctx) async {
  /* awaits, LLM calls, tool dispatch would live here */
}

JSPromise _handlerShim(Request request, JSObject env, JSObject ctx) =>
    _handler(request, env, ctx).toJS;

void main() {
  _fetchHandler = _handlerShim.toJS;
}
```

This shim is precisely where a real tina worker would bridge the async
agent loop, so proving it was a spike goal, not an accident.

### 3.4 `external factory` on an extension type compiles to JS `new`

Constructing JS objects from dart2wasm is cleanest as an external factory:

```dart
extension type Response._(JSObject o) implements JSObject {
  external factory Response([JSAny? body]);
}
// ...
return Response(body.toJS); // compiles to `new Response(body)`
```

No `callAsConstructor` retrieval of the global constructor is needed.
(Tried first; it works on JS backends but `callAsConstructor` is absent
from `JSFunction` under dart2wasm — the external factory is the idiomatic
and portable form.)

### 3.5 Portability detail worth knowing

The wasm imports two namespaces: `dart2wasm` (JS glue supplied by
`main.mjs`) and `wasm:js-string` (string builtins; `main.mjs` provides a
JS polyfill if the embedder doesn't). Both were linked fine by workerd.
Node 22 also runs the same module unmodified — useful as a fast
no-workerd smoke test (`node test/smoke.mjs`).

## 4. Approaches tried, and where each landed

| Approach | Result |
|---|---|
| `WebAssembly.compile(bytes)` inside the worker (`Data` import rule) | Rejected by embedder — `Wasm code generation disallowed` (§3.1) |
| `CompiledWasm` import rule + dart2wasm `instantiate(module)` | **Works** — the shipped wiring |
| dart2js + ES-module worker (the `cloudflare_workers` pub package's route) | Not re-tested; package is 3 years stale, dart2wasm is the better target |
| Async Dart function exported via `.toJS` directly | Compile error — needs the `JSPromise` shim (§3.3) |
| `callAsConstructor` on the global `Response` | Compiles on JS backends; API absent under dart2wasm — use `external factory` (§3.4) |

## 5. Replicating from scratch

All files live in `spikes/dart_wasm_worker/`. To rebuild the spike
elsewhere, create these five files, then run the three commands.

**`pubspec.yaml`** — no dependencies; any SDK ≥ 3.0 works:

```yaml
name: dart_wasm_worker_spike
environment:
  sdk: ^3.0.0
```

**`bin/main.dart`**:

```dart
import 'dart:async';
import 'dart:js_interop';

extension type Request._(JSObject o) implements JSObject {
  external String get url;
  external String get method;
}

extension type Response._(JSObject o) implements JSObject {
  external factory Response([JSAny? body]);
}

@JS('__dart_fetch')
external set _fetchHandler(JSFunction f);

Future<Response> _handler(Request request, JSObject env, JSObject ctx) async {
  final body = 'Hello from Dart (dart2wasm) inside Cloudflare Workers!\n'
      'method: ${request.method}\n'
      'url:    ${request.url}\n';
  return Response(body.toJS);
}

JSPromise _handlerShim(Request request, JSObject env, JSObject ctx) =>
    _handler(request, env, ctx).toJS;

void main() {
  _fetchHandler = _handlerShim.toJS;
}
```

**`worker/index.js`** — see §3.2 for the listing.

**`wrangler.toml`**:

```toml
name = "dart-wasm-worker-spike"
main = "worker/index.js"
compatibility_date = "2025-05-05"
rules = [{ type = "CompiledWasm", globs = ["**/*.wasm"] }]
```

**`public/index.html`** — any content; proves the `[assets]` binding and
that non-matching routes can fall through to assets.

Commands:

```bash
dart compile wasm -o build/main.wasm bin/main.dart   # → build/main.wasm + build/main.mjs
node test/smoke.mjs                                   # optional, no workerd needed
npx --yes wrangler@latest dev --port 8787             # real workerd, fully local
curl http://127.0.0.1:8787/health                     # → the Dart handler's response
```

(`test/smoke.mjs` in the spike reads `build/main.wasm` as bytes and drives
`compile`/`instantiate`/`invoke` from `build/main.mjs` under plain Node —
handy in CI before the wrangler leg. wrangler needs no install and no
Cloudflare account in local mode; if `$HOME` is read-only, point its
caches elsewhere: `npm_config_cache` / `XDG_CONFIG_HOME` / `XDG_DATA_HOME`
/ `XDG_CACHE_HOME`.)

## 6. What this does *not* establish

- **A production deploy.** `wrangler deploy` needs a Cloudflare account;
  everything above is the local (but real-binary) runtime. Worker size
  limits, cold-start with a multi-MB module, and streaming responses are
  unmeasured. This spike's wasm is ~27 KB; a tina engine instance will be
  orders of magnitude larger — the plan-tier size ceiling is the next
  thing to measure and is the main scale risk.
- **Node-API/polyfill dependence.** The worker imports nothing beyond the
  wasm and JS built-ins, so no `nodejs_compat` flag was needed. Real
  code wanting `process`/`Buffer` idioms would need those flags evaluated.
- **Dart SDK upgrade stability.** The dart2wasm JS loader's API shape
  (and the DEPRECATED `instantiate(module)` path we rely on) can change
  between SDK versions; pin the SDK and re-run the spike on upgrades.

## 7. Relation to `docs/tina-wasm-proposal.md`

Different question, complementary answers. The proposal asks whether tina
*as a host* should run third-party wasm plugins (wasmtime via FFI). This
spike asks whether Dart *as a guest* compiles to a wasm module that a
production-grade embedder (workerd) will run. It partially informs the
proposal's open question #2 ("Does dart2wasm/WasmGC output run well
enough for Dart-authored plugins?") — it demonstrates the compiler emits
portable WasmGC that a second, independent engine instantiates with only
standard imports (`dart2wasm` glue + `wasm:js-string`). It does **not**
answer the wasmtime half of that question, nor the fuel/epoch/latency
concerns in §1–2 of the proposal, which remain open there.

For the Workers-dispatch idea (a compiled tina "instance" deployed as a
worker): the spike removes the platform-feasibility unknown and sets two
design constraints from §3.1 — the instance ships as one static module
compiled at deploy time, and no runtime codegen (no fetch-and-compile of
snapshots/patches inside the worker).
