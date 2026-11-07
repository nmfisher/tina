#!/bin/sh
# Resolve every owned package's dependencies so analyze/test/check_architecture
# can run locally (mirrors CI's pub-get loop).
set -e
for spec in packages/*/pubspec.yaml packages/libraries/*/pubspec.yaml packages/plugins/*/pubspec.yaml apps/*/pubspec.yaml tool/repository/pubspec.yaml; do
  dir=$(dirname "$spec")
  if [ ! -f "$dir/.dart_tool/package_config.json" ]; then
    echo "== $dir"
    (cd "$dir" && dart pub get >/dev/null 2>&1) || (cd "$dir" && dart pub get --offline >/dev/null 2>&1) || echo "FAILED: $dir"
  fi
done
echo DONE
