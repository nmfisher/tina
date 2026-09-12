// Builds (links) the vendored Wasmtime native library into the package's
// native assets, one static archive per target under
// native/lib/<os>_<arch>/ — the same shape dart_notcurses uses for
// libnotcurses-core.a (see packages/dart_notcurses/hook/build.dart).
//
// Wasmtime v36.0.15 (LTS), C API "full" profile, from
// https://github.com/bytecodealliance/wasmtime/releases/tag/v36.0.15.
// Provenance (sha256 of the release tarballs, verified at download time):
//   wasmtime-v36.0.15-x86_64-linux-c-api.tar.xz  06b232dc824401323e58dd5bae837ed7aa54b94d6e0b1adca470ae37ec7e1ec4
//   wasmtime-v36.0.15-aarch64-linux-c-api.tar.xz a3425be4f270cf0e32f63658df8350d032deb596051a0a043e1af3f5f8f12b8e
//   wasmtime-v36.0.15-aarch64-macos-c-api.tar.xz c9dcfcb1a1b4d8b25576dae846519238c80d9906b917d78425688d211be72faf
// Each vendored archive carries its own SHA256SUMS under
// native/lib/<os>_<arch>/. The "full" profile is required: the "min" profile
// cannot compile or validate modules (no wasmtime_module_new /
// wasmtime_module_validate), which Phase 1's byte validation needs. WASI
// symbols exist inside the archive but tina never initializes WASI — API 1
// forbids host capabilities (.tickets/tin-w4sm.md).
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final targetOS = input.config.code.targetOS;
    final targetArch = input.config.code.targetArchitecture;

    final libDir = p.join(
      input.packageRoot.toFilePath(),
      'native',
      'lib',
      '${targetOS.name}_${targetArch.name}',
    );

    final archive = p.join(libDir, 'libwasmtime.a');
    if (!File(archive).existsSync()) {
      throw UnsupportedError(
        'No vendored Wasmtime static library for $targetOS/$targetArch.\n'
        'Looked in: $archive\n'
        'Vendored archives ship under native/lib/<os>_<arch>/ '
        '(wasmtime v36.0.15 C API, full profile).',
      );
    }

    // -force_load (macOS ld64) / --whole-archive (GNU ld) is LOAD-BEARING, as in
    // dart_notcurses: the @Native externals bind wasmtime symbols directly and
    // the glue object references none of them, so without forcing the whole
    // archive in the linker would drop every wasmtime object and the shared
    // library would export nothing.
    final flags = <String>[
      '-L$libDir',
      if (targetOS == OS.macOS) ...[
        '-Wl,-w', // suppress benign "built for newer macOS version" warnings
        '-force_load',
        archive,
      ] else ...[
        '-Wl,--whole-archive',
        archive,
        '-Wl,--no-whole-archive',
      ],
      '-lm',
      '-lpthread',
    ];

    final cbuilder = CBuilder.library(
      name: 'wasmtime_merged',
      assetName: 'dart_wasmtime.dart',
      sources: [
        p.join('native', 'src', 'glue.c'),
      ],
      flags: flags,
      language: Language.c,
    );

    await cbuilder.run(input: input, output: output);
  });
}
