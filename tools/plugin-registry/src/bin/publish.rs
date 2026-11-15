//! `registry-publish`: offline tooling for a static-first registry root.
//!
//! Subcommands:
//! - `keygen <key-file>`: fresh ed25519 seed (hex) + prints the public key.
//! - `pubkey <key-file>`: print the public key (base64, client-config form).
//! - `add <root> <key-file> <component.wasm> <meta.json>`: publish one
//!   plugin-version; refuses `(name, version)` re-publishes with different
//!   bytes; reassembles `index.json` + `index.html`.
//! - `build <root> <key-file>`: reassemble `index.json` + `index.html`
//!   from `entries/` (used after editing metadata in place).

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use tina_plugin_registry::{
    b64, canonical_json, generate_key, hex, load_signing_key, key_id, sign_entry,
    verify_entry, RegistryLayout, sha256_hex,
};

fn main() {
    if let Err(error) = run() {
        eprintln!("registry-publish: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("keygen") => {
            let key_file = expect(&args, 1, "keygen <key-file>")?;
            let public = generate_key(Path::new(&key_file))?;
            println!("public key (base64, for the client's [plugin-registry].key):");
            println!("{}", b64(public.as_bytes()));
            println!("key id: {}", key_id(&public));
            Ok(())
        }
        Some("pubkey") => {
            let key_file = expect(&args, 1, "pubkey <key-file>")?;
            let signing = load_signing_key(Path::new(&key_file))?;
            println!("{}", b64(signing.verifying_key().as_bytes()));
            Ok(())
        }
        Some("add") => {
            if args.len() != 5 {
                return Err("usage: add <root> <key-file> <component.wasm> <meta.json>".into());
            }
            add(
                Path::new(&args[1]),
                Path::new(&args[2]),
                Path::new(&args[3]),
                Path::new(&args[4]),
            )
        }
        Some("build") => {
            if args.len() != 3 {
                return Err("usage: build <root> <key-file>".into());
            }
            build(Path::new(&args[1]), Path::new(&args[2]))
        }
        _ => Err(
            "usage: registry-publish <keygen|pubkey|add|build> ...\n\
             keygen <key-file>\n\
             pubkey <key-file>\n\
             add <root> <key-file> <component.wasm> <meta.json>\n\
             build <root> <key-file>"
                .into(),
        ),
    }
}

fn expect<'a>(args: &'a [String], index: usize, usage: &str) -> Result<&'a str, String> {
    args.get(index)
        .map(String::as_str)
        .ok_or_else(|| format!("missing argument: {usage}"))
}

fn add(
    root: &Path,
    key_file: &Path,
    component: &Path,
    meta_path: &Path,
) -> Result<(), String> {
    let signing = load_signing_key(key_file)?;
    let layout = RegistryLayout::new(root);
    let bytes = std::fs::read(component)
        .map_err(|e| format!("reading {}: {e}", component.display()))?;
    let sha = sha256_hex(&bytes);
    let meta: Value = serde_json::from_slice(
        &std::fs::read(meta_path).map_err(|e| format!("reading {}: {e}", meta_path.display()))?,
    )
    .map_err(|e| format!("parsing {}: {e}", meta_path.display()))?;

    let name = meta
        .get("name")
        .and_then(Value::as_str)
        .ok_or("meta.name missing")?
        .to_string();
    let version = meta
        .get("version")
        .and_then(Value::as_str)
        .ok_or("meta.version missing")?
        .to_string();

    // Immutability: an existing entry for (name, version) must carry the
    // same artifact bytes. The entry file name sanitizes the name: slashes
    // become double underscores (a name like org/plugin must not create a
    // subdirectory).
    let entry_file_name = format!("{}-{}.json", name.replace('/', "__"), version);
    let entry_path = layout.root.join("entries").join(&entry_file_name);
    if entry_path.exists() {
        let existing: Value = serde_json::from_slice(
            &std::fs::read(&entry_path)
                .map_err(|e| format!("reading {}: {e}", entry_path.display()))?,
        )
        .map_err(|e| format!("parsing {}: {e}", entry_path.display()))?;
        let existing_sha = existing
            .pointer("/artifact/sha256")
            .and_then(Value::as_str)
            .ok_or("existing entry lacks artifact.sha256")?;
        if existing_sha != sha {
            return Err(format!(
                "refusing to re-publish {name} {version}: existing artifact {existing_sha} != new {sha} (bump the version)"
            ));
        }
    }

    // Validations the publisher owns: declared hashes match reality, grant
    // ids come from the known vocabulary, semver-shaped version.
    validate_semver(&version)?;
    validate_capabilities(&meta)?;

    let mut entry = json!({
        "name": name,
        "version": version,
        "description": meta.get("description").cloned().unwrap_or(Value::Null),
        "published": rfc3339_now(),
        "artifact": {"sha256": sha, "size": bytes.len(), "path": format!("blobs/{sha}.wasm")},
        "abi": meta.get("abi").cloned().unwrap_or(Value::Null),
        "capabilities": meta.get("capabilities").cloned().unwrap_or(json!([])),
    });
    let entry = sign_entry(entry, &signing)?;
    verify_entry(&entry, &signing.verifying_key()).expect("publisher self-check");

    std::fs::create_dir_all(layout.root.join("blobs"))
        .map_err(|e| format!("creating blobs/: {e}"))?;
    std::fs::create_dir_all(layout.root.join("entries"))
        .map_err(|e| format!("creating entries/: {e}"))?;
    std::fs::create_dir_all(layout.root.join("keys"))
        .map_err(|e| format!("creating keys/: {e}"))?;
    let blob = layout.blob_path(&sha);
    if !blob.exists() {
        std::fs::write(&blob, &bytes)
            .map_err(|e| format!("writing {}: {e}", blob.display()))?;
    }
    std::fs::write(&entry_path, serde_json::to_vec_pretty(&entry).unwrap())
        .map_err(|e| format!("writing {}: {e}", entry_path.display()))?;
    // Convenience copy of the public key for static deployments.
    std::fs::write(
        layout.keys_path(),
        format!(
            "ed25519-v1 {}\nkey id {}\n",
            b64(signing.verifying_key().as_bytes()),
            key_id(&signing.verifying_key())
        ),
    )
    .map_err(|e| format!("writing registry.pub: {e}"))?;

    build(root, key_file)?;
    println!(
        "published {} {} ({} bytes, sha256 {})",
        name,
        version,
        bytes.len(),
        &sha[..16]
    );
    Ok(())
}

