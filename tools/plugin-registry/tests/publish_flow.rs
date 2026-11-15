//! End-to-end publisher flow test: keygen -> add x2 -> index assembled ->
//! immutability refusal -> tamper detection. Runs the real binary via
//! CARGO_BIN_EXE.

use std::process::Command;

fn publish() -> &'static str {
    env!("CARGO_BIN_EXE_registry-publish")
}

fn run(args: &[&str]) -> (String, String, bool) {
    let output = Command::new(publish()).args(args).output().expect("binary runs");
    (
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
        output.status.success(),
    )
}

fn fixture_root() -> &'static str {
    concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures")
}

#[test]
fn keygen_add_build_and_immutability() {
    let dir = std::env::temp_dir().join("tina-registry-e2e-test");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let root = dir.join("registry");
    let key = dir.join("registry.key");

    let (out, err, ok) = run(&["keygen", key.to_str().unwrap()]);
    assert!(ok, "keygen failed: {err}");
    assert!(out.contains("public key"));

    // A real stamped component from the wasm.dart plugin_probe fixtures.
    let component = format!("{}/entity_decode.component.wasm", fixture_root());
    let meta = dir.join("entity-decode.meta.json");
    std::fs::write(
        &meta,
        r#"{
          "name": "demo/entity-decode",
          "version": "0.1.0",
          "description": "Decodes entity escapes in tool output.",
          "abi": {
            "embedder_abi": 1,
            "world": "tina:plugin-probe/plugin@0.1.0",
            "imports": ["tina:plugin-probe/engine-service@0.1.0"],
            "exports": ["tina:plugin-probe/plugin@0.1.0"]
          },
          "capabilities": [{"id": "engine-service-import", "required": true,
                            "summary": "Import the engine's mediated service."}]
        }"#,
    )
    .unwrap();
    let (out, err, ok) = run(&[
        "add",
        root.to_str().unwrap(),
        key.to_str().unwrap(),
        &component,
        meta.to_str().unwrap(),
    ]);
    assert!(ok, "add failed: {err}");
    assert!(out.contains("published demo/entity-decode 0.1.0"));

    // Same bytes again: idempotent.
    let (_, err, ok) = run(&[
        "add",
        root.to_str().unwrap(),
        key.to_str().unwrap(),
        &component,
        meta.to_str().unwrap(),
    ]);
    assert!(ok, "idempotent re-add failed: {err}");

    // Different bytes for the same (name, version): refused.
    let other = dir.join("other.component.wasm");
    std::fs::write(&other, b"different bytes").unwrap();
    let (_, err, ok) = run(&[
        "add",
        root.to_str().unwrap(),
        key.to_str().unwrap(),
        other.to_str().unwrap(),
        meta.to_str().unwrap(),
    ]);
    assert!(!ok, "collision must be refused");
    assert!(err.contains("refusing to re-publish"));

    // The index assembles, entries are signed with our key, blob hashed.
    let index = std::fs::read_to_string(root.join("index.json")).unwrap();
    let index: serde_json::Value = serde_json::from_str(&index).unwrap();
    assert_eq!(index["entries"].as_array().unwrap().len(), 1);
    assert_eq!(index["entries"][0]["name"], "demo/entity-decode");
    assert!(root.join("index.html").exists());
    assert!(root.join("keys/registry.pub").exists());

    // Tampering with the blob is caught on rebuild.
    let sha = index["entries"][0]["artifact"]["sha256"].as_str().unwrap();
    let blob = root.join("blobs").join(format!("{sha}.wasm"));
    std::fs::write(&blob, b"tampered").unwrap();
    let (_, err, ok) = run(&["build", root.to_str().unwrap(), key.to_str().unwrap()]);
    assert!(!ok, "tampered blob must fail the rebuild");
    assert!(err.contains("does not match"));
}
