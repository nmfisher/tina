//! Router-level tests: the blob route must serve content-addressed
//! artifacts (the axum 0.7 path-parameter syntax regression this guards).

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use std::path::PathBuf;
use tower::ServiceExt;
use tina_plugin_registry::RegistryLayout;

fn registry_server() -> axum::Router {
    // Reuse the server binary's router by building the same shape here;
    // the binary owns main(), so this test constructs the identical
    // router (kept in sync by this test failing on any route change).
    build_router(PathBuf::from(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/router-root"
    )))
}

// The server binary exposes its router for tests: re-declare it here is
// fragile, so the binary delegates construction to the lib instead.
use tina_plugin_registry::build_router;

#[tokio::test]
async fn blob_route_serves_and_404s_cleanly() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/router-root");
    let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    let blob = RegistryLayout::new(&root).blob_path(sha);
    std::fs::create_dir_all(blob.parent().unwrap()).unwrap();
    std::fs::write(&blob, b"artifact bytes").unwrap();

    let app = registry_server();

    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/blobs/{sha}.wasm"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let (parts, body) = response.into_parts();
    let bytes = body.collect().await.unwrap().to_bytes();
    assert_eq!(&bytes[..], b"artifact bytes");
    let _cache = parts.headers.get("cache-control").and_then(|v| v.to_str().ok()).unwrap_or("");
    assert_eq!(_cache, "public, max-age=31536000, immutable");

    // Traversal and unknown names are rejected without leaking paths.
    let traversal = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/blobs/..%2F..%2Fescape.wasm")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert!(
        traversal.status() == StatusCode::BAD_REQUEST
            || traversal.status() == StatusCode::NOT_FOUND,
        "traversal must not serve escaped paths: {}",
        traversal.status()
    );

    let missing = app
        .oneshot(
            Request::builder()
                .uri("/blobs/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.wasm")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(missing.status(), StatusCode::NOT_FOUND, "unknown blob names 404");
}

#[tokio::test]
async fn index_json_serves_raw_json() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/router-root");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("index.json"), b"{\"entries\":[]}").unwrap();
    let app = registry_server();
    let response = app
        .oneshot(
            Request::builder()
                .uri("/index.json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let (parts, body) = response.into_parts();
    let bytes = body.collect().await.unwrap().to_bytes();
    // The body must be the file itself, not a JSON-serialized byte array.
    assert_eq!(&bytes[..], b"{\"entries\":[]}");
    let content_type = parts
        .headers
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    assert!(content_type.starts_with("application/json"), "{content_type}");
}
