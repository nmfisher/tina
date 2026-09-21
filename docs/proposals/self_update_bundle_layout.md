# Proposal: give the self-updater a bundle directory it actually owns

## Context (2026-09-20 incident)

tina's updater decides its bundle root structurally: exe → `<root>/bin/tina`
→ `<root>`. The default install (`install.sh`) puts `bin/tina` + `lib/` into
`~/.local`, so the "bundle root" for a default install was `~/.local` itself.
`/update` to v0.7.1 renamed the entire directory to `~/.local.old` and moved a
fresh `bin/ + lib/` bundle into place; the next tina launch swept
`~/.local.old` away. Everything else living in `~/.local` — uv tools and all
their bin shims, `share/` (including signal-cli's linked-device store:
account.db, recipient/group/identity stores), `state/`, the Hermes installer's
binaries — was replaced and then destroyed, while a daemon kept running on the
deleted inodes and reported healthy.

v0.7.2 ships a guard (`.tina-bundle` marker + exclusive-contents check) so the
updater refuses any directory it doesn't exclusively own — renames nothing,
deletes nothing, and tells the user to re-run install.sh. That makes the
failure impossible; this proposal removes the *condition*: an install layout
in which the bundle root and a shared XDG prefix are the same directory.

## Proposal

Install the bundle where it is the only tenant:

    ~/.local/share/tina/bundle/bin/tina
    ~/.local/share/tina/bundle/lib/libnotcurses_merged.dylib …
    ~/.local/bin/tina   # wrapper: exec ~/.local/share/tina/bundle/bin/tina "$@"

- `~/.local/bin` is already on PATH; the wrapper is transparent.
- `Platform.resolvedExecutable` under `exec` is the real binary, so the
  updater's structural walk lands on `~/.local/share/tina/bundle` — a
  directory created by and for tina, where exclusive ownership is real
  rather than proven by heuristics. The 0.7.2 marker/ownership guard stays as
  belt-and-braces.
- `install.sh` gains a migration path: detect a legacy layout (real binary at
  `<dir>/tina`), move the bundle to `~/.local/share/tina/bundle`, write the
  wrapper, remove tina's old `lib/` files — deleting nothing that isn't
  tina's.
- `.github/workflows/release.yml`'s installer check (Verify installer against
  the published release) asserts the new layout: wrapper exec-able, bundle
  under `~/.local/share/tina/bundle`, native lib loading from `bundle/lib/`,
  `tina --version` healthy through the wrapper.
- Shared-prefix installs keep working exactly as 0.7.2+: `/update` refuses
  with a pointer to install.sh, which updates in place, touching only tina's
  files.

## Alternatives considered

- **Guard only (shipped in 0.7.2):** safe, but leaves `/update` permanently
  unavailable for default installs — every update routes through install.sh.
- **Symlink farm** (bin symlinks into a versioned dir): still writes into the
  shared `bin/`, still needs per-name collision checks, and macOS resolves
  `resolvedExecutable` to the symlink target — same structural trap.
- **OS package managers** (brew, apt): a proper ownership model, but changes
  the distribution story and the minisign trust-chain shape.

## Risks / notes

- The wrapper is a two-line `exec` script; signals and tty pass through, and
  the signed Mach-O is untouched, so Gatekeeper/notarization is unaffected.
- Anything that hardcoded `~/.local/lib` paths to tina's dylibs breaks at
  migration; release notes must call it out.
- First launch after migration may warn "not marked" if the marker step is
  missed — the migration must write `.tina-bundle` into the moved bundle.
