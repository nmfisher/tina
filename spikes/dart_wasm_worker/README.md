Spike: does dart2wasm output run inside Cloudflare Workers (workerd)?

Layout
  bin/main.dart     Dart fetch handler, exported to JS as `__dart_fetch`
  worker/index.js   ES-module worker entry: instantiates the wasm, forwards fetch
  public/           asset served at / to prove the handler is hit on other paths
  wrangler.toml     workerd config (`wrangler dev` runs fully local, no account)

Build + run
  dart run tool/build.dart
  npx --yes wrangler@latest dev --local --port 8787
  curl http://127.0.0.1:8787/health
