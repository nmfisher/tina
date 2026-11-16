#!/usr/bin/env python3
"""Generate registry.json + index.html for the static registry site.

Inputs (environment):
  OUT     site output dir (plugins/ already populated with .component.wasm)
  LAYOUT  the tina_layout_plugins package dir (for version parsing fallback)
  CATALOG tool/registry_site/catalog.json (included + planned entries)

argv[1]: the distributables manifest lines "name file-stem description"
(one per line; version comes from the package pubspec).
"""
import hashlib
from datetime import datetime, timezone
import html
import json
import os
import sys

out = os.environ["OUT"]
catalog = json.load(open(os.environ["CATALOG"]))
manifest_path = sys.argv[1]

entries = []
for line in open(manifest_path):
    parts = line.strip().split(" ", 4)
    if len(parts) != 5:
        continue
    name, version, slug, _stem, description = parts
    artifact_name = f"{slug}-{version}.component.wasm"
    # The build script copies to <slug>.component.wasm; version it here.
    src = os.path.join(out, "plugins", f"{slug}.component.wasm")
    dst = os.path.join(out, "plugins", artifact_name)
    os.replace(src, dst)
    blob = open(dst, "rb").read()
    entries.append({
        "name": name,
        "version": version,
        "description": description,
        "abi": {
            "embedder_abi": 1,
            "world": "tina:layout-app/layout-plugin@1.0.0",
        },
        "capabilities": [],
        "artifact": {
            "sha256": hashlib.sha256(blob).hexdigest(),
            "size": len(blob),
            "path": f"plugins/{artifact_name}",
        },
    })

for entry in catalog["included"]:
    entries.append({
        "name": entry["name"],
        "version": "0.10.0",
        "description": entry["description"],
        "source": "included",
        "capabilities": [],
    })
for entry in catalog["planned"]:
    entries.append({
        "name": entry["name"],
        "version": "0.0.0",
        "description": entry["description"],
        "source": "planned",
        "capabilities": [],
    })

entries.sort(key=lambda e: e["name"])
index = {
    "registry_format": 1,
    "updated": os.environ.get(
            "SITE_UPDATED",
            datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")),
    "entries": entries,
}
with open(os.path.join(out, "registry.json"), "w") as f:
    json.dump(index, f, indent=2, sort_keys=False)
    f.write("\n")

# ---- index.html: generated FROM registry.json, no framework, no deps ---------
rows = []
for e in index["entries"]:
    if e.get("source") == "included":
        badge = '<span class="badge included">included in the binary</span>'
        install = "<em>nothing to install</em>"
        cap_text = "-"
        sha = "-"
    elif e.get("source") == "planned":
        badge = '<span class="badge planned">planned</span>'
        install = "<em>not yet available</em>"
        cap_text = "-"
        sha = "-"
    else:
        badge = '<span class="badge">downloadable</span>'
        install = (
            f'<code>tina registry add {html.escape(e["name"])}</code>'
        )
        caps = e.get("capabilities") or []
        cap_text = (
            ", ".join(html.escape(c["id"]) for c in caps) if caps
            else "none (pure function)"
        )
        sha = e["artifact"]["sha256"]
        sha = f'<span class="sha" title="{sha}">{sha[:16]}&hellip;</span>'
    rows.append(f"""      <tr>
        <td><strong>{html.escape(e["name"])}</strong><br>
            <span class="ver">v{html.escape(e["version"])}</span> {badge}</td>
        <td>{html.escape(e["description"])}</td>
        <td>{cap_text}</td>
        <td>{sha}</td>
        <td>{install}</td>
      </tr>""")

page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>tina plugin registry</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 16px/1.5 system-ui, sans-serif; margin: 0 auto; max-width: 60rem; padding: 2rem 1rem; }}
  h1 {{ font-size: 1.4rem; }} h1 span {{ font-weight: 400; opacity: .7; font-size: 1rem; }}
  table {{ border-collapse: collapse; width: 100%; font-size: .9rem; }}
  th, td {{ text-align: left; padding: .5rem .6rem; border-bottom: 1px solid color-mix(in srgb, currentColor 20%, transparent); vertical-align: top; }}
  th {{ font-size: .8rem; text-transform: uppercase; letter-spacing: .04em; opacity: .7; }}
  code {{ background: color-mix(in srgb, currentColor 8%, transparent); padding: .1rem .35rem; border-radius: .3rem; font-size: .85em; }}
  .badge {{ font-size: .7rem; border: 1px solid color-mix(in srgb, currentColor 35%, transparent); border-radius: 1rem; padding: .05rem .5rem; white-space: nowrap; }}
  .badge.included {{ opacity: .8; }}
  .badge.planned {{ opacity: .8; border-style: dashed; }}
  .sha {{ font-family: ui-monospace, monospace; font-size: .8em; }}
  .ver {{ opacity: .7; font-size: .8rem; }}
  footer {{ margin-top: 2rem; font-size: .8rem; opacity: .75; }}
</style>
</head>
<body>
<h1>tina plugin registry <span>&mdash; installable components for <a href="https://github.com/nmfisher/tina">tina</a></span></h1>
<p>Every downloadable component below is integrity-checked (sha256) and the
whole index is <a href="registry.json.minisig">minisign-signed</a>; the
client refuses a bad signature or hash mismatch. Installing asks for
capability consent &mdash; provenance is not permission.</p>
<table>
  <thead><tr><th>Plugin</th><th>Description</th><th>Capabilities</th><th>sha256</th><th>Install</th></tr></thead>
  <tbody>
{chr(10).join(rows)}
  </tbody>
</table>
<footer>
  <p>Index: <a href="registry.json">registry.json</a> &middot;
  signature: <a href="registry.json.minisig">registry.json.minisig</a> &middot;
  format: registry_format&nbsp;1.</p>
</footer>
</body>
</html>
"""
with open(os.path.join(out, "index.html"), "w") as f:
    f.write(page)
print(f"registry.json: {len(entries)} entries "
      f"({sum(1 for e in entries if 'artifact' in e)} downloadable)")