fn build(root: &Path, key_file: &Path) -> Result<(), String> {
    // The key is loaded to re-verify every entry before it lands in the
    // index: a tampered entries/ directory must not assemble.
    let signing = load_signing_key(key_file)?;
    let layout = RegistryLayout::new(root);
    let mut entries = Vec::new();
    let entries_dir = layout.root.join("entries");
    let mut paths: Vec<PathBuf> = std::fs::read_dir(&entries_dir)
        .map_err(|e| format!("reading {}: {e}", entries_dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("json"))
        .collect();
    paths.sort();
    for path in paths {
        let raw = std::fs::read(&path)
            .map_err(|e| format!("reading {}: {e}", path.display()))?;
        let entry: Value = serde_json::from_slice(&raw)
            .map_err(|e| format!("parsing {}: {e}", path.display()))?;
        verify_entry(&entry, &signing.verifying_key())
            .map_err(|e| format!("entry {} fails signature: {e}", path.display()))?;
        // The blob must exist and hash to the declared value.
        let sha = entry
            .pointer("/artifact/sha256")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("entry {} lacks artifact.sha256", path.display()))?
            .to_string();
        let blob = layout.blob_path(&sha);
        let blob_bytes = std::fs::read(&blob)
            .map_err(|e| format!("reading {}: {e}", blob.display()))?;
        if sha256_hex(&blob_bytes) != sha {
            return Err(format!(
                "blob {} does not match its declared sha256",
                blob.display()
            ));
        }
        entries.push(entry);
    }
    entries.sort_by_key(|e| {
        format!(
            "{} {}",
            e.get("name").and_then(Value::as_str).unwrap_or(""),
            e.get("version").and_then(Value::as_str).unwrap_or("")
        )
    });
    let index = json!({
        "registry": "tina-plugin-registry",
        "format": 1,
        "updated": rfc3339_now(),
        "entries": entries,
    });
    std::fs::write(layout.index_path(), serde_json::to_vec_pretty(&index).unwrap())
        .map_err(|e| format!("writing index.json: {e}"))?;
    std::fs::write(layout.html_path(), render_html(&index))
        .map_err(|e| format!("writing index.html: {e}"))?;
    Ok(())
}

fn validate_semver(version: &str) -> Result<(), String> {
    let core = version.split('-').next().unwrap_or(version);
    let parts: Vec<&str> = core.split('.').collect();
    if parts.len() != 3 || parts.iter().any(|p| p.is_empty() || !p.chars().all(|c| c.is_ascii_digit())) {
        return Err(format!("version {version:?} is not core semver (x.y.z)"));
    }
    Ok(())
}

/// The grant ids the host understands today (policy.rs PLUGIN_GRANTS) plus
/// the consent surfaces from the design (§4). Publishing an unknown id is a
/// publisher error.
const KNOWN_CAPABILITY_IDS: [&str; 6] = [
    "session.read-context",
    "engine-service-import",
    "engine-service-call",
    "session-store",
    "filesystem",
    "network",
];

