# AGENTS.md — Upward discovery for agent sessions working in tina.

## Release process

To cut a new tina release:

1. **Bump version** in `pubspec.yaml` (semver, e.g. `1.4.3`).

2. **Tag and push**:
   ```bash
   git tag v1.4.3
   git push origin v1.4.3
   ```

3. **GitHub Actions** fires the `release` workflow (`.github/workflows/release.yml`), which:
   - Builds 3 targets natively/macOS and via Docker (linux-x64, linux-arm64)
   - Produces per-target tarballs: `tina-1.4.3-macos-arm64.tar.gz`, etc.
   - Creates the GitHub release with `softprops/action-gh-release@v2`, attaching all artifacts.

4. **Announce** the new release / tag as appropriate.

## Branch-prefix rule (Nick, 2026-08-18)

- NEVER use the `asb/` prefix for branches, refs, or worktrees that I create myself.
- The `asb/` prefix is RESERVED for the sandbox scripts (`sandbox.sh`, `clean.sh`).
- Diagnostic refs and temporary branches must use a different prefix (e.g. `diag/`, `tmp/`).

## Notcurses-only backend (global memory)

- Nick ONLY cares about the `dart_notcurses` backend; never work on, test, or spend effort on the ANSI backend.
- This applies to instructions given to sandbox agents working on tina too.

## tina is a PUBLIC repository (global memory)

- NEVER push secrets, API keys, tokens, credentials, personal/private data, or anything undesirable to disclose publicly.
- Env-var *names* are fine; values must never be pushed.
- When in doubt, ask before pushing.

## PR-URL rule (global memory)

- Whenever a PR is raised (by a sandbox agent, by me, or by anyone), ALWAYS include the PR URL in my reply — every time, without being asked.