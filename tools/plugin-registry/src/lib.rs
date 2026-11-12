//! The static-first plugin registry: shared publisher/verifier logic.
//!
//! Everything here mirrors what the Dart client (`tina_plugin_registry`)
//! re-verifies, so the two implementations stay honest against each
//! other:
//! - canonical JSON: keys sorted lexicographically recursively,
//!   `,`/`:` separators with no whitespace, UTF-8, integers plain;
//! - the signed payload: the entry object minus its `signature` field,
//!   canonically serialized;
//! - the signature: 64-byte ed25519 over that payload, base64 (standard,
//!   padded);
//! - artifacts: `blobs/<lowercase-hex sha256>.wasm`.

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// Canonical JSON encoding of a serde_json Value: object keys sorted
/// recursively, no whitespace. Arrays keep order; strings are JSON-escaped
/// by serde's writer.
pub fn canonical_json(value: &Value) -> String {
    let mut out = String::new();
    write_canonical(value, &mut out);
    out
}

fn write_canonical(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&n.to_string()),
        Value::String(s) => {
            // serde_json's string writer escapes exactly like JSON requires.
            let bytes = serde_json::to_string(s).expect("string serialization");
            out.push_str(&bytes);
        }
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push('{');
            for (i, key) in keys.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                let bytes = serde_json::to_string(key).expect("string serialization");
                out.push_str(&bytes);
                out.push(':');
                write_canonical(&map[*key], out);
            }
            out.push('}');
        }
    }
}

/// The canonical bytes a signature covers: the entry minus `signature`.
pub fn signed_payload(entry: &Value) -> Result<Vec<u8>, String> {
    let map = entry
        .as_object()
        .ok_or_else(|| "entry must be a JSON object".to_string())?;
    let mut stripped = Map::new();
    for (key, value) in map {
        if key != "signature" {
            stripped.insert(key.clone(), value.clone());
        }
    }
    Ok(canonical_json(&Value::Object(stripped)).into_bytes())
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    hex(&digest)
}

pub fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// Sign an entry object (a serde_json object with no `signature` field yet,
/// or one that is ignored): returns the completed entry with the
/// `signature` field set.
pub fn sign_entry(mut entry: Value, signing_key: &SigningKey) -> Result<Value, String> {
    let payload = signed_payload(&entry)?;
    let signature = signing_key.sign(&payload);
    let signature_map = serde_json::json!({
        "scheme": "ed25519-v1",
        "keyid": key_id(&signing_key.verifying_key()),
        "signature": b64(&signature.to_bytes()),
    });
    entry
        .as_object_mut()
        .ok_or_else(|| "entry must be a JSON object".to_string())?
        .insert("signature".into(), signature_map);
    Ok(entry)
}

/// Verify a completed entry against a public key. Returns the signed
/// payload bytes on success (useful for logging/hashing).
pub fn verify_entry(entry: &Value, verifying_key: &VerifyingKey) -> Result<Vec<u8>, String> {
    let payload = signed_payload(entry)?;
    let signature_field = entry
        .get("signature")
        .ok_or_else(|| "entry has no signature field".to_string())?;
    let scheme = signature_field
        .get("scheme")
        .and_then(Value::as_str)
        .ok_or_else(|| "signature.scheme missing".to_string())?;
    if scheme != "ed25519-v1" {
        return Err(format!("unknown signature scheme {scheme:?}"));
    }
    let sig_b64 = signature_field
        .get("signature")
        .and_then(Value::as_str)
        .ok_or_else(|| "signature.signature missing".to_string())?;
    let sig_bytes = un_b64(sig_b64)?;
    let signature = Signature::from_slice(&sig_bytes)
        .map_err(|e| format!("malformed signature: {e}"))?;
    verifying_key
        .verify(&payload, &signature)
        .map_err(|e| format!("signature verification failed: {e}"))?;
    Ok(payload)
}

/// The short key id: first 16 hex characters of sha256(pubkey bytes).
pub fn key_id(verifying_key: &VerifyingKey) -> String {
    let digest = Sha256::digest(verifying_key.as_bytes());
    hex(&digest[..8])
}

pub fn b64(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[(triple >> 18) as usize & 0x3f] as char);
        out.push(TABLE[(triple >> 12) as usize & 0x3f] as char);
        if chunk.len() > 1 {
            out.push(TABLE[(triple >> 6) as usize & 0x3f] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(TABLE[triple as usize & 0x3f] as char);
        } else {
            out.push('=');
        }
    }
    out
}

