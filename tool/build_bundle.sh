#!/usr/bin/env bash
#
# Build the tina CLI bundle (bin/tina + lib/libnotcurses_merged.so) for one
# or all target platforms, into build/cli/<os>_<arch>/bundle/.
#
# Targets:
#   linux-arm64   Docker (tool/docker/linux.Dockerfile, --platform linux/arm64)
#   linux-x64     Docker (--platform linux/amd64; QEMU-emulated on Apple Silicon)
#   macos-arm64   native `dart build` on the host (Docker can't build macOS binaries)
#   all           every target above (macos-arm64 only when run on macOS)
#   host          (default) the host's own platform
#
# Linux builds run in the image's own filesystem (no bind-mount); the bundle is
# extracted with docker create + cp — mirroring packages/dart_notcurses/tool.
# macOS builds need a local Dart SDK >=3.12 (tina's pubspec requires it; e.g.
# a recent Flutter ships one). Run from the repo root.
#
# Prereqs for each platform's notcurses archive must already be staged under
# packages/dart_notcurses/native/lib/<os>_<arch>/ (see
# packages/dart_notcurses/tool/build_notcurses*.sh). Currently: linux_arm64,
# linux_x64, macos_arm64.
#
# Usage:
#   ./tool/build_bundle.sh                 # host platform
#   ./tool/build_bundle.sh linux-arm64
#   ./tool/build_bundle.sh all
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_TAG="tina-bundle:latest"

err() { echo "error: $*" >&2; exit 1; }

build_linux() {
  local dart_arch="$1" platform="$2"   # dart_arch: arm64|x64
  local out_dir="$REPO_ROOT/build/cli/linux_${dart_arch}"
  command -v docker >/dev/null 2>&1 || err "docker not found in PATH"
  # The T7 volume litters AppleDouble ._ sidecars that break Docker's context
  # sender (xattr EPERM); remove them before building.
  find "$REPO_ROOT" -name '._*' -delete 2>/dev/null || true
  echo "==> building linux/${dart_arch} bundle (Docker, $platform)"
  docker build --platform "$platform" \
    -t "$IMAGE_TAG" \
    -f "$SCRIPT_DIR/docker/linux.Dockerfile" \
    "$REPO_ROOT"
  local cid; cid="$(docker create --platform "$platform" "$IMAGE_TAG")"
  rm -rf "$out_dir/bundle"
  mkdir -p "$out_dir"
  docker cp "$cid:/work/build/cli/linux_${dart_arch}/bundle" "$out_dir/bundle"
  docker rm "$cid" >/dev/null 2>&1 || true
  # docker cp onto this volume litters AppleDouble ._ sidecars; drop them so the
  # bundle is clean for downstream consumers.
  find "$out_dir/bundle" -name '._*' -delete 2>/dev/null || true
  echo "==> staged $out_dir/bundle"
  ( cd "$out_dir/bundle" && find . -type f -exec ls -lh {} \; )
}

build_macos_arm64() {
  command -v dart >/dev/null 2>&1 || err "dart not found in PATH (need Dart >=3.12)"
  [ "$(uname -s)" = "Darwin" ] || err "macos-arm64 must be built on macOS"
  echo "==> building macos/arm64 bundle (native)"
  # Regenerate lib/version.g.dart from the pubspec first so the compiled
  # binary carries the release version (the Docker path does the same).
  ( cd "$REPO_ROOT" && dart pub get \
    && dart run tool/generate_version.dart "$REPO_ROOT" \
    && dart build cli -t bin/tina.dart )
  echo "==> staged $REPO_ROOT/build/cli/macos_arm64/bundle"
}

host_target() {
  case "$(uname -s)/$(uname -m)" in
    Darwin/arm64)   echo macos-arm64 ;;
    Linux/aarch64)  echo linux-arm64 ;;
    Linux/x86_64)   echo linux-x64 ;;
    *) err "unrecognized host: $(uname -s)/$(uname -m)" ;;
  esac
}

run_target() {
  case "$1" in
    linux-arm64) build_linux arm64 linux/arm64 ;;
    linux-x64)   build_linux x64   linux/amd64 ;;
    macos-arm64) build_macos_arm64 ;;
    *) err "unknown target: $1 (want linux-arm64|linux-x64|macos-arm64|all|host)" ;;
  esac
}

target="${1:-host}"
if [ "$target" = "host" ]; then
  target="$(host_target)"
  echo "==> host target: $target"
fi

if [ "$target" = "all" ]; then
  run_target linux-arm64
  run_target linux-x64
  if [ "$(uname -s)" = "Darwin" ]; then
    run_target macos-arm64
  else
    echo "(skipping macos-arm64: not on macOS)"
  fi
else
  run_target "$target"
fi

echo "==> done. bundles under $REPO_ROOT/build/cli/"
