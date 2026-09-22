#!/bin/sh
# tina installer — downloads the latest GitHub release, verifies it against a
# minisign signature over the checksum manifest, and installs a private bundle.
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
#   --dir DIR                  launcher directory (default: ~/.local/bin)
#   --bundle-dir DIR           private bundle (default: $XDG_DATA_HOME/tina,
#                              or ~/.local/share/tina)
#   --version vX.Y.Z           install a specific tag instead of latest
#   --insecure-checksum-only   skip signature verification (checksum only)
set -eu

REPO='nmfisher/tina'
# Pin: minisign public key for release manifests. Must match minisign.pub in
# the repository root; rotate BOTH together.
PUBKEY_COMMENT='minisign public key 998FE64CB07F896A'
PUBKEY='RWRqiX+wTOaPmS7+JVz0pccep+0NBr6xDpLrf37v054BXCPDnGbpma92'

INSTALL_DIR="${TINA_INSTALL_DIR:-$HOME/.local/bin}"
BUNDLE_DIR="${TINA_BUNDLE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/tina}"
VERSION=''
VERIFY_SIG=1

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || die '--dir needs a value'; INSTALL_DIR=$2; shift 2 ;;
    --bundle-dir) [ $# -ge 2 ] || die '--bundle-dir needs a value'; BUNDLE_DIR=$2; shift 2 ;;
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
STAGE=''
LAUNCH_STAGE=''
MOVED_OLD=0
INSTALLED=0
DONE=0
cleanup() {
  if [ "$DONE" = 0 ]; then
    # A failed launcher replacement must leave the previous install usable.
    if [ "$INSTALLED" = 1 ]; then
      mv "$BUNDLE_DIR" "$STAGE/failed" || return
    fi
    if [ "$MOVED_OLD" = 1 ]; then
      mv "$BUNDLE_DIR.old" "$BUNDLE_DIR" || return
    fi
  fi
  [ -z "$STAGE" ] || rm -rf "$STAGE"
  [ -z "$LAUNCH_STAGE" ] || rm -rf "$LAUNCH_STAGE"
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

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

# Keep ownership checks aligned with isOwnedBundleRoot in updater.dart. Neither
# installer nor updater may rename a shared prefix or follow a linked bundle.
owned_bundle() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  [ -f "$1/.tina-bundle" ] && [ ! -L "$1/.tina-bundle" ] || return 1
  [ -f "$1/bin/tina" ] && [ ! -L "$1/bin/tina" ] || return 1
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ ! -L "$entry" ] || return 1
    case "$(basename "$entry")" in
      bin|lib)
        [ -d "$entry" ] || return 1
        for f in "$entry"/* "$entry"/.[!.]* "$entry"/..?*; do
          [ -e "$f" ] || [ -L "$f" ] || continue
          [ -f "$f" ] && [ ! -L "$f" ] || return 1
          case "$(basename "$entry")/$(basename "$f")" in
            bin/tina|lib/libtina*|lib/libnotcurses*|lib/libsqlite3.so|lib/libsqlite3.dylib) ;;
            *) return 1 ;;
          esac
        done
        ;;
      .*) [ -f "$entry" ] || return 1 ;;
      *) return 1 ;;
    esac
  done
}

# --- install -----------------------------------------------------------------
# Canonicalize parent directories so launcher targets are absolute, including
# --dir/--bundle-dir arguments containing spaces or relative paths.
mkdir -p "$INSTALL_DIR" "$(dirname "$BUNDLE_DIR")"
INSTALL_DIR=$(cd "$INSTALL_DIR" && pwd -P)
BUNDLE_DIR="$(cd "$(dirname "$BUNDLE_DIR")" && pwd -P)/$(basename "$BUNDLE_DIR")"
case "$(basename "$BUNDLE_DIR")" in
  .|..|/) die 'bundle directory must have its own name' ;;
esac
case "$INSTALL_DIR/" in
  "$BUNDLE_DIR/"*) die 'launcher directory must be outside the private bundle' ;;
esac
[ ! -d "$INSTALL_DIR/tina" ] || die "$INSTALL_DIR/tina is a directory"
if [ -e "$BUNDLE_DIR" ] || [ -L "$BUNDLE_DIR" ]; then
  owned_bundle "$BUNDLE_DIR" || die "$BUNDLE_DIR is not an exclusively-tina bundle; leaving it untouched"
fi
if [ -e "$BUNDLE_DIR.old" ] || [ -L "$BUNDLE_DIR.old" ]; then
  owned_bundle "$BUNDLE_DIR.old" || die "$BUNDLE_DIR.old is not an exclusively-tina bundle; leaving it untouched"
fi

tar -xzf "$TMP/$ASSET" -C "$TMP"
SOURCE="$TMP/bundle"
[ -f "$SOURCE/bin/tina" ] || die 'bundle/bin/tina not found in the archive'
[ ! -L "$SOURCE/.tina-bundle" ] || die 'archive has a linked bundle marker'
printf 'tina bundle root\n' > "$SOURCE/.tina-bundle"
owned_bundle "$SOURCE" || die 'archive is not a tina-only bundle'
chmod +x "$SOURCE/bin/tina"

# Stage on the destination filesystem before moving the live bundle. Keep bin/
# and lib/ together: Dart resolves native assets relative to the real executable.
STAGE=$(mktemp -d "$(dirname "$BUNDLE_DIR")/.tina-install.XXXXXX")
cp -R "$SOURCE" "$STAGE/bundle"
LAUNCH_STAGE=$(mktemp -d "$INSTALL_DIR/.tina-launcher.XXXXXX")
ln -s "$BUNDLE_DIR/bin/tina" "$LAUNCH_STAGE/tina"
if [ -d "$BUNDLE_DIR.old" ]; then
  rm -rf "$BUNDLE_DIR.old"
fi
if [ -d "$BUNDLE_DIR" ]; then
  mv "$BUNDLE_DIR" "$BUNDLE_DIR.old"
  MOVED_OLD=1
fi
mv "$STAGE/bundle" "$BUNDLE_DIR"
INSTALLED=1
# Rename the link over the old binary/link, never copy through an existing link.
# Legacy libraries in the shared ../lib directory remain untouched.
mv -f "$LAUNCH_STAGE/tina" "$INSTALL_DIR/tina"
DONE=1

say "installed bundle: $BUNDLE_DIR"
say "launcher: $INSTALL_DIR/tina -> $BUNDLE_DIR/bin/tina"
say 'Future updates: run /update in tina, then restart.'
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) say "NOTE: $INSTALL_DIR is not on your PATH — add it to your shell profile." ;;
esac
"$INSTALL_DIR/tina" --version 2>/dev/null || true