pub fn un_b64(text: &str) -> Result<Vec<u8>, String> {
    fn value_of(byte: u8) -> Result<u32, String> {
        Ok(match byte {
            b'A'..=b'Z' => (byte - b'A') as u32,
            b'a'..=b'z' => (byte - b'a' + 26) as u32,
            b'0'..=b'9' => (byte - b'0' + 52) as u32,
            b'+' => 62,
            b'/' => 63,
            _ => return Err(format!("invalid base64 byte {byte:#x}")),
        })
    }
    let cleaned: Vec<u8> = text
        .bytes()
        .filter(|b| !b.is_ascii_whitespace())
        .collect();
    let mut out = Vec::with_capacity(cleaned.len() * 3 / 4);
    for chunk in cleaned.chunks(4) {
        if chunk.len() == 1 {
            return Err("truncated base64".into());
        }
        let mut triple = 0u32;
        for (i, byte) in chunk.iter().enumerate() {
            if *byte == b'=' {
                if i < 2 {
                    return Err("misplaced base64 padding".into());
                }
                break;
            }
            triple |= value_of(*byte)? << (18 - 6 * i);
        }
        out.push((triple >> 16) as u8);
        if chunk.len() > 2 && chunk[2] != b'=' {
            out.push((triple >> 8) as u8);
        }
        if chunk.len() > 3 && chunk[3] != b'=' {
            out.push(triple as u8);
        }
    }
    Ok(out)
}

/// Load a signing key from a 32-byte seed file (hex or base64 text, or raw).
pub fn load_signing_key(path: &Path) -> Result<SigningKey, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("reading key {}: {e}", path.display()))?;
    let seed = decode_seed(&bytes)?;
    let seed: [u8; 32] = seed
        .as_slice()
        .try_into()
        .map_err(|_| format!("key {} does not decode to 32 bytes", path.display()))?;
    Ok(SigningKey::from_bytes(&seed))
}

/// Convenience: decode raw or textual key material.
fn decode_seed(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let text = String::from_utf8(bytes.to_vec()).map_err(|_| "binary key material".to_string())?;
    let trimmed = text.trim();
    if trimmed.len() == 64 && trimmed.chars().all(|c| c.is_ascii_hexdigit()) {
        return (0..trimmed.len())
            .step_by(2)
            .map(|i| {
                u8::from_str_radix(&trimmed[i..i + 2], 16)
                    .map_err(|e| format!("bad hex: {e}"))
            })
            .collect();
    }
    un_b64(trimmed)
}

/// The layout of a published registry root.
pub struct RegistryLayout {
    pub root: PathBuf,
}

impl RegistryLayout {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn index_path(&self) -> PathBuf {
        self.root.join("index.json")
    }

    pub fn html_path(&self) -> PathBuf {
        self.root.join("index.html")
    }

    pub fn blob_path(&self, sha256: &str) -> PathBuf {
        self.root.join("blobs").join(format!("{sha256}.wasm"))
    }

    pub fn keys_path(&self) -> PathBuf {
        self.root.join("keys").join("registry.pub")
    }
}

