//! `registry-server`: the thin axum reference server for a static-first
//! registry root. Read-only over the directory; publishing is an offline
//! `registry-publish` step. Routes:
//! - `GET /`                  -> generated HTML index page (index.html)
//! - `GET /index.json`        -> the catalog
//! - `GET /blobs/<file>.wasm` -> content-addressed artifacts (immutable)
//! - `GET /keys/registry.pub` -> convenience copy of the public key
//! Any other static file server over the same root is equivalent.

use axum::Router;
use std::path::PathBuf;

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
    let app = tina_plugin_registry::build_router(resolved);
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .unwrap_or_else(|e| panic!("binding {addr}: {e}"));
    println!("registry-server: serving {} on http://{addr}", root.display());
    axum::serve(listener, app).await.expect("server run");
}
