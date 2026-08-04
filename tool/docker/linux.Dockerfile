# Builds the tina CLI bundle for the container's platform (linux/arm64 or
# linux/amd64). Driven by ../build_bundle.sh, which sets --platform and extracts
# the resulting build/cli/<os>_<arch>/bundle/. Mirrors the approach used by
# packages/dart_notcurses/tool/docker: the build runs in the image's own
# filesystem (no bind-mount) for reproducibility.
FROM dart:3.12

# tina's native build hook (packages/dart_notcurses/hook/build.dart) needs
# clang — native_toolchain_c's CBuilder requires it (gcc alone won't do) — plus
# the dev headers libnotcurses_merged.so links against (-ltinfo -lunistring
# -ldeflate). build-essential provides ar/ld for the link step.
RUN apt-get update && apt-get install -y --no-install-recommends \
        clang build-essential libtinfo-dev libunistring-dev libdeflate-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

# The whole workspace (bin/, lib/, packages/, data/, pubspec). .dockerignore at
# the repo root keeps build/, .git, .dart_tool out of the context.
COPY . /work

RUN dart pub get && dart build cli -t bin/tina.dart
# Bundle now at /work/build/cli/<os>_<arch>/bundle/