fn validate_capabilities(meta: &Value) -> Result<(), String> {
    let Some(capabilities) = meta.get("capabilities").and_then(Value::as_array) else {
        return Ok(());
    };
    for capability in capabilities {
        let id = capability
            .get("id")
            .and_then(Value::as_str)
            .ok_or("capability without an id")?;
        if !KNOWN_CAPABILITY_IDS.contains(&id) {
            return Err(format!("unknown capability id {id:?}"));
        }
        // Every id-specific parameter must be one of the schema's.
        let allowed: &[&str] = match id {
            "session-store" => &["access", "required", "summary"],
            "filesystem" => &["mode", "paths", "required", "summary"],
            "network" => &["domains", "required", "summary"],
            _ => &["required", "summary"],
        };
        for key in capability.as_object().map(|m| m.keys()).into_iter().flatten() {
            if key == "id" {
                continue;
            }
            if !allowed.contains(&key.as_str()) {
                return Err(format!("capability {id:?} has unexpected field {key:?}"));
            }
        }
    }
    Ok(())
}

fn rfc3339_now() -> String {
    // Seconds-precision UTC RFC3339 without pulling a time crate: derive it
    // from `date -u` when available, else fall back to unix seconds.
    if let Ok(output) = std::process::Command::new("date").arg("-u").arg("+%Y-%m-%dT%H:%M:%SZ").output() {
        if output.status.success() {
            let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !text.is_empty() {
                return text;
            }
        }
    }
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("unix-{seconds}")
}

fn render_html(index: &Value) -> String {
    let mut rows = String::new();
    if let Some(entries) = index.get("entries").and_then(Value::as_array) {
        for entry in entries {
            let name = entry.get("name").and_then(Value::as_str).unwrap_or("?");
            let version = entry.get("version").and_then(Value::as_str).unwrap_or("?");
            let description = entry
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or("");
            let sha = entry.pointer("/artifact/sha256").and_then(Value::as_str).unwrap_or("?");
            let size = entry.pointer("/artifact/size").and_then(Value::as_u64).unwrap_or(0);
            let mut capabilities = String::new();
            if let Some(list) = entry.get("capabilities").and_then(Value::as_array) {
                let items: Vec<String> = list
                    .iter()
                    .filter_map(|c| Some(canonical_grant_string(c).ok()?))
                    .collect();
                capabilities = items.join(", ");
            }
            rows.push_str(&format!(
                "<tr><td><strong>{name}</strong></td><td>{version}</td>\
                 <td>{description}</td><td><code>{capabilities}</code></td>\
                 <td><code>{}</code></td><td class=\"num\">{size}</td></tr>\n",
                &sha[..sha.len().min(16)]
            ));
        }
    }
    let updated = index.get("updated").and_then(Value::as_str).unwrap_or("?");
    format!(
        "<!doctype html>\n<html><head><meta charset=\"utf-8\">\
         <title>Tina plugin registry</title>\
         <style>body{{font-family:system-ui,sans-serif;margin:2rem;max-width:72rem}}\
         table{{border-collapse:collapse;width:100%}}td,th{{border:1px solid #ccc;padding:.4rem;text-align:left}}\
         code{{font-size:.85em}}.num{{text-align:right}}</style></head><body>\
         <h1>Tina plugin registry</h1>\
         <p>Static-first registry; updated {updated}. Verify signatures client-side.</p>\
         <table><thead><tr><th>Name</th><th>Version</th><th>Description</th>\
         <th>Capabilities</th><th>Artifact</th><th>Size</th></tr></thead>\
         <tbody>\n{rows}</tbody></table>\
         <p><a href=\"index.json\">index.json</a> · \
         <a href=\"keys/registry.pub\">registry public key</a></p>\
         </body></html>\n"
    )
}

/// The canonical grant string for a capability object: `<id>` when no
/// parameters, otherwise `<id>:<key>=<value>[,...]` with keys and values
/// sorted. Mirrors the Dart client's encoder byte for byte.
pub fn canonical_grant_string(capability: &Value) -> Result<String, String> {
    let map = capability
        .as_object()
        .ok_or("capability must be an object")?;
    let id = map
        .get("id")
        .and_then(Value::as_str)
        .ok_or("capability without an id")?;
    let mut params: Vec<(String, String)> = Vec::new();
    for (key, value) in map {
        if key == "id" || key == "required" || key == "summary" {
            continue;
        }
        let encoded = match value {
            Value::String(s) => s.clone(),
            other => canonical_json(other),
        };
        params.push((key.clone(), encoded));
    }
    params.sort();
    if params.is_empty() {
        return Ok(id.to_string());
    }
    let joined = params
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join(",");
    Ok(format!("{id}:{joined}"))
}
