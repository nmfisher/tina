# dart2wasm → Cloudflare Workers spike

**Verdict: it runs.** A Dart fetch handler compiled with `dart compile wasm`
was served by the real Workers runtime (workerd, via `wrangler dev` — the
same runtime production uses):

```
$ curl http://127.0.0.1:8787/health
Hello from Dart (dart2wasm) inside Cloudflare Workers!
method: GET
url:    http://127.0.0.1:8787/health
```

## Findings (the stuff only a spike reveals)

1. **Runtime wasm compilation is banned in workerd.**
   `WebAssembly.compile(bytes)` inside a worker fails with
   `CompileError: Wasm code generation disallowed by embedder`. So a naive
   "fetch .wasm bytes and compile" loader does not work.
2. **The working wiring: compile at startup, link via imports.**
   - `wrangler.toml`: `rules = [{ type = "CompiledWasm", globs = ["**/*.wasm"] }]`
     → the `.wasm` import arrives as a `WebAssembly.Module` compiled by
     workerd itself (its own codegen permission, at startup).
   - dart2wasm's generated `main.mjs` `instantiate(module)` accepts a
     pre-compiled module and supplies the `dart2wasm` imports and the
     `wasm:js-string` polyfill itself. So `index.js` is ~5 lines.
   - Consequence: **no deferred/dynamic wasm modules** on Workers — a single
     static module only. Fine for a self-contained agent instance.
3. **Async handlers need a `JSPromise` shim.** `Function.toJS` rejects
   `Future<T>` in signatures; export a sync shim returning
   `future.toJS` (`Future<JSAny?>.toJS` → `JSPromise`). Same pattern any
   awaited tool/LLM call would use.
4. **`external factory` on an extension type = JS `new`.**
   `external factory Response([JSAny? body])` compiles to `new Response(...)`
   on dart2wasm — no `callAsConstructor` gymnastics needed.

## Layout

    bin/main.dart     Dart fetch handler, exported as global `__dart_fetch`
    worker/index.js   ES-module worker entry (~5 lines, see Findings #2)
    public/           asset served at / (proves [assets] fallthrough works)
    wrangler.toml     CompiledWasm rule + assets binding
    test/smoke.mjs    Node smoke test (no workerd needed)
    tool/build.dart   dart compile wasm + node smoke

## Run it

    dart run tool/build.dart                  # compile + node smoke test
    npx --yes wrangler@latest dev --port 8787 # real workerd, fully local
    curl http://127.0.0.1:8787/health         # → the Dart handler's response

Node ≥ 20 runs the smoke test as-is (dart2wasm's loader reads the wasm as
bytes and supplies its own import object — no experimental flags needed).

## Not yet proven

- **A production deploy** (`wrangler deploy` needs a Cloudflare account).
  Local `wrangler dev` runs the real workerd binary, so production behavior
  is expected to match — but it hasn't been clicked through.
- **Size**: this wasm is ~27 KB. A tina engine instance will be orders of
  magnitude larger; the worker size limit (a few MB gzipped depending on
  plan) is untested with a real bundle.
