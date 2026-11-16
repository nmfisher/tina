#!/bin/sh
# Build the static registry site (the public nmfisher/tina-registry tree):
#   registry.json + registry.json.minisign at the root
#   plugins/<name>-<version>.component.wasm
#   index.html (generated FROM registry.json), README.md
#
# Distributables today: the three layout strategy components (solver,
# focus, hang - packages/plugins/tina_layout_plugins, stable SDK build).
# The 14 binary-embedded engine plugins and the planned update-tui are
# catalog entries only ("source": "included" / no artifact).
#
# Signing: production signs registry.json with the tina release minisign
# key (Nick, before deploy):
#   minisign -S -l -m registry.json -x registry.json.minisig -s <release.sec>
# (LEGACY format -l is required: the in-client verifier is pure Dart and
# verifies the raw-signature format; minisign -V accepts it everywhere.)
# Locally, pass --minisign-key <test.sec> to sign with a throwaway key
# for the loopback acceptance test - the test key never leaves the
# machine and is not copied into the site tree.
#
# Usage:
#   tool/build_registry_site.sh [--out DIR] [--wasm-dart DIR]
#                               [--minisign-key SEC_KEY_FILE] [--skip-build]
#   DART          pinned stable SDK dart (default: $HOME/tools/... then PATH)
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/build/registry-site"

SKIP_BUILD=0
SIGN_KEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --wasm-dart) WASM_DART_CLI="$2"; shift 2 ;;
    --minisign-key) SIGN_KEY="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

DART="${DART:-$(command -v dart || true)}"
DART="${DART:-$HOME/tools/dart-sdk-3.14.0-stable/bin/dart}"
[ -x "$DART" ] || { echo "no dart (set DART=)" >&2; exit 1; }

WASM_DART="${WASM_DART_CLI:-${WASM_DART:-$ROOT/wasm.dart}}"
[ -d "$WASM_DART/pkg/wasm_tools" ] || WASM_DART=/tmp/m3-wasmdart
[ -d "$WASM_DART/pkg/wasm_tools" ] || { echo "no wasm.dart checkout (--wasm-dart)" >&2; exit 1; }

LAYOUT="$ROOT/packages/plugins/tina_layout_plugins"
[ -f "$LAYOUT/pubspec.yaml" ] || { echo "missing $LAYOUT (layout plugins package)" >&2; exit 1; }

# --- 1. rebuild the distributable components (stable SDK) ---------------------
if [ "$SKIP_BUILD" = 0 ]; then
  echo "=== rebuilding layout components (stable SDK, wasm_tools compile)"
  OVERRIDES="$LAYOUT/pubspec_overrides.yaml"
  GENERATED=0
  if [ ! -f "$OVERRIDES" ]; then
    cat > "$OVERRIDES" <<EOF
dependency_overrides:
  hooks: 2.2.0
  wasm_components:
    path: $WASM_DART/pkg/wasm_components
  wasm_tools:
    path: $WASM_DART/pkg/wasm_tools
EOF
    GENERATED=1
  fi
  restore() {
    [ "$GENERATED" = 1 ] && rm -f "$OVERRIDES" || true
  }
  trap restore EXIT
  # A hooks_runner cache built by a different SDK breaks the hook dill;
  # drop it so pub get regenerates with the pinned SDK.
  rm -rf "$LAYOUT/.dart_tool/hooks_runner"
  ( cd "$LAYOUT" && "$DART" pub get >/dev/null && PATH="$(dirname "$DART"):$HOME/.cargo/bin:$PATH" ./tool/build.sh )
  restore; trap - EXIT
fi

for f in layout_solver layout_focus layout_hang; do
  [ -f "$LAYOUT/bin/$f.wasm" ] || { echo "missing $LAYOUT/bin/$f.wasm" >&2; exit 1; }
done

# --- 2. assemble the site tree -------------------------------------------------
echo "=== assembling site at $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/plugins"

# name | component stem | description (no pipes inside fields)
DIST='tina/layout-solver|layout_solver|The built-in grid solver as an installable layout strategy (tina:layout@1.0.0). Identical rects to the compiled-in solver by construction.
tina/layout-focus|layout_focus|Weighted-track layout strategy: equal-share weighted tracks (65/35 becomes 50/50) - the deliberately different strategy proving swappability.
tina/layout-hang|layout_hang|The wedge fixture: solve never returns; the host epoch-kills it and the TUI falls back. For testing strategy timeout handling.'
VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$LAYOUT/pubspec.yaml" | head -1)"
[ -n "$VERSION" ] || { echo "no version in $LAYOUT/pubspec.yaml" >&2; exit 1; }
: > /tmp/registry_dist.$$
echo "$DIST" | while IFS='|' read -r name file description; do
  [ -n "$name" ] || continue
  slug="$(echo "$name" | tr '/' '-')"
  cp "$LAYOUT/bin/$file.wasm" "$OUT/plugins/$slug.component.wasm"
  echo "$name $VERSION $slug $file $description" >> /tmp/registry_dist.$$
done

# shellcheck disable=SC2016
DART="$DART" OUT="$OUT" LAYOUT="$LAYOUT" CATALOG="$ROOT/tool/registry_site/catalog.json" \
  python3 "$ROOT/tool/registry_site/generate_site.py" /tmp/registry_dist.$$

rm -f /tmp/registry_dist.$$
cp "$ROOT/tool/registry_site/README.md" "$OUT/README.md"

# --- 3. sign (optional) ---------------------------------------------------------
if [ -n "$SIGN_KEY" ]; then
  command -v minisign >/dev/null 2>&1 || { echo "minisign not installed (brew/apt install minisign)" >&2; exit 1; }
  echo "=== signing registry.json with the provided key (legacy format)"
  ( cd "$OUT" && printf '\n' | minisign -S -l -s "$SIGN_KEY" -m registry.json -x registry.json.minisig 2>/dev/null )
  echo "signed: $OUT/registry.json.minisign"
else
  echo "=== unsigned build (production: Nick signs registry.json with the release key before deploy;"
  echo "    see README.md in the site tree)"
fi

echo "=== site tree:"
find "$OUT" -type f | sort | sed "s|^|  |"