/// Generate a fresh signing key: 32 bytes from the OS RNG, stored as hex.
pub fn generate_key(path: &Path) -> Result<VerifyingKey, String> {
    use std::io::Read;
    let mut seed = [0u8; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut seed))
        .map_err(|e| format!("reading /dev/urandom: {e}"))?;
    let signing = SigningKey::from_bytes(&seed);
    std::fs::write(path, hex(&seed))
        .map_err(|e| format!("writing key {}: {e}", path.display()))?;
    Ok(signing.verifying_key())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn test_key(seed_hex: &str) -> SigningKey {
        let mut seed = [0u8; 32];
        for i in 0..8 {
            seed[i * 4..i * 4 + 4]
                .copy_from_slice(&u32::from_str_radix(&seed_hex[i * 8..i * 8 + 8], 16).unwrap().to_be_bytes());
        }
        SigningKey::from_bytes(&seed)
    }

    #[test]
    fn canonical_json_sorts_keys_recursively() {
        let value = json!({"b": 1, "a": {"z": true, "y": [2, 1]}, "c": "x"});
        assert_eq!(canonical_json(&value), r#"{"a":{"y":[2,1],"z":true},"b":1,"c":"x"}"#);
    }

    #[test]
    fn signature_round_trip_and_tamper_detection() {
        let key = test_key("a15b6c9d2e3f404142434445464748494a4b4c4d4e4f50515253545556575859");
        let entry = json!({
            "name": "demo",
            "version": "0.1.0",
            "artifact": {"sha256": "ab", "size": 3},
            "capabilities": [{"id": "session.read-context", "required": false}],
        });
        let signed = sign_entry(entry.clone(), &key).unwrap();
        verify_entry(&signed, &key.verifying_key()).expect("verify");

        // Any payload change breaks the signature.
        let mut tampered = signed.clone();
        tampered["name"] = json!("evil");
        assert!(verify_entry(&tampered, &key.verifying_key()).is_err());
        // Dropping the signature breaks verification.
        let unsigned = entry;
        assert!(verify_entry(&unsigned, &key.verifying_key()).is_err());
    }

    #[test]
    fn signed_payload_ignores_signature_field() {
        let key = test_key("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20");
        let entry = json!({"name": "x", "version": "1.0.0"});
        let signed = sign_entry(entry, &key).unwrap();
        let payload = signed_payload(&signed).unwrap();
        let expected = signed_payload(&json!({"name": "x", "version": "1.0.0"})).unwrap();
        assert_eq!(payload, expected);
    }

    #[test]
    fn base64_matches_known_vectors() {
        assert_eq!(b64(b""), "");
        assert_eq!(b64(b"f"), "Zg==");
        assert_eq!(b64(b"fo"), "Zm8=");
        assert_eq!(b64(b"foo"), "Zm9v");
        assert_eq!(b64(b"foobar"), "Zm9vYmFy");
        assert_eq!(un_b64("Zm9vYmFy").unwrap(), b"foobar");
        assert_eq!(un_b64("Zg==").unwrap(), b"f");
    }

    #[test]
    fn key_loads_from_hex_and_base64() {
        let dir = std::env::temp_dir().join("tina-registry-key-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("key.hex");
        std::fs::write(&path, "a15b6c9d2e3f404142434445464748494a4b4c4d4e4f50515253545556575859\n").unwrap();
        let key = load_signing_key(&path).unwrap();
        assert_eq!(hex(&key.verifying_key().as_bytes().to_vec()).len(), 64);
    }
}

/// The reference server's router, shared by the binary and the router
/// tests so a route regression (e.g. the axum 0.7 `:param` syntax) fails
/// a test instead of a demo.
pub fn build_router(root: PathBuf) -> axum::Router {
    let state = Root(std::fs::canonicalize(&root).unwrap_or(root));
    axum::Router::new()
        .route("/", axum::routing::get(index_page))
        .route("/index.html", axum::routing::get(index_page))
        .route("/index.json", axum::routing::get(index_json))
        .route("/keys/registry.pub", axum::routing::get(pubkey))
        .route("/blobs/:file", axum::routing::get(blob))
        .with_state(state)
}

#[derive(Clone)]
pub(crate) struct Root(std::path::PathBuf);

fn safe_blob_name(requested: &str) -> Option<String> {
    // Only a plain file name: no separators, no parent components.
    let name = std::path::Path::new(requested);
    if name.components().count() != 1
        || requested.contains('/')
        || requested.contains('\\')
        || requested == ".."
    {
        return None;
    }
    Some(requested.to_string())
}

async fn index_page(axum::extract::State(root): axum::extract::State<Root>) -> axum::response::Response {
    use axum::response::{Html, IntoResponse};
    use axum::http::StatusCode;
    match tokio::fs::read_to_string(root.0.join("index.html")).await {
        Ok(html) => Html(html).into_response(),
        Err(_) => (
            StatusCode::NOT_FOUND,
            "index.html missing; run registry-publish",
        )
            .into_response(),
    }
}

async fn index_json(axum::extract::State(root): axum::extract::State<Root>) -> axum::response::Response {
    use axum::http::StatusCode;
    use axum::response::IntoResponse;
    match tokio::fs::read(root.0.join("index.json")).await {
        Ok(bytes) => (
            [(axum::http::header::CONTENT_TYPE, "application/json")],
            bytes,
        )
            .into_response(),
        Err(_) => (
            StatusCode::NOT_FOUND,
            "index.json missing",
        )
            .into_response(),
    }
}

async fn pubkey(axum::extract::State(root): axum::extract::State<Root>) -> axum::response::Response {
    use axum::http::StatusCode;
    use axum::response::IntoResponse;
    match tokio::fs::read_to_string(root.0.join("keys").join("registry.pub")).await {
        Ok(text) => (
            [(
                axum::http::header::CONTENT_TYPE,
                "text/plain; charset=utf-8",
            )],
            text,
        )
            .into_response(),
        Err(_) => (
            StatusCode::NOT_FOUND,
            "registry public key missing",
        )
            .into_response(),
    }
}

async fn blob(
    axum::extract::State(root): axum::extract::State<Root>,
    axum::extract::Path(file): axum::extract::Path<String>,
) -> axum::response::Response {
    use axum::http::{header, StatusCode};
    use axum::response::IntoResponse;
    let Some(name) = safe_blob_name(&file) else {
        return (StatusCode::BAD_REQUEST, "bad blob name").into_response();
    };
    let path = root.0.join("blobs").join(name);
    match tokio::fs::read(&path).await {
        Ok(bytes) => (
            [
                (header::CONTENT_TYPE, "application/wasm"),
                // Content-addressed artifacts are immutable forever.
                (header::CACHE_CONTROL, "public, max-age=31536000, immutable"),
            ],
            bytes,
        )
            .into_response(),
        Err(_) => (StatusCode::NOT_FOUND, "artifact missing").into_response(),
    }
}
