//! `registry-server`: the thin axum reference server for a static-first
//! registry root. Read-only over the directory; publishing is an offline
//! `registry-publish` step. Routes:
//! - `GET /`                  -> generated HTML index page (index.html)
//! - `GET /index.json`        -> the catalog
//! - `GET /blobs/<file>.wasm` -> content-addressed artifacts (immutable)
//! - `GET /keys/registry.pub` -> convenience copy of the public key
//! Any other static file server over the same root is equivalent.

use axum::http::{header, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use std::path::{Path, PathBuf};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (root, addr) = match args.as_slice() {
        [root] => (PathBuf::from(root), "127.0.0.1:8642".to_string()),
        [root, addr] => (PathBuf::from(root), addr.clone()),
        _ => {
            eprintln!("usage: registry-server <registry-root> [addr]");
            std::process::exit(2);
        }
    };
    let resolved = std::fs::canonicalize(&root).unwrap_or(root.clone());
    let state = Root(resolved);
    let app = Router::new()
        .route("/", get(index_page))
        .route("/index.html", get(index_page))
        .route("/index.json", get(index_json))
        .route("/keys/registry.pub", get(pubkey))
        .route("/blobs/{file}", get(blob))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .unwrap_or_else(|e| panic!("binding {addr}: {e}"));
    println!("registry-server: serving {} on http://{addr}", root.display());
    axum::serve(listener, app).await.expect("server run");
}

#[derive(Clone)]
struct Root(PathBuf);

fn safe_join(root: &Path, requested: &str) -> Option<PathBuf> {
    // Only plain file names inside a fixed subdirectory; no traversal.
    let name = Path::new(requested);
    if name.components().count() != 1 {
        return None;
    }
    let joined = root.join(name);
    joined.is_file().then_some(joined)
}

async fn index_page(axum::extract::State(root): axum::extract::State<Root>) -> Response {
    match tokio::fs::read_to_string(root.0.join("index.html")).await {
        Ok(html) => Html(html).into_response(),
        Err(_) => (StatusCode::NOT_FOUND, "index.html missing; run registry-publish").into_response(),
    }
}

async fn index_json(axum::extract::State(root): axum::extract::State<Root>) -> Response {
    match tokio::fs::read(root.0.join("index.json")).await {
        Ok(bytes) => Json(bytes).into_response(),
        Err(_) => (StatusCode::NOT_FOUND, "index.json missing").into_response(),
    }
}

async fn pubkey(axum::extract::State(root): axum::extract::State<Root>) -> Response {
    match tokio::fs::read_to_string(root.0.join("keys").join("registry.pub")).await {
        Ok(text) => (
            [(header::CONTENT_TYPE, "text/plain; charset=utf-8")],
            text,
        )
            .into_response(),
        Err(_) => (StatusCode::NOT_FOUND, "registry public key missing").into_response(),
    }
}

async fn blob(
    axum::extract::State(root): axum::extract::State<Root>,
    axum::extract::Path(file): axum::extract::Path<String>,
) -> Response {
    let Some(path) = safe_join(&root.0.join("blobs"), &file) else {
        return (StatusCode::BAD_REQUEST, "bad blob name").into_response();
    };
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
