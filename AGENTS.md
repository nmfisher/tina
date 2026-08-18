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