#!/bin/sh
# tina installer — downloads the latest GitHub release, verifies it against a
# minisign signature over the checksum manifest, and installs the binary.
#
#   curl -fsSL https://raw.githubusercontent.com/nmfisher/tina/main/install.sh | sh
#   # or download first, read it, then run:
#   sh install.sh [--dir DIR] [--insecure-checksum-only] [--version vX.Y.Z]
#
# Trust model (be honest about it): this script arrives over the same channel
# as the artifacts, so it cannot bootstrap trust from nothing. What the
# embedded minisign public key buys is a pinned verification root: a tampered
# or maliciously replaced release asset fails verification even if the GitHub
# release page itself served it. It does not defend against the nmfisher/tina
# GitHub account being compromised — pin --version and audit if you need that.
#
# Flags:
#   --dir DIR                  install directory (default: ~/.local/bin)
#   --version vX.Y.Z           install a specific tag instead of latest
#   --insecure-checksum-only   skip signature verification (checksum only)
set -eu

REPO='nmfisher/tina'
# Pin: minisign public key for release manifests. Must match minisign.pub in
# the repository root; rotate BOTH together.
PUBKEY_COMMENT='minisign public key 998FE64CB07F896A'
PUBKEY='RWRqiX+wTOaPmS7+JVz0pccep+0NBr6xDpLrf37v054BXCPDnGbpma92'

INSTALL_DIR="${TINA_INSTALL_DIR:-$HOME/.local/bin}"
VERSION=''
VERIFY_SIG=1

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || die '--dir needs a value'; INSTALL_DIR=$2; shift 2 ;;
    --version) [ $# -ge 2 ] || die '--version needs a value'; VERSION=$2; shift 2 ;;
    --insecure-checksum-only) VERIFY_SIG=0; shift ;;
    *) die "unknown flag: $1 (see --help usage in the header)" ;;
  esac
done

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 ||
  die 'need curl or wget to download'
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
  die 'need sha256sum or shasum to verify checksums'

fetch() { # fetch URL OUT — fatal on failure
  fetch_soft "$1" "$2" || die "download failed: $1"
}

fetch_soft() { # fetch_soft URL OUT — returns non-zero on failure (silent)
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2" 2>/dev/null
  else
    wget -qO "$2" "$1" 2>/dev/null
  fi
}

# --- scratch space ------------------------------------------------------------
TMP=$(mktemp -d) || die 'mktemp failed'
trap 'rm -rf "$TMP"' EXIT

# --- resolve the release ----------------------------------------------------
if [ -n "$VERSION" ]; then
  RELEASE_URL="https://github.com/$REPO/releases/download/$VERSION"
  TAG="$VERSION"
else
  API='https://api.github.com/repos/'"$REPO"'/releases/latest'
  fetch "$API" "$TMP/release.json"
  TAG=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$TMP/release.json" | head -1)
  [ -n "$TAG" ] || die 'could not resolve latest release tag (rate limited? try --version vX.Y.Z)'
  RELEASE_URL="https://github.com/$REPO/releases/download/$TAG"
  say "latest release: $TAG"
fi

# --- detect platform ---------------------------------------------------------
OS=$(uname -s); ARCH=$(uname -m)
case "$OS" in
  Linux) OS_PART='linux' ;;
  Darwin) OS_PART='macos' ;;
  *) die "unsupported OS: $OS (release assets cover linux + macos)" ;;
esac
case "$ARCH" in
  x86_64|amd64) ARCH_PART='x64' ;;
  aarch64|arm64) ARCH_PART='arm64' ;;
  *) die "unsupported architecture: $ARCH" ;;
esac
ASSET="tina-${TAG}-${OS_PART}-${ARCH_PART}.tar.gz"
say "asset: $ASSET"

# --- download ----------------------------------------------------------------
fetch "$RELEASE_URL/$ASSET"            "$TMP/$ASSET"
# Newer releases carry an aggregate sha256sums.txt (minisign-signed); older
# ones only have a per-asset .sha256. Accept both; signature verification
# requires the aggregate manifest.
if fetch_soft "$RELEASE_URL/sha256sums.txt" "$TMP/sha256sums.txt"; then
  HAVE_MANIFEST=1
  if [ "$VERIFY_SIG" = 1 ]; then
    if ! fetch_soft "$RELEASE_URL/sha256sums.txt.minisig" "$TMP/sha256sums.txt.minisig"; then
      die "release $TAG has an unsigned manifest; use --insecure-checksum-only to accept checksum-only verification"
    fi
  fi
else
  HAVE_MANIFEST=0
  fetch "$RELEASE_URL/$ASSET.sha256" "$TMP/$ASSET.sha256"
fi

# --- verify -------------------------------------------------------------------
SUM='sha256sum'; command -v sha256sum >/dev/null 2>&1 || SUM='shasum -a 256'
if [ "$HAVE_MANIFEST" = 1 ]; then
  LINE=$(grep " $ASSET\$" "$TMP/sha256sums.txt" || true)
  [ -n "$LINE" ] || die "$ASSET missing from sha256sums.txt"
  EXPECTED=$(printf '%s\n' "$LINE" | awk '{print $1}')
else
  EXPECTED=$(awk '{print $1}' "$TMP/$ASSET.sha256")
fi
ACTUAL=$($SUM "$TMP/$ASSET" | awk '{print $1}')
[ "$ACTUAL" = "$EXPECTED" ] ||
  die "checksum mismatch for $ASSET (expected $EXPECTED, got $ACTUAL)"
say "checksum ok: $ASSET"

if [ "$VERIFY_SIG" = 1 ]; then
  [ "$HAVE_MANIFEST" = 1 ] ||
    die "release $TAG predates signed manifests — use --insecure-checksum-only to accept checksum-only verification"
  command -v minisign >/dev/null 2>&1 ||
    die 'minisign is required for signature verification — install it
  (apt install minisign / brew install minisign), or re-run with
  --insecure-checksum-only to skip it (checksums only, no authenticity)'
  printf '%s\n%s\n' "$PUBKEY_COMMENT" "$PUBKEY" > "$TMP/release.pub"
  minisign -V -q -p "$TMP/release.pub" -x "$TMP/sha256sums.txt.minisig" \
    -m "$TMP/sha256sums.txt" ||
    die 'SIGNATURE VERIFICATION FAILED — do not install this release'
  say "signature ok: sha256sums.txt (key $PUBKEY_COMMENT)"
fi

# --- install --------------------------------------------------------------------
mkdir -p "$INSTALL_DIR" || die "cannot create $INSTALL_DIR"
tar -xzf "$TMP/$ASSET" -C "$TMP"
# The bundle contains the `tina` binary at its root; find it if nested.
BIN=$(find "$TMP" -name tina -type f | head -1)
[ -n "$BIN" ] || die 'tina binary not found in the bundle'
chmod +x "$BIN" && mv "$BIN" "$INSTALL_DIR/tina"
say "installed: $INSTALL_DIR/tina"
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) say "NOTE: $INSTALL_DIR is not on your PATH — add it to your shell profile." ;;
esac
"$INSTALL_DIR/tina" --version 2>/dev/null || true
