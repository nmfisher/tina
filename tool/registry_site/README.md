# tina plugin registry

The static plugin registry for [tina](https://github.com/nmfisher/tina):
a catalog of installable wasm components plus the binary-embedded plugin
documentation. Served as a plain static site; every download is
integrity-checked by the client (sha256 against the signed index) and the
index itself is minisign-signed.

- `registry.json` — the index (`registry_format` 1). `tina registry list`
  renders it; `tina registry add <name>` installs from it.
- `registry.json.minisig` — the minisign signature over `registry.json`
  (legacy/raw format). Clients pin the tina release minisign key and
  refuse anything else.
- `plugins/<name>-<version>.component.wasm` — the distributable
  components. Platform-independent (one component runs on macOS and
  Linux).
- `index.html` — the human catalog page, generated FROM `registry.json`
  by `tool/build_registry_site.sh` (in the tina repo). No framework, no
  external assets.

## Rebuilding the site

From a tina checkout:

```sh
tool/build_registry_site.sh --out <site-dir> [--wasm-dart <wasm.dart checkout>]
```

The script recompiles the distributable plugins with the pinned stable
SDK, regenerates `registry.json` (names, versions, descriptions,
capabilities, sha256, artifact paths) and `index.html`, and copies the
components into `plugins/`. Regenerate `index.html` whenever
`registry.json` changes — the page is derived, never hand-edited.

## Signing (production, before every deploy)

`registry.json` must be signed with the tina release minisign key — the
same root the installer pins. In minisign's **legacy** format:

```sh
minisign -S -l -m registry.json -x registry.json.minisig -s <release-secret.key>
```

`-l` is required: tina's built-in verifier checks the raw-signature
format (pure Dart, no external tool at install time); `minisign -V`
accepts the legacy format everywhere, so the signature remains valid for
command-line verification too. A deploy without a current signature
makes every client refuse the index.

The release secret key never lives in this repository. Local testing
signs with a throwaway key:

```sh
minisign -G -W -p test.pub -s test.sec
tool/build_registry_site.sh --out dist --minisign-key test.sec
rm test.sec   # never commit, never deploy a test-signed index as production
TINA_REGISTRY_MINISIGN="$(cat test.pub)" # ...or --minisign-key "$(cat test.pub)"
```

## Deploying to Cloudflare Pages

Dashboard (git-connected, recommended):

1. Push this repository (or the `dist` tree's repo) to GitHub as
   `nmfisher/tina-registry` (public).
2. Cloudflare dashboard → Workers & Pages → Create → Pages →
   **Connect to Git** → select `nmfisher/tina-registry`.
3. Build settings: Framework preset **None**, Build command **empty**,
   Output directory **/** (the site is pre-built; `registry.json` and
   `plugins/` are committed artifacts).
4. Save and Deploy. The site serves at `https://tina-registry.pages.dev`
   (add a custom domain under Custom domains if desired).

Wrangler (direct upload):

```sh
npx wrangler pages deploy . --project-name=tina-registry
```

Run from the site root (`registry.json`, `plugins/`, `index.html` in
`.`). First-time use: `npx wrangler pages project create tina-registry`.

CI signing (later): wire the release minisign secret into the Pages
build so every deploy re-signs a freshly generated index — see the tina
repo's `.github/workflows/release.yml` minisign job for the secret
handling pattern.

## Adding a plugin

1. Build the component (stable SDK; see the tina repo's
   `tool/build_registry_site.sh`).
2. Add its entry to the script's distributables list (name, stem,
   description) — capabilities come from the plugin manifest and are
   declared in the entry.
3. Rebuild the site, sign `registry.json`, deploy.
